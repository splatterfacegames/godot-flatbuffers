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

// TestTable: 18 fields
b.startObject(18);
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
const root = b.endObject();
b.finish(root);

writeFileSync(new URL('../golden/test1.bin', import.meta.url), b.asUint8Array());
console.log('wrote golden/test1.bin', b.asUint8Array().length, 'bytes');

// second vector: defaults everywhere (tiny buffer)
const b2 = new Builder(64);
b2.startObject(18);
b2.addFieldInt32(16, 42, 42); // explicit default -> skipped
const r2 = b2.endObject();
b2.finish(r2);
writeFileSync(new URL('../golden/test2_defaults.bin', import.meta.url), b2.asUint8Array());
console.log('wrote golden/test2_defaults.bin', b2.asUint8Array().length, 'bytes');
