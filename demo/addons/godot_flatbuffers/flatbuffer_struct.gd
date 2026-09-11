class_name FlatBufferStruct
extends RefCounted

## Read-side view over an inline struct (fixed layout, no vtable).
## Obtain via FlatBuffer.get_struct(slot) for a struct field,
## FlatBuffer.get_vector_struct(slot, i, size) for struct vector elements,
## or wrap() with an absolute buffer position.
## All accessors take the member's byte offset within the struct, which the
## code generator bakes into typed getters — never hand-computed by callers.

# self-preload: resolves without the global class cache (headless --script use)
const _Self := preload("res://addons/godot_flatbuffers/flatbuffer_struct.gd")

var _buf: PackedByteArray
var _pos: int  # absolute position of the struct's first byte

static func wrap(buf: PackedByteArray, pos: int) -> _Self:
	var s: _Self = _Self.new()
	s._buf = buf
	s._pos = pos
	return s

func is_valid() -> bool:
	return _buf != null and _pos >= 0 and _pos < _buf.size()

# ── scalars (off = byte offset of member within the struct) ─

func get_bool(off: int, d := false) -> bool:
	return _buf.decode_u8(_pos + off) != 0 if _in(off, 1) else d

func get_i8(off: int, d := 0) -> int:
	return _buf.decode_s8(_pos + off) if _in(off, 1) else d

func get_u8(off: int, d := 0) -> int:
	return _buf.decode_u8(_pos + off) if _in(off, 1) else d

func get_i16(off: int, d := 0) -> int:
	return _buf.decode_s16(_pos + off) if _in(off, 2) else d

func get_u16(off: int, d := 0) -> int:
	return _buf.decode_u16(_pos + off) if _in(off, 2) else d

func get_i32(off: int, d := 0) -> int:
	return _buf.decode_s32(_pos + off) if _in(off, 4) else d

func get_u32(off: int, d := 0) -> int:
	return _buf.decode_u32(_pos + off) if _in(off, 4) else d

func get_i64(off: int, d := 0) -> int:
	return _buf.decode_s64(_pos + off) if _in(off, 8) else d

func get_u64(off: int, d := 0) -> int:
	# Values above i64::MAX return the raw bit pattern as a negative int;
	# use get_u64_hex/get_u64_bytes for the full unsigned range.
	return _buf.decode_u64(_pos + off) if _in(off, 8) else d

func get_u64_hex(off: int, d := "") -> String:
	if not _in(off, 8):
		return d
	return "0x%08x%08x" % [_buf.decode_u32(_pos + off + 4), _buf.decode_u32(_pos + off)]

func get_u64_bytes(off: int, d := PackedByteArray()) -> PackedByteArray:
	return _buf.slice(_pos + off, _pos + off + 8) if _in(off, 8) else d

func get_f32(off: int, d := 0.0) -> float:
	return _buf.decode_float(_pos + off) if _in(off, 4) else d

func get_f64(off: int, d := 0.0) -> float:
	return _buf.decode_double(_pos + off) if _in(off, 8) else d

## Nested struct member at byte offset `off` (structs may contain structs).
func get_struct(off: int) -> _Self:
	return null if not _in(off, 1) else _Self.wrap(_buf, _pos + off)

func _in(off: int, size: int) -> bool:
	return _buf != null and off >= 0 and _pos + off + size <= _buf.size()
