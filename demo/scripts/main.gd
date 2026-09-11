extends Control
## godot-flatbuffers live demo — build / decode / verify / bench packets
## entirely in GDScript, running in the browser.

const GEN := preload("res://gen/demo_generated.gd")
const FB := preload("res://addons/godot_flatbuffers/flatbuffer.gd")
const FBB := preload("res://addons/godot_flatbuffers/flatbuffer_builder.gd")
const FBV := preload("res://addons/godot_flatbuffers/flatbuffer_verifier.gd")

var msg_type: OptionButton
var seq_edit: LineEdit
var sent_by_edit: LineEdit
# per-type field editors (LineEdits / OptionButton), populated on type switch
var fields_box: VBoxContainer
var field_edits := {}
var out_hex: TextEdit
var decode_out: TextEdit
var bench_out: Label
var last_packet: PackedByteArray

func _ready() -> void:
	_build_ui()
	_on_type_changed(0)

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.075, 0.115)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	root.offset_left = 16; root.offset_top = 12; root.offset_right = -16; root.offset_bottom = -12
	add_child(root)

	var title := Label.new()
	title.text = "godot-flatbuffers — FlatBuffers in pure GDScript, running in your browser"
	title.add_theme_font_size_override("font_size", 20)
	root.add_child(title)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)

	# ── left: builder ──
	var left := PanelContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 6)
	left.add_child(lv)

	lv.add_child(_h("Build a packet"))
	msg_type = OptionButton.new()
	for t in ["ChatMsg", "MoveMsg", "SpawnMsg"]: msg_type.add_item(t)
	msg_type.item_selected.connect(_on_type_changed)
	lv.add_child(msg_type)

	seq_edit = _row(lv, "seq", "42")
	sent_by_edit = _row(lv, "sent_by", "web-demo")
	fields_box = VBoxContainer.new()
	lv.add_child(fields_box)

	var build_btn := Button.new()
	build_btn.text = "Build buffer"
	build_btn.pressed.connect(_on_build)
	lv.add_child(build_btn)

	# ── right: output ──
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	cols.add_child(right)

	right.add_child(_h("Wire format (hex)"))
	out_hex = TextEdit.new()
	out_hex.custom_minimum_size = Vector2(0, 120)
	out_hex.editable = false
	right.add_child(out_hex)

	right.add_child(_h("Decode (read back through generated accessors)"))
	decode_out = TextEdit.new()
	decode_out.custom_minimum_size = Vector2(0, 160)
	decode_out.editable = false
	right.add_child(decode_out)

	var row := HBoxContainer.new()
	var verify_btn := Button.new()
	verify_btn.text = "Verify buffer"
	verify_btn.pressed.connect(_on_verify)
	row.add_child(verify_btn)
	var bench_btn := Button.new()
	bench_btn.text = "Bench: 5k build+decode"
	bench_btn.pressed.connect(_on_bench)
	row.add_child(bench_btn)
	right.add_child(row)
	bench_out = Label.new()
	right.add_child(bench_out)

func _h(t: String) -> Label:
	var l := Label.new(); l.text = t
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color(0.55, 0.72, 1.0))
	return l

func _row(parent: Control, label: String, dflt := "") -> LineEdit:
	var h := HBoxContainer.new()
	var l := Label.new(); l.text = label; l.custom_minimum_size.x = 90
	h.add_child(l)
	var e := LineEdit.new(); e.text = dflt; e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(e)
	parent.add_child(h)
	return e

func _on_type_changed(idx: int) -> void:
	for c in fields_box.get_children(): c.queue_free()
	field_edits.clear()
	match idx:
		0: # ChatMsg
			field_edits.author = _row(fields_box, "author", "dodo")
			field_edits.text = _row(fields_box, "text", "kweh! wark!")
			field_edits.sent_at = _row(fields_box, "sent_at", "1757480000")
		1: # MoveMsg
			field_edits.from_cell = _row(fields_box, "from_cell", "4")
			field_edits.to_cell = _row(fields_box, "to_cell", "5")
			field_edits.card_id = _row(fields_box, "card_id", "74")
			field_edits.combo_chain = _row(fields_box, "combo_chain", "1,0,4")
		2: # SpawnMsg
			field_edits.name = _row(fields_box, "name", "spriggan")
			field_edits.score = _row(fields_box, "score", "9.5")
			field_edits.pos = _row(fields_box, "pos xyz", "1.0,2.5,-3")
			field_edits.tags = _row(fields_box, "tags (csv)", "primal,shiny")
			var sh := OptionButton.new()
			for s in ["Circle", "Square", "Triangle"]: sh.add_item(s)
			sh.selected = 1
			var h := HBoxContainer.new()
			var l := Label.new(); l.text = "shape"; l.custom_minimum_size.x = 90
			h.add_child(l); h.add_child(sh); fields_box.add_child(h)
			field_edits.shape = sh

func _build_packet() -> PackedByteArray:
	var b := FBB.new()
	var mtype := 0
	var moff := 0
	match msg_type.selected:
		0:
			mtype = GEN.Demo_DemoMsg.CHATMSG
			moff = GEN.ChatMsg.create_chat_msg(b,
				b.create_string(field_edits.author.text),
				b.create_string(field_edits.text.text),
				int(field_edits.sent_at.text))
		1:
			mtype = GEN.Demo_DemoMsg.MOVEMSG
			var chain: Array = []
			for p in field_edits.combo_chain.text.split(","):
				if p.strip_edges() != "": chain.append(int(p))
			var coff := b.create_u8_vector(chain)
			moff = GEN.MoveMsg.create_move_msg(b,
				int(field_edits.from_cell.text), int(field_edits.to_cell.text),
				int(field_edits.card_id.text), coff)
		2:
			mtype = GEN.Demo_DemoMsg.SPAWNMSG
			var tag_offs: Array = []
			for t in field_edits.tags.text.split(","):
				if t.strip_edges() != "": tag_offs.append(b.create_string(t.strip_edges()))
			var toff := b.create_offset_vector(tag_offs)
			var pos: Array = []
			for p in field_edits.pos.text.split(","):
				if p.strip_edges() != "": pos.append(float(p))
			while pos.size() < 3: pos.append(0.0)
			moff = GEN.SpawnMsg.create_spawn_msg(b,
				b.create_string(field_edits.name.text),
				field_edits.shape.selected,
				float(field_edits.score.text), pos, toff)
	# create_packet(b, seq, sent_by_off, msg_type, msg_off)
	var pkt := GEN.Packet.create_packet(b, int(seq_edit.text),
		b.create_string(sent_by_edit.text), mtype, moff)
	b.finish(pkt)
	return b.to_packed_byte_array()

func _on_build() -> void:
	var t0 := Time.get_ticks_usec()
	last_packet = _build_packet()
	var us := Time.get_ticks_usec() - t0
	var hex := last_packet.hex_encode()
	# pretty: group bytes in 2s? hex_encode gives contiguous; wrap at 32 chars
	var wrapped := ""
	for i in range(0, hex.length(), 32):
		wrapped += hex.substr(i, 32) + "\n"
	out_hex.text = wrapped.strip_edges()
	decode_out.text = _decode_packet(last_packet) + "\n(built %d bytes in %d µs)" % [last_packet.size(), us]

func _on_verify() -> void:
	var hex := out_hex.text.strip_edges().replace("\n", "").replace(" ", "")
	if hex.length() % 2 != 0:
		decode_out.text = "verify: odd hex length"
		return
	var bytes := PackedByteArray()
	for i in range(0, hex.length(), 2):
		bytes.append(hex.substr(i, 2).hex_to_int())
	var ok := FBV.verify(bytes)
	var extra := ""
	if ok:
		extra = "\n" + _decode_packet(bytes)
	decode_out.text = "verify: %s (size %d)%s" % ["VALID" if ok else "INVALID", bytes.size(), extra]

func _on_bench() -> void:
	const N := 5000
	var t0 := Time.get_ticks_usec()
	for i in N:
		var p := _build_packet()
		var e := GEN.Packet.get_root_as(p)
		var _x: int = e.seq()
	var total := Time.get_ticks_usec() - t0
	bench_out.text = "%d packets built+decoded in %.1f ms  →  %.0f ops/sec" % [N, total / 1000.0, N / (total / 1e6)]

func _decode_packet(buf: PackedByteArray) -> String:
	var p = GEN.Packet.get_root_as(buf)
	var lines := ["Packet seq=%d sent_by='%s' msg_type=%d" % [p.seq(), p.sent_by(), p.msg_type()],
		"json: " + p.to_json()]
	match p.msg_type():
		GEN.Demo_DemoMsg.CHATMSG:
			var m = GEN.ChatMsg.wrap_fb(p.msg())
			lines.append("  ChatMsg author='%s' text='%s' sent_at=%d" % [m.author(), m.text(), m.sent_at()])
		GEN.Demo_DemoMsg.MOVEMSG:
			var m = GEN.MoveMsg.wrap_fb(p.msg())
			var chain := []
			for i in m.combo_chain_len(): chain.append(m.combo_chain(i))
			lines.append("  MoveMsg %d→%d card=%d combo=%s" % [m.from_cell(), m.to_cell(), m.card_id(), chain])
		GEN.Demo_DemoMsg.SPAWNMSG:
			var m = GEN.SpawnMsg.wrap_fb(p.msg())
			var tags := []
			for i in m.tags_len(): tags.append(m.tags(i))
			var pos = m.pos()
			var pos_s := "null" if pos == null else "(%.2f, %.2f, %.2f)" % [pos.x(), pos.y(), pos.z()]
			lines.append("  SpawnMsg name='%s' shape=%d score=%.2f pos=%s tags=%s" % [m.name(), m.shape(), m.score(), pos_s, tags])
	return "\n".join(lines)
