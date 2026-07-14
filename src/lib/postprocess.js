import sharp from "sharp";
import { AppError } from "./errors.js";
import { CLIPS, DIRECTIONS } from "./prompt.js";

const CHROMA_CANDIDATES = Object.freeze([
  { name: "magenta", hex: "#FF00FF", rgb: [255, 0, 255] },
  { name: "green", hex: "#00FF00", rgb: [0, 255, 0] },
  { name: "cyan", hex: "#00FFFF", rgb: [0, 255, 255] },
  { name: "yellow", hex: "#FFFF00", rgb: [255, 255, 0] },
  { name: "red", hex: "#FF2020", rgb: [255, 32, 32] },
]);

/**
 * Convierte la miniatura de Roblox en una referencia cuadrada y una copia transparente.
 */
export async function prepareAvatarReference(input, renderResolution) {
  const size = clampInteger(renderResolution, 256, 1536, 768);
  try {
    const normalized = await sharp(input, { failOn: "error" })
      .rotate()
      .ensureAlpha()
      .png()
      .toBuffer();
    const trimmed = await safeTrim(normalized);
    const maximum = Math.floor(size * 0.86);
    const subject = await sharp(trimmed)
      .resize(maximum, maximum, {
        fit: "inside",
        withoutEnlargement: false,
        kernel: sharp.kernel.lanczos3,
      })
      .png()
      .toBuffer();
    const metadata = await sharp(subject).metadata();
    const subjectWidth = metadata.width ?? maximum;
    const subjectHeight = metadata.height ?? maximum;
    const left = Math.max(0, Math.floor((size - subjectWidth) / 2));
    const top = Math.max(0, size - subjectHeight - Math.floor(size * 0.055));

    const transparent = await sharp({
      create: {
        width: size,
        height: size,
        channels: 4,
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      },
    })
      .composite([{ input: subject, left, top }])
      .png()
      .toBuffer();

    const reference = await sharp({
      create: {
        width: size,
        height: size,
        channels: 4,
        background: { r: 245, g: 247, b: 250, alpha: 1 },
      },
    })
      .composite([{ input: subject, left, top }])
      .png()
      .toBuffer();

    return {
      transparent,
      reference,
      renderResolution: size,
      subjectBox: { left, top, width: subjectWidth, height: subjectHeight },
    };
  } catch (error) {
    throw new AppError("La miniatura de Roblox no se pudo preparar como referencia.", {
      status: 502,
      code: "invalid_avatar_image",
      cause: error,
    });
  }
}

/** Elige un chroma que tenga poco parecido con el avatar visible. */
export async function chooseChromaColor(transparentAvatar) {
  const { data, info } = await sharp(transparentAvatar)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const samples = [];
  const pixelCount = info.width * info.height;
  const stride = Math.max(1, Math.floor(pixelCount / 8_000));
  for (let pixel = 0; pixel < pixelCount; pixel += stride) {
    const offset = pixel * 4;
    if (data[offset + 3] < 80) continue;
    samples.push([data[offset], data[offset + 1], data[offset + 2]]);
  }
  if (!samples.length) return { ...CHROMA_CANDIDATES[0] };

  let winner = CHROMA_CANDIDATES[0];
  let winnerScore = -Infinity;
  for (const candidate of CHROMA_CANDIDATES) {
    const distances = samples.map((sample) => squaredDistance(sample, candidate.rgb));
    distances.sort((a, b) => a - b);
    const lowPercentile = distances[Math.floor(distances.length * 0.04)] ?? 0;
    const average = distances.reduce((sum, value) => sum + value, 0) / distances.length;
    const score = lowPercentile * 0.82 + average * 0.18;
    if (score > winnerScore) {
      winner = candidate;
      winnerScore = score;
    }
  }
  return { ...winner };
}

/**
 * Elimina el fondo por flood fill desde los bordes. Primero detecta el color real
 * dominante del borde, por lo que tolera pequeñas variaciones respecto al chroma pedido.
 */
export async function removeChromaBackground(input, chroma, { trim = true } = {}) {
  const expected = Array.isArray(chroma?.rgb) ? chroma.rgb : parseHexColor(chroma?.hex ?? chroma);
  const { data, info } = await sharp(input, { failOn: "error" })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const width = info.width;
  const height = info.height;
  const pixels = width * height;
  if (!pixels || width < 2 || height < 2) {
    throw new AppError("ComfyUI produjo una imagen vacía.", {
      status: 502,
      code: "empty_generated_image",
    });
  }

  const detected = detectBorderColor(data, width, height, expected);
  const background = new Uint8Array(pixels);
  const queue = new Int32Array(pixels);
  let head = 0;
  let tail = 0;
  const seedThreshold = 78 ** 2;
  const walkThreshold = 118 ** 2;

  const enqueue = (pixel, threshold) => {
    if (background[pixel]) return;
    const offset = pixel * 4;
    if (
      data[offset + 3] <= 8 ||
      squaredDistance([data[offset], data[offset + 1], data[offset + 2]], detected) <= threshold
    ) {
      background[pixel] = 1;
      queue[tail++] = pixel;
    }
  };

  for (let x = 0; x < width; x += 1) {
    enqueue(x, seedThreshold);
    enqueue((height - 1) * width + x, seedThreshold);
  }
  for (let y = 1; y < height - 1; y += 1) {
    enqueue(y * width, seedThreshold);
    enqueue(y * width + width - 1, seedThreshold);
  }

  while (head < tail) {
    const pixel = queue[head++];
    const x = pixel % width;
    const y = Math.floor(pixel / width);
    if (x > 0) enqueue(pixel - 1, walkThreshold);
    if (x + 1 < width) enqueue(pixel + 1, walkThreshold);
    if (y > 0) enqueue(pixel - width, walkThreshold);
    if (y + 1 < height) enqueue(pixel + width, walkThreshold);
  }

  const directThreshold = 42 ** 2;
  const featherThreshold = 98 ** 2;
  for (let pixel = 0; pixel < pixels; pixel += 1) {
    const offset = pixel * 4;
    if (background[pixel]) {
      data[offset + 3] = 0;
      continue;
    }
    const distance = squaredDistance(
      [data[offset], data[offset + 1], data[offset + 2]],
      detected,
    );
    if (distance <= directThreshold) {
      data[offset + 3] = 0;
    } else if (distance < featherThreshold) {
      const factor =
        (Math.sqrt(distance) - Math.sqrt(directThreshold)) /
        (Math.sqrt(featherThreshold) - Math.sqrt(directThreshold));
      data[offset + 3] = Math.round(data[offset + 3] * Math.max(0, Math.min(1, factor)));
    }
  }

  // El antialias de Studio mezcla el borde del avatar con el chroma antes de
  // entregarnos la captura. Quitar sólo el alpha deja RGB magenta/verde dentro
  // del contorno y la cuantización posterior lo convierte en píxeles sólidos.
  // Reconstruimos esos bordes desde un color interior cercano y reducimos el
  // spill restante antes de crear la paleta compartida.
  despillChromaEdges(data, width, height, background, detected);
  removeTinyAlphaComponents(data, width, height);
  const opaqueCount = countOpaquePixels(data);
  if (opaqueCount < Math.max(12, pixels * 0.0002)) {
    throw new AppError(
      "No pude separar el personaje del fondo. Prueba otra semilla o describe mejor el avatar.",
      {
        status: 422,
        code: "subject_not_detected",
        details: { expected: rgbToHex(expected), detected: rgbToHex(detected) },
      },
    );
  }

  const transparent = await sharp(data, { raw: { width, height, channels: 4 } })
    .png()
    .toBuffer();
  return trim ? safeTrim(transparent) : transparent;
}

/** Reduce un personaje transparente a una celda fija y alinea los pies. */
export async function renderSpriteCell(input, { cellSize, paletteColors }) {
  const size = clampInteger(cellSize, 16, 512, 64);
  const colors = clampInteger(paletteColors, 8, 256, 64);
  const paddingX = Math.max(2, Math.round(size * 0.055));
  const paddingTop = Math.max(2, Math.round(size * 0.045));
  const paddingBottom = Math.max(2, Math.round(size * 0.035));
  const maxWidth = size - paddingX * 2;
  const maxHeight = size - paddingTop - paddingBottom;
  const trimmed = await safeTrim(input);
  const metadata = await sharp(trimmed).metadata();
  const width = metadata.width ?? 1;
  const height = metadata.height ?? 1;
  const scale = Math.min(maxWidth / width, maxHeight / height);
  const targetWidth = Math.max(1, Math.round(width * scale));
  const targetHeight = Math.max(1, Math.round(height * scale));
  const resized = await sharp(trimmed)
    .resize(targetWidth, targetHeight, { fit: "fill", kernel: sharp.kernel.nearest })
    .ensureAlpha()
    .png()
    .toBuffer();
  const left = Math.floor((size - targetWidth) / 2);
  const top = Math.max(paddingTop, size - paddingBottom - targetHeight);
  const centered = await sharp({
    create: {
      width: size,
      height: size,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: resized, left, top }])
    .png({ palette: true, colours: colors, dither: 0, compressionLevel: 9 })
    .toBuffer();
  const aligned = await alignSpriteCell(centered, { cellSize: size, paletteColors: colors });
  return removeIsolatedAlphaPixels(aligned);
}

/**
 * Calcula una sola transformación para todas las poses capturadas desde una
 * misma cámara de Studio. La raíz visual del idle queda fija y ninguna pose se
 * vuelve a recortar, centrar o escalar de forma independiente.
 */
export async function createStudioCellTransform(reference, { cellSize, paletteColors } = {}) {
  return createRegisteredStudioTransform(reference, { cellSize, paletteColors }, "feet");
}

/**
 * Registra el nado alrededor del torso/raíz del rig. Una pose horizontal no
 * tiene una línea de pies útil y por eso no debe heredar el pivote del suelo.
 */
export async function createStudioSwimCellTransform(reference, { cellSize, paletteColors } = {}) {
  return createRegisteredStudioTransform(reference, { cellSize, paletteColors }, "torso");
}

async function createRegisteredStudioTransform(reference, { cellSize, paletteColors } = {}, anchorMode) {
  const { data, info } = await sharp(reference).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const size = clampInteger(cellSize, 16, 512, 64);
  const colors = clampInteger(paletteColors, 8, 256, 64);
  const anchor = analyzeFootAnchor(data, info.width, info.height);
  if (!anchor) {
    throw new AppError("La captura idle de Studio no contiene un personaje visible.", {
      status: 502,
      code: "studio_reference_subject_missing",
    });
  }

  // Un margen mayor que el de un frame aislado reserva espacio para brazos y
  // piernas extendidos sin sacrificar la escala común de la secuencia.
  const paddingX = Math.max(3, Math.round(size * 0.10));
  // El cuarto keyframe de varias animaciones de salto eleva la cabeza por
  // encima del volumen idle. Reservar el mismo margen horizontal también
  // arriba evita recortarlo sin desplazar el pivote de los pies.
  // Accesorios altos (halos, cuernos, antenas) pueden tocar el borde cuando la
  // animación de salto eleva todo el rig. El 18 % reserva además el pequeño
  // desplazamiento vertical real de las animaciones equipadas sin recentrar
  // cada pose ni alterar el pivote compartido de los pies.
  const paddingTop = Math.max(3, Math.round(size * 0.18));
  const paddingBottom = Math.max(3, Math.round(size * 0.07));
  const subjectWidth = anchor.bounds.right - anchor.bounds.left + 1;
  const subjectHeight = anchor.bounds.bottom - anchor.bounds.top + 1;
  const scale = Math.min(
    (size - paddingX * 2) / subjectWidth,
    (size - paddingTop - paddingBottom) / subjectHeight,
  );
  const targetX = Math.floor(size / 2) + 1;
  const targetY = anchorMode === "torso" ? Math.floor(size / 2) : size - paddingBottom - 1;
  const sourceAnchorX = anchorMode === "torso"
    ? Math.round((anchor.bounds.left + anchor.bounds.right) / 2)
    : anchor.x;
  const sourceAnchorY = anchorMode === "torso"
    ? Math.round(anchor.bounds.top + subjectHeight * 0.53)
    : anchor.y;
  const windowWidth = Math.max(1, Math.round(size / scale));
  const windowHeight = Math.max(1, Math.round(size / scale));

  return {
    sourceWidth: info.width,
    sourceHeight: info.height,
    outputSize: size,
    paletteColors: colors,
    scale,
    windowWidth,
    windowHeight,
    windowLeft: Math.round(sourceAnchorX - targetX / scale),
    windowTop: Math.round(sourceAnchorY - targetY / scale),
    anchorMode,
  };
}

export async function renderStudioSpriteCell(input, transform, { cellSize, paletteColors } = {}) {
  const metadata = await sharp(input).metadata();
  const size = clampInteger(cellSize, 16, 512, transform?.outputSize ?? 64);
  const colors = clampInteger(paletteColors, 8, 256, transform?.paletteColors ?? 64);
  if (
    !transform
    || metadata.width !== transform.sourceWidth
    || metadata.height !== transform.sourceHeight
    || size !== transform.outputSize
  ) {
    throw new AppError("La pose de Studio no coincide con el encuadre fijo de su dirección.", {
      status: 502,
      code: "studio_motion_registration_mismatch",
    });
  }
  const extendLeft = Math.max(0, -transform.windowLeft);
  const extendTop = Math.max(0, -transform.windowTop);
  const extendRight = Math.max(
    0,
    transform.windowLeft + transform.windowWidth - transform.sourceWidth,
  );
  const extendBottom = Math.max(
    0,
    transform.windowTop + transform.windowHeight - transform.sourceHeight,
  );
  const registered = await sharp(input)
    .ensureAlpha()
    .extend({
      left: extendLeft,
      top: extendTop,
      right: extendRight,
      bottom: extendBottom,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .extract({
      left: transform.windowLeft + extendLeft,
      top: transform.windowTop + extendTop,
      width: transform.windowWidth,
      height: transform.windowHeight,
    })
    .resize(size, size, { fit: "fill", kernel: sharp.kernel.nearest })
    .png({ palette: true, colours: colors, dither: 0, compressionLevel: 9 })
    .toBuffer();
  return removeIsolatedAlphaPixels(registered);
}

/** Elimina únicamente píxeles alfa completamente solos; conserva grupos y diagonales finas. */
export async function removeIsolatedAlphaPixels(input) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const isolated = [];
  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      const offset = (y * info.width + x) * 4;
      if (data[offset + 3] < 8) continue;
      let neighbor = false;
      for (let dy = -1; dy <= 1 && !neighbor; dy += 1) {
        for (let dx = -1; dx <= 1; dx += 1) {
          if (!dx && !dy) continue;
          const nx = x + dx;
          const ny = y + dy;
          if (nx < 0 || nx >= info.width || ny < 0 || ny >= info.height) continue;
          if (data[(ny * info.width + nx) * 4 + 3] >= 8) {
            neighbor = true;
            break;
          }
        }
      }
      if (!neighbor) isolated.push(offset);
    }
  }
  for (const offset of isolated) data.fill(0, offset, offset + 4);
  return sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } })
    .png({ compressionLevel: 9, palette: false })
    .toBuffer();
}

/**
 * Alinea una celda por las piernas y los pies, no por accesorios asimétricos.
 * Así todas las direcciones comparten el mismo pivote visual en el juego.
 */
export async function alignSpriteCell(input, { cellSize, paletteColors } = {}) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const size = clampInteger(cellSize, 16, 512, info.width);
  const colors = clampInteger(paletteColors, 8, 256, 64);
  if (info.width !== size || info.height !== size) return Buffer.from(input);
  const anchor = analyzeFootAnchor(data, info.width, info.height);
  if (!anchor) return Buffer.from(input);

  // Un píxel a la derecha del centro geométrico deja un pivote entero común
  // en celdas pares y, para accesorios anchos, maximiza la intersección útil
  // entre vistas izquierda/derecha sin recortar ninguna de las dos.
  const targetX = Math.floor(size / 2) + 1;
  const targetY = size - Math.max(2, Math.round(size * 0.035)) - 1;
  const horizontalLimits = translationLimits(anchor.bounds.left, anchor.bounds.right, size);
  const verticalLimits = translationLimits(anchor.bounds.top, anchor.bounds.bottom, size);
  const shiftX = Math.max(horizontalLimits.minimum, Math.min(horizontalLimits.maximum, Math.round(targetX - anchor.x)));
  const shiftY = Math.max(verticalLimits.minimum, Math.min(verticalLimits.maximum, Math.round(targetY - anchor.y)));
  if (!shiftX && !shiftY) return Buffer.from(input);

  const output = Buffer.alloc(data.length);
  for (let y = anchor.bounds.top; y <= anchor.bounds.bottom; y += 1) {
    for (let x = anchor.bounds.left; x <= anchor.bounds.right; x += 1) {
      const source = (y * size + x) * 4;
      if (data[source + 3] < 1) continue;
      const destinationX = x + shiftX;
      const destinationY = y + shiftY;
      if (destinationX < 0 || destinationX >= size || destinationY < 0 || destinationY >= size) continue;
      const destination = (destinationY * size + destinationX) * 4;
      data.copy(output, destination, source, source + 4);
    }
  }
  return sharp(output, { raw: { width: size, height: size, channels: 4 } })
    .png({ palette: true, colours: colors, dither: 0, compressionLevel: 9 })
    .toBuffer();
}

export async function measureSpriteFootAnchor(input) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const anchor = analyzeFootAnchor(data, info.width, info.height);
  return anchor ? { x: anchor.x, y: anchor.y, bounds: anchor.bounds } : null;
}

/**
 * Corrige solamente el desplazamiento horizontal de una pose contra el torso
 * de su vista idle. Los pies siguen conservando la altura calculada por
 * alignSpriteCell y la zancada no se deforma ni se vuelve a escalar.
 */
export async function alignSpriteTorsoToReference(input, reference, { cellSize, paletteColors } = {}) {
  const [source, target] = await Promise.all([
    sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
    sharp(reference).ensureAlpha().raw().toBuffer({ resolveWithObject: true }),
  ]);
  const size = clampInteger(cellSize, 16, 512, source.info.width);
  const colors = clampInteger(paletteColors, 8, 256, 64);
  if (
    source.info.width !== size
    || source.info.height !== size
    || target.info.width !== size
    || target.info.height !== size
  ) {
    return Buffer.from(input);
  }

  const sourceAnchor = analyzeTorsoAnchor(source.data, size, size);
  const targetAnchor = analyzeTorsoAnchor(target.data, size, size);
  if (!sourceAnchor || !targetAnchor) return Buffer.from(input);

  const horizontalLimits = translationLimits(sourceAnchor.bounds.left, sourceAnchor.bounds.right, size);
  const shiftX = Math.max(
    horizontalLimits.minimum,
    Math.min(horizontalLimits.maximum, Math.round(targetAnchor.x - sourceAnchor.x)),
  );
  if (!shiftX) return Buffer.from(input);

  const output = Buffer.alloc(source.data.length);
  for (let y = sourceAnchor.bounds.top; y <= sourceAnchor.bounds.bottom; y += 1) {
    for (let x = sourceAnchor.bounds.left; x <= sourceAnchor.bounds.right; x += 1) {
      const sourceOffset = (y * size + x) * 4;
      if (source.data[sourceOffset + 3] < 1) continue;
      const destinationX = x + shiftX;
      if (destinationX < 0 || destinationX >= size) continue;
      const destinationOffset = (y * size + destinationX) * 4;
      source.data.copy(output, destinationOffset, sourceOffset, sourceOffset + 4);
    }
  }

  return sharp(output, { raw: { width: size, height: size, channels: 4 } })
    .png({ palette: true, colours: colors, dither: 0, compressionLevel: 9 })
    .toBuffer();
}

export async function measureSpriteTorsoAnchor(input) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const anchor = analyzeTorsoAnchor(data, info.width, info.height);
  return anchor ? { x: anchor.x, bounds: anchor.bounds } : null;
}

export async function assembleSpriteSheet(frames, { cellSize, paletteColors }) {
  const size = clampInteger(cellSize, 16, 512, 64);
  // Las celdas ya comparten una paleta armonizada. Volver a cuantizar la hoja
  // completa puede convertir tonos cálidos poco frecuentes en gris/blanco.
  void paletteColors;
  const composites = frames.map((frame) => ({
    input: frame.buffer,
    left: frame.column * size,
    top: frame.row * size,
  }));
  const columns = Math.max(1, ...frames.map((frame) => frame.column + 1));
  const rows = Math.max(1, ...frames.map((frame) => frame.row + 1));
  return sharp({
    create: {
      width: size * columns,
      height: size * rows,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite(composites)
    .png({ palette: false, compressionLevel: 9 })
    .toBuffer();
}

export async function createPixelPreview(sheet, scale = 4) {
  const metadata = await sharp(sheet).metadata();
  const factor = clampInteger(scale, 2, 12, 4);
  return sharp(sheet)
    .resize((metadata.width ?? 256) * factor, (metadata.height ?? 256) * factor, {
      kernel: sharp.kernel.nearest,
    })
    .png({ compressionLevel: 9 })
    .toBuffer();
}

export function createAtlasData({ username, cellSize, frames, sheetFilename = "sheet.png" }) {
  const size = clampInteger(cellSize, 16, 512, 64);
  const atlasFrames = {};
  for (const frame of frames) {
    atlasFrames[`${frame.key}.png`] = {
      frame: { x: frame.column * size, y: frame.row * size, w: size, h: size },
      rotated: false,
      trimmed: false,
      spriteSourceSize: { x: 0, y: 0, w: size, h: size },
      sourceSize: { w: size, h: size },
        duration: frame.clip.key === "idle" || frame.clip.key === "idle_alt"
          ? Math.round(4_000 / Math.max(1, frame.frameCount ?? 1))
          : frame.clip.key === "run"
            ? 72
            : frame.clip.key === "jump" || frame.clip.key === "fall"
              ? 90
              : 100,
    };
  }
  return {
    frames: atlasFrames,
    animations: Object.fromEntries(DIRECTIONS.flatMap((direction) =>
      CLIPS.map((clip) => [
        `${direction.key}_${clip.key}`,
        frames
          .filter((frame) => frame.direction.key === direction.key && frame.clip.key === clip.key)
          .map((frame) => `${frame.key}.png`),
      ]),
    )),
    meta: {
      app: "Roblox Sprite Forge Local",
      version: "1.0.0",
      image: sheetFilename,
      format: "RGBA8888",
      size: {
        w: size * Math.max(1, ...frames.map((frame) => frame.column + 1)),
        h: size * DIRECTIONS.length * CLIPS.length,
      },
      scale: "1",
      character: username,
      directions: DIRECTIONS.map((direction) => direction.key),
      clips: CLIPS.map((clip) => clip.key),
      framesPerAnimation: Math.max(1, ...frames.map((frame) => frame.frameCount ?? 1)),
      frameCounts: Object.fromEntries(CLIPS.map((clip) => [
        clip.key,
        Math.max(
          1,
          ...frames
            .filter((frame) => frame.clip.key === clip.key)
            .map((frame) => frame.frameCount ?? 1),
        ),
      ])),
    },
  };
}

function detectBorderColor(data, width, height, expected) {
  const buckets = new Map();
  const border = Math.max(1, Math.floor(Math.min(width, height) * 0.04));
  const step = Math.max(1, Math.floor(Math.max(width, height) / 300));
  for (let y = 0; y < height; y += step) {
    for (let x = 0; x < width; x += step) {
      if (x >= border && x < width - border && y >= border && y < height - border) continue;
      const offset = (y * width + x) * 4;
      if (data[offset + 3] < 20) continue;
      const key = `${Math.round(data[offset] / 16)},${Math.round(data[offset + 1] / 16)},${Math.round(data[offset + 2] / 16)}`;
      const bucket = buckets.get(key) ?? { count: 0, r: 0, g: 0, b: 0 };
      bucket.count += 1;
      bucket.r += data[offset];
      bucket.g += data[offset + 1];
      bucket.b += data[offset + 2];
      buckets.set(key, bucket);
    }
  }
  let winner = null;
  for (const bucket of buckets.values()) {
    if (!winner || bucket.count > winner.count) winner = bucket;
  }
  if (!winner || winner.count < 4) return expected;
  return [
    Math.round(winner.r / winner.count),
    Math.round(winner.g / winner.count),
    Math.round(winner.b / winner.count),
  ];
}

function despillChromaEdges(data, width, height, background, chroma) {
  const pixels = width * height;
  const source = Buffer.from(data);
  const edgeDistance = new Uint8Array(pixels);
  edgeDistance.fill(15);
  for (let pixel = 0; pixel < pixels; pixel += 1) {
    if (background[pixel] || source[pixel * 4 + 3] <= 18) edgeDistance[pixel] = 0;
  }

  // Distancia Chebyshev aproximada al fondo en dos pasadas. Sólo necesitamos
  // distinguir una banda de cuatro píxeles, así que saturamos pronto.
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const pixel = y * width + x;
      if (!edgeDistance[pixel]) continue;
      let nearest = edgeDistance[pixel];
      if (x > 0) nearest = Math.min(nearest, edgeDistance[pixel - 1] + 1);
      if (y > 0) nearest = Math.min(nearest, edgeDistance[pixel - width] + 1);
      if (x > 0 && y > 0) nearest = Math.min(nearest, edgeDistance[pixel - width - 1] + 1);
      if (x + 1 < width && y > 0) nearest = Math.min(nearest, edgeDistance[pixel - width + 1] + 1);
      edgeDistance[pixel] = Math.min(15, nearest);
    }
  }
  for (let y = height - 1; y >= 0; y -= 1) {
    for (let x = width - 1; x >= 0; x -= 1) {
      const pixel = y * width + x;
      if (!edgeDistance[pixel]) continue;
      let nearest = edgeDistance[pixel];
      if (x + 1 < width) nearest = Math.min(nearest, edgeDistance[pixel + 1] + 1);
      if (y + 1 < height) nearest = Math.min(nearest, edgeDistance[pixel + width] + 1);
      if (x + 1 < width && y + 1 < height) nearest = Math.min(nearest, edgeDistance[pixel + width + 1] + 1);
      if (x > 0 && y + 1 < height) nearest = Math.min(nearest, edgeDistance[pixel + width - 1] + 1);
      edgeDistance[pixel] = Math.min(15, nearest);
    }
  }

  const maximumBand = 4;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const pixel = y * width + x;
      const distance = edgeDistance[pixel];
      if (!distance || distance > maximumBand) continue;
      const offset = pixel * 4;
      if (source[offset + 3] <= 18) continue;

      const targetDistance = Math.min(7, distance + 2);
      const candidate = findInteriorColor(
        source,
        edgeDistance,
        width,
        height,
        x,
        y,
        targetDistance,
      );
      let reconstructed = false;
      if (candidate) {
        const current = [source[offset], source[offset + 1], source[offset + 2]];
        const currentDistance = Math.sqrt(squaredDistance(current, chroma));
        const interiorDistance = Math.sqrt(squaredDistance(candidate, chroma));
        if (interiorDistance > 40 && currentDistance < interiorDistance * 0.985) {
          const alpha = Math.max(0.08, Math.min(1, currentDistance / interiorDistance));
          const predicted = candidate.map((channel, index) => (
            alpha * channel + (1 - alpha) * chroma[index]
          ));
          const residual = Math.sqrt(squaredDistance(current, predicted));
          if (residual <= 72) {
            data[offset] = candidate[0];
            data[offset + 1] = candidate[1];
            data[offset + 2] = candidate[2];
            reconstructed = true;
          }
        }
      }
      if (!reconstructed) suppressChromaSpill(data, offset, chroma, distance, maximumBand);
    }
  }

  // Algunas texturas UGC (sobre todo cabello con planos transparentes) dejan
  // entrar el fondo por toda la superficie, no sólo por el contorno. Como el
  // chroma se elige precisamente por ser lejano a la paleta del avatar, es
  // seguro eliminar su dominante también en el interior visible.
  for (let pixel = 0; pixel < pixels; pixel += 1) {
    const offset = pixel * 4;
    if (background[pixel] || data[offset + 3] <= 18) continue;
    suppressChromaSpill(data, offset, chroma, 1, 1);
  }
}

function findInteriorColor(source, edgeDistance, width, height, x, y, targetDistance) {
  for (let radius = 1; radius <= 9; radius += 1) {
    let winner = null;
    let winnerSpatialDistance = Infinity;
    const left = Math.max(0, x - radius);
    const right = Math.min(width - 1, x + radius);
    const top = Math.max(0, y - radius);
    const bottom = Math.min(height - 1, y + radius);
    for (let candidateY = top; candidateY <= bottom; candidateY += 1) {
      for (let candidateX = left; candidateX <= right; candidateX += 1) {
        if (Math.max(Math.abs(candidateX - x), Math.abs(candidateY - y)) !== radius) continue;
        const pixel = candidateY * width + candidateX;
        const offset = pixel * 4;
        if (edgeDistance[pixel] < targetDistance || source[offset + 3] < 220) continue;
        const spatialDistance = Math.hypot(candidateX - x, candidateY - y);
        if (spatialDistance >= winnerSpatialDistance) continue;
        winnerSpatialDistance = spatialDistance;
        winner = [source[offset], source[offset + 1], source[offset + 2]];
      }
    }
    if (winner) return winner;
  }
  return null;
}

function suppressChromaSpill(data, offset, chroma, distance, maximumBand) {
  const maximum = Math.max(...chroma, 1);
  const dominant = [];
  const other = [];
  for (let channel = 0; channel < 3; channel += 1) {
    if (chroma[channel] >= maximum * 0.72) dominant.push(channel);
    else other.push(channel);
  }
  if (!dominant.length || !other.length) return;
  const dominantFloor = Math.min(...dominant.map((channel) => data[offset + channel]));
  const otherCeiling = Math.max(...other.map((channel) => data[offset + channel]));
  const excess = dominantFloor - otherCeiling;
  if (excess <= 18) return;
  const strength = Math.max(0.25, (maximumBand + 1 - distance) / maximumBand);
  for (const channel of dominant) {
    const share = chroma[channel] / maximum;
    data[offset + channel] = Math.max(
      0,
      Math.round(data[offset + channel] - excess * strength * share),
    );
  }
}

async function safeTrim(input) {
  try {
    return await sharp(input)
      .ensureAlpha()
      .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 }, threshold: 2 })
      .png()
      .toBuffer();
  } catch {
    return sharp(input).ensureAlpha().png().toBuffer();
  }
}

function removeTinyAlphaComponents(data, width, height) {
  const pixels = width * height;
  const labels = new Int32Array(pixels);
  const queue = new Int32Array(pixels);
  const counts = [0];
  let label = 0;
  let largest = 0;
  for (let start = 0; start < pixels; start += 1) {
    if (labels[start] || data[start * 4 + 3] <= 18) continue;
    label += 1;
    let head = 0;
    let tail = 0;
    queue[tail++] = start;
    labels[start] = label;
    let count = 0;
    while (head < tail) {
      const pixel = queue[head++];
      count += 1;
      const x = pixel % width;
      const y = Math.floor(pixel / width);
      for (let dy = -1; dy <= 1; dy += 1) {
        for (let dx = -1; dx <= 1; dx += 1) {
          if (!dx && !dy) continue;
          const nx = x + dx;
          const ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          const neighbor = ny * width + nx;
          if (labels[neighbor] || data[neighbor * 4 + 3] <= 18) continue;
          labels[neighbor] = label;
          queue[tail++] = neighbor;
        }
      }
    }
    counts[label] = count;
    largest = Math.max(largest, count);
  }
  if (!largest) return;
  const minimum = Math.max(3, Math.floor(largest * 0.0005));
  for (let pixel = 0; pixel < pixels; pixel += 1) {
    const component = labels[pixel];
    if (!component || counts[component] < minimum) data[pixel * 4 + 3] = 0;
  }
}

function countOpaquePixels(data) {
  let count = 0;
  for (let offset = 3; offset < data.length; offset += 4) {
    if (data[offset] > 18) count += 1;
  }
  return count;
}

function squaredDistance(a, b) {
  return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2;
}

function parseHexColor(value) {
  const match = String(value ?? "").trim().match(/^#?([0-9a-f]{6})$/i);
  if (!match) {
    throw new AppError("El color chroma no es válido.", {
      status: 500,
      code: "invalid_chroma_color",
      details: { value },
    });
  }
  const number = Number.parseInt(match[1], 16);
  return [(number >> 16) & 255, (number >> 8) & 255, number & 255];
}

function rgbToHex(rgb) {
  return `#${rgb.map((value) => value.toString(16).padStart(2, "0")).join("")}`.toUpperCase();
}

function clampInteger(value, minimum, maximum, fallback) {
  const number = Number(value);
  if (!Number.isInteger(number)) return fallback;
  return Math.max(minimum, Math.min(maximum, number));
}

function analyzeFootAnchor(data, width, height) {
  let left = width;
  let right = -1;
  let top = height;
  let bottom = -1;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (data[(y * width + x) * 4 + 3] < 8) continue;
      left = Math.min(left, x);
      right = Math.max(right, x);
      top = Math.min(top, y);
      bottom = Math.max(bottom, y);
    }
  }
  if (right < left) return null;
  const subjectHeight = bottom - top + 1;
  const lowerBandTop = Math.max(top, bottom - Math.max(3, Math.round(subjectHeight * 0.28)));
  const horizontalSamples = [];
  for (let y = lowerBandTop; y <= bottom; y += 1) {
    for (let x = left; x <= right; x += 1) {
      if (data[(y * width + x) * 4 + 3] >= 8) horizontalSamples.push(x);
    }
  }
  horizontalSamples.sort((a, b) => a - b);
  const middle = Math.floor(horizontalSamples.length / 2);
  const x = horizontalSamples.length % 2
    ? horizontalSamples[middle]
    : (horizontalSamples[middle - 1] + horizontalSamples[middle]) / 2;
  return { x, y: bottom, bounds: { left, right, top, bottom } };
}

function analyzeTorsoAnchor(data, width, height) {
  const footAnchor = analyzeFootAnchor(data, width, height);
  if (!footAnchor) return null;
  const { bounds } = footAnchor;
  const subjectHeight = bounds.bottom - bounds.top + 1;
  const torsoTop = Math.round(bounds.top + subjectHeight * 0.34);
  const torsoBottom = Math.round(bounds.top + subjectHeight * 0.60);
  const boundsCenter = (bounds.left + bounds.right) / 2;
  const rowCenters = [];

  // El torso suele ser el tramo opaco contiguo más ancho de cada fila.
  // Medirlo por filas evita que brazos, cabello o colas dominen el ancla.
  for (let y = torsoTop; y <= torsoBottom; y += 1) {
    const runs = [];
    let runStart = -1;
    for (let x = bounds.left; x <= bounds.right + 1; x += 1) {
      const opaque = x <= bounds.right && data[(y * width + x) * 4 + 3] >= 8;
      if (opaque && runStart < 0) runStart = x;
      if (!opaque && runStart >= 0) {
        runs.push({
          start: runStart,
          end: x - 1,
          length: x - runStart,
        });
        runStart = -1;
      }
    }
    runs.sort((left, right) => (
      right.length - left.length
      || Math.abs((left.start + left.end) / 2 - boundsCenter)
        - Math.abs((right.start + right.end) / 2 - boundsCenter)
    ));
    if (runs[0]) rowCenters.push((runs[0].start + runs[0].end) / 2);
  }
  if (!rowCenters.length) return null;
  rowCenters.sort((left, right) => left - right);
  const middle = Math.floor(rowCenters.length / 2);
  const x = rowCenters.length % 2
    ? rowCenters[middle]
    : (rowCenters[middle - 1] + rowCenters[middle]) / 2;
  return { x, bounds };
}

function translationLimits(start, end, size) {
  return { minimum: -start, maximum: size - 1 - end };
}
