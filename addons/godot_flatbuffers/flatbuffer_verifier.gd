class_name FlatBufferVerifier
extends RefCounted

## Verification for untrusted buffers.
##
## Structural fallback — verify(buf) / verify_size_prefixed(buf):
## bounds-checks the root table's vtable and every stored field location.
## Catches truncated/corrupt buffers but cannot check field types.
##
## Schema-aware — verify_root(buf, spec):
## `spec` maps vtable slot -> field descriptor (emitted by generate_gd.py
## as each table's `_spec()`; hand-written specs work too):
##   {"k": "scalar", "size": N}                       scalar field of N bytes
##   {"k": "string"}
##   {"k": "table",  "spec": Dictionary | Callable}   Callable resolves to a
##                                                    Dictionary spec (breaks
##                                                    recursive schemas)
##   {"k": "struct", "size": N}                       inline struct field
##   {"k": "vector", "elem": <desc>}                  elem desc per above;
##                                                    offset elems verified
##                                                    per element
##   {"k": "union",  "type_slot": N, "members": {tag: <desc>}}
##                                                    sibling tag field read
##                                                    from type_slot; member
##                                                    descs are table/string
##
## Generated accessors expose this as `SomeTable.verify(buf)`.

const MAX_DEPTH := 64
const MAX_VECTOR_ELEMS := 1 << 24  # sanity cap

# ── structural fallback ─────────────────────────────────────

static func verify(buf: PackedByteArray) -> bool:
	if buf.size() < 4:
		return false
	var root := buf.decode_u32(0)
	if root < 4 or root + 4 > buf.size():
		return false
	return _check_table(buf, root, 0)

static func verify_size_prefixed(buf: PackedByteArray) -> bool:
	if buf.size() < 8 or buf.decode_u32(0) != buf.size() - 4:
		return false
	var root := 4 + buf.decode_u32(4)
	if root < 8 or root + 4 > buf.size():
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
		if rel < 4 or rel >= obj_len:
			return false
		var field_pos := pos + rel
		if field_pos + 4 > buf.size():
			return false
	return true

## Stricter check for a known scalar-only table (no nested objects):
## confirms the root table is well formed. Use verify() otherwise.
static func verify_shallow(buf: PackedByteArray) -> bool:
	return verify(buf)

# ── schema-aware ────────────────────────────────────────────

static func verify_root(buf: PackedByteArray, spec: Dictionary, size_prefixed := false) -> bool:
	var base := 0
	if size_prefixed:
		if buf.size() < 8 or buf.decode_u32(0) != buf.size() - 4:
			return false
		base = 4
	elif buf.size() < 4:
		return false
	var root := base + buf.decode_u32(base)
	if root < base + 4 or root + 4 > buf.size():
		return false
	return _verify_table(buf, root, spec, 0)

static func _verify_table(buf: PackedByteArray, pos: int, spec: Dictionary, depth: int) -> bool:
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
	for i in range(4, vt_len, 2):
		var rel := buf.decode_u16(vt + i)
		if rel == 0:
			continue
		# field data lives inside the object, past the leading soffset
		if rel < 4 or rel >= obj_len:
			return false
		var d: Variant = spec.get((i - 4) >> 1)
		if d == null:
			continue  # field unknown to this spec (schema evolution): bounds-checked above
		if not _verify_field(buf, pos, vt, rel, obj_len, d, depth):
			return false
	# union tag/payload consistency: tag==0 requires payload absent and vice versa
	for slot in spec:
		var d: Variant = spec[slot]
		if not (d is Dictionary) or String(d.get("k", "")) != "union":
			continue
		var idx := 4 + int(slot) * 2
		var has_payload := idx + 2 <= vt_len and buf.decode_u16(vt + idx) != 0
		if (_union_tag(buf, pos, vt, vt_len, d) == 0) == has_payload:
			return false
	return true

static func _union_tag(buf: PackedByteArray, pos: int, vt: int, vt_len: int, d: Dictionary) -> int:
	var tidx := 4 + int(d.get("type_slot", -1)) * 2
	if tidx >= 4 and tidx + 2 <= vt_len:
		var trel := buf.decode_u16(vt + tidx)
		if trel != 0:
			return buf.decode_u8(pos + trel)
	return 0

static func _verify_field(buf: PackedByteArray, pos: int, vt: int, rel: int, obj_len: int, d: Dictionary, depth: int) -> bool:
	var fpos := pos + rel
	match String(d.get("k", "")):
		"scalar", "struct":
			return rel + int(d["size"]) <= obj_len
		"string":
			var t := _off_target(buf, fpos)
			return t >= 0 and _check_string(buf, t)
		"table":
			var t := _off_target(buf, fpos)
			if t < 0:
				return false
			var s: Variant = d.get("spec")
			if s is Callable:
				s = s.call()
			if s is Dictionary:
				return _verify_table(buf, t, s, depth + 1)
			return _check_table(buf, t, depth + 1)
		"vector":
			var t := _off_target(buf, fpos)
			if t < 0 or t + 4 > buf.size():
				return false
			return _verify_vector(buf, t, d.get("elem", {}), depth)
		"union":
			return _verify_union(buf, pos, vt, fpos, d, depth)
	return false

static func _verify_vector(buf: PackedByteArray, t: int, elem: Variant, depth: int) -> bool:
	var n := buf.decode_u32(t)
	if n > MAX_VECTOR_ELEMS:
		return false
	if not (elem is Dictionary):
		return false
	match String(elem.get("k", "")):
		"scalar", "struct":
			return t + 4 + n * int(elem["size"]) <= buf.size()
		"string", "table":
			if t + 4 + n * 4 > buf.size():
				return false
			for i in n:
				var e := t + 4 + i * 4
				var tgt := _off_target(buf, e)
				if tgt < 0:
					return false
				if String(elem["k"]) == "string":
					if not _check_string(buf, tgt):
						return false
				else:
					var s: Variant = elem.get("spec")
					if s is Callable:
						s = s.call()
					if s is Dictionary:
						if not _verify_table(buf, tgt, s, depth + 1):
							return false
					elif not _check_table(buf, tgt, depth + 1):
						return false
			return true
	return false

static func _verify_union(buf: PackedByteArray, pos: int, vt: int, fpos: int, d: Dictionary, depth: int) -> bool:
	var tag := _union_tag(buf, pos, vt, buf.decode_u16(vt), d)
	if tag == 0:
		return false  # payload present with NONE tag
	var m: Variant = d.get("members", {}).get(tag)
	if not (m is Dictionary):
		return false  # tag value not in this spec
	if String(m.get("k", "")) == "string":
		var t := _off_target(buf, fpos)
		return t >= 0 and _check_string(buf, t)
	var t := _off_target(buf, fpos)
	if t < 0:
		return false
	var s: Variant = m.get("spec")
	if s is Callable:
		s = s.call()
	if s is Dictionary:
		return _verify_table(buf, t, s, depth + 1)
	return _check_table(buf, t, depth + 1)

# Absolute position of the object a uoffset field points at, or -1.
static func _off_target(buf: PackedByteArray, fpos: int) -> int:
	if fpos + 4 > buf.size():
		return -1
	var off := buf.decode_u32(fpos)
	if off <= 0:
		return -1
	var t := fpos + off
	return t if t + 4 <= buf.size() else -1

static func _check_string(buf: PackedByteArray, pos: int) -> bool:
	if pos < 4 or pos + 4 > buf.size():
		return false
	var n := buf.decode_u32(pos)
	return pos + 4 + n < buf.size() and buf[pos + 4 + n] == 0
