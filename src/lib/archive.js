import fs from "node:fs";
import path from "node:path";
import archiver from "archiver";

export function createZip({ jobDirectory, zipPath }) {
  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(zipPath);
    const archive = archiver("zip", { zlib: { level: 9 } });
    output.on("close", resolve);
    output.on("error", reject);
    archive.on("warning", (error) => {
      if (error.code !== "ENOENT") reject(error);
    });
    archive.on("error", reject);
    archive.pipe(output);
    for (const name of [
      "sheet.png",
      "preview.png",
      "sheet.json",
      "manifest.json",
      "reference.png",
      "reference-transparent.png",
    ]) {
      const file = path.join(jobDirectory, name);
      if (fs.existsSync(file)) archive.file(file, { name });
    }
    for (const folder of ["frames", "guides", "raw"]) {
      const directory = path.join(jobDirectory, folder);
      if (fs.existsSync(directory)) archive.directory(directory, folder);
    }
    archive.finalize().catch(reject);
  });
}
