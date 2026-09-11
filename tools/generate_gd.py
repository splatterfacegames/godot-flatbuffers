#!/usr/bin/env python3
"""generate_gd.py — emit GDScript FlatBuffers accessors from a .bfbs schema.

Usage:
    flatc --schema -b -o . schema.fbs          # produces schema.bfbs
    python generate_gd.py schema.bfbs out_generated.gd

Requires: pip install flatbuffers, and reflection.fbs compiled with
    flatc --python reflection.fbs   (point --reflect-path at its output)

Emits a single .gd file containing one inner class per table plus enum
constants. Read side wraps the pure-GDScript FlatBuffer runtime; build side
emits create_*() functions taking FlatBufferBuilder. Structs get an inline
packer (create_<name>) plus a struct-vector helper; every table gets a
schema-aware verify() backed by FlatBufferVerifier.
"""
import argparse
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tests", "gen_py"))
sys.path.insert(0, os.environ.get("REFLECT_GEN", ""))
from reflection.Schema import Schema  # noqa: E402
from reflection.BaseType import BaseType  # noqa: E402

# BaseType -> (reader getter, builder add, size)
SCALAR = {
    BaseType.Bool: ("get_bool", "add_bool_field", 1),
    BaseType.Byte: ("get_i8", "add_i8_field", 1),
    BaseType.UByte: ("get_u8", "add_u8_field", 1),
    BaseType.UType: ("get_u8", "add_u8_field", 1),
    BaseType.Short: ("get_i16", "add_i16_field", 2),
    BaseType.UShort: ("get_u16", "add_u16_field", 2),
    BaseType.Int: ("get_i32", "add_i32_field", 4),
    BaseType.UInt: ("get_u32", "add_u32_field", 4),
    BaseType.Long: ("get_i64", "add_i64_field", 8),
    BaseType.ULong: ("get_u64", "add_u64_field", 8),
    BaseType.Float: ("get_f32", "add_f32_field", 4),
    BaseType.Double: ("get_f64", "add_f64_field", 8),
}
VEC_GET = {
    BaseType.Bool: "get_vector_bool", BaseType.Byte: "get_vector_i8",
    BaseType.UByte: "get_vector_u8", BaseType.UType: "get_vector_u8",
    BaseType.Short: "get_vector_i16", BaseType.UShort: "get_vector_u16",
    BaseType.Int: "get_vector_i32", BaseType.UInt: "get_vector_u32",
    BaseType.Long: "get_vector_i64", BaseType.ULong: "get_vector_u64",
    BaseType.Float: "get_vector_f32", BaseType.Double: "get_vector_f64",
    BaseType.String: "get_vector_string",
}
# BaseType -> (vector elem size, create_*_vector helper)
VEC_BUILD = {
    BaseType.Bool: (1, "create_bool_vector"), BaseType.Byte: (1, "create_i8_vector"),
    BaseType.UByte: (1, "create_u8_vector"), BaseType.UType: (1, "create_u8_vector"),
    BaseType.Short: (2, "create_i16_vector"), BaseType.UShort: (2, "create_u16_vector"),
    BaseType.Int: (4, "create_i32_vector"), BaseType.UInt: (4, "create_u32_vector"),
    BaseType.Long: (8, "create_i64_vector"), BaseType.ULong: (8, "create_u64_vector"),
    BaseType.Float: (4, "create_f32_vector"), BaseType.Double: (8, "create_f64_vector"),
}
# struct member BaseType -> raw write_* on the builder
WRITE = {
    BaseType.Bool: "write_bool", BaseType.Byte: "write_i8",
    BaseType.UByte: "write_u8", BaseType.UType: "write_u8",
    BaseType.Short: "write_i16", BaseType.UShort: "write_u16",
    BaseType.Int: "write_i32", BaseType.UInt: "write_u32",
    BaseType.Long: "write_i64", BaseType.ULong: "write_u64",
    BaseType.Float: "write_f32", BaseType.Double: "write_f64",
}

def snake(name: bytes) -> str:
    return name.decode()

def gd_ident(name: str) -> str:
    out, up = [], True
    for ch in name:
        if ch.isupper() and not up:
            out.append("_")
        up = ch.isupper()
        out.append(ch.lower())
    return "".join(out)

# Godot built-in/global names a generated class must not shadow
RESERVED = {"Error", "Object", "RefCounted", "String", "StringName", "Array",
            "Dictionary", "Callable", "Signal", "Vector2", "Vector3", "Vector4",
            "Color", "Transform2D", "Transform3D", "Quaternion", "Basis",
            "AABB", "Rect2", "Plane", "Node", "Resource", "PackedByteArray"}

def safe(name: str) -> str:
    return name + "FB" if name in RESERVED else name

def member_size(t, obj_by_index) -> int:
    """Byte size of a struct member's storage."""
    bt = t.BaseType()
    if bt == BaseType.Obj:
        return obj_by_index[t.Index()].Bytesize()
    if bt == BaseType.Array:
        return t.ElementSize() * t.FixedLength()
    return t.BaseSize()

def elem_desc(et, t, obj_by_index):
    """Verifier spec desc for a vector element type."""
    if et == BaseType.String:
        return '{"k": "string"}'
    if et == BaseType.Obj:
        o = obj_by_index[t.Index()]
        if o.IsStruct():
            return '{"k": "struct", "size": %d}' % o.Bytesize()
        tn = safe(o.Name().decode().split(".")[-1])
        return '{"k": "table", "spec": Callable(%s, "_spec")}' % tn
    size = VEC_BUILD.get(et, (4, ""))[0]
    return '{"k": "scalar", "size": %d}' % size

def field_desc(f, fields_by_name, objects, obj_by_index, enums):
    """Verifier spec desc for one table field, or None."""
    bt = f.Type().BaseType()
    if bt == BaseType.String:
        return '{"k": "string"}'
    if bt == BaseType.Obj:
        o = obj_by_index[f.Type().Index()]
        if o.IsStruct():
            return '{"k": "struct", "size": %d}' % o.Bytesize()
        tn = safe(o.Name().decode().split(".")[-1])
        return '{"k": "table", "spec": Callable(%s, "_spec")}' % tn
    if bt == BaseType.Union:
        type_field = fields_by_name.get(snake(f.Name()) + "_type")
        type_slot = type_field.Id() if type_field else -1
        members = []
        if 0 <= f.Type().Index() < len(enums):
            e = enums[f.Type().Index()]
            for i in range(e.ValuesLength()):
                v = e.Values(i)
                ut = v.UnionType()
                if ut is None or v.Value() == 0:
                    continue
                if ut.BaseType() == BaseType.String:
                    members.append('%d: {"k": "string"}' % v.Value())
                elif ut.BaseType() == BaseType.Obj:
                    mo = obj_by_index[ut.Index()]
                    tn = safe(mo.Name().decode().split(".")[-1])
                    members.append('%d: {"k": "table", "spec": Callable(%s, "_spec")}'
                                   % (v.Value(), tn))
        return ('{"k": "union", "type_slot": %d, "members": {%s}}'
                % (type_slot, ", ".join(members)))
    if bt == BaseType.Vector:
        d = '{"k": "vector", "elem": %s}' % elem_desc(
            f.Type().Element(), f.Type(), obj_by_index)
        # nested_flatbuffer: "Type" attribute naming the embedded root table
        for i in range(f.AttributesLength()):
            a = f.Attributes(i)
            if a.Key() == b"nested_flatbuffer":
                want = a.Value().decode().strip('"').split(".")[-1]
                for o in objects:
                    if o.Name().decode().split(".")[-1] == want:
                        tn = safe(want)
                        d = d[:-1] + ', "nested": Callable(%s, "_spec")}' % tn
                        break
        return d
    if bt in SCALAR:
        return '{"k": "scalar", "size": %d}' % SCALAR[bt][2]
    return None

def emit_struct(lines, o, objects, obj_by_index):
    """Accessor + inline packer + vector helper for a struct."""
    cname = safe(o.Name().decode().split(".")[-1])
    size, align = o.Bytesize(), o.Minalign()
    fields = [o.Fields(i) for i in range(o.FieldsLength())]
    lines.append(f"class {cname}:")
    lines.append(f"\tconst SIZE := {size}")
    lines.append(f"\tconst ALIGN := {align}")
    lines.append("\tvar _s: FlatBufferStruct_")
    lines.append(f"\tstatic func wrap_fb(s: FlatBufferStruct_) -> {cname}:")
    lines.append("\t\tif s == null: return null")
    lines.append(f"\t\tvar x := {cname}.new()")
    lines.append("\t\tx._s = s")
    lines.append("\t\treturn x")
    lines.append("\tfunc is_valid() -> bool: return _s != null and _s.is_valid()")

    for f in fields:
        fn = snake(f.Name())
        off, bt = f.Offset(), f.Type().BaseType()
        if bt == BaseType.Obj:
            tn = safe(obj_by_index[f.Type().Index()].Name().decode().split(".")[-1])
            lines.append(f"\tfunc {fn}() -> {tn}: return {tn}.wrap_fb(_s.get_struct({off}))")
        elif bt == BaseType.Array:
            et = f.Type().Element()
            n = f.Type().FixedLength()
            lines.append(f"\tfunc {fn}_len() -> int: return {n}")
            if et == BaseType.Obj:
                tn = safe(obj_by_index[f.Type().Index()].Name().decode().split(".")[-1])
                es = obj_by_index[f.Type().Index()].Bytesize()
                lines.append(f"\tfunc {fn}(i: int) -> {tn}: return {tn}.wrap_fb(_s.get_struct({off} + i * {es}))")
            else:
                g = SCALAR.get(et, ("get_i32", "", 4))[0]
                es = SCALAR.get(et, ("", "", 4))[2]
                lines.append(f"\tfunc {fn}(i: int) -> Variant: return _s.{g}({off} + i * {es})")
        elif bt == BaseType.ULong:
            lines.append(f"\tfunc {fn}() -> Variant: return _s.get_u64({off})")
            lines.append(f"\tfunc {fn}_hex() -> String: return _s.get_u64_hex({off})")
        else:
            g = SCALAR.get(bt, ("get_i32", "", 4))[0]
            lines.append(f"\tfunc {fn}() -> Variant: return _s.{g}({off})")

    # inline packer: members written in descending byte-offset order, with
    # explicit pad() for alignment gaps — mirrors the canonical impls.
    params = []
    for f in fields:
        bt = f.Type().BaseType()
        if bt in (BaseType.Obj, BaseType.Array):
            params.append(f"{snake(f.Name())}: Variant = null")
        else:
            is_float = bt in (BaseType.Float, BaseType.Double)
            params.append(f"{snake(f.Name())}: {'float' if is_float else 'int'} = 0")
    lines.append("")
    lines.append(f"\t## Write the struct inline at the builder head (tables: pass the")
    lines.append(f"\t## result straight to add_struct_field; vectors: create_{gd_ident(cname)}_vector).")
    lines.append(f"\tstatic func create_{gd_ident(cname)}(__b: FlatBufferBuilder_, {', '.join(params)}) -> int:")
    lines.append(f"\t\t__b.prep({align}, {size})")
    by_off = sorted(fields, key=lambda f: f.Offset(), reverse=True)
    prev_start = size
    for f in by_off:
        off = f.Offset()
        msz = member_size(f.Type(), obj_by_index)
        gap = prev_start - (off + msz)
        if gap > 0:
            lines.append(f"\t\t__b.pad({gap})")
        fn, bt = snake(f.Name()), f.Type().BaseType()
        if bt == BaseType.Obj:
            tn = safe(obj_by_index[f.Type().Index()].Name().decode().split(".")[-1])
            lines.append(f"\t\t{tn}.create_{gd_ident(tn)}.callv([__b] + {fn})")
        elif bt == BaseType.Array:
            et = f.Type().Element()
            n = f.Type().FixedLength()
            if et == BaseType.Obj:
                tn = safe(obj_by_index[f.Type().Index()].Name().decode().split(".")[-1])
                lines.append(f"\t\tfor i in range({n} - 1, -1, -1):")
                lines.append(f"\t\t\t{tn}.create_{gd_ident(tn)}.callv([__b] + {fn}[i])")
            else:
                w = WRITE.get(et, "write_i32")
                lines.append(f"\t\tfor i in range({n} - 1, -1, -1): __b.{w}({fn}[i])")
        else:
            w = WRITE.get(bt, "write_i32")
            lines.append(f"\t\t__b.{w}({fn})")
        prev_start = off
    if by_off and by_off[-1].Offset() > 0:
        lines.append(f"\t\t__b.pad({by_off[-1].Offset()})")
    lines.append("\t\treturn __b.offset()")

    csn = gd_ident(cname)
    lines.append("")
    lines.append(f"\t## Vector of `{cname}` — `data` is an Array of member args")
    lines.append(f"\t## (each element an Array passed to create_{csn}).")
    lines.append(f"\tstatic func create_{csn}_vector(__b: FlatBufferBuilder_, data: Array) -> int:")
    lines.append(f"\t\t__b.start_vector(SIZE, data.size(), ALIGN)")
    lines.append("\t\tfor i in range(data.size() - 1, -1, -1):")
    lines.append(f"\t\t\tcreate_{csn}.callv([__b] + data[i])")
    lines.append("\t\treturn __b.end_vector()")
    lines.append("")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("bfbs")
    ap.add_argument("out")
    ap.add_argument("--class-name", default="FBSchema")
    args = ap.parse_args()

    schema = Schema.GetRootAs(open(args.bfbs, "rb").read(), 0)
    objects = [schema.Objects(i) for i in range(schema.ObjectsLength())]
    enums = [schema.Enums(i) for i in range(schema.EnumsLength())]
    obj_by_index = {i: o for i, o in enumerate(objects)}

    lines = [f"# GENERATED by generate_gd.py from {os.path.basename(args.bfbs)} — do not edit",
             "class_name %s" % args.class_name, "",
             "const FlatBuffer_ = preload(\"res://addons/godot_flatbuffers/flatbuffer.gd\")",
             "const FlatBufferBuilder_ = preload(\"res://addons/godot_flatbuffers/flatbuffer_builder.gd\")",
             "const FlatBufferStruct_ = preload(\"res://addons/godot_flatbuffers/flatbuffer_struct.gd\")",
             "const FlatBufferVerifier_ = preload(\"res://addons/godot_flatbuffers/flatbuffer_verifier.gd\")",
             ""]

    # enums -> consts
    for e in enums:
        ename = e.Name().decode().replace(".", "_")
        lines.append(f"class {ename}:")
        for i in range(e.ValuesLength()):
            v = e.Values(i)
            lines.append(f"\tconst {snake(v.Name()).upper()} = {v.Value()}")
        lines.append("")

    for o in objects:
        if o.IsStruct():
            emit_struct(lines, o, objects, obj_by_index)
            continue
        cname = safe(o.Name().decode().split(".")[-1])
        lines.append(f"class {cname}:")
        lines.append("\tvar _t: FlatBuffer_")
        lines.append("\tstatic func get_root_as(buf: PackedByteArray) -> %s:" % cname)
        lines.append("\t\treturn wrap_fb(FlatBuffer_.root(buf))")
        lines.append("\tstatic func get_size_prefixed_root_as(buf: PackedByteArray) -> %s:" % cname)
        lines.append("\t\treturn wrap_fb(FlatBuffer_.root_size_prefixed(buf))")
        lines.append("\tstatic func wrap_fb(fb: FlatBuffer_) -> %s:" % cname)
        lines.append("\t\tif fb == null: return null")
        lines.append("\t\tvar x := %s.new()" % cname)
        lines.append("\t\tx._t = fb")
        lines.append("\t\treturn x")
        lines.append("\t## Schema-aware verification (FlatBufferVerifier_ fallback: FBV.verify).")
        lines.append("\tstatic func verify(buf: PackedByteArray, size_prefixed := false) -> bool:")
        lines.append("\t\treturn FlatBufferVerifier_.verify_root(buf, _spec(), size_prefixed)")
        lines.append("\tstatic func _spec() -> Dictionary:")
        fields = [o.Fields(i) for i in range(o.FieldsLength())]
        fields_by_name = {snake(f.Name()): f for f in fields}
        descs = []
        for f in fields:
            d = field_desc(f, fields_by_name, objects, obj_by_index, enums)
            if d is not None:
                descs.append("%d: %s" % (f.Id(), d))
        lines.append("\t\treturn {%s}" % ", ".join(descs))

        for f in fields:
            fn = snake(f.Name())
            slot = f.Id()
            bt = f.Type().BaseType()
            et = f.Type().Element()
            dflt_i, dflt_r = f.DefaultInteger(), f.DefaultReal()
            if bt == BaseType.String:
                lines.append(f"\tfunc {fn}() -> String: return _t.get_string({slot})")
            elif bt == BaseType.Obj:
                so = obj_by_index[f.Type().Index()]
                tn = safe(so.Name().decode().split(".")[-1])
                if so.IsStruct():
                    lines.append(f"\tfunc {fn}() -> {tn}: return {tn}.wrap_fb(_t.get_struct({slot})) if _t.has_field({slot}) else null")
                else:
                    lines.append(f"\tfunc {fn}() -> {tn}: return {tn}.wrap_fb(_t.get_table({slot})) if _t.has_field({slot}) else null")
            elif bt == BaseType.Union:
                # `{name}_type` accessor comes from the separately-emitted UType field
                lines.append(f"\tfunc {fn}() -> FlatBuffer_: return _t.get_table({slot})")
            elif bt == BaseType.Vector:
                if et == BaseType.Obj:
                    vo = obj_by_index[f.Type().Index()]
                    tn = safe(vo.Name().decode().split(".")[-1])
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.vector_len({slot})")
                    if vo.IsStruct():
                        lines.append(f"\tfunc {fn}(i: int) -> {tn}: return {tn}.wrap_fb(_t.get_vector_struct({slot}, i, {tn}.SIZE))")
                    else:
                        lines.append(f"\tfunc {fn}(i: int) -> {tn}: return {tn}.wrap_fb(_t.get_vector_table({slot}, i))")
                elif et == BaseType.String:
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.vector_len({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> String: return _t.get_vector_string({slot}, i)")
                elif et == BaseType.UByte:
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.vector_len({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> Variant: return _t.get_vector_u8({slot}, i)")
                    lines.append(f"\tfunc {fn}_bytes() -> PackedByteArray: return _t.get_vector_bytes({slot})")
                elif et == BaseType.ULong:
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.vector_len({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> Variant: return _t.get_vector_u64({slot}, i)")
                    lines.append(f"\tfunc {fn}_hex(i: int) -> String: return _t.get_vector_u64_hex({slot}, i)")
                else:
                    g = VEC_GET.get(et, "get_vector_i32")
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.vector_len({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> Variant: return _t.{g}({slot}, i)")
            elif bt == BaseType.ULong:
                lines.append(f"\tfunc {fn}() -> Variant: return _t.get_u64({slot}, {dflt_i})")
                lines.append(f"\tfunc {fn}_hex() -> String: return _t.get_u64_hex({slot}, \"0x{int(dflt_i) & 0xFFFFFFFFFFFFFFFF:x}\")")
            else:
                g, _, _ = SCALAR.get(bt, ("get_i32", "add_i32_field", 4))
                is_float = bt in (BaseType.Float, BaseType.Double)
                d = dflt_r if is_float else dflt_i
                drepr = repr(d) if is_float else str(d)
                lines.append(f"\tfunc {fn}() -> Variant: return _t.{g}({slot}, {drepr})")
            if f.Optional() and bt not in (BaseType.String, BaseType.Obj,
                                           BaseType.Union, BaseType.Vector):
                lines.append(f"\tfunc has_{fn}() -> bool: return _t.has_field({slot})")

        # per-field vector creators (official codegen parity)
        for f in fields:
            if f.Type().BaseType() != BaseType.Vector:
                continue
            fn, et = snake(f.Name()), f.Type().Element()
            if et == BaseType.Obj:
                vo = obj_by_index[f.Type().Index()]
                tn = safe(vo.Name().decode().split(".")[-1])
                if vo.IsStruct():
                    lines.append(f"\tstatic func create_{fn}_vector(__b: FlatBufferBuilder_, data: Array) -> int: return {tn}.create_{gd_ident(tn)}_vector(__b, data)")
                    lines.append(f"\tstatic func start_{fn}_vector(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector({tn}.SIZE, n, {tn}.ALIGN)")
                else:
                    lines.append(f"\tstatic func create_{fn}_vector(__b: FlatBufferBuilder_, data: Array) -> int: return __b.create_offset_vector(data)")
                    lines.append(f"\tstatic func start_{fn}_vector(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector(4, n, 4)")
            elif et == BaseType.String:
                lines.append(f"\tstatic func create_{fn}_vector(__b: FlatBufferBuilder_, data: Array) -> int: return __b.create_offset_vector(data)")
                lines.append(f"\tstatic func start_{fn}_vector(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector(4, n, 4)")
            elif et == BaseType.UByte:
                lines.append(f"\tstatic func create_{fn}_vector(__b: FlatBufferBuilder_, data: Variant) -> int:")
                lines.append("\t\treturn __b.create_byte_vector(data) if data is PackedByteArray else __b.create_u8_vector(data)")
                lines.append(f"\tstatic func start_{fn}_vector(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector(1, n, 1)")
            else:
                es, helper = VEC_BUILD.get(et, (4, "create_i32_vector"))
                lines.append(f"\tstatic func create_{fn}_vector(__b: FlatBufferBuilder_, data: Array) -> int: return __b.{helper}(data)")
                lines.append(f"\tstatic func start_{fn}_vector(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector({es}, n, {es})")

        # create_* builder
        params = []
        body = [f"\t\t__b.start_table({o.FieldsLength()})"]
        for f in fields:
            fn = snake(f.Name())
            bt = f.Type().BaseType()
            if bt == BaseType.Union:
                # flatc already emits a `{name}_type` UType field — the union
                # itself contributes only the data offset param/write.
                params.append(f"{fn}_off: int = 0")
                body.append(f"\t\t__b.add_offset_field({f.Id()}, {fn}_off, 0)")
                continue
            if bt == BaseType.Obj and obj_by_index[f.Type().Index()].IsStruct():
                tn = safe(obj_by_index[f.Type().Index()].Name().decode().split(".")[-1])
                params.append(f"{fn}: Array = []")
                body.append(f"\t\tif {fn}: __b.add_struct_field({f.Id()}, {tn}.create_{gd_ident(tn)}.callv([__b] + {fn}), 0)")
                continue
            if bt in (BaseType.String, BaseType.Obj, BaseType.Vector):
                params.append(f"{fn}_off: int = 0")
                body.append(f"\t\t__b.add_offset_field({f.Id()}, {fn}_off, 0)")
            else:
                _, adder, _ = SCALAR.get(bt, ("", "add_i32_field", 4))
                is_float = bt in (BaseType.Float, BaseType.Double)
                d = f.DefaultReal() if is_float else f.DefaultInteger()
                params.append(f"{fn}: {'float' if is_float else 'int'} = {d}")
                body.append(f"\t\t__b.{adder}({f.Id()}, {fn}, {d})")
        required = [f for f in fields if f.Required()]
        lines.append("")
        lines.append(f"\tstatic func create_{gd_ident(cname)}(__b: FlatBufferBuilder_, {', '.join(params)}) -> int:")
        lines.extend(body)
        if required:
            lines.append("\t\tvar __t := __b.end_table()")
            for f in required:
                lines.append(f"\t\t__b.required_field(__t, {4 + f.Id() * 2})")
            lines.append("\t\treturn __t")
        else:
            lines.append("\t\treturn __b.end_table()")
        lines.append("")
    open(args.out, "w", encoding="utf-8").write("\n".join(lines))
    print(f"wrote {args.out}: {len(objects)} objects, {len(enums)} enums")
    return 0

if __name__ == "__main__":
    sys.exit(main())
