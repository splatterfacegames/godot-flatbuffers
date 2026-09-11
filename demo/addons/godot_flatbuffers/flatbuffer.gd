class_name FlatBuffer
extends RefCounted

## Read-side view over a flatbuffer table.
## Obtain via FlatBuffer.root(bytes) for the root table, or
## FlatBuffer.at(bytes, table_offset) for a nested table.
## All field access is by vtable slot index (schema field order).

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

static func at(buf: PackedByteArray, pos: int) -> FlatBuffer:
	var fb := FlatBuffer.new()
	fb._buf = buf
	fb._pos = pos
	return fb

func is_valid() -> bool:
	return _buf != null and _pos >= 4 and _pos + 4 <= _buf.size()

# Absolute position of field's stored value, or -1 if absent (use default).
func field_pos(slot: int) -> int:
	var vt := _pos - _buf.decode_s32(_pos)
	var idx := 4 + slot * 2
	if vt < 0 or idx + 2 > _buf.decode_u16(vt):
		return -1
	var rel := _buf.decode_u16(vt + idx)
	return _pos + rel if rel != 0 else -1

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
