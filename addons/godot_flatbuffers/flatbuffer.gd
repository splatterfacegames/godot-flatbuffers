class_name FlatBuffer
extends RefCounted

## Read-side view over a flatbuffer table.
## Obtain via FlatBuffer.root(bytes) for the root table, or
## FlatBuffer.at(bytes, table_offset) for a nested table.
## All field access is by vtable slot index (schema field order).

const _FBStruct := preload("res://addons/godot_flatbuffers/flatbuffer_struct.gd")

var _buf: PackedByteArray
var _pos: int  # absolute position of this table's soffset

static func root(buf: PackedByteArray) -> FlatBuffer:
	var fb := FlatBuffer.new()
	fb._buf = buf
	if buf.size() < 4:
		fb._pos = -1
		return fb
	fb._pos = buf.decode_u32(0)
	return fb

## Root table of a `--size-prefixed` buffer (u32 length prefix at byte 0).
static func root_size_prefixed(buf: PackedByteArray) -> FlatBuffer:
	var fb := FlatBuffer.new()
	fb._buf = buf
	if buf.size() < 8:
		fb._pos = -1
		return fb
	fb._pos = 4 + buf.decode_u32(4)
	return fb

## True when buf carries the given 4-byte file_identifier
## (set via flatc's `file_identifier` / FlatBufferBuilder.finish).
static func buffer_has_identifier(buf: PackedByteArray, file_identifier: String, size_prefixed := false) -> bool:
	var off := 4 if size_prefixed else 0
	var id := file_identifier.to_utf8_buffer()
	return id.size() == 4 and buf.size() >= off + 8 and buf.slice(off + 4, off + 8) == id

static func at(buf: PackedByteArray, pos: int) -> FlatBuffer:
	var fb := FlatBuffer.new()
	fb._buf = buf
	fb._pos = pos
	return fb

func is_valid() -> bool:
	return _buf != null and _pos >= 4 and _pos + 4 <= _buf.size()

# Absolute position of field's stored value, or -1 if absent (use default).
func field_pos(slot: int) -> int:
	if _pos < 4 or _pos + 4 > _buf.size():
		return -1
	var vt := _pos - _buf.decode_s32(_pos)
	var idx := 4 + slot * 2
	if vt < 0 or idx + 2 > _buf.decode_u16(vt):
		return -1
	var rel := _buf.decode_u16(vt + idx)
	return _pos + rel if rel != 0 else -1

## True when a field is explicitly present in the buffer (not the schema
## default). Needed for `force_defaults` output and `optional` scalars.
func has_field(slot: int) -> bool:
	return field_pos(slot) >= 0

# Offset of the (v)table/string/vector a uoffset field points at, or -1.
func _indirect(slot: int) -> int:
	var p := field_pos(slot)
	if p < 0:
		return -1
	return p + _buf.decode_u32(p)

# ── scalars ──────────────────────────────────────────────────

func get_bool(slot: int, d := false) -> bool:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_u8(p) != 0

func get_i8(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_s8(p)

func get_u8(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_u8(p)

func get_i16(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_s16(p)

func get_u16(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_u16(p)

func get_i32(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_s32(p)

func get_u32(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_u32(p)

func get_i64(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_s64(p)

func get_u64(slot: int, d := 0) -> int:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_u64(p)

## Full-range u64 accessor: returns "0x%016x". Use for values that may
## exceed i64::MAX — get_u64() returns their bit pattern as a negative int.
func get_u64_hex(slot: int, d := "") -> String:
	var p := field_pos(slot)
	if p < 0:
		return d
	return "0x%08x%08x" % [_buf.decode_u32(p + 4), _buf.decode_u32(p)]

## Full-range u64 accessor: the raw 8 little-endian bytes.
func get_u64_bytes(slot: int, d := PackedByteArray()) -> PackedByteArray:
	var p := field_pos(slot)
	return d if p < 0 else _buf.slice(p, p + 8)

func get_f32(slot: int, d := 0.0) -> float:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_float(p)

func get_f64(slot: int, d := 0.0) -> float:
	var p := field_pos(slot)
	return d if p < 0 else _buf.decode_double(p)

# ── strings / subtables ─────────────────────────────────────

func get_string(slot: int, d := "") -> String:
	var p := _indirect(slot)
	if p < 0:
		return d
	var n := _buf.decode_u32(p)
	return _buf.slice(p + 4, p + 4 + n).get_string_from_utf8()

func get_table(slot: int) -> FlatBuffer:
	var p := _indirect(slot)
	return null if p < 0 else FlatBuffer.at(_buf, p)

## Inline struct field (no vtable, data stored at the field position).
## Returns null when the field is absent.
func get_struct(slot: int) -> _FBStruct:
	var p := field_pos(slot)
	return null if p < 0 else _FBStruct.wrap(_buf, p)

## Root table of a nested flatbuffer embedded in a `[ubyte]` field
## (the `nested_flatbuffer` attribute pattern). Null when absent.
func get_nested_root(slot: int) -> FlatBuffer:
	var p := _indirect(slot)
	if p < 0:
		return null
	var base := p + 4  # skip the vector's length prefix; nested buffer starts there
	if base + 4 > _buf.size():
		return null
	return FlatBuffer.at(_buf, base + _buf.decode_u32(base))

# ── vectors ──────────────────────────────────────────────────

func vector_len(slot: int) -> int:
	var p := _indirect(slot)
	return 0 if p < 0 else _buf.decode_u32(p)

# Absolute position of vector element i (scalar or uoffset-to-table).
func _vec_elem(slot: int, i: int, elem_size: int) -> int:
	var p := _indirect(slot)
	if p < 0:
		return -1
	var n := _buf.decode_u32(p)
	if i < 0 or i >= n:
		return -1
	return p + 4 + i * elem_size

func get_vector_u8(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 1)
	return 0 if p < 0 else _buf.decode_u8(p)

func get_vector_i8(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 1)
	return 0 if p < 0 else _buf.decode_s8(p)

func get_vector_i16(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 2)
	return 0 if p < 0 else _buf.decode_s16(p)

func get_vector_u16(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 2)
	return 0 if p < 0 else _buf.decode_u16(p)

func get_vector_i32(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 4)
	return 0 if p < 0 else _buf.decode_s32(p)

func get_vector_u32(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 4)
	return 0 if p < 0 else _buf.decode_u32(p)

func get_vector_i64(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 8)
	return 0 if p < 0 else _buf.decode_s64(p)

func get_vector_u64(slot: int, i: int) -> int:
	var p := _vec_elem(slot, i, 8)
	return 0 if p < 0 else _buf.decode_u64(p)

## Full-range u64 element accessor, same rationale as get_u64_hex.
func get_vector_u64_hex(slot: int, i: int, d := "") -> String:
	var p := _vec_elem(slot, i, 8)
	if p < 0:
		return d
	return "0x%08x%08x" % [_buf.decode_u32(p + 4), _buf.decode_u32(p)]

func get_vector_f32(slot: int, i: int) -> float:
	var p := _vec_elem(slot, i, 4)
	return 0.0 if p < 0 else _buf.decode_float(p)

func get_vector_f64(slot: int, i: int) -> float:
	var p := _vec_elem(slot, i, 8)
	return 0.0 if p < 0 else _buf.decode_double(p)

func get_vector_bool(slot: int, i: int) -> bool:
	return get_vector_u8(slot, i) != 0

func get_vector_string(slot: int, i: int) -> String:
	var p := _vec_elem(slot, i, 4)
	if p < 0:
		return ""
	var sp := p + _buf.decode_u32(p)
	var n := _buf.decode_u32(sp)
	return _buf.slice(sp + 4, sp + 4 + n).get_string_from_utf8()

func get_vector_table(slot: int, i: int) -> FlatBuffer:
	var p := _vec_elem(slot, i, 4)
	if p < 0:
		return null
	return FlatBuffer.at(_buf, p + _buf.decode_u32(p))

## Element i of a `[struct]` vector (fixed-size elements stored inline).
func get_vector_struct(slot: int, i: int, struct_size: int) -> _FBStruct:
	var p := _vec_elem(slot, i, struct_size)
	return null if p < 0 else _FBStruct.wrap(_buf, p)

## Whole `[ubyte]`/`[byte]` vector as a PackedByteArray (byte-vector helper).
func get_vector_bytes(slot: int) -> PackedByteArray:
	var p := _indirect(slot)
	if p < 0:
		return PackedByteArray()
	var n := _buf.decode_u32(p)
	return _buf.slice(p + 4, p + 4 + n)

# ── 64-bit offsets: (offset64) fields and (vector64) vectors ──
#
# An `offset64` field stores a u64 forward offset (targets may live beyond
# the 32-bit region); the target itself keeps its normal u32 length prefix.
# A `vector64` field stores a u64 offset to a vector with a u64 length
# prefix whose elements start immediately after it.

# Absolute position of the object a uoffset64 field points at, or -1.
func _indirect64(slot: int) -> int:
	var p := field_pos(slot)
	if p < 0 or p + 8 > _buf.size():
		return -1
	return p + _buf.decode_u64(p)

## String behind an `(offset64)` field (u64 offset, u32 length).
func get_string64(slot: int, d := "") -> String:
	var p := _indirect64(slot)
	if p < 0:
		return d
	var n := _buf.decode_u32(p)
	return _buf.slice(p + 4, p + 4 + n).get_string_from_utf8()

## Length of an `(offset64)` vector (u64 field offset, u32 length prefix).
func vector_len_off64(slot: int) -> int:
	var p := _indirect64(slot)
	return 0 if p < 0 else _buf.decode_u32(p)

# Absolute position of element i of an `(offset64)` vector (u32 length).
func _vec_elem_off64(slot: int, i: int, elem_size: int) -> int:
	var p := _indirect64(slot)
	if p < 0:
		return -1
	var n := _buf.decode_u32(p)
	if i < 0 or i >= n:
		return -1
	return p + 4 + i * elem_size

## Length of a `(vector64)` vector (u64 offset, u64 length prefix).
func vector64_len(slot: int) -> int:
	var p := _indirect64(slot)
	return 0 if p < 0 else _buf.decode_u64(p)

# Absolute position of element i of a `(vector64)` vector (elems at t + 8).
func _vec64_elem(slot: int, i: int, elem_size: int) -> int:
	var p := _indirect64(slot)
	if p < 0:
		return -1
	var n := _buf.decode_u64(p)
	if i < 0 or i >= n:
		return -1
	return p + 8 + i * elem_size

func get_vector64_u8(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 1)
	return 0 if p < 0 else _buf.decode_u8(p)

func get_vector64_i8(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 1)
	return 0 if p < 0 else _buf.decode_s8(p)

func get_vector64_i16(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 2)
	return 0 if p < 0 else _buf.decode_s16(p)

func get_vector64_u16(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 2)
	return 0 if p < 0 else _buf.decode_u16(p)

func get_vector64_i32(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 4)
	return 0 if p < 0 else _buf.decode_s32(p)

func get_vector64_u32(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 4)
	return 0 if p < 0 else _buf.decode_u32(p)

func get_vector64_i64(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 8)
	return 0 if p < 0 else _buf.decode_s64(p)

func get_vector64_u64(slot: int, i: int) -> int:
	var p := _vec64_elem(slot, i, 8)
	return 0 if p < 0 else _buf.decode_u64(p)

func get_vector64_u64_hex(slot: int, i: int, d := "") -> String:
	var p := _vec64_elem(slot, i, 8)
	if p < 0:
		return d
	return "0x%08x%08x" % [_buf.decode_u32(p + 4), _buf.decode_u32(p)]

func get_vector64_f32(slot: int, i: int) -> float:
	var p := _vec64_elem(slot, i, 4)
	return 0.0 if p < 0 else _buf.decode_float(p)

func get_vector64_f64(slot: int, i: int) -> float:
	var p := _vec64_elem(slot, i, 8)
	return 0.0 if p < 0 else _buf.decode_double(p)

func get_vector64_bool(slot: int, i: int) -> bool:
	return get_vector64_u8(slot, i) != 0

## Element i of a `[struct] (vector64)` vector.
func get_vector64_struct(slot: int, i: int, struct_size: int) -> _FBStruct:
	var p := _vec64_elem(slot, i, struct_size)
	return null if p < 0 else _FBStruct.wrap(_buf, p)

## Element i of a `[string] (vector64)` vector (elements are u64 offsets).
func get_vector64_string(slot: int, i: int) -> String:
	var p := _vec64_elem(slot, i, 8)
	if p < 0:
		return ""
	var sp := p + _buf.decode_u64(p)
	var n := _buf.decode_u32(sp)
	return _buf.slice(sp + 4, sp + 4 + n).get_string_from_utf8()

## Element i of a `[Table] (vector64)` vector (elements are u64 offsets).
func get_vector64_table(slot: int, i: int) -> FlatBuffer:
	var p := _vec64_elem(slot, i, 8)
	if p < 0:
		return null
	return FlatBuffer.at(_buf, p + _buf.decode_u64(p))

## Whole `[ubyte] (vector64)` vector as a PackedByteArray.
func get_vector64_bytes(slot: int) -> PackedByteArray:
	var p := _indirect64(slot)
	if p < 0:
		return PackedByteArray()
	var n := _buf.decode_u64(p)
	return _buf.slice(p + 8, p + 8 + n)

# ── shared u64 coercion helpers (generated code uses these) ──

## Coerce int / float / "0x…" hex / decimal-string to the raw u64 bit
## pattern (signed int). Floats above 2^53 lose precision — inherent to
## JSON; pass a string for exactness.
static func u64_from(v: Variant, d := 0) -> int:
	match typeof(v):
		TYPE_INT:
			return v
		TYPE_FLOAT:
			return int(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := (v as String).strip_edges()
			if s.begins_with("0x") or s.begins_with("0X"):
				s = s.substr(2).right(16)
				var lo := ("0" + s.right(8)).hex_to_int() & 0xFFFFFFFF
				var hi := ("0" + s.left(maxi(0, s.length() - 8))).hex_to_int() & 0xFFFFFFFF if s.length() > 8 else 0
				return (hi << 32) | lo  # wraps mod 2^64 — desired
			var r := 0
			for c in s.to_utf8_buffer():
				if c < 0x30 or c > 0x39:
					return d
				r = r * 10 + (c - 0x30)  # wraps mod 2^64 — desired
			return r
	return d

## u64 bit pattern -> JSON-convention number: the unsigned value. Values
## above i64::MAX come back as float (same value flatc's --json parses to).
static func u64_json(v: int) -> Variant:
	return v if v >= 0 else 18446744073709551616.0 + v
