class_name FlatBufferBuilder
extends RefCounted

## FlatBuffers buffer builder. Builds back-to-front exactly like the
## canonical implementations: create child objects (strings, vectors,
## tables) first, then reference them via uoffsets.
##
## var b := FlatBufferBuilder.new()
## var name := b.create_string("dodo")
## b.start_table(1); b.add_string_field(0, name, ""); var t := b.end_table()
## b.finish(t); var bytes := b.to_packed_byte_array()

var _bb: PackedByteArray
var _space: int            # next free write index; buffer fills downward
var _min_align := 1
var _vtable: Array[int]    # builder offsets of fields in the table being built
var _object_start := 0     # offset() at start_table()
var _vector_count := 0
var _written_vtables: Dictionary = {}  # vtable bytes (hex str) -> builder offset
var _nested := false

func _init(capacity := 1024) -> void:
	_bb = PackedByteArray()
	_bb.resize(capacity)
	_space = capacity

## Bytes used so far == distance from end of buffer.
func offset() -> int:
	return _bb.size() - _space

func _grow(needed: int) -> void:
	var used := offset()
	var new_size := maxi(_bb.size() * 2, _bb.size() + needed)
	var nbb := PackedByteArray()
	nbb.resize(new_size)
	for i in used:
		nbb[new_size - used + i] = _bb[_space + i]
	_bb = nbb
	_space = new_size - used

## Align the write head for a `size`-byte element plus `additional` bytes
## that must remain addressable after the element (per the canonical impl).
func prep(size: int, additional: int) -> void:
	if size > _min_align:
		_min_align = size
	var align_size := (-(offset() + additional)) & (size - 1)
	var need := align_size + size + additional
	if _space < need:
		_grow(need)
	_space -= align_size  # padding (content is don't-care)

func _put_u8(v: int) -> void:
	_space -= 1
	_bb[_space] = v & 0xFF

func _put_u16(v: int) -> void:
	_space -= 2
	_bb.encode_u16(_space, v & 0xFFFF)

func _put_u32(v: int) -> void:
	_space -= 4
	_bb.encode_u32(_space, v & 0xFFFFFFFF)

func _put_u64(v: int) -> void:
	_space -= 8
	_bb.encode_u64(_space, v)

# uoffset to an already-built object (its builder offset).
func _put_uoffset(target: int) -> void:
	prep(4, 0)
	_space -= 4
	_bb.encode_u32(_space, offset() - target)

# ── scalar prepend (writes immediately) ─────────────────────

func prepend_bool(v: bool) -> void: prep(1, 0); _put_u8(1 if v else 0)
func prepend_u8(v: int) -> void:  prep(1, 0); _put_u8(v)
func prepend_i8(v: int) -> void:  prep(1, 0); _put_u8(v)
func prepend_u16(v: int) -> void: prep(2, 0); _put_u16(v)
func prepend_i16(v: int) -> void: prep(2, 0); _put_u16(v)
func prepend_u32(v: int) -> void: prep(4, 0); _put_u32(v)
func prepend_i32(v: int) -> void: prep(4, 0); _put_u32(v)
func prepend_u64(v: int) -> void: prep(8, 0); _put_u64(v)
func prepend_i64(v: int) -> void: prep(8, 0); _put_u64(v)
func prepend_f32(v: float) -> void:
	prep(4, 0)
	_space -= 4
	_bb.encode_float(_space, v)
func prepend_f64(v: float) -> void:
	prep(8, 0)
	_space -= 8
	_bb.encode_double(_space, v)

# ── strings / vectors ───────────────────────────────────────

func create_string(s: String) -> int:
	var bs := s.to_utf8_buffer()
	var n := bs.size()
	prep(4, n + 1)
	_put_u8(0)                    # NUL terminator (highest address)
	_space -= n
	for i in n:
		_bb[_space + i] = bs[i]
	_put_u32(n)                   # length prefix (lowest address)
	return offset()

## Begin a vector: caller must then prepend elements in REVERSE order
## (last element first), then call end_vector().
func start_vector(elem_size: int, count: int, alignment: int) -> void:
	prep(4, elem_size * count)
	prep(alignment, elem_size * count)
	_vector_count = count
	_nested = true

func end_vector() -> int:
	_put_u32(_vector_count)
	_nested = false
	return offset()

## Convenience: vector of uoffsets to previously built objects.
func create_offset_vector(offsets: Array) -> int:
	start_vector(4, offsets.size(), 4)
	for i in range(offsets.size() - 1, -1, -1):
		_put_uoffset(offsets[i])
	return end_vector()

func create_u32_vector(vals: Array) -> int:
	start_vector(4, vals.size(), 4)
	for i in range(vals.size() - 1, -1, -1):
		_put_u32(vals[i])
	return end_vector()

func create_u8_vector(vals: Array) -> int:
	start_vector(1, vals.size(), 1)
	for i in range(vals.size() - 1, -1, -1):
		_put_u8(vals[i])
	return end_vector()

# ── tables ──────────────────────────────────────────────────

func start_table(num_fields: int) -> void:
	_vtable = []
	_vtable.resize(num_fields)
	_vtable.fill(0)
	_object_start = offset()
	_nested = true

func _slot(i: int) -> void:
	_vtable[i] = offset()

# add_* helpers: skip the field entirely when v == default (flatbuffers semantics)
func add_offset_field(i: int, off: int, d := 0) -> void:
	if off != d: _put_uoffset(off); _slot(i)
func add_bool_field(i: int, v: bool, d := false) -> void:
	if v != d: prepend_bool(v); _slot(i)
func add_i8_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_i8(v); _slot(i)
func add_u8_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_u8(v); _slot(i)
func add_i16_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_i16(v); _slot(i)
func add_u16_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_u16(v); _slot(i)
func add_i32_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_i32(v); _slot(i)
func add_u32_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_u32(v); _slot(i)
func add_i64_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_i64(v); _slot(i)
func add_u64_field(i: int, v: int, d := 0) -> void:
	if v != d: prepend_u64(v); _slot(i)
func add_f32_field(i: int, v: float, d := 0.0) -> void:
	if v != d: prepend_f32(v); _slot(i)
func add_f64_field(i: int, v: float, d := 0.0) -> void:
	if v != d: prepend_f64(v); _slot(i)

func end_table() -> int:
	prep(4, 0)
	_put_u32(0)                    # soffset placeholder (patched below)
	var tbl := offset()

	# trim trailing unused slots — vtable only covers fields up to the last used
	var used := _vtable.size()
	while used > 0 and _vtable[used - 1] == 0:
		used -= 1

	var obj_len := tbl - _object_start
	var vt_len := 4 + used * 2

	# materialize vtable bytes: [u16 vt_len][u16 obj_len][u16 field rel offs...]
	var vt := PackedByteArray()
	vt.resize(vt_len)
	vt.encode_u16(0, vt_len)
	vt.encode_u16(2, obj_len)
	for i in used:
		vt.encode_u16(4 + i * 2, tbl - _vtable[i] if _vtable[i] != 0 else 0)

	var key := vt.hex_encode()
	var vt_off: int
	if _written_vtables.has(key):
		vt_off = _written_vtables[key]   # dedup: reuse identical vtable
	else:
		prep(2, 0)
		_space -= vt_len
		for i in vt_len:
			_bb[_space + i] = vt[i]
		vt_off = offset()
		_written_vtables[key] = vt_off

	# patch soffset at table start: signed distance table→vtable
	_bb.encode_s32(_bb.size() - tbl, vt_off - tbl)
	_nested = false
	return tbl

# ── finish ──────────────────────────────────────────────────

func finish(root: int, file_identifier := "") -> void:
	var extra := 4 + file_identifier.length()
	prep(_min_align, extra)
	if file_identifier.length() > 0:
		var id := file_identifier.to_utf8_buffer()
		# file identifier is exactly 4 bytes; builder writes back-to-front
		for i in range(3, -1, -1):
			_put_u8(id[i] if i < id.size() else 0)
	_put_uoffset(root)

func to_packed_byte_array() -> PackedByteArray:
	return _bb.slice(_space)
