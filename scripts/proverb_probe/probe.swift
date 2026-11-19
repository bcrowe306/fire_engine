// ProVerb's reference probe (macOS only, outside the app and the engine):
// loads an installed reverb Audio Unit and renders test signals through it
// offline, to measure what it does at its output. It never looks inside
// the plug-in: only its parameters, as the host sees them, and its sound.
//
//   swiftc -O scripts/proverb_probe/probe.swift -o .build/proverb_probe
//   .build/proverb_probe list "ValhallaRoom"
//   .build/proverb_probe render "ValhallaRoom" jobs.json OUT_DIR
//
// A job: {"name": "...", "params": {"<param name>": value, ...},
// "signal": "impulse" | "noise" | "sine:<hz>", "seconds": 6}. Values are
// the parameter's own (as `list` prints its range). Renders are 48 kHz
// stereo float WAVs.

import AVFoundation
import AudioToolbox
import Foundation

let SR = 48_000.0

func find(_ name: String) -> AVAudioUnitComponent? {
    let any = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
    return AVAudioUnitComponentManager.shared().components(matching: any).first { $0.name.contains(name) }
}

func load(_ c: AVAudioUnitComponent) -> AVAudioUnit {
    var unit: AVAudioUnit?
    let done = DispatchSemaphore(value: 0)
    AVAudioUnit.instantiate(with: c.audioComponentDescription, options: [.loadOutOfProcess]) { u, err in
        if let err = err { fputs("instantiate: \(err)\n", stderr) }
        unit = u
        done.signal()
    }
    done.wait()
    guard let u = unit else { fputs("could not load \(c.name)\n", stderr); exit(1) }
    return u
}

func params(_ u: AVAudioUnit) -> [AUParameter] { u.auAudioUnit.parameterTree?.allParameters ?? [] }

func list(_ u: AVAudioUnit) {
    for p in params(u) {
        var line = "\(p.displayName)\t\(p.minValue)..\(p.maxValue)\tnow \(p.value) (\(p.string(fromValue: nil)))"
        if let vs = p.valueStrings { line += "\tchoices: " + vs.joined(separator: " | ") }
        else {
            let steps = 4
            let shown = (0...steps).map { k -> String in
                var v = p.minValue + (p.maxValue - p.minValue) * Float(k) / Float(steps)
                return "\(v)=\(p.string(fromValue: &v))"
            }
            line += "\t" + shown.joined(separator: ", ")
        }
        print(line)
    }
}

struct Job: Decodable {
    let name: String
    let params: [String: Float]
    let signal: String
    let seconds: Double
}

func signal(_ kind: String, frames: Int) -> [Float] {
    var x = [Float](repeating: 0, count: frames)
    if kind == "impulse" {
        x[0] = 1
    } else if kind == "noise" {
        var seed: UInt64 = 12345
        for i in 0..<min(frames, Int(SR * 0.05)) { // a 50 ms burst
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            x[i] = (Float(seed >> 40) / Float(1 << 24)) * 2 - 1
        }
    } else if kind.hasPrefix("sine:"), let hz = Double(kind.dropFirst(5)) {
        for i in 0..<min(frames, Int(SR * 1.0)) { x[i] = Float(0.5 * sin(2 * Double.pi * hz * Double(i) / SR)) } // a second of it
    }
    return x
}

func writeWav(_ path: String, _ l: [Float], _ r: [Float]) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 2)!
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count))!
    buf.frameLength = AVAudioFrameCount(l.count)
    for i in 0..<l.count { buf.floatChannelData![0][i] = l[i]; buf.floatChannelData![1][i] = r[i] }
    try file.write(from: buf)
}

func render(_ c: AVAudioUnitComponent, _ jobs: [Job], _ out: String) throws {
    for job in jobs {
        let u = load(c) // (a fresh one each: nothing left over from the last)
        let byName = Dictionary(params(u).map { ($0.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, v) in job.params {
            guard let p = byName[name] else { fputs("\(job.name): no parameter \(name)\n", stderr); exit(1) }
            p.value = v
        }
        let engine = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(u)
        engine.connect(player, to: u, format: fmt)
        engine.connect(u, to: engine.mainMixerNode, format: fmt)
        let frames = Int(SR * job.seconds)
        let x = signal(job.signal, frames: frames)
        let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        inBuf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { inBuf.floatChannelData![0][i] = x[i]; inBuf.floatChannelData![1][i] = x[i] }
        try engine.start()
        player.scheduleBuffer(inBuf, at: nil)
        player.play()
        var l = [Float](), r = [Float]()
        let block = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        while l.count < frames {
            let n = AVAudioFrameCount(min(512, frames - l.count))
            let st = try engine.renderOffline(n, to: block)
            guard st == .success else { fputs("\(job.name): render \(st.rawValue)\n", stderr); exit(1) }
            for i in 0..<Int(block.frameLength) { l.append(block.floatChannelData![0][i]); r.append(block.floatChannelData![1][i]) }
        }
        engine.stop()
        try writeWav("\(out)/\(job.name).wav", l, r)
        print("wrote \(job.name)")
    }
}

let args = CommandLine.arguments
guard args.count >= 3, let comp = find(args[2]) else { fputs("usage: probe list|render NAME [jobs.json OUT_DIR] (no such Audio Unit?)\n", stderr); exit(1) }
if args[1] == "list" {
    print("\(comp.manufacturerName) \(comp.name) \(comp.versionString)")
    list(load(comp))
} else if args[1] == "render", args.count >= 5 {
    let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
    try FileManager.default.createDirectory(atPath: args[4], withIntermediateDirectories: true)
    try render(comp, jobs, args[4])
}
