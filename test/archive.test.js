import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createZip } from "../src/lib/archive.js";

test("crea un ZIP con los artefactos del trabajo", async (context) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "rsf-archive-"));
  context.after(() => fs.rm(directory, { recursive: true, force: true }));
  await fs.mkdir(path.join(directory, "frames"));
  await fs.writeFile(path.join(directory, "sheet.png"), Buffer.from("png"));
  await fs.writeFile(path.join(directory, "manifest.json"), "{}");
  await fs.writeFile(path.join(directory, "frames", "down_idle.png"), Buffer.from("frame"));
  const zipPath = path.join(directory, "roblox-sprites.zip");
  await createZip({ jobDirectory: directory, zipPath });
  const stats = await fs.stat(zipPath);
  assert.ok(stats.size > 50);
});
