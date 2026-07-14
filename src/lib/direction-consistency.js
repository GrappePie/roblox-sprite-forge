import sharp from "sharp";
import { alignSpriteCell } from "./postprocess.js";

export const MIRRORED_DIRECTION_SOURCES = Object.freeze({
  up_right: "up_left",
  right: "left",
  down_right: "down_left",
});

const DIRECTION_ORDER = Object.freeze([
  "down", "down_left", "left", "up_left", "up", "up_right", "right", "down_right",
]);

const DIRECTION_PAIRS = Object.freeze([
  { key: "down", anchorKeys: ["down"], leftKey: "down_left", rightKey: "down_right" },
  { key: "side", anchorKeys: ["down", "up"], leftKey: "left", rightKey: "right" },
  { key: "up", anchorKeys: ["up"], leftKey: "up_left", rightKey: "up_right" },
]);

export function getDirectionMasterStrategy(directionKey, engine = "deterministic") {
  const sourceKey = engine === "deterministic" ? MIRRORED_DIRECTION_SOURCES[directionKey] : null;
  return sourceKey
    ? { kind: "mirrored", sourceKey }
    : { kind: "generated", sourceKey: null };
}

export async function createMirroredDirectionMaster(source, options = {}) {
  if (!source) throw new Error("Falta el maestro de origen para crear la dirección reflejada.");
  const mirrored = await sharp(source)
    .flop()
    .png({ compressionLevel: 9, palette: false })
    .toBuffer();
  return alignSpriteCell(mirrored, options);
}

/**
 * Conserva una sola identidad y una sola convención de fase para cada pareja
 * diagonal. ComfyUI aún propone ambas vistas, pero la candidata más parecida
 * al maestro frontal/trasero se convierte siempre en un maestro canónico del
 * lado derecho. La izquierda se deriva después por espejo. De este modo la
 * semilla no puede cambiar qué lado define el sentido temporal del ciclo.
 */
export async function normalizeDirectionalMasters(inputMasters, options = {}) {
  const masters = new Map(inputMasters);
  const pairs = {};

  for (const pair of DIRECTION_PAIRS) {
    const normalized = await normalizePair(masters, pair, options);
    if (normalized) pairs[pair.key] = normalized;
  }

  const down = pairs.down ?? null;
  const selection = Object.keys(pairs).length
    ? {
        version: 3,
        canonicalSide: "right",
        pairs,
        // Compatibilidad con manifiestos y herramientas anteriores, que leen
        // la selección de las diagonales inferiores en el nivel superior.
        sourceKey: down?.sourceKey ?? null,
        mirroredKey: down?.mirroredKey ?? null,
        scores: down?.scores ?? null,
      }
    : null;

  return { masters, selection };
}

/**
 * Cuantiza todos los maestros como una sola imagen para compartir exactamente
 * la misma paleta. Cuantizar cada ángulo por separado hacía que tonos de piel,
 * pelo y ropa cambiaran levemente al girar.
 */
export async function harmonizeDirectionMasterPalette(inputMasters, options = {}) {
  const masters = new Map(inputMasters);
  const entries = DIRECTION_ORDER
    .filter((key) => masters.has(key))
    .map((key) => [key, masters.get(key)]);
  const harmonized = await harmonizeSpritePalette(new Map(entries), options);
  for (const [key, buffer] of harmonized) masters.set(key, buffer);
  return masters;
}

/**
 * Cuantiza cualquier conjunto de celdas como una sola tira. Se usa para que
 * las poses 3D capturadas de caminar compartan exactamente la paleta de sus
 * maestros idle, en vez de parpadear entre cuantizaciones independientes.
 */
export async function harmonizeSpritePalette(inputImages, options = {}) {
  const images = new Map(inputImages);
  const entries = [...images.entries()];
  if (!entries.length) return images;

  const metadata = await sharp(entries[0][1]).metadata();
  const width = metadata.width ?? options.cellSize ?? 64;
  const height = metadata.height ?? options.cellSize ?? 64;
  const colors = Math.max(8, Math.min(256, Number(options.paletteColors) || 64));
  const strip = await sharp({
    create: {
      width: width * entries.length,
      height,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite(entries.map(([, input], index) => ({ input, left: index * width, top: 0 })))
    .png({ palette: true, colours: colors, dither: 0, compressionLevel: 9 })
    .toBuffer();
  const [sharedPalette, accentPalette] = await Promise.all([
    readOpaquePalette(strip),
    readAccentPalette(entries),
  ]);

  await Promise.all(entries.map(async ([key, original], index) => {
    const quantized = await sharp(strip)
      .extract({ left: index * width, top: 0, width, height })
      .png({ palette: false, compressionLevel: 9 })
      .toBuffer();
    const warmPreserved = await preserveWarmColorFamilies(original, quantized, sharedPalette);
    images.set(
      key,
      await preserveAccentColorFamilies(original, warmPreserved, accentPalette),
    );
  }));
  return images;
}

/**
 * Evita que una paleta global convierta reflejos de piel cálida en gris/blanco.
 * Sólo sustituye píxeles cuyo original era claramente cálido y cuya salida se
 * volvió neutral; la ropa blanca original permanece intacta.
 */
export async function preserveWarmColorFamilies(original, quantized, palette = []) {
  const [source, output] = await Promise.all([
    sharp(original).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
    sharp(quantized).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
  ]);
  if (source.info.width !== output.info.width || source.info.height !== output.info.height) {
    return quantized;
  }
  const warmPalette = palette.filter(isWarmColor);
  const fallbackPalette = warmPalette.length ? warmPalette : null;
  for (let offset = 0; offset < output.data.length; offset += 4) {
    if (source.data[offset + 3] <= 30 || output.data[offset + 3] <= 30) continue;
    const sourceColor = [source.data[offset], source.data[offset + 1], source.data[offset + 2]];
    const outputColor = [output.data[offset], output.data[offset + 1], output.data[offset + 2]];
    if (!isWarmColor(sourceColor) || !isNeutralLight(outputColor)) continue;
    if (colorDistanceSquared(sourceColor, outputColor) < 18 ** 2) continue;
    const replacement = fallbackPalette
      ? nearestColor(sourceColor, fallbackPalette)
      : sourceColor;
    output.data[offset] = replacement[0];
    output.data[offset + 1] = replacement[1];
    output.data[offset + 2] = replacement[2];
  }
  return sharp(output.data, {
    raw: { width: output.info.width, height: output.info.height, channels: 4 },
  }).png({ palette: false, compressionLevel: 9 }).toBuffer();
}

/**
 * Reserva hasta cuatro familias saturadas muy pequeñas (por ejemplo iris o
 * maquillaje) para que la frecuencia global no las convierta en gris.
 */
export async function preserveAccentColorFamilies(original, quantized, palette = []) {
  if (!palette.length) return Buffer.from(quantized);
  const [source, output] = await Promise.all([
    sharp(original).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
    sharp(quantized).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
  ]);
  if (source.info.width !== output.info.width || source.info.height !== output.info.height) {
    return Buffer.from(quantized);
  }
  let restored = 0;
  for (let offset = 0; offset < output.data.length; offset += 4) {
    if (source.data[offset + 3] <= 30 || output.data[offset + 3] <= 30) continue;
    const sourceColor = [source.data[offset], source.data[offset + 1], source.data[offset + 2]];
    if (!isAccentColor(sourceColor)) continue;
    const replacement = nearestColor(sourceColor, palette);
    if (hueDistance(sourceColor, replacement) > 50) continue;
    const outputColor = [output.data[offset], output.data[offset + 1], output.data[offset + 2]];
    if (colorDistanceSquared(outputColor, replacement) < 30 ** 2) continue;
    output.data[offset] = replacement[0];
    output.data[offset + 1] = replacement[1];
    output.data[offset + 2] = replacement[2];
    restored += 1;
  }
  if (!restored) return Buffer.from(quantized);
  return sharp(output.data, {
    raw: { width: output.info.width, height: output.info.height, channels: 4 },
  }).png({ palette: false, compressionLevel: 9 }).toBuffer();
}

async function readAccentPalette(entries) {
  const masters = entries.filter(([key]) => String(key).startsWith("master:"));
  const samples = (masters.length ? masters : entries).slice(0, 16);
  const buckets = new Map();
  for (const [, input] of samples) {
    const { data } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    for (let offset = 0; offset < data.length; offset += 4) {
      if (data[offset + 3] <= 30) continue;
      const color = [data[offset], data[offset + 1], data[offset + 2]];
      if (!isAccentColor(color)) continue;
      const key = Math.floor((colorHue(color) + 22.5) / 45) % 8;
      const bucket = buckets.get(key) ?? { count: 0, red: 0, green: 0, blue: 0 };
      bucket.count += 1;
      bucket.red += color[0];
      bucket.green += color[1];
      bucket.blue += color[2];
      buckets.set(key, bucket);
    }
  }
  return [...buckets.values()]
    .sort((left, right) => right.count - left.count)
    .slice(0, 4)
    .map((bucket) => [
      Math.round(bucket.red / bucket.count),
      Math.round(bucket.green / bucket.count),
      Math.round(bucket.blue / bucket.count),
    ]);
}

async function readOpaquePalette(input) {
  const { data } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const colors = new Map();
  for (let offset = 0; offset < data.length; offset += 4) {
    if (data[offset + 3] <= 30) continue;
    const key = `${data[offset]},${data[offset + 1]},${data[offset + 2]}`;
    if (!colors.has(key)) colors.set(key, [data[offset], data[offset + 1], data[offset + 2]]);
  }
  return [...colors.values()];
}

function isWarmColor([red, green, blue]) {
  return red >= 90 && red - green >= 12 && green - blue >= 8;
}

function isNeutralLight([red, green, blue]) {
  return Math.max(red, green, blue) - Math.min(red, green, blue) <= 14
    && (red + green + blue) / 3 >= 145;
}

function isAccentColor([red, green, blue]) {
  const maximum = Math.max(red, green, blue);
  const minimum = Math.min(red, green, blue);
  return maximum >= 120 && maximum - minimum >= 70;
}

function colorHue([red, green, blue]) {
  const normalized = [red / 255, green / 255, blue / 255];
  const maximum = Math.max(...normalized);
  const minimum = Math.min(...normalized);
  const delta = maximum - minimum;
  if (!delta) return 0;
  let hue;
  if (maximum === normalized[0]) hue = ((normalized[1] - normalized[2]) / delta) % 6;
  else if (maximum === normalized[1]) hue = (normalized[2] - normalized[0]) / delta + 2;
  else hue = (normalized[0] - normalized[1]) / delta + 4;
  return (hue * 60 + 360) % 360;
}

function hueDistance(left, right) {
  const distance = Math.abs(colorHue(left) - colorHue(right));
  return Math.min(distance, 360 - distance);
}

function nearestColor(source, palette) {
  let winner = palette[0];
  let winnerDistance = Infinity;
  for (const candidate of palette) {
    const distance = colorDistanceSquared(source, candidate);
    if (distance < winnerDistance) {
      winner = candidate;
      winnerDistance = distance;
    }
  }
  return winner;
}

function colorDistanceSquared(left, right) {
  return (left[0] - right[0]) ** 2 + (left[1] - right[1]) ** 2 + (left[2] - right[2]) ** 2;
}

async function normalizePair(masters, pair, options) {
  const left = masters.get(pair.leftKey);
  const right = masters.get(pair.rightKey);
  const anchors = pair.anchorKeys.map((key) => masters.get(key)).filter(Boolean);
  if (!anchors.length || !left || !right) return null;

  const [anchorDescriptors, leftDescriptor, rightDescriptor] = await Promise.all([
    Promise.all(anchors.map(identityDescriptor)),
    identityDescriptor(left),
    identityDescriptor(right),
  ]);
  const leftScore = averageDistance(leftDescriptor, anchorDescriptors);
  const rightScore = averageDistance(rightDescriptor, anchorDescriptors);
  const sourceKey = rightScore <= leftScore ? pair.rightKey : pair.leftKey;
  const mirroredKey = sourceKey === pair.rightKey ? pair.leftKey : pair.rightKey;
  const source = masters.get(sourceKey);

  // La locomoción usa el lado derecho como convención anatómica canónica. Si
  // la mejor imagen nació a la izquierda, primero se refleja hacia la derecha
  // y solo entonces se construye la pareja. Esto elimina la inversión que
  // antes dependía de qué candidato ganaba para una semilla concreta.
  const rightCandidate = sourceKey === pair.rightKey ? source : await sharp(source)
    .flop()
    .png({ compressionLevel: 9, palette: false })
    .toBuffer();
  const canonicalRight = await alignSpriteCell(rightCandidate, options);
  const canonicalLeft = await createMirroredDirectionMaster(canonicalRight, options);
  masters.set(pair.rightKey, canonicalRight);
  masters.set(pair.leftKey, canonicalLeft);

  return {
    sourceKey,
    mirroredKey,
    canonicalKey: pair.rightKey,
    scores: { [pair.leftKey]: leftScore, [pair.rightKey]: rightScore },
  };
}

// Alias para consumidores y manifiestos anteriores a la normalización v3.
export const normalizeDiagonalMasters = normalizeDirectionalMasters;
export const normalizeLowerDiagonalMasters = normalizeDirectionalMasters;

function averageDistance(descriptor, anchors) {
  return anchors.reduce((sum, anchor) => sum + descriptorDistance(descriptor, anchor), 0) / anchors.length;
}

async function identityDescriptor(buffer) {
  const { data, info } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const histogram = new Float64Array(64);
  const rows = new Float64Array(info.height);
  const means = [0, 0, 0];
  let opaque = 0;
  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      const index = (y * info.width + x) * 4;
      if (data[index + 3] < 8) continue;
      const red = data[index];
      const green = data[index + 1];
      const blue = data[index + 2];
      const bucket = (red >> 6) * 16 + (green >> 6) * 4 + (blue >> 6);
      histogram[bucket] += 1;
      rows[y] += 1;
      means[0] += red;
      means[1] += green;
      means[2] += blue;
      opaque += 1;
    }
  }
  if (!opaque) return { histogram, rows, means, opaqueRatio: 0 };
  for (let index = 0; index < histogram.length; index += 1) histogram[index] /= opaque;
  for (let index = 0; index < rows.length; index += 1) rows[index] /= opaque;
  for (let index = 0; index < means.length; index += 1) means[index] /= opaque * 255;
  return {
    histogram,
    rows,
    means,
    opaqueRatio: opaque / (info.width * info.height),
  };
}

function descriptorDistance(left, right) {
  const histogram = l1Distance(left.histogram, right.histogram);
  const rows = l1Distance(left.rows, right.rows);
  const means = l1Distance(left.means, right.means) / left.means.length;
  const coverage = Math.abs(left.opaqueRatio - right.opaqueRatio);
  return histogram * 0.68 + rows * 0.17 + means * 0.1 + coverage * 0.05;
}

function l1Distance(left, right) {
  let distance = 0;
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) distance += Math.abs(left[index] - right[index]);
  return distance;
}
