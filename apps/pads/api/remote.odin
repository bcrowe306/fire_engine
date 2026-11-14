package pads_api

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// What the generated remote methods (gen_remote.odin) read their
// arguments with and answer by.

@(private)
remote_answer :: proc(out: ^strings.Builder, r: Result, value: any, err: string) {
	strings.write_string(out, `{"result": "`)
	fmt.sbprint(out, r)
	strings.write_string(out, `"`)
	if value != nil {
		data, merr := json.marshal(value, {use_enum_names = true}, context.temp_allocator)
		if merr == nil {
			strings.write_string(out, `, "value": `)
			strings.write_string(out, string(data))
		}
	}
	if err != "" {
		strings.write_string(out, `, "error": `)
		data, _ := json.marshal(err, allocator = context.temp_allocator)
		strings.write_string(out, string(data))
	}
	strings.write_string(out, "}")
}

@(private)
remote_error :: proc(api: ^Api, r: Result) -> string {
	if r == .Ok do return ""
	e, _ := last_error(api)
	return e
}

@(private)
remote_f64 :: proc(args: json.Object, name: string, ok: ^bool) -> f64 {
	#partial switch x in args[name] {
	case json.Float:   return f64(x)
	case json.Integer: return f64(x)
	}
	ok^ = false
	return 0
}

@(private)
remote_f64_or :: proc(args: json.Object, name: string, dflt: f64, ok: ^bool) -> f64 {
	if name not_in args do return dflt
	return remote_f64(args, name, ok)
}

@(private)
remote_f32 :: proc(args: json.Object, name: string, ok: ^bool) -> f32 {
	return f32(remote_f64(args, name, ok))
}

@(private)
remote_f32_or :: proc(args: json.Object, name: string, dflt: f32, ok: ^bool) -> f32 {
	if name not_in args do return dflt
	return remote_f32(args, name, ok)
}

@(private)
remote_enum_or :: proc(args: json.Object, name: string, names: []string, dflt: i32, ok: ^bool) -> i32 {
	if name not_in args do return dflt
	return remote_enum(args, name, names, ok)
}

@(private)
remote_i64 :: proc(args: json.Object, name: string, ok: ^bool) -> i64 {
	#partial switch x in args[name] {
	case json.Integer: return i64(x)
	case json.Float:   if f64(i64(x)) == f64(x) do return i64(x)
	}
	ok^ = false
	return 0
}

@(private)
remote_i64_or :: proc(args: json.Object, name: string, dflt: i64, ok: ^bool) -> i64 {
	if name not_in args do return dflt
	return remote_i64(args, name, ok)
}

// A list of whole numbers (a JSON array). Temporary.
@(private)
remote_i64s :: proc(args: json.Object, name: string, ok: ^bool) -> []i64 {
	arr, is := args[name].(json.Array)
	if !is {
		ok^ = false
		return nil
	}
	out := make([]i64, len(arr), context.temp_allocator)
	for v, k in arr {
		#partial switch x in v {
		case json.Integer: out[k] = i64(x)
		case json.Float:   // (numbers are parsed as floats: a whole one is fine)
			if f64(i64(x)) == f64(x) do out[k] = i64(x)
			else do ok^ = false
		case:              ok^ = false
		}
	}
	return out
}

@(private)
remote_sub :: proc(args: json.Object, name: string, ok: ^bool) -> Subscription {
	return Subscription(remote_i64(args, name, ok))
}

@(private)
remote_bool :: proc(args: json.Object, name: string, ok: ^bool) -> bool {
	if x, is := args[name].(json.Boolean); is do return bool(x)
	ok^ = false
	return false
}

@(private)
remote_bool_or :: proc(args: json.Object, name: string, dflt: bool, ok: ^bool) -> bool {
	if name not_in args do return dflt
	return remote_bool(args, name, ok)
}

@(private)
remote_string :: proc(args: json.Object, name: string, ok: ^bool) -> string {
	if x, is := args[name].(json.String); is do return string(x)
	ok^ = false
	return ""
}

// An enum argument, by its name ("Cowbell") or its number.
@(private)
remote_enum :: proc(args: json.Object, name: string, names: []string, ok: ^bool) -> i32 {
	#partial switch x in args[name] {
	case json.String:
		for n, k in names do if n == string(x) do return i32(k)
	case json.Integer:
		return i32(x)
	}
	ok^ = false
	return 0
}
