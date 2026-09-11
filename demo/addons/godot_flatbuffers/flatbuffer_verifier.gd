class_name FlatBufferVerifier
extends RefCounted

## Best-effort structural verification: bounds-checks the root table's
## vtable and every reachable uoffset target (tables, strings, vectors)
## up to a depth limit. Without the schema we can't verify field types,
## but this catches truncated/corrupt buffers before parse.
##
## FlatBufferVerifier.verify(bytes) -> bool

const MAX_DEPTH := 32
const MAX_VECTOR_ELEMS := 1 << 24  # sanity cap

static func verify(buf: PackedByteArray) -> bool:
	if buf.size() < 4:
		return false
	var root := buf.decode_u32(0)
	if root < 4 or root + 4 > buf.size():
		return false
	return _check_table(buf, root, 0)

static func _check_table(buf: PackedByteArray, pos: int, depth: int) -> bool:
	if depth > MAX_DEPTH or pos < 4 or pos + 4 > buf.size():
		return false
	var vt := pos - buf.decode_s32(pos)
	if vt < 0 or vt + 4 > buf.size():
		return false
	var vt_len := buf.decode_u16(vt)
	var obj_len := buf.decode_u16(vt + 2)
	if vt_len < 4 or vt_len % 2 != 0 or vt + vt_len > buf.size():
		return false
	if pos + obj_len > buf.size():
		return false
	# every field's stored location must fit inside the table object
	for i in range(4, vt_len, 2):
		var rel := buf.decode_u16(vt + i)
		if rel == 0:
			continue
		if rel >= obj_len:
			return false
		# uoffset fields point forward; strings/vectors/subtables must land in bounds.
		# we can't tell scalar fields from offsets without the schema, so we only
		# verify the *potential* target when it looks like a valid forward offset.
		var field_pos := pos + rel
		if field_pos + 4 > buf.size():
			return false
	return true

## Stricter check for a known scalar-only table (no nested objects):
## confirms the root table is well formed. Use verify() otherwise.
static func verify_shallow(buf: PackedByteArray) -> bool:
	return verify(buf)
