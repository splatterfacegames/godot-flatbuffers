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
per-field getters, `create_*` builder), a class per enum of consts (plus
`name_of`/`value_of` string maps), object-API (`to_dict`/`from_dict`) and
JSON (`to_json`/`from_json`) helpers on every table and struct, and a
`<Service>Client` + `<Service>Server` pair per `rpc_service`.

```gdscript
var req := TT.JoinReq.create_join_req(b, b.create_string("Jetha"), 42, b.create_string("tok"))
var env := TT.Envelope.create_envelope(b, 1, TT.TT_ClientMsg.JOINREQ, req)
b.finish(env)
peer.send(b.to_packed_byte_array())
```

### Object API — `to_dict` / `from_dict`

Every generated table and struct converts to/from a plain `Dictionary`:

```gdscript
var d := TT.Envelope.get_root_as(buf).to_dict()
var b2 := FlatBufferBuilder.new()
b2.finish(TT.Envelope.from_dict(b2, d))
```

Conventions: field names are verbatim; tables and structs nest as
Dictionaries; vectors become Arrays; `[ubyte]`/`[byte]` become
`PackedByteArray`; enum fields become their declared names (`"Blue"`);
`ulong` fields keep the raw signed bit pattern (`-1` = u64 max — see the u64
note; `from_dict` also accepts `"0x..."` hex and decimal strings); unions use
flatc's shape `{"u_type": "MemberName", "u": {...}}`. Absent fields are
simply missing keys; `from_dict` honors `required` fields the same way
`create_*` does.

### JSON — `to_json` / `from_json`

`to_json()` stringifies the same shape `flatc --json --strict-json` produces:
only fields present in the buffer are emitted, field names verbatim, enums
as declared names, `ulong` as an unsigned decimal number, `[ubyte]` as an
int array. Verified by parsing `flatc --json` output and deep-comparing.

`from_json(text)` builds and returns a wrapped root. Caveat: a `ulong` value
above `2^63-1` arrives through JSON as a float — it survives `to_json`→
`from_json` within double precision but cannot be exactly recovered (use
`to_dict`/`from_dict` with hex strings for exact round-trips).

### Union ergonomics

For `u:MyUnion` fields the generated class emits `u_as_<member>()` returning
the typed wrapper (or `String` for string members; `null`/`""` when the tag
doesn't match) and `u_unwrap()` returning whichever member `u_type()` names.
Vector unions get `us_unwrap(i)`. The raw `FlatBuffer` accessor stays
available as `u()`.

### gRPC-style services

`rpc_service S { M(Req):Res; }` generates `SClient`/`SServer`, transport
agnostic — inject any `send(path, payload: PackedByteArray) -> PackedByteArray`:

```gdscript
class MyHandler:
    func check(req, _b) -> Variant:
        return {"tag": "ok"}          # Dictionary -> packed via Res.from_dict

var server := GTS.CalcServer.new(MyHandler.new())
var client := GTS.CalcClient.new(server.dispatch)   # in-process loopback
var res := client.check(b, GTS.Inner.create_inner(b, 1, b.create_string("q")))
```

Method paths are `/<namespace>.<Service>/<Method>`; the handler may return a
`Dictionary` (packed via `Res.from_dict`) or a table offset built on the
supplied builder.

### vector64 / offset64

`(vector64)` fields (u64 field offset, u64 length prefix, elements
contiguous after it — the canonical `FlatBufferBuilder64` layout) are fully
supported: `create_*_vector64`/`start_*_vector64`/`end_vector64` on the
builder, `vector64_len`/`get_vector64_*` readers, `add_offset64_field` for
the 8-byte field offset, generated typed accessors, and verifier spec kind
`"vector64"`. As upstream requires, all 64-bit objects must be serialized
before any 32-bit object — the builder enforces this.

`(offset64)` alone (on strings or 32-bit-length vectors) works via
`add_offset64_field` + `get_string64`/`vector_len_off64`/`_vec_elem_off64`
and spec kind `"off64"`.

**Known upstream caveat (not ours):** `flatc -b` (JSON→binary) uses a
32-bit-fallback path for vector64 that inserts an extra pad between the u64
length and elements when the vector's own size is not 8-aligned, and flatc's
`.bfbs` reflection output does not record the `offset64`/`nested_flatbuffer`
attributes — so generated code can't auto-detect `offset64`-only fields
(use the runtime API above) or auto-mark nested-buffer verification (pass a
`"nested"` spec entry, as `tests/run_tests.gd` does).

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
- **Sorted vectors / `key`**: for a `[table]` vector whose element table has a
  `(key)` field, generated code emits `<field>_by_key(v)` — a binary search
  over the sorted vector (flatc's `LookupByKey` parity).
- **Optional scalars** (`x:int = null`): `has_<x>()` reports presence;
  `create_*`/`from_dict` emit the field only when set.
- **Deprecated fields** remain readable/writable (`flatc --json` emits them
  too); **`(id: N)` attributes** are honored — all generated accessors are
  keyed on the field's `Id`, not declaration order.
- **Remaining gaps: none known.** The only documented caveats are the
  upstream flatc ones noted under "vector64 / offset64" (`.bfbs` attribute
  stripping, `flatc -b` padding quirk) and the JSON `ulong > 2^63-1`
  precision note above.

## Testing

```sh
godot --headless --import          # once: builds the global class cache
godot --headless --script tests/run_tests.gd
```

Regenerate fixtures after changing `tests/schema.fbs` / `tests/v64.fbs`:

```sh
cd tests/node && node gen_golden.mjs       # golden .bin vectors (npm i first)
flatc --schema -b -o tests tests/schema.fbs tests/v64.fbs
flatc -b -o tests/golden tests/v64.fbs tests/golden/v64_input.json   # test5_v64.bin
flatc --json --strict-json --raw-binary -o tests/golden tests/schema.fbs -- tests/golden/test1.bin
python tools/generate_gd.py tests/schema.bfbs tests/gen_schema.gd --class-name FBSchema
python tools/generate_gd.py tests/v64.bfbs tests/gen_v64.gd --class-name FBV64Schema
python tools/generate_gd.py tests/tt.bfbs tests/gen_tt.gd --class-name FBTTSchema
```

## License

MIT — see [LICENSE](LICENSE).
