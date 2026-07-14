import { config } from "../src/config.js";
import { ComfyClient } from "../src/lib/comfy.js";

const client = new ComfyClient({
  baseUrl: config.comfyUrl,
  pollMs: config.comfyPollMs,
  frameTimeoutMs: config.frameTimeoutMs,
});
const diagnosis = await client.diagnose(config.models);

console.log("\nRoblox Sprite Forge Local · diagnóstico\n");
console.log(`ComfyUI: ${diagnosis.url}`);
console.log(`Conexión: ${diagnosis.reachable ? "OK" : "FALLÓ"}`);
if (diagnosis.device) {
  console.log(`Dispositivo: ${diagnosis.device.name}`);
  if (diagnosis.device.vramTotal) console.log(`VRAM total: ${formatBytes(diagnosis.device.vramTotal)}`);
  if (diagnosis.device.vramFree) console.log(`VRAM libre: ${formatBytes(diagnosis.device.vramFree)}`);
}

if (!diagnosis.reachable) {
  console.error(`\n${diagnosis.error ?? "No se pudo conectar con ComfyUI."}`);
  console.error("Inicia ComfyUI y confirma que escucha en el puerto configurado.\n");
  process.exitCode = 1;
} else {
  printList("Nodos faltantes", diagnosis.missingNodes);
  printList("Modelos faltantes", diagnosis.missingModels);
  if (diagnosis.ok) {
    console.log("\nTodo listo para generar sprites. ✨\n");
  } else {
    console.error("\nComfyUI está activo, pero la instalación aún no está completa. Consulta README.md.\n");
    process.exitCode = 1;
  }
}

function printList(title, items) {
  if (!items?.length) return;
  console.log(`\n${title}:`);
  for (const item of items) console.log(`  - ${item}`);
}

function formatBytes(value) {
  const bytes = Number(value);
  if (!Number.isFinite(bytes)) return String(value);
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
}
