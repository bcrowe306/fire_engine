# Fire Engine
A realtime audio engine for music production, performence, sound design. Written in Odin.


# Engine Structure:
* Engine
  * Backend
    * WASAPI
    * CORE_AUDIO/MIDI
    * ALSA/JACK
    * ASIO
  * Engine
    * AudioGraph
      * Node based
      * Inputs/Outputs
      * Sample Accurate events
      * Multithreaded with a thread pool
    * Midi
      * Input/Output devices
      * Control Surfaces: Custom control surface sdk. Loaded through dynamic libraries
    * Common DSP
      * DSP primitives, Filters, Dynamics, Delays, FFT, Convolutions, 
      * Effects built on top of primitives
      * Devices: A custom CLAP like SDK/Interface for loading dynamic devices.
    * Sequencing/Arranging/Recording/Session
      * Sequencing based workflow
      * Arrange/timeline based workflow
      * Recording and loop recording
      * Clip based workflow
* Application
  * Allows applications to built on top of the engine
  * Flexible enough to build apps for SBC devices like raspberry pi, or full desktop DAWs
