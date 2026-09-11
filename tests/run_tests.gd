extends SceneTree
## headless test runner: godot --headless --script tests/run_tests.gd
## (run from the project root so res:// resolves)

const FB := preload("res://addons/godot_flatbuffers/flatbuffer.gd")
const FBB := preload("res://addons/godot_flatbuffers/flatbuffer_builder.gd")
const FBV := preload("res://addons/godot_flatbuffers/flatbuffer_verifier.gd")

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
	ok(bytes.size() == 280, "golden size 280 (got %d)" % bytes.size())
	ok(FBV.verify(bytes), "verifier accepts")

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

	print("== read golden/test2_defaults.bin ==")
	var d := FileAccess.get_file_as_bytes("res://tests/golden/test2_defaults.bin")
	ok(FBV.verify(d), "verifier accepts defaults buf")
	var td: FB = FB.root(d)
	ok(td.get_i32(16, 42) == 42, "absent int -> default 42")
	ok(td.get_string(11, "none") == "none", "absent name -> default")

	print("== rebuild + byte-compare ==")
	var rebuilt := _rebuild()
	ok(rebuilt == bytes, "builder output byte-identical to official builder (got %d bytes)" % rebuilt.size())
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

	print("== corruption cases ==")
	ok(not FBV.verify(PackedByteArray([1, 2])), "tiny buffer rejected")
	var trunc := bytes.slice(0, 20)
	ok(not FBV.verify(trunc), "truncated buffer rejected")

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

	b.start_table(18)
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
	var root := b.end_table()
	b.finish(root)
	return b.to_packed_byte_array()
