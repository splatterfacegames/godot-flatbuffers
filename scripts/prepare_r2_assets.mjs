import { mkdir, readdir, rename, rm, stat } from "node:fs/promises";
import { extname, join, relative } from "node:path";

const source = process.argv[2] ?? "dist";
const destination = process.argv[3] ?? ".r2-upload";
const limit = Number(process.env.PAGES_ASSET_LIMIT_BYTES ?? 24 * 1024 * 1024);
const supported = new Set([".pck", ".wasm"]);
const moved = [];

async function filesUnder(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path));
    else if (entry.isFile()) files.push(path);
  }
  return files;
}

await rm(destination, { force: true, recursive: true });

for (const path of await filesUnder(source)) {
  const metadata = await stat(path);
  if (metadata.size <= limit) continue;

  const suffix = extname(path).toLowerCase();
  if (!supported.has(suffix)) {
    throw new Error(`${relative(source, path)} exceeds the Pages limit but cannot be served by the R2 function`);
  }

  const assetPath = relative(source, path);
  const target = join(destination, assetPath);
  await mkdir(join(target, ".."), { recursive: true });
  await rename(path, target);
  moved.push({ path: assetPath.replaceAll("\\", "/"), bytes: metadata.size });
}

console.log(JSON.stringify({ limit, moved }, null, 2));
