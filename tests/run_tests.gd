extends SceneTree
## headless test runner: godot --headless --script tests/run_tests.gd
## (run from the project root so res:// resolves)

const FB := preload("res://addons/godot_flatbuffers/flatbuffer.gd")
const FBB := preload("res://addons/godot_flatbuffers/flatbuffer_builder.gd")
const FBV := preload("res://addons/godot_flatbuffers/flatbuffer_verifier.gd")
const GTS := preload("res://tests/gen_schema.gd")
const V64S := preload("res://tests/gen_v64.gd")

var failures := 0

class _CalcHandler:
	## gRPC-style handler: dictionary in, dictionary out.
	func check(req, _b) -> Variant:
		return {"tag": "echo " + req.s()}

## Deep JSON-value compare: numbers compare approximately (flatc emits u64
## as decimal; Godot parses > i64::MAX as float), dicts/arrays recursively.
func _jdeq(a: Variant, b: Variant) -> bool:
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size(): return false
		for k in a:
			if not b.has(k) or not _jdeq(a[k], b[k]): return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size(): return false
		for i in a.size():
			if not _jdeq(a[i], b[i]): return false
		return true
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return a == b

func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  ok: " + msg)
	else:
		failures += 1
		printerr("  FAIL: " + msg)

func _init() -> void:
	print("== read golden/test1.bin ==")
	var bytes := FileAccess.get_file_as_bytes("res://tests/golden/test1.bin")
	ok(FBV.verify(bytes), "verifier accepts")
	ok(GTS.TestTable.verify(bytes), "schema-aware verify accepts")

	var t: FB = FB.root(bytes)
	ok(t.get_bool(0), "b=true")
	ok(t.get_i8(1) == -8, "i8=-8 (got %d)" % t.get_i8(1))
	ok(t.get_u8(2) == 200, "u8=200 (got %d)" % t.get_u8(2))
	ok(t.get_i16(3) == -3000, "i16=-3000 (got %d)" % t.get_i16(3))
	ok(t.get_u16(4) == 60000, "u16=60000 (got %d)" % t.get_u16(4))
	ok(t.get_i32(5) == -123456, "i32 (got %d)" % t.get_i32(5))
	ok(t.get_u32(6) == 4000000000, "u32 (got %d)" % t.get_u32(6))
	ok(t.get_i64(7) == -9000000000, "i64 (got %d)" % t.get_i64(7))
	ok(t.get_u64(8) == 8000000000000000000, "u64 (got %d)" % t.get_u64(8))
	ok(is_equal_approx(t.get_f32(9), 1.5), "f32=1.5")
	ok(is_equal_approx(t.get_f64(10), 3.141592653589793), "f64=pi")
	ok(t.get_string(11) == "dodo", "name='dodo' (got '%s')" % t.get_string(11))
	ok(t.vector_len(12) == 5, "nums len 5")
	var nums_ok := true
	for i in 5:
		if t.get_vector_i32(12, i) != i + 1: nums_ok = false
	ok(nums_ok, "nums == [1,2,3,4,5]")
	ok(t.vector_len(13) == 3, "strs len 3")
	ok(t.get_vector_string(13, 0) == "alpha" and t.get_vector_string(13, 2) == "gamma", "strs contents")
	var inner: FB = t.get_table(14)
	ok(inner != null and inner.get_i32(0) == 7 and inner.get_string(1) == "seven", "inner.x=7,s='seven'")
	var in0: FB = t.get_vector_table(15, 0)
	var in1t: FB = t.get_vector_table(15, 1)
	ok(in0.get_i32(0) == 7 and in1t.get_i32(0) == -3, "inners vec tables")
	ok(t.get_i32(16, 42) == 77, "with_default overridden=77")
	ok(t.get_string(17, "fallback") == "fallback", "absent string -> default")

	print("== structs ==")
	var pos := t.get_struct(18)
	ok(pos != null, "pos struct present")
	ok(pos != null and is_equal_approx(pos.get_f32(0), 10.5)
		and is_equal_approx(pos.get_f32(4), -2.25)
		and is_equal_approx(pos.get_f32(8), 3.0), "pos = (10.5,-2.25,3.0)")
	ok(t.vector_len(19) == 2, "points len 2")
	var p0 := t.get_vector_struct(19, 0, 12)
	var p1 := t.get_vector_struct(19, 1, 12)
	ok(is_equal_approx(p0.get_f32(0), 1.0) and is_equal_approx(p0.get_f32(4), 0.0), "points[0]=(1,0,0)")
	ok(is_equal_approx(p1.get_f32(0), 0.0) and is_equal_approx(p1.get_f32(4), 1.0), "points[1]=(0,1,0)")
	var tr := t.get_struct(20)
	ok(tr != null and tr.get_i8(0) == -1 and tr.get_i16(16) == -3
		and is_equal_approx(tr.get_f64(8), 2.5), "tricky {a:-1,b:2.5,c:-3} across padding")
	var gt := GTS.TestTable.get_root_as(bytes)
	ok(is_equal_approx(gt.pos().x(), 10.5) and is_equal_approx(gt.pos().z(), 3.0), "generated pos accessor")
	ok(gt.points_len() == 2 and is_equal_approx(gt.points(1).y(), 1.0), "generated points vector")
	ok(gt.tricky().a() == -1 and is_equal_approx(gt.tricky().b(), 2.5), "generated tricky accessor")

	print("== u64 full range ==")
	ok(t.get_u64(21) == -1, "big64 raw int = -1 (bit pattern of u64 max)")
	ok(t.get_u64_hex(21) == "0xffffffffffffffff", "big64 hex = u64 max (got %s)" % t.get_u64_hex(21))
	ok(t.get_u64_bytes(21) == PackedByteArray([255, 255, 255, 255, 255, 255, 255, 255]), "big64 bytes")
	ok(gt.big64_hex() == "0xffffffffffffffff", "generated big64_hex")

	print("== byte vector / nested root ==")
	var emb0: FB = t.get_nested_root(22)
	ok(emb0 != null and emb0.get_i32(0) == 99 and emb0.get_string(1) == "nested",
		"blob is a nested Inner buffer (nested_flatbuffer)")
	ok(gt.blob_len() > 4, "generated blob_len")

	print("== enums, unions, keys, optional, deprecated, ids ==")
	ok(gt.col() == GTS.GT_Color.BLUE and gt.col() == 7, "col = Blue (enum)")
	ok(GTS.GT_Color.name_of(7) == "Blue" and GTS.GT_Color.value_of("Blue") == 7, "enum name/value maps")
	ok(gt.payload_type() == GTS.GT_Payload.INNER, "payload_type = Inner")
	var pl: Variant = gt.payload_unwrap()
	ok(pl != null and pl.x() == 7 and pl.s() == "seven", "payload_unwrap -> Inner")
	ok(gt.payload_as_inner() != null and gt.payload_as_inner().x() == 7, "payload_as_inner typed")
	ok(gt.payload_as_other() == null, "payload_as_other null for mismatched tag")
	ok(gt.payloads_len() == 2 and gt.payloads_type(0) == 1 and gt.payloads_type(1) == 2, "payloads union vector tags")
	var pu0: Variant = gt.payloads_unwrap(0)
	var pu1: Variant = gt.payloads_unwrap(1)
	ok(pu0 != null and pu0.x() == -3 and pu0.s() == "minus", "payloads[0] unwrap -> Inner")
	ok(pu1 != null and pu1.tag() == "alt", "payloads[1] unwrap -> Other")
	ok(gt.items_len() == 3 and gt.items_by_key(5).val() == 50, "items_by_key(5) -> val 50")
	ok(gt.items_by_key(1).id() == 1 and gt.items_by_key(9).val() == 90, "items_by_key edges")
	ok(gt.items_by_key(4) == null, "items_by_key(4) -> null")
	ok(gt.has_opt() and gt.opt() == 7, "optional scalar opt set to 7")
	ok(gt.legacy() == "old", "deprecated field legacy reads")
	ok(gt.ids().a() == 5 and gt.ids().c() == 6, "Ids: explicit ids honored")
	var dft := FileAccess.get_file_as_bytes("res://tests/golden/test2_defaults.bin")
	ok(not GTS.TestTable.get_root_as(dft).has_opt(), "optional scalar absent on defaults buf")

	print("== object API: to_dict ==")
	var od := gt.to_dict()
	ok(od["i32"] == -123456 and od["name"] == "dodo" and od["u64"] == 8000000000000000000, "to_dict scalars")
	ok(od["big64"] == -1, "to_dict big64 raw bit pattern (-1)")
	ok(od["col"] == "Blue", "to_dict enum name")
	ok(od["pos"] == {"x": 10.5, "y": -2.25, "z": 3.0}, "to_dict struct")
	ok(od["inner"] == {"x": 7, "s": "seven"}, "to_dict nested table")
	ok(od["inners"].size() == 2 and od["inners"][1]["s"] == "minus", "to_dict table vector")
	ok(od["points"][0] == {"x": 1.0, "y": 0.0, "z": 0.0}, "to_dict struct vector")
	ok(od["tricky"] == {"a": -1, "b": 2.5, "c": -3}, "to_dict padded struct")
	ok(od["payload_type"] == "Inner" and od["payload"]["x"] == 7, "to_dict union")
	ok(od["payloads_type"] == ["Inner", "Other"] and od["payloads"][1]["tag"] == "alt", "to_dict union vector")
	ok(od["items"][2] == {"id": 9, "val": 90}, "to_dict keyed vector")
	ok(od["opt"] == 7 and od["legacy"] == "old", "to_dict optional+deprecated")
	ok(od["ids"] == {"a": 5, "c": 6}, "to_dict Ids in id order")
	ok(od["blob"] is PackedByteArray and od["blob"].size() == 36, "to_dict byte vector -> PackedByteArray")
	ok(not od.has("wide") and not od.has("absent_defaulted"), "absent fields omitted")

	print("== JSON: to_json vs flatc --json ==")
	var fjson := FileAccess.get_file_as_string("res://tests/golden/test1.json")
	var flatc_d: Variant = JSON.parse_string(fjson)
	ok(flatc_d is Dictionary, "flatc --json reference parses")
	var ours: Variant = JSON.parse_string(gt.to_json())
	ok(ours is Dictionary, "to_json produces valid JSON")
	ok(_jdeq(ours, flatc_d), "to_json matches flatc --json output (parsed)")

	print("== from_dict / from_json round-trip ==")
	var b7 := FBB.new()
	b7.finish(GTS.TestTable.from_dict(b7, od))
	var rt7 := GTS.TestTable.get_root_as(b7.to_packed_byte_array())
	ok(rt7.i32() == -123456 and rt7.name() == "dodo" and rt7.big64() == -1, "from_dict scalars (u64 max exact)")
	ok(rt7.col() == 7 and rt7.opt() == 7 and rt7.has_opt(), "from_dict enum+optional")
	ok(rt7.payload_as_inner().x() == 7 and rt7.payloads_unwrap(1).tag() == "alt", "from_dict unions")
	ok(rt7.items_by_key(5).val() == 50 and rt7.items_len() == 3, "from_dict keyed vector")
	ok(rt7.legacy() == "old" and rt7.ids().a() == 5 and rt7.ids().c() == 6, "from_dict deprecated+ids")
	ok(rt7.blob_bytes() == gt.blob_bytes(), "from_dict byte vector")
	ok(rt7.pos() != null and is_equal_approx(rt7.pos().x(), 10.5), "from_dict struct")
	ok(rt7.inner().s() == "seven" and rt7.inners(1).x() == -3, "from_dict nested tables")
	ok(GTS.TestTable.verify(b7.to_packed_byte_array()), "from_dict output verifies")
	var fj := GTS.TestTable.from_json(fjson)
	ok(fj != null and fj.i32() == -123456 and fj.name() == "dodo", "from_json reads flatc JSON")
	ok(fj.col() == GTS.GT_Color.BLUE and fj.payload_as_inner().x() == 7, "from_json enum+union")
	ok(fj.items_by_key(9).val() == 90 and fj.opt() == 7, "from_json keyed+optional")
	ok(fj.u64() == 8000000000000000000, "from_json u64 in range")
	# u64 > i64::MAX arrives as a float; int() overflows to i64::MIN
	# (= 0x8000000000000000 as u64) — precision loss is inherent to JSON.
	ok(fj.big64() == -9223372036854775808, "from_json big64 saturates (documented precision loss)")
	var b8 := FBB.new()
	b8.finish(GTS.TestTable.from_dict(b8, {"big64": "0xffffffffffffffff", "u64": "8000000000000000000"}))
	ok(GTS.TestTable.get_root_as(b8.to_packed_byte_array()).big64_hex() == "0xffffffffffffffff",
		"from_dict accepts hex/decimal strings for u64")
	# required field still enforced through from_dict
	var b9 := FBB.new()
	var miss := GTS.Inner.from_dict(b9, {"x": 1})
	ok(not b9.required_field(miss, 6), "from_dict required field check fires")

	print("== size-prefixed + file identifier ==")
	var sp := FileAccess.get_file_as_bytes("res://tests/golden/test3_sizeprefixed.bin")
	ok(sp.decode_u32(0) == sp.size() - 4, "size prefix = %d" % sp.decode_u32(0))
	ok(FBV.verify_size_prefixed(sp), "verify_size_prefixed accepts")
	ok(FB.buffer_has_identifier(sp, "GT1!", true), "file identifier GT1! present")
	var ts: FB = FB.root_size_prefixed(sp)
	ok(ts.get_i32(5) == -7, "size-prefixed root i32=-7")
	ok(GTS.TestTable.verify(sp, true), "schema verify size-prefixed")
	ok(GTS.TestTable.get_size_prefixed_root_as(sp).i32() == -7, "generated size-prefixed root")
	# byte-identical rebuild of the size-prefixed golden
	var bsp := FBB.new()
	bsp.start_table(23)
	bsp.add_i32_field(5, -7, 0)
	bsp.add_i32_field(16, 42, 42)  # skipped (default)
	bsp.finish_size_prefixed(bsp.end_table(), "GT1!")
	ok(bsp.to_packed_byte_array() == sp, "size-prefixed rebuild byte-identical (%d vs %d bytes)"
		% [bsp.to_packed_byte_array().size(), sp.size()])

	print("== force_defaults ==")
	var fb4 := FileAccess.get_file_as_bytes("res://tests/golden/test4_forced.bin")
	ok(FBV.verify(fb4), "forced buffer verifies")
	var tf: FB = FB.root(fb4)
	ok(tf.has_field(16), "with_default present despite == default")
	ok(tf.get_i32(16, 99) == 42, "with_default forced value = 42")
	ok(tf.has_field(0) and not tf.get_bool(0), "b=false forced present")

	print("== read golden/test2_defaults.bin ==")
	var d := FileAccess.get_file_as_bytes("res://tests/golden/test2_defaults.bin")
	ok(FBV.verify(d), "verifier accepts defaults buf")
	var td: FB = FB.root(d)
	ok(td.get_i32(16, 42) == 42, "absent int -> default 42")
	ok(td.get_string(11, "none") == "none", "absent name -> default")
	ok(not td.has_field(16), "has_field false for absent default")
	ok(not td.has_field(18), "absent struct -> has_field false")
	ok(td.get_struct(18) == null, "absent struct -> null")

	print("== rebuild + byte-compare ==")
	var rebuilt := _rebuild()
	ok(rebuilt == bytes, "builder output byte-identical to official builder (got %d vs %d bytes)" % [rebuilt.size(), bytes.size()])
	var rd: FB = FB.root(rebuilt)
	ok(rd.get_string(11) == "dodo" and rd.get_u64(8) == 8000000000000000000, "rebuilt re-reads correctly")

	print("== generated accessors (tt.fbs) ==")
	const GEN := preload("res://tests/gen_tt.gd")
	var gb := FBB.new()
	# create_join_req(b, name_off, avatar_id, device_token_off) — id order
	var jr := GEN.JoinReq.create_join_req(gb, gb.create_string("Jetha"), 42, gb.create_string("tok123"))
	# create_envelope(b, seq, client_type, client_off, server_type, server_off)
	var env := GEN.Envelope.create_envelope(gb, 1, GEN.TT_ClientMsg.JOINREQ, jr, 0, 0)
	gb.finish(env)
	var gbuf := gb.to_packed_byte_array()
	var ge := GEN.Envelope.get_root_as(gbuf)
	ok(ge.seq() == 1, "envelope seq=1")
	ok(ge.client_type() == GEN.TT_ClientMsg.JOINREQ, "union tag = JoinReq")
	var req: Object = GEN.JoinReq.wrap_fb(ge.client())
	ok(req.name() == "Jetha" and req.avatar_id() == 42, "joinreq fields round-trip")
	var unwrapped: Variant = ge.client_unwrap()
	ok(unwrapped != null and unwrapped.name() == "Jetha", "client_unwrap typed member")
	ok(ge.client_as_queue_req() == null, "as_<other> null on tag mismatch")
	var ed := ge.to_dict()
	ok(ed["client_type"] == "JoinReq" and ed["client"]["avatar_id"] == 42, "union in to_dict")
	ok(GEN.Envelope.verify(gbuf), "schema-aware verify on union buffer")
	# union tag/payload mismatch must fail verification
	var bad := PackedByteArray(gbuf)
	var envpos := bad.decode_u32(0)
	var evt := envpos - bad.decode_s32(envpos)
	var crel := bad.decode_u16(evt + 4 + 2 * 2)   # slot 2 = client payload
	var cpos := envpos + crel
	bad.encode_u8(envpos + bad.decode_u16(evt + 4 + 1 * 2), 0)  # client_type -> NONE
	ok(not GEN.Envelope.verify(bad), "verify rejects payload with NONE union tag")
	var bad2 := PackedByteArray(gbuf)
	bad2.encode_u32(cpos, 0xFFFFFFF0)             # client -> wild offset
	ok(not GEN.Envelope.verify(bad2), "verify rejects out-of-bounds union target")
	ok(FBV.verify(bad2), "structural verify still passes (no schema)")

	print("== builder extras ==")
	var bb := FBB.new()
	bb.force_defaults = true
	bb.start_table(2)
	bb.add_i32_field(0, 7, 7)        # == default, forced by flag
	bb.add_i32_field(1, 5, 0, true)  # != default anyway; per-call force also ok
	var ft := bb.end_table()
	bb.finish(ft)
	var fbuf := bb.to_packed_byte_array()
	var fbt: FB = FB.root(fbuf)
	ok(fbt.has_field(0) and fbt.get_i32(0) == 7, "force_defaults flag emits default-valued field")

	var bb2 := FBB.new()
	var blob2 := bb2.create_byte_vector(PackedByteArray([9, 8, 7]))
	bb2.start_table(1)
	bb2.add_offset_field(0, blob2, 0)
	bb2.finish_size_prefixed(bb2.end_table(), "GT1!")
	var sp2 := bb2.to_packed_byte_array()
	ok(FB.buffer_has_identifier(sp2, "GT1!", true), "built buffer carries identifier")
	ok(sp2.decode_u32(0) == sp2.size() - 4, "built size prefix correct")
	var nr: FB = FB.root_size_prefixed(sp2)
	ok(nr != null and nr.get_vector_bytes(0) == PackedByteArray([9, 8, 7]), "size-prefixed byte vector round-trip")

	# nested buffer: embed a finished Inner table inside a [ubyte] field
	var ib := FBB.new()
	ib.finish(GTS.Inner.create_inner(ib, 99, ib.create_string("nested")))
	var nb := FBB.new()
	var nest := nb.create_byte_vector(ib.to_packed_byte_array())
	nb.start_table(1)
	nb.add_offset_field(0, nest, 0)
	nb.finish(nb.end_table())
	var nroot: FB = FB.root(nb.to_packed_byte_array())
	var emb: FB = nroot.get_nested_root(0)
	ok(emb != null and emb.get_i32(0) == 99 and emb.get_string(1) == "nested", "nested buffer root round-trip")

	# struct vector round-trip via generated helper
	var vb := FBB.new()
	var pts := GTS.Vec3.create_vec3_vector(vb, [[1.5, 2.5, 3.5], [4.5, 5.5, 6.5]])
	vb.start_table(1)
	vb.add_offset_field(0, pts, 0)
	vb.finish(vb.end_table())
	var vr: FB = FB.root(vb.to_packed_byte_array())
	var v1 := vr.get_vector_struct(0, 1, GTS.Vec3.SIZE)
	ok(vr.vector_len(0) == 2 and is_equal_approx(v1.get_f32(4), 5.5), "generated struct vector round-trip")

	# required field detection
	var rb := FBB.new()
	rb.start_table(2)
	rb.add_i32_field(0, 1, 0)  # slot 1 (required s) omitted
	var rtbl := rb.end_table()
	ok(not rb.required_field(rtbl, 6), "required_field detects missing required slot")

	# shared-string dedup: two fields, one string body
	var sb := FBB.new()
	var sa := sb.create_shared_string("dup")
	var sb2 := sb.create_shared_string("dup")
	ok(sa == sb2, "create_shared_string dedups")
	sb.start_table(2)
	sb.add_offset_field(0, sa, 0)
	sb.add_offset_field(1, sb2, 0)
	sb.finish(sb.end_table())
	var sr: FB = FB.root(sb.to_packed_byte_array())
	ok(sr.get_string(0) == "dup" and sr.get_string(1) == "dup", "shared string reads both fields")

	# remaining scalar vector creators round-trip
	var cv := FBB.new()
	var v16 := cv.create_i16_vector([-2, 3])
	var vu16 := cv.create_u16_vector([60001, 7])
	var vi8 := cv.create_i8_vector([-5, 6])
	cv.start_table(3)
	cv.add_offset_field(0, v16, 0)
	cv.add_offset_field(1, vu16, 0)
	cv.add_offset_field(2, vi8, 0)
	cv.finish(cv.end_table())
	var cr: FB = FB.root(cv.to_packed_byte_array())
	ok(cr.get_vector_i16(0, 0) == -2 and cr.get_vector_i16(0, 1) == 3, "i16 vector round-trip")
	ok(cr.get_vector_u16(1, 0) == 60001, "u16 vector round-trip")
	ok(cr.get_vector_i8(2, 0) == -5, "i8 vector round-trip")

	# u64 hex write path (> i64::MAX) + builder reset()
	var hb := FBB.new()
	hb.start_table(1)
	hb.add_u64_hex_field(0, "0x8000000000000000")
	hb.finish(hb.end_table())
	var hr: FB = FB.root(hb.to_packed_byte_array())
	ok(hr.get_u64_hex(0) == "0x8000000000000000", "u64 hex write/read > i64::MAX")
	hb.reset()
	hb.start_table(1)
	hb.add_i32_field(0, 9, 0)
	hb.finish(hb.end_table())
	ok(FB.root(hb.to_packed_byte_array()).get_i32(0) == 9, "builder reset() reuses cleanly")

	# dedup_vtables = false emits a vtable per table. The u16 prepend realigns
	# the head so both u8-field tables produce byte-identical vtables.
	var dd := FBB.new()
	dd.dedup_vtables = false
	for i in 2:
		dd.start_table(1)
		dd.add_u8_field(0, 1, 0)
		dd.end_table()
		if i == 0: dd.prepend_u16(0)
	var dd2 := FBB.new()
	for i in 2:
		dd2.start_table(1)
		dd2.add_u8_field(0, 1, 0)
		dd2.end_table()
		if i == 0: dd2.prepend_u16(0)
	ok(dd.offset() > dd2.offset(), "dedup_vtables=false writes duplicate vtables")

	print("== vector64 / offset64 ==")
	# flatc-built golden (canonical layout: u64 len, elems contiguous)
	var v64 := FileAccess.get_file_as_bytes("res://tests/golden/test5_v64.bin")
	ok(V64S.Big.verify(v64), "vector64 golden verifies")
	var big := V64S.Big.get_root_as(v64)
	ok(big.d_len() == 8 and big.d_bytes() == PackedByteArray([222, 173, 190, 239, 1, 2, 3, 4]), "vector64 u8 elems")
	ok(big.idx_len() == 2 and big.idx(0) == 100000 and big.idx(1) == -42, "vector64 i32 elems")
	# byte-identical rebuild of the flatc output — note flatc -b writes the
	# table's fields in reverse declaration order (idx lands at lower rel),
	# so we add idx's field before d's to match byte-for-byte.
	var vb64 := FBB.new()
	var d64 := vb64.create_byte_vector64(PackedByteArray([222, 173, 190, 239, 1, 2, 3, 4]))
	var i64v := vb64.create_i32_vector64([100000, -42])
	vb64.start_table(2)
	vb64.add_offset64_field(1, i64v, 0)
	vb64.add_offset64_field(0, d64, 0)
	vb64.finish(vb64.end_table())
	ok(vb64.to_packed_byte_array() == v64, "vector64 rebuild byte-identical to flatc (%d vs %d)"
		% [vb64.to_packed_byte_array().size(), v64.size()])
	# vector64 field through generated TestTable accessors
	var wb := FBB.new()
	var woff := GTS.TestTable.create_wide_vector64(wb, [5, 8000000000000000000])
	wb.start_table(33)
	wb.add_offset64_field(32, woff, 0)
	wb.finish(wb.end_table())
	var wt := GTS.TestTable.get_root_as(wb.to_packed_byte_array())
	ok(wt.wide_len() == 2 and wt.wide(0) == 5 and wt.wide(1) == 8000000000000000000,
		"generated vector64 field round-trip")
	ok(GTS.TestTable.verify(wb.to_packed_byte_array()), "schema verify on vector64 buffer")
	# 64-bit region ordering: creating a vector64 after a 32-bit object errors
	var ob64 := FBB.new()
	ob64.create_string("x")
	var bad64 := ob64.create_u8_vector64([1])
	ok(bad64 == 0, "vector64 after 32-bit object rejected (ordering rule)")
	# offset64 field: u64 offset pointing at a normal u32-len string
	var ob := FBB.new()
	var so64 := ob.create_string("far away")
	ob.start_table(1)
	ob.add_offset64_field(0, so64, 0)
	ob.finish(ob.end_table())
	var oroot: FB = FB.root(ob.to_packed_byte_array())
	ok(oroot.get_string64(0) == "far away", "offset64 string field round-trip")
	var obuf := ob.to_packed_byte_array()
	ok(FBV.verify(obuf), "structural verify on offset64 buffer")
	ok(FBV.verify_root(obuf, {0: {"k": "off64"}}), "schema verify offset64 string spec")
	# vector64 of structs (elements contiguous after u64 len)
	var sv := FBB.new()
	var pts64 := GTS.Vec3.create_vec3_vector64(sv, [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
	sv.start_table(1)
	sv.add_offset64_field(0, pts64, 0)
	sv.finish(sv.end_table())
	var svr: FB = FB.root(sv.to_packed_byte_array())
	var e1 := svr.get_vector64_struct(0, 1, GTS.Vec3.SIZE)
	ok(svr.vector64_len(0) == 2 and e1 != null and is_equal_approx(e1.get_f32(0), 4.0),
		"vector64 struct elements")
	# vector64 of strings: elements via create_string64 (64-bit region)
	var ovs := FBB.new()
	var so1 := ovs.create_string64("big-a")
	var so2 := ovs.create_string64("big-b")
	var sv64 := ovs.create_offset64_vector([so1, so2])
	ovs.start_table(1)
	ovs.add_offset64_field(0, sv64, 0)
	ovs.finish(ovs.end_table())
	var ovsr: FB = FB.root(ovs.to_packed_byte_array())
	ok(ovsr.vector64_len(0) == 2 and ovsr.get_vector64_string(0, 0) == "big-a"
		and ovsr.get_vector64_string(0, 1) == "big-b", "vector64 string elements")

	print("== generated gRPC service ==")
	var server := GTS.CalcServer.new(_CalcHandler.new())
	var client := GTS.CalcClient.new(server.dispatch)
	var cb := FBB.new()
	var res := client.check(cb, GTS.Inner.create_inner(cb, 1, cb.create_string("ping")))
	ok(res != null and res.tag() == "echo ping", "loopback rpc Check(Inner)->Other")
	ok(server.dispatch("/GT.Calc/Nope", PackedByteArray()).is_empty(), "unknown path -> empty")
	# handler may also return a builder offset directly
	var cb2 := FBB.new()
	var req2 := GTS.Inner.create_inner(cb2, 5, cb2.create_string("q"))
	cb2.finish(req2)
	var raw := server.dispatch("/GT.Calc/Check", cb2.to_packed_byte_array())
	var rres := GTS.Other.get_root_as(raw)
	ok(rres != null and rres.tag() == "echo q", "dispatcher decodes request and encodes reply")

	print("== corruption cases ==")
	ok(not FBV.verify(PackedByteArray([1, 2])), "tiny buffer rejected")
	var trunc := bytes.slice(0, 20)
	ok(not FBV.verify(trunc), "truncated buffer rejected")
	# a single u8 field lands on the buffer's last byte — must not be rejected
	var mb := FBB.new()
	mb.start_table(1)
	mb.add_u8_field(0, 7, 0)
	mb.finish(mb.end_table())
	ok(FBV.verify(mb.to_packed_byte_array()), "verify accepts buffer ending in a u8 field")
	var cor := PackedByteArray(bytes)
	var npos := cor.decode_u32(0)
	var nvt := npos - cor.decode_s32(npos)
	var nrel := cor.decode_u16(nvt + 4 + 11 * 2)   # name field
	cor.encode_u32(npos + nrel, 0xFFFFFFF0)        # wild uoffset on 'name'
	ok(not GTS.TestTable.verify(cor), "schema verify rejects wild string offset")
	# corrupt the nested buffer's root offset inside the blob vector.
	# (flatc drops nested_flatbuffer from .bfbs attributes, so the "nested"
	# spec piece is hand-written here — the generator emits it when present.)
	var cor2 := PackedByteArray(bytes)
	var brel := cor2.decode_u16(nvt + 4 + 22 * 2)  # blob field
	var bpos := npos + brel + cor2.decode_u32(npos + brel)  # vector data start
	var nested_spec := {22: {"k": "vector", "elem": {"k": "scalar", "size": 1},
		"nested": Callable(GTS.Inner, "_spec")}}
	ok(FBV.verify_root(bytes, nested_spec), "nested_flatbuffer spec verifies embedded buffer")
	cor2.encode_u32(bpos + 4, 0xFFFFFFF0)          # nested root uoffset -> wild
	ok(not FBV.verify_root(cor2, nested_spec), "nested spec rejects corrupt embedded buffer")
	ok(FBV.verify(cor2), "structural verify ignores nested payload")
	# union vector: a tag naming no union member must fail
	var cor3 := PackedByteArray(bytes)
	var ptrel := cor3.decode_u16(nvt + 4 + 26 * 2)   # payloads_type field
	var ptvec := npos + ptrel + cor3.decode_u32(npos + ptrel)
	cor3.encode_u8(ptvec + 4, 9)                   # first tag -> 9 (not a member)
	ok(not GTS.TestTable.verify(cor3), "union_vector rejects unknown tag")
	ok(GTS.TestTable.verify(bytes), "untouched buffer still verifies")

	print("")
	if failures == 0:
		print("ALL TESTS PASSED")
	else:
		printerr("%d FAILURES" % failures)
	quit(failures)

func _rebuild() -> PackedByteArray:
	var b := FBB.new()
	# mirror gen_golden.mjs exactly (children first, same order)
	var s7 := b.create_string("seven")
	b.start_table(2); b.add_i32_field(0, 7, 0); b.add_offset_field(1, s7, 0)
	var in1 := b.end_table()
	var sm := b.create_string("minus")
	b.start_table(2); b.add_i32_field(0, -3, 0); b.add_offset_field(1, sm, 0)
	var in2 := b.end_table()
	var inners_vec := b.create_offset_vector([in1, in2])
	var name := b.create_string("dodo")
	var strs_vec := b.create_offset_vector([
		b.create_string("alpha"), b.create_string("beta"), b.create_string("gamma")])
	b.start_vector(4, 5, 4)
	for v in [5, 4, 3, 2, 1]: b.prepend_i32(v)
	var nums_vec := b.end_vector()
	# blob = nested flatbuffer (a finished Inner buffer embedded as bytes);
	# write fields in the same order as gen_golden.mjs for byte-identity
	var ib2 := FBB.new()
	var ns := ib2.create_string("nested")
	ib2.start_table(2)
	ib2.add_i32_field(0, 99, 0)
	ib2.add_offset_field(1, ns, 0)
	ib2.finish(ib2.end_table())
	var blob := b.create_byte_vector(ib2.to_packed_byte_array())
	var points_vec := GTS.Vec3.create_vec3_vector(b, [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
	# items: Item{id,val} sorted by key — (1,100),(5,50),(9,90)
	var items_vec := b.create_offset_vector([
		GTS.Item.create_item(b, 1, 100),
		GTS.Item.create_item(b, 5, 50),
		GTS.Item.create_item(b, 9, 90)])
	# union payloads: [Inner(in2), Other{tag:"alt"}]
	var other_off := GTS.Other.create_other(b, b.create_string("alt"))
	var pay_tags := b.create_u8_vector([1, 2])
	var pay_vec := b.create_offset_vector([in2, other_off])
	var ids_off := GTS.Ids.create_ids(b, 5, 6)
	var legacy_off := b.create_string("old")

	b.start_table(33)
	b.add_i8_field(0, 1, 0)                       # bool
	b.add_i8_field(1, -8, 0)
	b.add_u8_field(2, 200, 0)
	b.add_i16_field(3, -3000, 0)
	b.add_u16_field(4, 60000, 0)
	b.add_i32_field(5, -123456, 0)
	b.add_u32_field(6, 4000000000, 0)
	b.add_i64_field(7, -9000000000, 0)
	b.add_u64_field(8, 8000000000000000000, 0)
	b.add_f32_field(9, 1.5, 0.0)
	b.add_f64_field(10, 3.141592653589793, 0.0)
	b.add_offset_field(11, name, 0)
	b.add_offset_field(12, nums_vec, 0)
	b.add_offset_field(13, strs_vec, 0)
	b.add_offset_field(14, in1, 0)
	b.add_offset_field(15, inners_vec, 0)
	b.add_i32_field(16, 77, 42)                   # non-default value
	b.add_struct_field(18, GTS.Vec3.create_vec3(b, 10.5, -2.25, 3.0), 0)
	b.add_offset_field(19, points_vec, 0)
	b.add_struct_field(20, GTS.Tricky.create_tricky(b, -1, 2.5, -3), 0)
	b.add_u64_hex_field(21, "0xffffffffffffffff")
	b.add_offset_field(22, blob, 0)
	b.add_i8_field(23, 7, 0)                        # col = Blue
	b.add_u8_field(24, 1, 0)                        # payload_type = Inner
	b.add_offset_field(25, in1, 0)                  # payload
	b.add_offset_field(26, pay_tags, 0)             # payloads_type
	b.add_offset_field(27, pay_vec, 0)              # payloads
	b.add_offset_field(28, items_vec, 0)            # items
	b.add_i32_field(29, 7, 0)                       # opt (optional, set)
	b.add_offset_field(30, legacy_off, 0)           # legacy
	b.add_offset_field(31, ids_off, 0)              # ids
	var root := b.end_table()
	b.finish(root)
	return b.to_packed_byte_array()
