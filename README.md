# godot-flatbuffers

Pure-GDScript [FlatBuffers](https://flatbuffers.dev) runtime for Godot 4 — no
GDExtension, no native toolchain. Copy `addons/godot_flatbuffers/` into your
project and it works on every platform Godot exports to (desktop, mobile, web).

## What's included

| File | Purpose |
|---|---|
| `addons/godot_flatbuffers/flatbuffer.gd` | `FlatBuffer` — read-side view over a table (scalars, strings, subtables, vectors, unions) |
| `addons/godot_flatbuffers/flatbuffer_builder.gd` | `FlatBufferBuilder` — canonical back-to-front buffer construction with vtable dedup |
| `addons/godot_flatbuffers/flatbuffer_verifier.gd` | `FlatBufferVerifier` — structural bounds-checking for untrusted buffers |
| `tools/generate_gd.py` | `.bfbs` → typed `.gd` accessor generator (uses flatc's own binary reflection) |

The builder is verified **byte-identical** against the official JS
implementation (`tests/run_tests.gd` rebuilds a golden buffer produced by
`flatbuffers`'s JS `Builder` and asserts equality).

## Quick start

```gdscript
const FB := preload("res://addons/godot_flatbuffers/flatbuffer.gd")
const FBB := preload("res://addons/godot_flatbuffers/flatbuffer_builder.gd")

# build
var b := FBB.new()
var name := b.create_string("dodo")
b.start_table(2)
b.add_u32_field(0, 17, 0)      # slot 0: card_id
b.add_offset_field(1, name, 0) # slot 1: name
var root := b.end_table()
b.finish(root)
var bytes := b.to_packed_byte_array()

# read
var t := FB.root(bytes)
var card_id := t.get_u32(0, 0)   # (slot, default)
var card_name := t.get_string(1)
```

## Code generation from schemas

`generate_gd.py` reads a **binary schema** (`.bfbs`) produced by the official
`flatc` compiler — no `.fbs` parsing, so it can never drift from flatc's own
interpretation:

```sh
# produce the binary schema
flatc --schema -b -o . myproto.fbs        # -> myproto.bfbs

# one-time: python bindings for reflection.fbs (ships with flatc sources)
flatc --python -o tools/reflection_gen reflection.fbs
pip install flatbuffers

# emit accessors
REFLECT_GEN=tools/reflection_gen python tools/generate_gd.py myproto.bfbs myproto_generated.gd
```

Generated output: one file with a class per table (`get_root_as`, `wrap_fb`,
per-field getters, `create_*` builder) and a class per enum of consts. Union
fields expose `x()` returning the raw `FlatBuffer` — wrap it with the member
type indicated by `x_type()`.

```gdscript
var req := TT.JoinReq.create_join_req(b, 42, b.create_string("tok"), b.create_string("Jetha"))
var env := TT.Envelope.create_envelope(b, req, TT.TT_ClientMsg.JOINREQ, 1)
b.finish(env)
peer.send(b.to_packed_byte_array())
```

## Runtime notes / limitations

- Field access is by **vtable slot index** (the `Id` flatc assigns), which the
  generator bakes into typed getters — you never write raw slots by hand when
  using generated code.
- Structs are not yet supported (tables-only schemas).
- `u64` values above `2^63-1` cannot be represented by GDScript's signed `int`.
- The verifier is structural (bounds/offsets), not schema-aware.

## Testing

```sh
godot --headless --import          # once: builds the global class cache
godot --headless --script tests/run_tests.gd
```

Regenerate goldens with `cd tests/node && node gen_golden.mjs`
(`npm i` first in `tests/node`).

## License

MIT — see [LICENSE](LICENSE).
