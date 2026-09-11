// Builds golden flatbuffer test vectors using the official JS builder.
// Output: tests/golden/*.bin — read by the GDScript test suite.
import { Builder } from 'flatbuffers';
import { writeFileSync } from 'node:fs';

const b = new Builder(1024);

// inner tables first (children before parents)
function makeInner(x, s) {
  const sOff = b.createString(s);
  b.startObject(2);
  b.addFieldInt32(0, x, 0);
  b.addFieldOffset(1, sOff, 0);
  return b.endObject();
}

function offsetVec(offs) {
  b.startVector(4, offs.length, 4);
  for (let i = offs.length - 1; i >= 0; i--) b.addOffset(offs[i]);  // reversed
  return b.endVector();
}

const in1 = makeInner(7, 'seven');
const in2 = makeInner(-3, 'minus');
const innersVec = offsetVec([in1, in2]);

const name = b.createString('dodo');
const strs = [b.createString('alpha'), b.createString('beta'), b.createString('gamma')];
const strsVec = offsetVec(strs);

// nums vector
b.startVector(4, 5, 4);
for (const v of [5, 4, 3, 2, 1]) b.addInt32(v);  // reversed
const numsVec = b.endVector();

// blob = nested flatbuffer: a complete Inner buffer embedded as [ubyte]
const b5 = new Builder(64);
{
  const s = b5.createString('nested');
  b5.startObject(2);
  b5.addFieldInt32(0, 99, 0);
  b5.addFieldOffset(1, s, 0);
  b5.finish(b5.endObject());
}
const blob = b.createByteVector(b5.asUint8Array());

// points [Vec3]: elements (1,0,0) and (0,1,0), written reversed;
// each Vec3 packs as prep(4,12) + writeFloat32(z,y,x)
b.startVector(12, 2, 4);
b.prep(4, 12); b.writeFloat32(0); b.writeFloat32(1); b.writeFloat32(0);  // elem1 (0,1,0)
b.prep(4, 12); b.writeFloat32(0); b.writeFloat32(0); b.writeFloat32(1);  // elem0 (1,0,0)
const pointsVec = b.endVector();

// TestTable: 23 fields
b.startObject(23);
b.addFieldInt8(0, 1, 0);            // b:bool
b.addFieldInt8(1, -8, 0);           // i8
b.addFieldInt8(2, 200, 0);          // u8
b.addFieldInt16(3, -3000, 0);       // i16
b.addFieldInt16(4, 60000, 0);       // u16
b.addFieldInt32(5, -123456, 0);     // i32
b.addFieldInt32(6, 4000000000, 0);  // u32
b.addFieldInt64(7, BigInt('-9000000000'), BigInt(0));   // i64
b.addFieldInt64(8, BigInt('8000000000000000000'), BigInt(0)); // u64
b.addFieldFloat32(9, 1.5, 0);       // f32
b.addFieldFloat64(10, 3.141592653589793, 0);            // f64
b.addFieldOffset(11, name, 0);      // name
b.addFieldOffset(12, numsVec, 0);   // nums
b.addFieldOffset(13, strsVec, 0);   // strs
b.addFieldOffset(14, in1, 0);       // inner
b.addFieldOffset(15, innersVec, 0); // inners
b.addFieldInt32(16, 77, 42);        // with_default (non-default value)
// slot 17 absent_defaulted: intentionally not set
b.prep(4, 12);                      // pos:Vec3 (10.5, -2.25, 3.0) inline
b.writeFloat32(3.0); b.writeFloat32(-2.25); b.writeFloat32(10.5);
b.addFieldStruct(18, b.offset(), 0);
b.addFieldOffset(19, pointsVec, 0); // points
b.prep(8, 24);                      // tricky:Tricky {a:-1, b:2.5, c:-3} inline
b.pad(6);                           // tail pad bytes 18..23
b.writeInt16(-3);                   // c @16
b.writeFloat64(2.5);                // b @8
b.pad(7);                           // bytes 1..7
b.writeInt8(-1);                    // a @0
b.addFieldStruct(20, b.offset(), 0);
b.addFieldInt64(21, BigInt('18446744073709551615'), BigInt(0)); // big64 = u64 max
b.addFieldOffset(22, blob, 0);      // blob
const root = b.endObject();
b.finish(root);

writeFileSync(new URL('../golden/test1.bin', import.meta.url), b.asUint8Array());
console.log('wrote golden/test1.bin', b.asUint8Array().length, 'bytes');

// second vector: defaults everywhere (tiny buffer)
const b2 = new Builder(64);
b2.startObject(23);
b2.addFieldInt32(16, 42, 42); // explicit default -> skipped
const r2 = b2.endObject();
b2.finish(r2);
writeFileSync(new URL('../golden/test2_defaults.bin', import.meta.url), b2.asUint8Array());
console.log('wrote golden/test2_defaults.bin', b2.asUint8Array().length, 'bytes');

// third: size-prefixed root with file identifier "GT1!"
const b3 = new Builder(64);
b3.startObject(23);
b3.addFieldInt32(5, -7, 0);
b3.addFieldInt32(16, 42, 42); // skipped (default)
const r3 = b3.endObject();
b3.finish(r3, 'GT1!', true);
writeFileSync(new URL('../golden/test3_sizeprefixed.bin', import.meta.url), b3.asUint8Array());
console.log('wrote golden/test3_sizeprefixed.bin', b3.asUint8Array().length, 'bytes');

// fourth: forceDefaults — default-valued fields are emitted explicitly
const b4 = new Builder(64);
b4.forceDefaults(true);
b4.startObject(23);
b4.addFieldInt32(16, 42, 42);   // default value, but forced -> present in buffer
b4.addFieldInt8(0, 0, 0);       // b=false, forced
const r4 = b4.endObject();
b4.finish(r4);
writeFileSync(new URL('../golden/test4_forced.bin', import.meta.url), b4.asUint8Array());
console.log('wrote golden/test4_forced.bin', b4.asUint8Array().length, 'bytes');
