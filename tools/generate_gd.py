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
packer (create_<name>) plus struct-vector helpers; every table gets a
schema-aware verify() backed by FlatBufferVerifier, object-API dict
(to_dict/from_dict) and JSON (to_json/from_json) round-trip helpers, typed
union accessors (u_as_x / u_unwrap), lookup_by_key helpers for keyed table
vectors, and transport-agnostic gRPC-style client/dispatcher classes for
rpc_service declarations.
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
VEC_GET64 = {
    BaseType.Bool: "get_vector64_bool", BaseType.Byte: "get_vector64_i8",
    BaseType.UByte: "get_vector64_u8", BaseType.UType: "get_vector64_u8",
    BaseType.Short: "get_vector64_i16", BaseType.UShort: "get_vector64_u16",
    BaseType.Int: "get_vector64_i32", BaseType.UInt: "get_vector64_u32",
    BaseType.Long: "get_vector64_i64", BaseType.ULong: "get_vector64_u64",
    BaseType.Float: "get_vector64_f32", BaseType.Double: "get_vector64_f64",
    BaseType.String: "get_vector64_string",
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
VEC_BUILD64 = {
    BaseType.Bool: (1, "create_bool_vector64"), BaseType.Byte: (1, "create_i8_vector64"),
    BaseType.UByte: (1, "create_u8_vector64"), BaseType.UType: (1, "create_u8_vector64"),
    BaseType.Short: (2, "create_i16_vector64"), BaseType.UShort: (2, "create_u16_vector64"),
    BaseType.Int: (4, "create_i32_vector64"), BaseType.UInt: (4, "create_u32_vector64"),
    BaseType.Long: (8, "create_i64_vector64"), BaseType.ULong: (8, "create_u64_vector64"),
    BaseType.Float: (4, "create_f32_vector64"), BaseType.Double: (8, "create_f64_vector64"),
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

def cls_name(o) -> str:
    return safe(o.Name().decode().split(".")[-1])

def enum_class(e) -> str:
    return e.Name().decode().replace(".", "_")

def member_size(t, obj_by_index) -> int:
    """Byte size of a struct member's storage."""
    bt = t.BaseType()
    if bt == BaseType.Obj:
        return obj_by_index[t.Index()].Bytesize()
    if bt == BaseType.Array:
        return t.ElementSize() * t.FixedLength()
    return t.BaseSize()

def is_enum_field(f) -> bool:
    """Scalar field whose Type indexes an enum (non-union)."""
    return f.Type().Index() >= 0 and f.Type().BaseType() in SCALAR \
        and f.Type().BaseType() != BaseType.UType

def is_utype_sibling(fn: str, fields_by_name, fields) -> bool:
    """True when `fn` is the auto-generated `<union>_type` field."""
    if not fn.endswith("_type"):
        return False
    base = fn[:-5]
    for f in fields:
        if snake(f.Name()) == base:
            bt = f.Type().BaseType()
            if bt == BaseType.Union:
                return True
            if bt == BaseType.Vector and f.Type().Element() == BaseType.Union:
                return True
    return False

def union_members_of(t, enums, obj_by_index):
    """[(tag, value_name, member_class|None, is_string)] for a union Type."""
    out = []
    idx = t.Index()
    if idx < 0 or idx >= len(enums):
        return out
    e = enums[idx]
    for i in range(e.ValuesLength()):
        v = e.Values(i)
        if v.Value() == 0:
            continue
        ut = v.UnionType()
        if ut is None:
            continue
        if ut.BaseType() == BaseType.String:
            out.append((v.Value(), v.Name().decode(), None, True))
        elif ut.BaseType() == BaseType.Obj:
            out.append((v.Value(), v.Name().decode(),
                        cls_name(obj_by_index[ut.Index()]), False))
    return out

def elem_desc(et, t, obj_by_index):
    """Verifier spec desc for a vector element type."""
    if et == BaseType.String:
        return '{"k": "string"}'
    if et == BaseType.Obj:
        o = obj_by_index[t.Index()]
        if o.IsStruct():
            return '{"k": "struct", "size": %d}' % o.Bytesize()
        return '{"k": "table", "spec": Callable(%s, "_spec")}' % cls_name(o)
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
        return '{"k": "table", "spec": Callable(%s, "_spec")}' % cls_name(o)
    if bt == BaseType.Union:
        type_field = fields_by_name.get(snake(f.Name()) + "_type")
        type_slot = type_field.Id() if type_field else -1
        members = []
        for tag, _n, cls, is_str in union_members_of(f.Type(), enums, obj_by_index):
            if is_str:
                members.append('%d: {"k": "string"}' % tag)
            elif cls:
                members.append('%d: {"k": "table", "spec": Callable(%s, "_spec")}'
                               % (tag, cls))
        return ('{"k": "union", "type_slot": %d, "members": {%s}}'
                % (type_slot, ", ".join(members)))
    if bt == BaseType.Vector and f.Type().Element() == BaseType.Union:
        type_field = fields_by_name.get(snake(f.Name()) + "_type")
        type_slot = type_field.Id() if type_field else -1
        members = []
        for tag, _n, cls, is_str in union_members_of(f.Type(), enums, obj_by_index):
            if is_str:
                members.append('%d: {"k": "string"}' % tag)
            elif cls:
                members.append('%d: {"k": "table", "spec": Callable(%s, "_spec")}'
                               % (tag, cls))
        return ('{"k": "union_vector", "type_slot": %d, "members": {%s}}'
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
    if bt == BaseType.Vector64:
        return '{"k": "vector64", "elem": %s}' % elem_desc(
            f.Type().Element(), f.Type(), obj_by_index)
    if bt in SCALAR:
        return '{"k": "scalar", "size": %d}' % SCALAR[bt][2]
    return None

def _default_lit(f) -> str:
    """Default literal for a scalar field."""
    bt = f.Type().BaseType()
    if bt in (BaseType.Float, BaseType.Double):
        return repr(f.DefaultReal())
    if bt == BaseType.Bool:
        return "true" if f.DefaultInteger() else "false"
    return str(f.DefaultInteger())

def emit_struct(lines, o, objects, obj_by_index):
    """Accessor + inline packer + vector helpers + dict API for a struct."""
    cname = cls_name(o)
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
            tn = cls_name(obj_by_index[f.Type().Index()])
            lines.append(f"\tfunc {fn}() -> {tn}: return {tn}.wrap_fb(_s.get_struct({off}))")
        elif bt == BaseType.Array:
            et = f.Type().Element()
            n = f.Type().FixedLength()
            lines.append(f"\tfunc {fn}_len() -> int: return {n}")
            if et == BaseType.Obj:
                tn = cls_name(obj_by_index[f.Type().Index()])
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
            tn = cls_name(obj_by_index[f.Type().Index()])
            lines.append(f"\t\t{tn}.create_{gd_ident(tn)}.callv([__b] + {fn})")
        elif bt == BaseType.Array:
            et = f.Type().Element()
            n = f.Type().FixedLength()
            if et == BaseType.Obj:
                tn = cls_name(obj_by_index[f.Type().Index()])
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
    for sfx, v64 in (("", False), ("64", True)):
        start, end = ("start_vector64", "end_vector64") if v64 else ("start_vector", "end_vector")
        lines.append("")
        lines.append(f"\t## Vector of `{cname}` — `data` is an Array of member args")
        lines.append(f"\t## (each element an Array passed to create_{csn}).")
        lines.append(f"\tstatic func create_{csn}_vector{sfx}(__b: FlatBufferBuilder_, data: Array) -> int:")
        lines.append(f"\t\t__b.{start}(SIZE, data.size(), ALIGN)")
        lines.append("\t\tfor i in range(data.size() - 1, -1, -1):")
        lines.append(f"\t\t\tcreate_{csn}.callv([__b] + data[i])")
        lines.append(f"\t\treturn __b.{end}()")
    lines.append("")

    # dict API: members -> plain Dictionary; from_dict returns the positional
    # arg list used by create_<name> (nested structs/arrays nest as Arrays).
    def _struct_dict(member_call, lines, fields, obj_by_index):
        lines.append("\t\tvar __d := {}")
        for f in fields:
            fn, bt = snake(f.Name()), f.Type().BaseType()
            if bt == BaseType.Obj:
                lines.append(f"\t\t__d[\"{fn}\"] = {fn}().{member_call}()")
            elif bt == BaseType.Array:
                lines.append(f"\t\t__d[\"{fn}\"] = _arr_{fn}_{member_call}()")
            elif bt == BaseType.ULong and member_call == "_json_dict":
                lines.append(f"\t\t__d[\"{fn}\"] = FlatBuffer_.u64_json({fn}())")
            else:
                lines.append(f"\t\t__d[\"{fn}\"] = {fn}()")
        lines.append("\t\treturn __d")

    lines.append("\t## Object API: this struct as a plain Dictionary.")
    lines.append("\tfunc to_dict() -> Dictionary:")
    _struct_dict("to_dict", lines, fields, obj_by_index)
    lines.append("")
    lines.append("\tfunc _json_dict() -> Dictionary:")
    _struct_dict("_json_dict", lines, fields, obj_by_index)
    for f in fields:
        fn, bt = snake(f.Name()), f.Type().BaseType()
        if bt == BaseType.Array:
            n = f.Type().FixedLength()
            et = f.Type().Element()
            for member_call in ("to_dict", "_json_dict"):
                lines.append(f"\tfunc _arr_{fn}_{member_call}() -> Array:")
                lines.append(f"\t\tvar __a := []")
                if et == BaseType.Obj:
                    lines.append(f"\t\tfor i in {n}: __a.append({fn}(i).{member_call}())")
                elif et == BaseType.ULong and member_call == "_json_dict":
                    lines.append(f"\t\tfor i in {n}: __a.append(FlatBuffer_.u64_json({fn}(i)))")
                else:
                    lines.append(f"\t\tfor i in {n}: __a.append({fn}(i))")
                lines.append("\t\treturn __a")
    lines.append("\t## Build the positional arg list for create_%s from a dict." % csn)
    lines.append("\tstatic func from_dict(d: Dictionary) -> Array:")
    lines.append("\t\treturn [")
    for f in fields:
        fn, bt = snake(f.Name()), f.Type().BaseType()
        if bt == BaseType.Obj:
            tn = cls_name(obj_by_index[f.Type().Index()])
            lines.append(f"\t\t\t{tn}.from_dict(d.get(\"{fn}\", {{}})),")
        elif bt == BaseType.Array:
            lines.append(f"\t\t\td.get(\"{fn}\", []),")
        elif bt == BaseType.ULong:
            lines.append(f"\t\t\tFlatBuffer_.u64_from(d.get(\"{fn}\", 0)),")
        else:
            zero = "0.0" if bt in (BaseType.Float, BaseType.Double) else \
                ("false" if bt == BaseType.Bool else "0")
            lines.append(f"\t\t\td.get(\"{fn}\", {zero}),")
    lines.append("\t\t]")
    lines.append("")

def _emit_dict_field(lines, f, fields_by_name, objects, obj_by_index, enums, mode):
    """Emit `__d["name"] = ...` for one field. mode: 'dict' or 'json'."""
    fn = snake(f.Name())
    slot = f.Id()
    bt = f.Type().BaseType()
    et = f.Type().Element()
    ind = "\t\t"
    json = mode == "json"
    opt_guard = f"_t.has_field({slot})"
    optional_scalar = f.Optional() and bt in SCALAR

    if bt == BaseType.Union:
        e = enum_class(enums[f.Type().Index()])
        tfield = fields_by_name.get(fn + "_type")
        tslot = tfield.Id() if tfield else -1
        lines.append(f"{ind}if _t.has_field({slot}) or _t.has_field({tslot}):")
        lines.append(f"{ind}\t__d[\"{fn}_type\"] = {e}.name_of({fn}_type())")
        lines.append(f"{ind}\tvar __w: Variant = {fn}_unwrap()")
        conv = f"_json_dict()" if json else "to_dict()"
        lines.append(f"{ind}\t__d[\"{fn}\"] = __w.{conv} if __w is RefCounted else __w")
        return
    if bt == BaseType.Vector and et == BaseType.Union:
        e = enum_class(enums[f.Type().Index()])
        conv = f"_json_dict()" if json else "to_dict()"
        lines.append(f"{ind}if _t.has_field({slot}):")
        lines.append(f"{ind}\tvar __tags := []")
        lines.append(f"{ind}\tvar __vals := []")
        lines.append(f"{ind}\tfor i in {fn}_len():")
        lines.append(f"{ind}\t\t__tags.append({e}.name_of({fn}_type(i)))")
        lines.append(f"{ind}\t\tvar __w: Variant = {fn}_unwrap(i)")
        lines.append(f"{ind}\t\t__vals.append(__w.{conv} if __w is RefCounted else __w)")
        lines.append(f"{ind}\t__d[\"{fn}_type\"] = __tags")
        lines.append(f"{ind}\t__d[\"{fn}\"] = __vals")
        return
    if bt in (BaseType.Vector, BaseType.Vector64):
        is64 = bt == BaseType.Vector64
        len_get = "vector64_len" if is64 else "vector_len"
        if et == BaseType.Obj:
            vo = obj_by_index[f.Type().Index()]
            tn = cls_name(vo)
            conv = "_json_dict" if json else "to_dict"
            lines.append(f"{ind}if {opt_guard}:")
            lines.append(f"{ind}\tvar __a := []")
            lines.append(f"{ind}\tfor i in {fn}_len(): __a.append({fn}(i).{conv}())")
            lines.append(f"{ind}\t__d[\"{fn}\"] = __a")
            return
        if et == BaseType.String:
            lines.append(f"{ind}if {opt_guard}:")
            lines.append(f"{ind}\tvar __a := []")
            lines.append(f"{ind}\tfor i in {fn}_len(): __a.append({fn}(i))")
            lines.append(f"{ind}\t__d[\"{fn}\"] = __a")
            return
        if et == BaseType.UByte:
            v = f"Array({fn}_bytes())" if json else f"{fn}_bytes()"
            lines.append(f"{ind}if {opt_guard}: __d[\"{fn}\"] = {v}")
            return
        if et == BaseType.ULong:
            conv_e = f"FlatBuffer_.u64_json({fn}(i))" if json else f"{fn}(i)"
            lines.append(f"{ind}if {opt_guard}:")
            lines.append(f"{ind}\tvar __a := []")
            lines.append(f"{ind}\tfor i in {fn}_len(): __a.append({conv_e})")
            lines.append(f"{ind}\t__d[\"{fn}\"] = __a")
            return
        lines.append(f"{ind}if {opt_guard}:")
        lines.append(f"{ind}\tvar __a := []")
        lines.append(f"{ind}\tfor i in {fn}_len(): __a.append({fn}(i))")
        lines.append(f"{ind}\t__d[\"{fn}\"] = __a")
        return
    if bt == BaseType.Obj:
        tn = cls_name(obj_by_index[f.Type().Index()])
        conv = "_json_dict" if json else "to_dict"
        lines.append(f"{ind}if {opt_guard}: __d[\"{fn}\"] = {fn}().{conv}()")
        return
    if bt == BaseType.String:
        lines.append(f"{ind}if {opt_guard}: __d[\"{fn}\"] = {fn}()")
        return
    if bt == BaseType.ULong:
        v = f"FlatBuffer_.u64_json({fn}())" if json else f"{fn}()"
        # flatc --json emits only fields present in the buffer; the object
        # dict materializes non-optional defaults instead.
        if optional_scalar or json:
            lines.append(f"{ind}if {opt_guard}: __d[\"{fn}\"] = {v}")
        else:
            lines.append(f"{ind}__d[\"{fn}\"] = {v}")
        return
    if is_enum_field(f):
        e = enum_class(enums[f.Type().Index()])
        v = f"{e}.name_of({fn}())"
        if optional_scalar or json:
            lines.append(f"{ind}if {opt_guard}: __d[\"{fn}\"] = {v}")
        else:
            lines.append(f"{ind}__d[\"{fn}\"] = {v}")
        return
    if bt in SCALAR:
        if optional_scalar or json:
            lines.append(f"{ind}if {opt_guard}: __d[\"{fn}\"] = {fn}()")
        else:
            lines.append(f"{ind}__d[\"{fn}\"] = {fn}()")
        return

def _emit_from_dict_field(lines, f, fields_by_name, objects, obj_by_index, enums):
    """Emit the from_dict body pieces for one field: children offsets, then
    the add_*_field call inside the started table."""
    fn = snake(f.Name())
    slot = f.Id()
    bt = f.Type().BaseType()
    et = f.Type().Element()
    children, adds = [], []

    if bt == BaseType.Union:
        e = enum_class(enums[f.Type().Index()])
        members = union_members_of(f.Type(), enums, obj_by_index)
        tfield = fields_by_name.get(fn + "_type")
        tslot = tfield.Id() if tfield else -1
        children.append(f"var __v_{fn} := 0")
        children.append(f"var __v_{fn}_tag := 0")
        children.append(f"if __d.has(\"{fn}_type\") or __d.has(\"{fn}\"):")
        children.append(f"\tvar __tagv: Variant = __d.get(\"{fn}_type\", 0)")
        children.append(f"\t__v_{fn}_tag = {e}.value_of(str(__tagv)) if __tagv is String else int(__tagv)")
        children.append(f"\tmatch __v_{fn}_tag:")
        for tag, _n, cls, is_str in members:
            if is_str:
                children.append(f"\t\t{tag}: __v_{fn} = __b.create_string(str(__d.get(\"{fn}\", \"\")))")
            else:
                children.append(f"\t\t{tag}: __v_{fn} = {cls}.from_dict(__b, __d.get(\"{fn}\", {{}}))")
        adds.append(f"__b.add_u8_field({tslot}, __v_{fn}_tag, 0)")
        adds.append(f"__b.add_offset_field({slot}, __v_{fn}, 0)")
        return children, adds
    if bt == BaseType.Vector and et == BaseType.Union:
        e = enum_class(enums[f.Type().Index()])
        members = union_members_of(f.Type(), enums, obj_by_index)
        tfield = fields_by_name.get(fn + "_type")
        tslot = tfield.Id() if tfield else -1
        cases = []
        for tag, _n, cls, is_str in members:
            if is_str:
                cases.append(f"{tag}: __offs.append(__b.create_string(str(v)))")
            else:
                cases.append(f"{tag}: __offs.append({cls}.from_dict(__b, v))")
        children.append(f"var __v_{fn} := 0")
        children.append(f"var __v_{fn}_tags := 0")
        children.append(f"if __d.has(\"{fn}\"):")
        children.append(f"\tvar __offs := []")
        children.append(f"\tvar __tags := []")
        children.append(f"\tvar __tn: Variant = __d.get(\"{fn}_type\", [])")
        children.append(f"\tfor i in __d[\"{fn}\"].size():")
        children.append(f"\t\tvar v: Variant = __d[\"{fn}\"][i]")
        children.append(f"\t\tvar tt: Variant = __tn[i] if i < __tn.size() else 0")
        children.append(f"\t\tvar tg := {e}.value_of(str(tt)) if tt is String else int(tt)")
        children.append(f"\t\t__tags.append(tg)")
        children.append(f"\t\tmatch tg:")
        for c in cases:
            children.append(f"\t\t\t{c}")
        children.append(f"\t\t\t_: __offs.append(0)")
        children.append(f"\t__v_{fn} = __b.create_offset_vector(__offs)")
        children.append(f"\t__v_{fn}_tags = __b.create_u8_vector(__tags)")
        adds.append(f"__b.add_offset_field({tslot}, __v_{fn}_tags, 0)")
        adds.append(f"__b.add_offset_field({slot}, __v_{fn}, 0)")
        return children, adds
    if bt in (BaseType.Vector, BaseType.Vector64):
        is64 = bt == BaseType.Vector64
        if et == BaseType.Obj:
            vo = obj_by_index[f.Type().Index()]
            tn = cls_name(vo)
            if vo.IsStruct():
                vec_helper = f"create_{fn}_vector{'64' if is64 else ''}"
                children.append(f"var __v_{fn} := 0")
                children.append(f"if __d.has(\"{fn}\"):")
                children.append(f"\tvar __args := []")
                children.append(f"\tfor v in __d[\"{fn}\"]: __args.append({tn}.from_dict(v))")
                children.append(f"\t__v_{fn} = {vec_helper}(__b, __args)")
            else:
                children.append(f"var __v_{fn} := 0")
                children.append(f"if __d.has(\"{fn}\"):")
                children.append(f"\tvar __offs := []")
                children.append(f"\tfor v in __d[\"{fn}\"]: __offs.append({tn}.from_dict(__b, v))")
                helper = "create_offset64_vector" if is64 else "create_offset_vector"
                children.append(f"\t__v_{fn} = __b.{helper}(__offs)")
        elif et == BaseType.String:
            children.append(f"var __v_{fn} := 0")
            children.append(f"if __d.has(\"{fn}\"):")
            children.append(f"\tvar __offs := []")
            str_create = "create_string64" if is64 else "create_string"
            children.append(f"\tfor v in __d[\"{fn}\"]: __offs.append(__b.{str_create}(str(v)))")
            helper = "create_offset64_vector" if is64 else "create_offset_vector"
            children.append(f"\t__v_{fn} = __b.{helper}(__offs)")
        elif et == BaseType.UByte:
            helper = "create_byte_vector64" if is64 else "create_byte_vector"
            children.append(f"var __v_{fn} := 0")
            children.append(f"if __d.has(\"{fn}\"):")
            children.append(f"\tvar v: Variant = __d[\"{fn}\"]")
            if is64:
                children.append(f"\t__v_{fn} = __b.create_byte_vector64(v) if v is PackedByteArray else __b.create_u8_vector64(v)")
            else:
                children.append(f"\t__v_{fn} = __b.create_byte_vector(v) if v is PackedByteArray else __b.create_u8_vector(v)")
        elif et == BaseType.ULong:
            helper64 = "create_u64_vector64" if is64 else "create_u64_vector"
            children.append(f"var __v_{fn} := 0")
            children.append(f"if __d.has(\"{fn}\"):")
            children.append(f"\tvar __a := []")
            children.append(f"\tfor v in __d[\"{fn}\"]: __a.append(FlatBuffer_.u64_from(v))")
            children.append(f"\t__v_{fn} = __b.{helper64}(__a)")
        else:
            es, helper = (VEC_BUILD64 if is64 else VEC_BUILD).get(et, (4, "create_i32_vector"))
            children.append(f"var __v_{fn} := 0")
            children.append(f"if __d.has(\"{fn}\"): __v_{fn} = __b.{helper}(__d[\"{fn}\"])")
        adds.append(f"__b.add_offset{'64' if is64 else ''}_field({slot}, __v_{fn}, 0)")
        return children, adds
    if bt == BaseType.Obj:
        o = obj_by_index[f.Type().Index()]
        tn = cls_name(o)
        if o.IsStruct():
            adds.append(f"if __d.has(\"{fn}\"): __b.add_struct_field({slot}, {tn}.create_{gd_ident(tn)}.callv([__b] + {tn}.from_dict(__d[\"{fn}\"])), 0)")
        else:
            children.append(f"var __v_{fn} := 0")
            children.append(f"if __d.has(\"{fn}\") and __d[\"{fn}\"] is Dictionary: __v_{fn} = {tn}.from_dict(__b, __d[\"{fn}\"])")
            adds.append(f"__b.add_offset_field({slot}, __v_{fn}, 0)")
        return children, adds
    if bt == BaseType.String:
        children.append(f"var __v_{fn} := 0")
        children.append(f"if __d.has(\"{fn}\"): __v_{fn} = __b.create_string(str(__d[\"{fn}\"]))")
        adds.append(f"__b.add_offset_field({slot}, __v_{fn}, 0)")
        return children, adds
    if bt == BaseType.ULong:
        adds.append(f"__b.add_u64_field({slot}, FlatBuffer_.u64_from(__d.get(\"{fn}\", {_default_lit(f)})), {_default_lit(f)})")
        return children, adds
    if bt in SCALAR:
        _, adder, _ = SCALAR[bt]
        d = _default_lit(f)
        if f.Optional():
            adds.append(f"if __d.has(\"{fn}\"): __b.{adder}({slot}, __d[\"{fn}\"], {d}, true)")
        elif is_enum_field(f):
            e = enum_class(enums[f.Type().Index()])
            adds.append(f"var __v_{fn}_v: Variant = __d.get(\"{fn}\", {d})")
            adds.append(f"__b.{adder}({slot}, {e}.value_of(str(__v_{fn}_v)) if __v_{fn}_v is String else int(__v_{fn}_v), {d})")
        else:
            adds.append(f"__b.{adder}({slot}, __d.get(\"{fn}\", {d}), {d})")
        return children, adds
    return children, adds

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("bfbs")
    ap.add_argument("out")
    ap.add_argument("--class-name", default="FBSchema")
    args = ap.parse_args()

    schema = Schema.GetRootAs(open(args.bfbs, "rb").read(), 0)
    objects = [schema.Objects(i) for i in range(schema.ObjectsLength())]
    enums = [schema.Enums(i) for i in range(schema.EnumsLength())]
    services = [schema.Services(i) for i in range(schema.ServicesLength())]
    obj_by_index = {i: o for i, o in enumerate(objects)}

    lines = [f"# GENERATED by generate_gd.py from {os.path.basename(args.bfbs)} — do not edit",
             "class_name %s" % args.class_name, "",
             "const FlatBuffer_ = preload(\"res://addons/godot_flatbuffers/flatbuffer.gd\")",
             "const FlatBufferBuilder_ = preload(\"res://addons/godot_flatbuffers/flatbuffer_builder.gd\")",
             "const FlatBufferStruct_ = preload(\"res://addons/godot_flatbuffers/flatbuffer_struct.gd\")",
             "const FlatBufferVerifier_ = preload(\"res://addons/godot_flatbuffers/flatbuffer_verifier.gd\")",
             ""]

    # enums -> consts + name/value lookup (union enums get the same shape)
    for e in enums:
        ename = enum_class(e)
        lines.append(f"class {ename}:")
        names, values = [], []
        for i in range(e.ValuesLength()):
            v = e.Values(i)
            lines.append(f"\tconst {snake(v.Name()).upper()} = {v.Value()}")
            names.append("%d: \"%s\"" % (v.Value(), snake(v.Name())))
            values.append("\"%s\": %d" % (snake(v.Name()), v.Value()))
        lines.append(f"\tconst _NAMES := {{{', '.join(names)}}}")
        lines.append(f"\tconst _VALUES := {{{', '.join(values)}}}")
        lines.append("\tstatic func name_of(v: int) -> String: return str(_NAMES.get(v, \"\"))")
        lines.append("\tstatic func value_of(n: String) -> int: return int(_VALUES.get(n, 0))")
        lines.append("")

    for o in objects:
        if o.IsStruct():
            emit_struct(lines, o, objects, obj_by_index)
            continue
        cname = cls_name(o)
        fields = [o.Fields(i) for i in range(o.FieldsLength())]
        fields_by_name = {snake(f.Name()): f for f in fields}
        fields.sort(key=lambda f: f.Id())
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
                tn = cls_name(so)
                if so.IsStruct():
                    lines.append(f"\tfunc {fn}() -> {tn}: return {tn}.wrap_fb(_t.get_struct({slot})) if _t.has_field({slot}) else null")
                else:
                    lines.append(f"\tfunc {fn}() -> {tn}: return {tn}.wrap_fb(_t.get_table({slot})) if _t.has_field({slot}) else null")
            elif bt == BaseType.Union:
                # `{name}_type` accessor comes from the separately-emitted UType field
                lines.append(f"\tfunc {fn}() -> FlatBuffer_: return _t.get_table({slot})")
                members = union_members_of(f.Type(), enums, obj_by_index)
                ec = enum_class(enums[f.Type().Index()])
                for tag, vn, cls, is_str in members:
                    mname = gd_ident(vn)
                    if is_str:
                        lines.append(f"\tfunc {fn}_as_{mname}() -> String: return _t.get_string({slot}) if {fn}_type() == {tag} else \"\"")
                    else:
                        lines.append(f"\tfunc {fn}_as_{mname}() -> {cls}: return {cls}.wrap_fb(_t.get_table({slot})) if {fn}_type() == {tag} else null")
                lines.append(f"\t## Typed unwrap via the union tag — member wrapper, String, or null.")
                lines.append(f"\tfunc {fn}_unwrap() -> Variant:")
                lines.append(f"\t\tmatch {fn}_type():")
                for tag, vn, cls, is_str in members:
                    if is_str:
                        lines.append(f"\t\t\t{tag}: return _t.get_string({slot})")
                    else:
                        lines.append(f"\t\t\t{tag}: return {cls}.wrap_fb(_t.get_table({slot}))")
                lines.append("\t\t\t_: return null")
            elif bt == BaseType.Vector and et == BaseType.Union:
                ec = enum_class(enums[f.Type().Index()])
                lines.append(f"\tfunc {fn}_len() -> int: return _t.vector_len({slot})")
                lines.append(f"\tfunc {fn}(i: int) -> FlatBuffer_: return _t.get_vector_table({slot}, i)")
                members = union_members_of(f.Type(), enums, obj_by_index)
                lines.append(f"\t## Typed unwrap via the union tag — member wrapper, String, or null.")
                lines.append(f"\tfunc {fn}_unwrap(i: int) -> Variant:")
                lines.append(f"\t\tmatch {fn}_type(i):")
                for tag, vn, cls, is_str in members:
                    if is_str:
                        lines.append(f"\t\t\t{tag}: return _t.get_vector_string({slot}, i)")
                    else:
                        lines.append(f"\t\t\t{tag}: return {cls}.wrap_fb(_t.get_vector_table({slot}, i))")
                lines.append("\t\t\t_: return null")
            elif bt in (BaseType.Vector, BaseType.Vector64):
                is64 = bt == BaseType.Vector64
                vlen = "vector64_len" if is64 else "vector_len"
                if et == BaseType.Obj:
                    vo = obj_by_index[f.Type().Index()]
                    tn = cls_name(vo)
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.{vlen}({slot})")
                    if vo.IsStruct():
                        getter = "get_vector64_struct" if is64 else "get_vector_struct"
                        lines.append(f"\tfunc {fn}(i: int) -> {tn}: return {tn}.wrap_fb(_t.{getter}({slot}, i, {tn}.SIZE))")
                    else:
                        getter = "get_vector64_table" if is64 else "get_vector_table"
                        lines.append(f"\tfunc {fn}(i: int) -> {tn}: return {tn}.wrap_fb(_t.{getter}({slot}, i))")
                elif et == BaseType.String:
                    getter = "get_vector64_string" if is64 else "get_vector_string"
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.{vlen}({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> String: return _t.{getter}({slot}, i)")
                elif et == BaseType.UByte:
                    getter = "get_vector64_u8" if is64 else "get_vector_u8"
                    bytes_getter = "get_vector64_bytes" if is64 else "get_vector_bytes"
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.{vlen}({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> Variant: return _t.{getter}({slot}, i)")
                    lines.append(f"\tfunc {fn}_bytes() -> PackedByteArray: return _t.{bytes_getter}({slot})")
                elif et == BaseType.ULong:
                    getter = "get_vector64_u64" if is64 else "get_vector_u64"
                    hex_getter = "get_vector64_u64_hex" if is64 else "get_vector_u64_hex"
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.{vlen}({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> Variant: return _t.{getter}({slot}, i)")
                    lines.append(f"\tfunc {fn}_hex(i: int) -> String: return _t.{hex_getter}({slot}, i)")
                else:
                    g = (VEC_GET64 if is64 else VEC_GET).get(et, "get_vector_i32")
                    lines.append(f"\tfunc {fn}_len() -> int: return _t.{vlen}({slot})")
                    lines.append(f"\tfunc {fn}(i: int) -> Variant: return _t.{g}({slot}, i)")
            elif bt == BaseType.ULong:
                lines.append(f"\tfunc {fn}() -> Variant: return _t.get_u64({slot}, {dflt_i})")
                lines.append(f"\tfunc {fn}_hex() -> String: return _t.get_u64_hex({slot}, \"0x{int(dflt_i) & 0xFFFFFFFFFFFFFFFF:x}\")")
            else:
                g, _, _ = SCALAR.get(bt, ("get_i32", "add_i32_field", 4))
                lines.append(f"\tfunc {fn}() -> Variant: return _t.{g}({slot}, {_default_lit(f)})")
            if f.Optional() and bt not in (BaseType.String, BaseType.Obj,
                                           BaseType.Union, BaseType.Vector,
                                           BaseType.Vector64):
                lines.append(f"\tfunc has_{fn}() -> bool: return _t.has_field({slot})")

        # per-field vector creators (official codegen parity)
        for f in fields:
            bt = f.Type().BaseType()
            if bt not in (BaseType.Vector, BaseType.Vector64):
                continue
            if bt == BaseType.Vector and f.Type().Element() == BaseType.Union:
                continue
            fn, et = snake(f.Name()), f.Type().Element()
            is64 = bt == BaseType.Vector64
            sfx = "64" if is64 else ""
            if et == BaseType.Obj:
                vo = obj_by_index[f.Type().Index()]
                tn = cls_name(vo)
                if vo.IsStruct():
                    lines.append(f"\tstatic func create_{fn}_vector{sfx}(__b: FlatBufferBuilder_, data: Array) -> int: return {tn}.create_{gd_ident(tn)}_vector{sfx}(__b, data)")
                    lines.append(f"\tstatic func start_{fn}_vector{sfx}(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector{sfx}({tn}.SIZE, n, {tn}.ALIGN)")
                else:
                    helper = "create_offset64_vector" if is64 else "create_offset_vector"
                    lines.append(f"\tstatic func create_{fn}_vector{sfx}(__b: FlatBufferBuilder_, data: Array) -> int: return __b.{helper}(data)")
                    es = 8 if is64 else 4
                    lines.append(f"\tstatic func start_{fn}_vector{sfx}(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector{sfx}({es}, n, {es})")
            elif et == BaseType.String:
                helper = "create_offset64_vector" if is64 else "create_offset_vector"
                lines.append(f"\tstatic func create_{fn}_vector{sfx}(__b: FlatBufferBuilder_, data: Array) -> int: return __b.{helper}(data)")
                es = 8 if is64 else 4
                lines.append(f"\tstatic func start_{fn}_vector{sfx}(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector{sfx}({es}, n, {es})")
            elif et == BaseType.UByte:
                lines.append(f"\tstatic func create_{fn}_vector{sfx}(__b: FlatBufferBuilder_, data: Variant) -> int:")
                if is64:
                    lines.append("\t\treturn __b.create_byte_vector64(data) if data is PackedByteArray else __b.create_u8_vector64(data)")
                else:
                    lines.append("\t\treturn __b.create_byte_vector(data) if data is PackedByteArray else __b.create_u8_vector(data)")
                lines.append(f"\tstatic func start_{fn}_vector{sfx}(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector{sfx}(1, n, 1)")
            else:
                es, helper = (VEC_BUILD64 if is64 else VEC_BUILD).get(et, (4, "create_i32_vector"))
                lines.append(f"\tstatic func create_{fn}_vector{sfx}(__b: FlatBufferBuilder_, data: Array) -> int: return __b.{helper}(data)")
                lines.append(f"\tstatic func start_{fn}_vector{sfx}(__b: FlatBufferBuilder_, n: int) -> void: __b.start_vector{sfx}({es}, n, {es})")

        # lookup_by_key: binary search over a sorted [table] vector by its
        # (key) field — official LookupByKey parity.
        for f in fields:
            if f.Type().BaseType() != BaseType.Vector or \
                    f.Type().Element() != BaseType.Obj:
                continue
            vo = obj_by_index[f.Type().Index()]
            if vo.IsStruct():
                continue
            key_field = None
            for i in range(vo.FieldsLength()):
                kf = vo.Fields(i)
                if kf.Key():
                    key_field = kf
                    break
            if key_field is None:
                continue
            tn = cls_name(vo)
            fn = snake(f.Name())
            kfn = snake(key_field.Name())
            lines.append(f"\t## Binary search `{fn}` by its `{kfn}` key (vector must be sorted).")
            lines.append(f"\tfunc {fn}_by_key(k: Variant) -> {tn}:")
            lines.append("\t\tvar lo := 0")
            lines.append(f"\t\tvar hi := {fn}_len() - 1")
            lines.append("\t\twhile lo <= hi:")
            lines.append("\t\t\tvar mid := (lo + hi) >> 1")
            lines.append(f"\t\t\tvar e := {fn}(mid)")
            lines.append("\t\t\tif e == null: return null")
            lines.append(f"\t\t\tvar kv: Variant = e.{kfn}()")
            lines.append("\t\t\tif kv < k: lo = mid + 1")
            lines.append("\t\t\telif kv > k: hi = mid - 1")
            lines.append("\t\t\telse: return e")
            lines.append("\t\treturn null")

        # create_* builder
        params = []
        body = [f"\t\t__b.start_table({o.FieldsLength()})"]
        for f in fields:
            fn = snake(f.Name())
            bt = f.Type().BaseType()
            if bt == BaseType.Union:
                params.append(f"{fn}_off: int = 0")
                body.append(f"\t\t__b.add_offset_field({f.Id()}, {fn}_off, 0)")
                continue
            if bt == BaseType.Vector64:
                params.append(f"{fn}_off: int = 0")
                body.append(f"\t\t__b.add_offset64_field({f.Id()}, {fn}_off, 0)")
                continue
            if bt == BaseType.Obj and obj_by_index[f.Type().Index()].IsStruct():
                tn = cls_name(obj_by_index[f.Type().Index()])
                params.append(f"{fn}: Array = []")
                body.append(f"\t\tif {fn}: __b.add_struct_field({f.Id()}, {tn}.create_{gd_ident(tn)}.callv([__b] + {fn}), 0)")
                continue
            if bt in (BaseType.String, BaseType.Obj, BaseType.Vector):
                params.append(f"{fn}_off: int = 0")
                body.append(f"\t\t__b.add_offset_field({f.Id()}, {fn}_off, 0)")
            elif bt in SCALAR:
                _, adder, _ = SCALAR[bt]
                d = _default_lit(f)
                if f.Optional():
                    params.append(f"{fn} = null")
                    body.append(f"\t\tif {fn} != null: __b.{adder}({f.Id()}, {fn}, {d}, true)")
                else:
                    if bt == BaseType.Bool:
                        ty = "bool"
                    elif bt in (BaseType.Float, BaseType.Double):
                        ty = "float"
                    else:
                        ty = "int"
                    params.append(f"{fn}: {ty} = {d}")
                    body.append(f"\t\t__b.{adder}({f.Id()}, {fn}, {d})")
            else:
                _, adder, _ = SCALAR.get(bt, ("", "add_i32_field", 4))
                d = _default_lit(f)
                params.append(f"{fn}: int = {d}")
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

        # ── object API: to_dict / from_dict / to_json / from_json ──
        lines.append("")
        lines.append("\t## Object API: unpack to a plain Dictionary (field names")
        lines.append("\t## verbatim; tables/structs nest; unions become")
        lines.append("\t## {\"x_type\": \"Name\", \"x\": {...}}; ulong fields return the")
        lines.append("\t## raw signed bit pattern (hex via <f>_hex()); byte vectors")
        lines.append("\t## return PackedByteArray; enums return declared names.")
        lines.append("\tfunc to_dict() -> Dictionary:")
        lines.append("\t\tvar __d := {}")
        for f in fields:
            if is_utype_sibling(snake(f.Name()), fields_by_name, fields):
                continue
            _emit_dict_field(lines, f, fields_by_name, objects, obj_by_index, enums, "dict")
        lines.append("\t\treturn __d")
        lines.append("")
        lines.append("\t## flatc --json-shaped Dictionary (ulong as unsigned number,")
        lines.append("\t## byte vectors as int arrays). to_json() stringifies it.")
        lines.append("\tfunc _json_dict() -> Dictionary:")
        lines.append("\t\tvar __d := {}")
        for f in fields:
            if is_utype_sibling(snake(f.Name()), fields_by_name, fields):
                continue
            _emit_dict_field(lines, f, fields_by_name, objects, obj_by_index, enums, "json")
        lines.append("\t\treturn __d")
        lines.append("")
        lines.append("\tfunc to_json() -> String: return JSON.stringify(_json_dict())")
        lines.append("")
        lines.append("\t## Pack a Dictionary back into `__b`, returning the table offset.")
        lines.append("\t## Children are built first; absent keys leave fields unset.")
        lines.append("\tstatic func from_dict(__b: FlatBufferBuilder_, __d: Dictionary) -> int:")
        # vector64 children must be built before any 32-bit object — emit
        # their blocks first, keeping declaration order within each class.
        groups = {True: [], False: []}
        adds = []
        for f in fields:
            if is_utype_sibling(snake(f.Name()), fields_by_name, fields):
                continue
            c, a = _emit_from_dict_field(lines, f, fields_by_name, objects, obj_by_index, enums)
            groups[f.Type().BaseType() == BaseType.Vector64] += c
            adds += a
        for c in groups[True] + groups[False]:
            lines.append("\t\t" + c)
        lines.append(f"\t\t__b.start_table({o.FieldsLength()})")
        for a in adds:
            lines.append("\t\t" + a)
        if required:
            lines.append("\t\tvar __t := __b.end_table()")
            for f in required:
                lines.append(f"\t\t__b.required_field(__t, {4 + f.Id() * 2})")
            lines.append("\t\treturn __t")
        else:
            lines.append("\t\treturn __b.end_table()")
        lines.append("")
        lines.append("\t## Build a finished buffer from flatc --json-compatible text.")
        lines.append(f"\tstatic func from_json(text: String) -> {cname}:")
        lines.append("\t\tvar __d: Variant = JSON.parse_string(text)")
        lines.append("\t\tif not (__d is Dictionary): return null")
        lines.append("\t\tvar __b := FlatBufferBuilder_.new()")
        lines.append("\t\t__b.finish(from_dict(__b, __d))")
        lines.append("\t\treturn get_root_as(__b.to_packed_byte_array())")
        lines.append("")

    # ── services: transport-agnostic gRPC-style client + dispatcher ──
    for s in services:
        sname = s.Name().decode()
        scls = safe(sname.split(".")[-1])
        path_pfx = "/" + sname
        lines.append(f"class {scls}Client:")
        lines.append("\t## Callable(path: String, payload: PackedByteArray) -> PackedByteArray")
        lines.append("\tvar _send: Callable")
        lines.append("\tfunc _init(send: Callable) -> void: _send = send")
        for i in range(s.CallsLength()):
            c = s.Calls(i)
            mname = gd_ident(c.Name().decode())
            req = cls_name(c.Request())
            res = cls_name(c.Response())
            lines.append("")
            lines.append(f"\tfunc {mname}(__b: FlatBufferBuilder_, req: int, file_id := \"\") -> {res}:")
            lines.append("\t\t__b.finish(req, file_id)")
            lines.append(f"\t\tvar __r: PackedByteArray = _send.call(\"{path_pfx}/{c.Name().decode()}\", __b.to_packed_byte_array())")
            lines.append(f"\t\treturn {res}.get_root_as(__r) if __r.size() >= 4 else null")
        lines.append("")
        lines.append(f"class {scls}Server:")
        lines.append("\t## handler: Object with a method per rpc —")
        lines.append("\t##   method(req, __b: FlatBufferBuilder_) -> int (table offset)")
        lines.append("\t## or -> Dictionary (packed via from_dict).")
        lines.append("\tvar _handler: Object")
        lines.append("\tfunc _init(handler: Object) -> void: _handler = handler")
        lines.append("\tfunc dispatch(path: String, payload: PackedByteArray) -> PackedByteArray:")
        lines.append("\t\tvar __b := FlatBufferBuilder_.new()")
        lines.append("\t\tmatch path:")
        for i in range(s.CallsLength()):
            c = s.Calls(i)
            mname = gd_ident(c.Name().decode())
            req = cls_name(c.Request())
            res = cls_name(c.Response())
            lines.append(f"\t\t\t\"{path_pfx}/{c.Name().decode()}\":")
            lines.append(f"\t\t\t\tvar __res: Variant = _handler.{mname}({req}.get_root_as(payload), __b)")
            lines.append(f"\t\t\t\t__b.finish(__res if __res is int else {res}.from_dict(__b, __res))")
            lines.append("\t\t\t\treturn __b.to_packed_byte_array()")
        lines.append("\t\treturn PackedByteArray()")
        lines.append("")

    open(args.out, "w", encoding="utf-8").write("\n".join(lines))
    print(f"wrote {args.out}: {len(objects)} objects, {len(enums)} enums, {len(services)} services")
    return 0

if __name__ == "__main__":
    sys.exit(main())
