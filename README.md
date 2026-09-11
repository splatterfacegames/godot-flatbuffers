# godot-flatbuffers

Pure-GDScript [FlatBuffers](https://flatbuffers.dev) runtime for Godot 4 — no
GDExtension, no native toolchain. Copy `addons/godot_flatbuffers/` into your
project and it works on every platform Godot exports to (desktop, mobile, web).

## What's included

| File | Purpose |
|---|---|
| `addons/godot_flatbuffers/flatbuffer.gd` | `FlatBuffer` — read-side view over a table (scalars, strings, subtables, vectors, unions, structs, nested buffers) |
| `addons/godot_flatbuffers/flatbuffer_struct.gd` | `FlatBufferStruct` — read-side view over an inline struct (fixed layout, no vtable) |
| `addons/godot_flatbuffers/flatbuffer_builder.gd` | `FlatBufferBuilder` — canonical back-to-front buffer construction with vtable dedup |
| `addons/godot_flatbuffers/flatbuffer_verifier.gd` | `FlatBufferVerifier` — structural bounds-checking plus schema-aware verification for untrusted buffers |
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
- **Structs** are supported: `get_struct(slot)` / `get_vector_struct(slot, i, size)`
  return a `FlatBufferStruct` view; generated code emits typed struct accessors,
  an inline `create_<struct>(b, ...)` packer (wired into table builders via
  `add_struct_field`), and `create_<struct>_vector` / `start_<field>_vector`
  helpers. Nested struct members and fixed-size arrays inside structs work.
- **`u64` above `2^63-1`**: GDScript `int` is signed 64-bit, so `get_u64` /
  `add_u64_field` cover values up to `i64::MAX`; beyond that they expose the raw
  bit pattern as a negative int. Use `get_u64_hex` / `get_u64_bytes` (read) and
  `add_u64_hex_field` / `write_u64_hex` (write) for the full unsigned range;
  generated code emits `<field>_hex()` accessors for `ulong` fields.
- **Verifier**: `FlatBufferVerifier.verify()` is the schema-free structural
  bounds-check. Generated `SomeTable.verify(buf)` adds schema-aware verification
  (field sizes, string NUL terminators, vector contents, nested tables, union
  tag/payload consistency) via `verify_root(buf, _spec())`.
- **Size-prefixed buffers** (`flatc --size-prefixed`): `builder.finish(root, fid,
  true)` / `finish_size_prefixed` on write; `FlatBuffer.root_size_prefixed`,
  `FlatBufferVerifier.verify_size_prefixed`, and generated
  `get_size_prefixed_root_as` on read.
- **`force_defaults` schemas**: set `builder.force_defaults = true` or pass
  `force := true` to any `add_*_field`; `has_field(slot)` distinguishes an
  explicitly-stored default from an absent field.
- **Byte vectors**: `create_byte_vector(PackedByteArray)` writes a `[ubyte]`
  directly; `get_vector_bytes(slot)` reads it back. `get_nested_root(slot)`
  returns a `FlatBuffer` rooted at a `nested_flatbuffer`-style embedded buffer.
- Remaining gaps: no unpacked "object API" (`XxxT` data objects), no JSON/text
  round-trip, no `vector64` (>4 GiB vectors), no gRPC service emission. Union
  payloads expose the raw `FlatBuffer` — wrap it with the member type indicated
  by `<field>_type()`.

## Testing

```sh
godot --headless --import          # once: builds the global class cache
godot --headless --script tests/run_tests.gd
```

Regenerate fixtures after changing `tests/schema.fbs`:

```sh
cd tests/node && node gen_golden.mjs       # golden .bin vectors (npm i first)
flatc --schema -b -o tests tests/schema.fbs
python tools/generate_gd.py tests/schema.bfbs tests/gen_schema.gd --class-name GTS
python tools/generate_gd.py tests/tt.bfbs tests/gen_tt.gd --class-name FBSchema
```

## License

MIT — see [LICENSE](LICENSE).
