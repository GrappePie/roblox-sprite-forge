import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const files = [];
for (const folder of ["src", "public", "scripts", "test"]) {
  await collect(path.join(root, folder));
}

const javascriptFiles = files.filter((name) => name.endsWith(".js") || name.endsWith(".mjs"));
let failed = false;
for (const file of javascriptFiles) {
  const result = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
  if (result.status !== 0) {
    failed = true;
    console.error(result.stderr || result.stdout);
  }
}
if (failed) process.exit(1);

const importTargets = [
  path.join(root, "src", "config.js"),
  ...javascriptFiles.filter((file) => file.includes(`${path.sep}src${path.sep}lib${path.sep}`)),
];
for (const file of importTargets) {
  try {
    await import(`${pathToFileURL(file).href}?check=${Date.now()}-${Math.random()}`);
  } catch (error) {
    console.error(`No se pudo importar ${path.relative(root, file)}:`);
    console.error(error);
    process.exit(1);
  }
}

console.log(`Sintaxis válida en ${javascriptFiles.length} archivos JavaScript.`);
console.log(`Importaciones internas válidas en ${importTargets.length} módulos del servidor.`);

async function collect(directory) {
  const entries = await fs.readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) await collect(full);
    else files.push(full);
  }
}
