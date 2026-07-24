import path from "node:path";
import { importGoldenArtwork } from "../../src/lib/golden-artwork.js";

const root = path.resolve(import.meta.dirname, "../..");
const args = parseArgs(process.argv.slice(2));
if (!args.request || !args.image) {
  throw new Error(
    "Usage: npm run stylizer:import-result -- --request <request.json> --image <canonical.png>",
  );
}

const result = await importGoldenArtwork({
  requestPath: path.resolve(args.request),
  imagePath: path.resolve(args.image),
  resultsRoot: path.join(root, "stylization-results"),
  expectedFingerprint: args.fingerprint,
});
console.log(JSON.stringify({
  imported: result.outputDirectory,
  fingerprint: result.packageManifest.fingerprint,
  master: result.packageManifest.variants.master,
  derived: result.packageManifest.variants.derived,
  warnings: result.validationReport.warnings,
}, null, 2));

function parseArgs(values) {
  const parsed = {};
  for (let index = 0; index < values.length; index += 1) {
    const item = values[index];
    if (!item.startsWith("--")) continue;
    parsed[item.slice(2)] = values[index + 1];
    index += 1;
  }
  return parsed;
}
