extends SceneTree
## headless test runner: godot --headless --script tests/run_tests.gd
## (run from the project root so res:// resolves)

const FB := preload("res://addons/godot_flatbuffers/flatbuffer.gd")
const FBB := preload("res://addons/godot_flatbuffers/flatbuffer_builder.gd")
const FBV := preload("res://addons/godot_flatbuffers/flatbuffer_verifier.gd")
const GTS := preload("res://tests/gen_schema.gd")

var failures := 0

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
	var jr := GEN.JoinReq.create_join_req(gb, 42, gb.create_string("tok123"), gb.create_string("Jetha"))
	# create_envelope(b, client_off, client_type, seq, server_off, server_type)
	var env := GEN.Envelope.create_envelope(gb, jr, GEN.TT_ClientMsg.JOINREQ, 1, 0, 0)
	gb.finish(env)
	var gbuf := gb.to_packed_byte_array()
	var ge := GEN.Envelope.get_root_as(gbuf)
	ok(ge.seq() == 1, "envelope seq=1")
	ok(ge.client_type() == GEN.TT_ClientMsg.JOINREQ, "union tag = JoinReq")
	var req: Object = GEN.JoinReq.wrap_fb(ge.client())
	ok(req.name() == "Jetha" and req.avatar_id() == 42, "joinreq fields round-trip")
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
	ib.finish(GTS.Inner.create_inner(ib, ib.create_string("nested"), 99))
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

	b.start_table(23)
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
	var root := b.end_table()
	b.finish(root)
	return b.to_packed_byte_array()
