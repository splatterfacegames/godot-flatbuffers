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
var _shared_strings: Dictionary = {}   # create_shared_string dedup
var _nested := false
var _capacity := 1024

## When true, add_*_field emits fields even when v == default
## (matches flatc's `--force-defaults` / JS Builder.forceDefaults).
var force_defaults := false
## When false, every table gets its own vtable (no dedup).
var dedup_vtables := true

func _init(capacity := 1024) -> void:
	_capacity = capacity
	_bb = PackedByteArray()
	_bb.resize(capacity)
	_space = capacity

## Reset to an empty buffer, reusing the initial capacity.
func reset() -> void:
	_bb = PackedByteArray()
	_bb.resize(_capacity)
	_space = _capacity
	_min_align = 1
	_vtable = []
	_vector_count = 0
	_written_vtables.clear()
	_shared_strings.clear()
	_nested = false

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

## Write `n` zero bytes (explicit struct/vector padding, per the canonical impl).
## Distinct from prep() padding: pad() output is part of the object.
func pad(n: int) -> void:
	_space -= n
	for i in n:
		_bb[_space + i] = 0

# Raw writes with NO alignment/prep — used by generated struct packers and
# vector bodies after an explicit prep()/start_vector() has set up the space.
func write_bool(v: bool) -> void: _put_u8(1 if v else 0)
func write_u8(v: int) -> void:  _put_u8(v)
func write_i8(v: int) -> void:  _put_u8(v)
func write_u16(v: int) -> void: _put_u16(v)
func write_i16(v: int) -> void: _put_u16(v)
func write_u32(v: int) -> void: _put_u32(v)
func write_i32(v: int) -> void: _put_u32(v)
func write_u64(v: int) -> void: _put_u64(v)
func write_i64(v: int) -> void: _put_u64(v)
func write_f32(v: float) -> void:
	_space -= 4
	_bb.encode_float(_space, v)
func write_f64(v: float) -> void:
	_space -= 8
	_bb.encode_double(_space, v)

## Full-range u64 write from a hex string ("0x...", "0X..." or bare hex).
## Needed for values above i64::MAX which GDScript's signed int cannot hold.
func write_u64_hex(hex: String) -> void:
	var s := hex.strip_edges().trim_prefix("0x").trim_prefix("0X")
	var lo := ("0" + s.right(8)).hex_to_int() & 0xFFFFFFFF
	var hi := ("0" + s.left(maxi(0, s.length() - 8))).hex_to_int() & 0xFFFFFFFF if s.length() > 8 else 0
	_space -= 8
	_bb.encode_u32(_space, lo)
	_bb.encode_u32(_space + 4, hi)

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

func _check_not_nested(what: String) -> bool:
	if _nested:
		push_error("flatbuffers: cannot create %s while a table/vector is being built" % what)
		return false
	return true

func _check_nested(what: String) -> bool:
	if not _nested:
		push_error("flatbuffers: %s requires an open table/vector" % what)
		return false
	return true

func create_string(s: String) -> int:
	if not _check_not_nested("a string"):
		return 0
	var bs := s.to_utf8_buffer()
	var n := bs.size()
	prep(4, n + 1)
	_put_u8(0)                    # NUL terminator (highest address)
	_space -= n
	for i in n:
		_bb[_space + i] = bs[i]
	_put_u32(n)                   # length prefix (lowest address)
	return offset()

## create_string with dedup: repeated strings return the first offset.
func create_shared_string(s: String) -> int:
	if s.is_empty():
		return 0
	if _shared_strings.has(s):
		return _shared_strings[s]
	var off := create_string(s)
	_shared_strings[s] = off
	return off

## Begin a vector: caller must then prepend elements in REVERSE order
## (last element first), then call end_vector().
func start_vector(elem_size: int, count: int, alignment: int) -> void:
	if not _check_not_nested("a vector"):
		return
	prep(4, elem_size * count)
	prep(alignment, elem_size * count)
	_vector_count = count
	_nested = true

func end_vector() -> int:
	if not _check_nested("end_vector"):
		return 0
	_put_u32(_vector_count)
	_nested = false
	return offset()

## Convenience: vector of uoffsets to previously built objects.
func create_offset_vector(offsets: Array) -> int:
	start_vector(4, offsets.size(), 4)
	for i in range(offsets.size() - 1, -1, -1):
		_put_uoffset(offsets[i])
	return end_vector()

## `[ubyte]`/`[byte]` vector straight from a PackedByteArray.
func create_byte_vector(bytes: PackedByteArray) -> int:
	if not _check_not_nested("a byte vector"):
		return 0
	var n := bytes.size()
	start_vector(1, n, 1)
	_space -= n
	for i in n:
		_bb[_space + i] = bytes[i]
	return end_vector()

func create_bool_vector(vals: Array) -> int:
	start_vector(1, vals.size(), 1)
	for i in range(vals.size() - 1, -1, -1):
		_put_u8(1 if vals[i] else 0)
	return end_vector()

func create_i8_vector(vals: Array) -> int:
	start_vector(1, vals.size(), 1)
	for i in range(vals.size() - 1, -1, -1):
		_put_u8(vals[i])
	return end_vector()

func create_u8_vector(vals: Array) -> int:
	start_vector(1, vals.size(), 1)
	for i in range(vals.size() - 1, -1, -1):
		_put_u8(vals[i])
	return end_vector()

func create_i16_vector(vals: Array) -> int:
	start_vector(2, vals.size(), 2)
	for i in range(vals.size() - 1, -1, -1):
		_put_u16(vals[i])
	return end_vector()

func create_u16_vector(vals: Array) -> int:
	start_vector(2, vals.size(), 2)
	for i in range(vals.size() - 1, -1, -1):
		_put_u16(vals[i])
	return end_vector()

func create_i32_vector(vals: Array) -> int:
	start_vector(4, vals.size(), 4)
	for i in range(vals.size() - 1, -1, -1):
		_put_u32(vals[i])
	return end_vector()

func create_u32_vector(vals: Array) -> int:
	start_vector(4, vals.size(), 4)
	for i in range(vals.size() - 1, -1, -1):
		_put_u32(vals[i])
	return end_vector()

func create_i64_vector(vals: Array) -> int:
	start_vector(8, vals.size(), 8)
	for i in range(vals.size() - 1, -1, -1):
		_put_u64(vals[i])
	return end_vector()

func create_u64_vector(vals: Array) -> int:
	start_vector(8, vals.size(), 8)
	for i in range(vals.size() - 1, -1, -1):
		_put_u64(vals[i])
	return end_vector()

func create_f32_vector(vals: Array) -> int:
	start_vector(4, vals.size(), 4)
	for i in range(vals.size() - 1, -1, -1):
		write_f32(vals[i])
	return end_vector()

func create_f64_vector(vals: Array) -> int:
	start_vector(8, vals.size(), 8)
	for i in range(vals.size() - 1, -1, -1):
		write_f64(vals[i])
	return end_vector()

# ── tables ──────────────────────────────────────────────────

func start_table(num_fields: int) -> void:
	if not _check_not_nested("a table"):
		return
	_vtable = []
	_vtable.resize(num_fields)
	_vtable.fill(0)
	_object_start = offset()
	_nested = true

func _slot(i: int) -> void:
	if i >= 0 and i < _vtable.size():
		_vtable[i] = offset()
	else:
		push_error("flatbuffers: field slot %d out of range (table has %d)" % [i, _vtable.size()])

# add_* helpers: skip the field entirely when v == default, unless `force` or
# builder.force_defaults (needed for flatc `--force-defaults` schemas).
func add_offset_field(i: int, off: int, d := 0, force := false) -> void:
	if off != d or force or force_defaults: _put_uoffset(off); _slot(i)
func add_bool_field(i: int, v: bool, d := false, force := false) -> void:
	if v != d or force or force_defaults: prepend_bool(v); _slot(i)
func add_i8_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_i8(v); _slot(i)
func add_u8_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_u8(v); _slot(i)
func add_i16_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_i16(v); _slot(i)
func add_u16_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_u16(v); _slot(i)
func add_i32_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_i32(v); _slot(i)
func add_u32_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_u32(v); _slot(i)
func add_i64_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_i64(v); _slot(i)
func add_u64_field(i: int, v: int, d := 0, force := false) -> void:
	if v != d or force or force_defaults: prepend_u64(v); _slot(i)
func add_f32_field(i: int, v: float, d := 0.0, force := false) -> void:
	if v != d or force or force_defaults: prepend_f32(v); _slot(i)
func add_f64_field(i: int, v: float, d := 0.0, force := false) -> void:
	if v != d or force or force_defaults: prepend_f64(v); _slot(i)

## Full-range u64 field from a hex string (see write_u64_hex).
func add_u64_hex_field(i: int, hex: String, d := "0x0", force := false) -> void:
	if hex != d or force or force_defaults:
		prep(8, 0)
		write_u64_hex(hex)
		_slot(i)

## Struct field: `off` must be the return of a just-executed inline struct
## pack (e.g. `Vec3.create_vec3(b, ...)`) — structs live inside the table,
## so it is an error if anything was written between pack and this call.
func add_struct_field(i: int, off: int, d := 0) -> void:
	if off != d:
		nested(off)
		_slot(i)

## Canonical check that a struct/object was serialized inline: `off` must
## equal the current builder offset (JS: Builder.nested).
func nested(off: int) -> void:
	if off != offset():
		push_error("flatbuffers: struct must be serialized inline")

## Canonical check that a required field was set before end_table.
## `field_vt_offset` is the field's offset within the vtable: 4 + slot * 2.
## Returns false (and errors) when the field was not written.
func required_field(table: int, field_vt_offset: int) -> bool:
	var table_start := _bb.size() - table
	var vt := table_start - _bb.decode_s32(table_start)
	var ok := field_vt_offset < _bb.decode_u16(vt) and _bb.decode_u16(vt + field_vt_offset) != 0
	if not ok:
		push_error("flatbuffers: required field %d must be set" % field_vt_offset)
	return ok

func end_table() -> int:
	if not _check_nested("end_table"):
		return 0
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
	if dedup_vtables and _written_vtables.has(key):
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

## Finalize the buffer pointing at `root` (a builder offset from end_table).
## `file_identifier` must be empty or exactly 4 characters.
## `size_prefixed` writes a u32 byte-count before the root uoffset
## (flatc's `--size-prefixed`; read with FlatBuffer.root_size_prefixed).
func finish(root: int, file_identifier := "", size_prefixed := false) -> void:
	if _nested:
		push_error("flatbuffers: finish called while a table/vector is still open")
		return
	var id := file_identifier.to_utf8_buffer()
	if not id.is_empty() and id.size() != 4:
		push_error("flatbuffers: file identifier must be exactly 4 bytes")
		return
	var prefix := 4 if size_prefixed else 0
	prep(_min_align, 4 + id.size() + prefix)
	if not id.is_empty():
		# file identifier is exactly 4 bytes; builder writes back-to-front
		for i in range(3, -1, -1):
			_put_u8(id[i])
	_put_uoffset(root)
	if size_prefixed:
		prep(4, 0)
		_put_u32(offset())  # byte count of everything after the prefix itself

func finish_size_prefixed(root: int, file_identifier := "") -> void:
	finish(root, file_identifier, true)

func to_packed_byte_array() -> PackedByteArray:
	return _bb.slice(_space)
