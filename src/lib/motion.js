import sharp from "sharp";

/**
 * Anima una celda canónica sin volver a sintetizar el personaje. Idle usa una
 * respiración subpixel suave; caminar conserva el cuerpo rígido y articula las
 * piernas como capas para no deformar cara, cabello, ropa ni accesorios.
 */
export async function animateCanonicalCell(master, frame) {
  const { data, info } = await sharp(master).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const bounds = findOpaqueBounds(data, info.width, info.height);
  if (!bounds) return Buffer.from(master);
  const output = Buffer.alloc(data.length);
  const count = Math.max(2, Number(frame?.frameCount) || 4);
  const index = Math.max(1, Number(frame?.frameIndex) || 1);
  const phase = ((index - 1) / count) * Math.PI * 2;
  const clipKey = frame?.clip?.key ?? "idle";
  const isLocomotion = clipKey === "walk" || clipKey === "run" || clipKey === "climb";
  if (isLocomotion) {
    return renderLayeredLocomotion(
      data,
      info,
      bounds,
      phase,
      frame?.direction?.key ?? "down",
      clipKey,
    );
  }
  if (clipKey === "jump" || clipKey === "fall") {
    return renderAirborneFallback(data, info, bounds, clipKey, index, count);
  }
  const centerX = (bounds.left + bounds.right) / 2;
  const spriteWidth = Math.max(1, bounds.right - bounds.left + 1);
  const spriteHeight = Math.max(1, bounds.bottom - bounds.top + 1);
  const halfWidth = Math.max(1, spriteWidth / 2);

  // Pull mapping: recorremos cada destino y buscamos su origen. A diferencia
  // del mapeo hacia delante, nunca deja pixeles vacios entre zonas deformadas.
  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      const yRatio = (y - bounds.top) / spriteHeight;
      const xRatio = (x - centerX) / halfWidth;
      const { dx, dy } = calculateDisplacement({ xRatio, yRatio, phase, isWalk: false });
      const sourceX = Math.round(x - dx);
      const sourceY = Math.round(y - dy);
      if (sourceX < 0 || sourceX >= info.width || sourceY < 0 || sourceY >= info.height) continue;
      const source = (sourceY * info.width + sourceX) * 4;
      const target = (y * info.width + x) * 4;
      data.copy(output, target, source, source + 4);
    }
  }

  return sharp(output, {
    raw: { width: info.width, height: info.height, channels: 4 },
  }).png({ compressionLevel: 9, palette: false }).toBuffer();
}

async function renderAirborneFallback(source, info, bounds, clipKey, index, count) {
  const output = Buffer.alloc(source.length);
  const spriteHeight = Math.max(1, bounds.bottom - bounds.top + 1);
  const progress = count <= 1 ? 1 : (index - 1) / (count - 1);
  const ascent = clipKey === "jump" ? progress : 1 - progress;
  const offsetY = -Math.round(spriteHeight * 0.07 * ascent);
  const legTop = Math.round(bounds.top + spriteHeight * 0.6);
  const tuck = clipKey === "jump"
    ? Math.round(Math.sin(progress * Math.PI) * spriteHeight * 0.035)
    : Math.round((1 - progress) * spriteHeight * 0.02);

  for (let y = bounds.top; y <= bounds.bottom; y += 1) {
    for (let x = bounds.left; x <= bounds.right; x += 1) {
      const sourceIndex = (y * info.width + x) * 4;
      if (source[sourceIndex + 3] < 8) continue;
      const lowerBodyOffset = y >= legTop ? -tuck : 0;
      writePixel(source, output, sourceIndex, x, y + offsetY + lowerBodyOffset, info.width, info.height);
    }
  }
  return sharp(output, {
    raw: { width: info.width, height: info.height, channels: 4 },
  }).png({ compressionLevel: 9, palette: false }).toBuffer();
}

async function renderLayeredLocomotion(source, info, bounds, phase, direction, clipKey = "walk") {
  const output = Buffer.alloc(source.length);
  const width = info.width;
  const height = info.height;
  const spriteWidth = Math.max(1, bounds.right - bounds.left + 1);
  const spriteHeight = Math.max(1, bounds.bottom - bounds.top + 1);
  const cutY = Math.round(bounds.top + spriteHeight * 0.61);
  const centerX = findLowerBodyCenter(source, width, bounds, cutY);
  const isSide = direction === "left" || direction === "right";
  const isDiagonal = direction.includes("_");
  const isRun = clipKey === "run";
  const isClimb = clipKey === "climb";
  const facingX = direction.includes("left") ? -1 : direction.includes("right") ? 1 : 0;
  const facingY = direction.startsWith("down") ? 1 : direction.startsWith("up") ? -1 : 0;
  // En una vista diagonal reflejada, el lado anatómico cambia de lado en la
  // pantalla. Sin este signo, el maestro sí se refleja pero la fase de piernas
  // y brazos queda intercambiada entre izquierda y derecha.
  const anatomicalPhaseSign = isDiagonal ? facingX : 1;
  // En perfil las dos piernas están superpuestas en el maestro. Su eje real
  // debe salir de los píxeles que tocan el suelo, no del centro del personaje:
  // una cola o arma baja desplaza ese centro y deja una pierna de 1–2 píxeles.
  const legCenterX = isSide
    ? findGroundedFootCenter(source, width, height, bounds, cutY)
    : centerX;
  const legHalfWidth = isSide
    ? Math.max(4, spriteWidth * 0.29)
    : spriteWidth * 0.46;
  const gait = Math.cos(phase);
  const bobAmplitude = Math.max(
    1,
    Math.round(spriteHeight * (isRun
      ? (isDiagonal ? 0.028 : 0.024)
      : isClimb
        ? 0.014
        : (isDiagonal ? 0.016 : 0.012))),
  );
  const bob = -Math.round(Math.abs(Math.sin(phase)) * bobAmplitude);
  // El seno decide qué pie se despega. En una diagonal reflejada también debe
  // cambiar de lado; de lo contrario la rotación se refleja pero el contacto
  // con el suelo conserva la fase de pantalla y el ciclo izquierdo se vuelve
  // la reproducción temporal inversa del derecho.
  const liftPhase = Math.sin(phase) * anatomicalPhaseSign;
  const liftAmplitude = Math.max(
    1,
    Math.round(spriteHeight * (isRun
      ? (isSide ? 0.075 : isDiagonal ? 0.048 : 0.044)
      : isClimb
        ? (isSide ? 0.055 : 0.045)
        : (isSide ? 0.035 : isDiagonal ? 0.018 : 0.018))),
  );
  const rightLift = Math.round(Math.max(0, liftPhase) * liftAmplitude);
  const leftLift = Math.round(Math.max(0, -liftPhase) * liftAmplitude);
  const hipGap = isSide ? 1 : Math.max(1, Math.round(spriteWidth * 0.095));
  const sideLegOverlap = isSide ? Math.max(1, Math.round(spriteWidth * 0.075)) : 0;
  const legSource = (x, y) => y >= cutY && Math.abs(x - legCenterX) <= legHalfWidth;
  const legs = [
    {
      side: 1,
      predicate: (x, y) => legSource(x, y) && x <= legCenterX + sideLegOverlap,
      pivot: { x: legCenterX - hipGap, y: cutY + 1 },
      lift: leftLift,
    },
    {
      side: -1,
      predicate: (x, y) => legSource(x, y) && x > legCenterX - sideLegOverlap,
      pivot: { x: legCenterX + hipGap, y: cutY + 1 },
      lift: rightLift,
    },
  ].map((leg) => {
    const stride = gait * leg.side * anatomicalPhaseSign;
    const isFar = isSide && leg.side === facingX;
    // Perfil: desplazamiento horizontal claro. Frente/espalda: profundidad
    // mediante longitud aparente. Diagonal: combina ambos ejes sin que las dos
    // piernas viajen juntas.
    const angleDegrees = isSide
      ? (isRun ? 21 : isClimb ? 8 : 12)
      : isDiagonal
        ? (isRun ? 5 : isClimb ? 6 : 2)
        : 0;
    const depth = isSide ? (isFar ? -1 : 1) : stride * facingY;
    return {
      ...leg,
      // En perfil la pierna lejana se dibuja primero y ligeramente más oscura.
      // Esto mantiene legibles ambas piernas incluso cuando se cruzan.
      depth,
      angle: (-facingX * stride * angleDegrees * Math.PI) / 180,
      scaleY: 1 + stride * facingY * (isSide
        ? 0
        : isDiagonal
          ? (isRun ? 0.035 : 0.018)
          : isClimb
            ? 0.075
            : (isRun ? 0.095 : 0.065)),
      brightness: isFar ? 0.72 : isDiagonal && depth < 0 ? 0.93 : 1,
    };
  }).sort((left, right) => left.depth - right.depth);

  for (const leg of legs) {
    drawRigidLayer({
      source,
      target: output,
      width,
      height,
      predicate: leg.predicate,
      sourcePivot: leg.pivot,
      destinationPivot: { x: leg.pivot.x, y: leg.pivot.y + bob - leg.lift },
      angle: leg.angle,
      scaleY: leg.scaleY,
      brightness: leg.brightness,
    });
  }

  const shoulderY = Math.round(bounds.top + spriteHeight * 0.43);
  const armBottom = Math.round(bounds.top + spriteHeight * 0.72);
  const arms = buildArmLayers({
    source,
    width,
    height,
    bounds,
    centerX,
    shoulderY,
    armBottom,
    spriteWidth,
    spriteHeight,
    isSide,
    facingX,
  }).map((arm) => {
    // El brazo del mismo lado viaja en oposición a su pierna.
    const stride = -gait * arm.side * anatomicalPhaseSign;
    const angleDegrees = isSide
      ? (isRun ? 14 : isClimb ? 9 : 7)
      : isDiagonal
        ? (isRun ? 16 : isClimb ? 12 : 8)
        : 0;
    const armSwingAmplitude = Math.max(
      1,
      Math.round(spriteHeight * (isRun
        ? (isDiagonal ? 0.035 : 0.027)
        : isClimb
          ? 0.045
          : (isDiagonal ? 0.018 : 0.012))),
    );
    return {
      ...arm,
      depth: stride * facingY,
      angle: (-facingX * stride * angleDegrees * Math.PI) / 180,
      scaleY: 1 + stride * facingY * (isSide
        ? 0
        : isDiagonal
          ? (isRun ? 0.095 : 0.055)
          : isClimb
            ? 0.11
            : (isRun ? 0.085 : 0.045)),
      offsetY: Math.round(stride * facingY * armSwingAmplitude),
    };
  }).sort((left, right) => left.depth - right.depth);

  for (const arm of arms) {
    drawRigidLayer({
      source,
      target: output,
      width,
      height,
      predicate: (x, y) => arm.mask[y * width + x] === 1,
      sourcePivot: arm.pivot,
      destinationPivot: { x: arm.pivot.x, y: arm.pivot.y + bob + arm.offsetY },
      angle: arm.angle,
      scaleY: arm.scaleY,
    });
  }

  // La capa central permanece rígida. El solape en caderas y hombros oculta
  // las uniones sin estirar chaqueta, pelo, cara o accesorios.
  const legJoinRows = isDiagonal
    ? Math.max(5, Math.round(spriteHeight * 0.075))
    : 3;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const sourceIndex = (y * width + x) * 4;
      if (source[sourceIndex + 3] < 8) continue;
      const removeOriginalLeg = y > cutY + legJoinRows && legSource(x, y);
      // Se elimina exactamente la misma pieza que se anima. Antes se usaba
      // una franja geométrica distinta y quedaban pixeles del brazo original
      // inmóviles, visualmente iguales a un segundo brazo.
      const removeOriginalArm = y > shoulderY && arms.some((arm) => arm.mask[y * width + x] === 1);
      if (removeOriginalLeg || removeOriginalArm) continue;
      const forwardLead = isRun && (isSide || isDiagonal)
        ? facingX * Math.max(1, Math.round(spriteWidth * 0.025))
        : 0;
      writePixel(source, output, sourceIndex, x + forwardLead, y + bob, width, height);
    }
  }

  return sharp(output, {
    raw: { width, height, channels: 4 },
  }).png({ compressionLevel: 9, palette: false }).toBuffer();
}

function buildArmLayers({
  source,
  width,
  height,
  bounds,
  centerX,
  shoulderY,
  armBottom,
  spriteWidth,
  spriteHeight,
  isSide,
  facingX,
}) {
  const handSearchTop = Math.round(shoulderY + (armBottom - shoulderY) * 0.42);
  const handSearchBottom = Math.min(bounds.bottom, armBottom + Math.max(2, Math.round(spriteHeight * 0.055)));
  const warmPixels = new Uint8Array(width * height);
  for (let y = handSearchTop; y <= handSearchBottom; y += 1) {
    for (let x = bounds.left; x <= bounds.right; x += 1) {
      const index = (y * width + x) * 4;
      const red = source[index];
      const green = source[index + 1];
      const blue = source[index + 2];
      const alpha = source[index + 3];
      // La piel generada conserva una paleta cálida. La relación azul/verde
      // descarta colas rojas o amarillas sin depender de un tono concreto.
      if (alpha >= 8 && red > 165 && green > 85 && blue > 45 && red >= green && blue > green * 0.36) {
        warmPixels[y * width + x] = 1;
      }
    }
  }

  const handCandidates = connectedPixelGroups(warmPixels, width, height)
    .filter((group) => group.pixels.length >= 3)
    .map((group) => ({
      ...group,
      centerX: group.pixels.reduce((sum, pixel) => sum + pixel.x, 0) / group.pixels.length,
      centerY: group.pixels.reduce((sum, pixel) => sum + pixel.y, 0) / group.pixels.length,
      bottom: Math.max(...group.pixels.map((pixel) => pixel.y)),
    }))
    .filter((group) => group.bottom >= armBottom - Math.max(2, Math.round(spriteHeight * 0.07)))
    .sort((left, right) => right.centerY - left.centerY || right.pixels.length - left.pixels.length);

  const selectedHands = [];
  if (isSide) {
    if (handCandidates.length) selectedHands.push(handCandidates[0]);
  } else {
    const leftHand = handCandidates.find((hand) => hand.centerX < centerX - 1);
    const rightHand = handCandidates.find((hand) => hand.centerX > centerX + 1);
    if (leftHand) selectedHands.push(leftHand);
    if (rightHand) selectedHands.push(rightHand);
  }

  const expectedCenters = isSide
    ? [centerX + facingX * Math.max(1, spriteWidth * 0.075)]
    : [centerX - spriteWidth * 0.31, centerX + spriteWidth * 0.31];
  const desiredCount = isSide ? 1 : 2;
  while (selectedHands.length < desiredCount) {
    const expected = expectedCenters[selectedHands.length];
    selectedHands.push({ centerX: expected, centerY: armBottom, bottom: armBottom, pixels: [] });
  }

  // En perfil la manga ocupa casi todo el canto visible del torso. Una máscara
  // más estrecha deja su borde posterior quieto y vuelve a parecer otro brazo.
  const halfWidth = isSide
    ? Math.max(3, Math.round(spriteHeight * 0.07))
    : Math.max(2, Math.round(spriteHeight * 0.055));
  return selectedHands.slice(0, desiredCount).map((hand, index) => {
    const side = isSide ? (facingX || 1) : hand.centerX < centerX ? 1 : -1;
    const shoulderX = isSide
      ? centerX + facingX * Math.max(1, spriteWidth * 0.06)
      : centerX - side * spriteWidth * 0.29;
    const mask = new Uint8Array(width * height);
    const bottom = Math.min(handSearchBottom, Math.max(armBottom, hand.bottom));
    for (let y = shoulderY; y <= bottom; y += 1) {
      const progress = (y - shoulderY) / Math.max(1, bottom - shoulderY);
      const lineX = shoulderX + (hand.centerX - shoulderX) * progress;
      for (let x = Math.floor(lineX - halfWidth); x <= Math.ceil(lineX + halfWidth); x += 1) {
        if (x < 0 || x >= width) continue;
        if (source[(y * width + x) * 4 + 3] < 8) continue;
        mask[y * width + x] = 1;
      }
    }
    return {
      side,
      mask,
      pivot: { x: shoulderX, y: shoulderY + 1 },
      index,
    };
  });
}

function connectedPixelGroups(mask, width, height) {
  const visited = new Uint8Array(mask.length);
  const groups = [];
  for (let start = 0; start < mask.length; start += 1) {
    if (!mask[start] || visited[start]) continue;
    const queue = [start];
    const pixels = [];
    visited[start] = 1;
    while (queue.length) {
      const current = queue.pop();
      const x = current % width;
      const y = Math.floor(current / width);
      pixels.push({ x, y });
      for (let offsetY = -1; offsetY <= 1; offsetY += 1) {
        for (let offsetX = -1; offsetX <= 1; offsetX += 1) {
          if (!offsetX && !offsetY) continue;
          const nextX = x + offsetX;
          const nextY = y + offsetY;
          if (nextX < 0 || nextX >= width || nextY < 0 || nextY >= height) continue;
          const next = nextY * width + nextX;
          if (!mask[next] || visited[next]) continue;
          visited[next] = 1;
          queue.push(next);
        }
      }
    }
    groups.push({ pixels });
  }
  return groups;
}

function drawRigidLayer({
  source,
  target,
  width,
  height,
  predicate,
  sourcePivot,
  destinationPivot,
  angle,
  scaleY = 1,
  brightness = 1,
}) {
  const cosine = Math.cos(angle);
  const sine = Math.sin(angle);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const destinationX = x - destinationPivot.x;
      const destinationY = y - destinationPivot.y;
      const sourceX = Math.round(sourcePivot.x + cosine * destinationX + sine * destinationY);
      const sourceY = Math.round(sourcePivot.y + (-sine * destinationX + cosine * destinationY) / scaleY);
      if (sourceX < 0 || sourceX >= width || sourceY < 0 || sourceY >= height) continue;
      if (!predicate(sourceX, sourceY)) continue;
      const sourceIndex = (sourceY * width + sourceX) * 4;
      if (source[sourceIndex + 3] < 8) continue;
      const targetIndex = (y * width + x) * 4;
      if (brightness === 1) {
        source.copy(target, targetIndex, sourceIndex, sourceIndex + 4);
      } else {
        target[targetIndex] = Math.round(source[sourceIndex] * brightness);
        target[targetIndex + 1] = Math.round(source[sourceIndex + 1] * brightness);
        target[targetIndex + 2] = Math.round(source[sourceIndex + 2] * brightness);
        target[targetIndex + 3] = source[sourceIndex + 3];
      }
    }
  }
}

function findGroundedFootCenter(data, width, height, bounds, cutY) {
  const spriteHeight = bounds.bottom - bounds.top + 1;
  const bandTop = Math.max(cutY, bounds.bottom - Math.max(3, Math.round(spriteHeight * 0.09)));
  const grounded = new Uint8Array(width * height);
  for (let y = bandTop; y <= bounds.bottom; y += 1) {
    for (let x = bounds.left; x <= bounds.right; x += 1) {
      if (data[(y * width + x) * 4 + 3] >= 8) grounded[y * width + x] = 1;
    }
  }
  const feet = connectedPixelGroups(grounded, width, height)
    .sort((left, right) => right.pixels.length - left.pixels.length)[0];
  if (!feet?.pixels.length) return findLowerBodyCenter(data, width, bounds, cutY);
  return feet.pixels.reduce((sum, pixel) => sum + pixel.x, 0) / feet.pixels.length;
}

function findLowerBodyCenter(data, width, bounds, cutY) {
  const samples = [];
  const spriteHeight = bounds.bottom - bounds.top + 1;
  const lowerBandTop = Math.max(cutY, bounds.bottom - Math.max(3, Math.round(spriteHeight * 0.28)));
  for (let y = lowerBandTop; y <= bounds.bottom; y += 1) {
    for (let x = bounds.left; x <= bounds.right; x += 1) {
      if (data[(y * width + x) * 4 + 3] < 8) continue;
      samples.push(x);
    }
  }
  if (!samples.length) return (bounds.left + bounds.right) / 2;
  samples.sort((left, right) => left - right);
  const middle = Math.floor(samples.length / 2);
  return samples.length % 2 ? samples[middle] : (samples[middle - 1] + samples[middle]) / 2;
}

function writePixel(source, target, sourceIndex, x, y, width, height) {
  const destinationX = Math.round(x);
  const destinationY = Math.round(y);
  if (destinationX < 0 || destinationX >= width || destinationY < 0 || destinationY >= height) return;
  const targetIndex = (destinationY * width + destinationX) * 4;
  source.copy(target, targetIndex, sourceIndex, sourceIndex + 4);
}

export async function hasStableMotionTopology(master, candidate, { accessoryAware = false } = {}) {
  const [reference, animated] = await Promise.all([
    alphaProfile(master),
    alphaProfile(candidate),
  ]);
  if (!animated.pixelCount) return false;
  if (accessoryAware) {
    const pixelRatio = animated.pixelCount / Math.max(1, reference.pixelCount);
    const allowedExtraParts = Math.max(3, Math.ceil(reference.significantParts * 0.5));
    if (pixelRatio < 0.72 || pixelRatio > 1.2) return false;
    if (animated.significantParts > reference.significantParts + allowedExtraParts) return false;
    return animated.largestRatio >= Math.max(0.52, reference.largestRatio - 0.24);
  }
  if (animated.largestRatio < Math.max(0.9, reference.largestRatio - 0.08)) return false;
  return animated.significantParts <= reference.significantParts || animated.largestRatio >= 0.97;
}

/**
 * Valida que al menos la masa corporal principal conecte la parte superior con
 * los pies. Accesorios separados (cola, cabello largo, alas) pueden formar
 * componentes grandes propios y no deben confundirse con una pierna cortada.
 */
export async function hasVerticalBodyContinuity(candidate) {
  const { data, info } = await sharp(candidate).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const bounds = findOpaqueBounds(data, info.width, info.height);
  if (!bounds) return false;
  const spriteHeight = Math.max(1, bounds.bottom - bounds.top + 1);
  const upperLimit = bounds.top + spriteHeight * 0.58;
  const lowerLimit = bounds.top + spriteHeight * 0.86;
  const visited = new Uint8Array(info.width * info.height);
  let opaque = 0;
  const components = [];
  for (let start = 0; start < visited.length; start += 1) {
    if (visited[start] || data[start * 4 + 3] < 8) continue;
    const queue = [start];
    visited[start] = 1;
    let size = 0;
    let minimumY = info.height;
    let maximumY = -1;
    while (queue.length) {
      const current = queue.pop();
      const x = current % info.width;
      const y = Math.floor(current / info.width);
      size += 1;
      opaque += 1;
      minimumY = Math.min(minimumY, y);
      maximumY = Math.max(maximumY, y);
      for (let offsetY = -1; offsetY <= 1; offsetY += 1) {
        for (let offsetX = -1; offsetX <= 1; offsetX += 1) {
          if (!offsetX && !offsetY) continue;
          const nextX = x + offsetX;
          const nextY = y + offsetY;
          if (nextX < 0 || nextX >= info.width || nextY < 0 || nextY >= info.height) continue;
          const next = nextY * info.width + nextX;
          if (!visited[next] && data[next * 4 + 3] >= 8) {
            visited[next] = 1;
            queue.push(next);
          }
        }
      }
    }
    components.push({ size, minimumY, maximumY });
  }
  return components.some((component) =>
    component.minimumY <= upperLimit
    && component.maximumY >= lowerLimit
    && component.size >= opaque * 0.24
  );
}

export function calculateDisplacement({ xRatio, yRatio, phase, isWalk }) {
  let dx = 0;
  let dy = 0;
  if (!isWalk) {
    const breath = Math.sin(phase);
    const anchorAtFeet = 1 - smoothstep(0.48, 0.98, yRatio);
    dy -= breath * 1.25 * anchorAtFeet;
    dx += breath * 0.28 * xRatio * smoothstep(0.05, 0.45, 1 - yRatio);
    return { dx, dy };
  }

  const gait = Math.cos(phase);
  const liftPhase = Math.sin(phase);
  const side = Math.tanh(xRatio * 5);
  const bodyAnchor = 1 - smoothstep(0.68, 1, yRatio);
  dy -= Math.abs(liftPhase) * 1.25 * bodyAnchor;

  const legAmount = smoothstep(0.58, 0.98, yRatio);
  dx += gait * side * 3.2 * legAmount;
  dy -= Math.max(0, liftPhase * side) * 2.2 * legAmount;

  const armOuter = smoothstep(0.18, 0.62, Math.abs(xRatio));
  const armVertical = smoothstep(0.2, 0.36, yRatio) * (1 - smoothstep(0.62, 0.76, yRatio));
  dx -= gait * side * 2.4 * armOuter * armVertical;
  dy += liftPhase * side * 0.5 * armOuter * armVertical;
  return { dx, dy };
}

function findOpaqueBounds(data, width, height) {
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
  return right >= left ? { left, right, top, bottom } : null;
}

async function alphaProfile(buffer) {
  const { data, info } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const visited = new Uint8Array(info.width * info.height);
  const sizes = [];
  for (let start = 0; start < visited.length; start += 1) {
    if (visited[start] || data[start * 4 + 3] < 8) continue;
    const queue = [start];
    visited[start] = 1;
    let size = 0;
    while (queue.length) {
      const current = queue.pop();
      size += 1;
      const x = current % info.width;
      const y = Math.floor(current / info.width);
      for (let offsetY = -1; offsetY <= 1; offsetY += 1) {
        for (let offsetX = -1; offsetX <= 1; offsetX += 1) {
          if (!offsetX && !offsetY) continue;
          const nextX = x + offsetX;
          const nextY = y + offsetY;
          if (nextX < 0 || nextX >= info.width || nextY < 0 || nextY >= info.height) continue;
          const next = nextY * info.width + nextX;
          if (!visited[next] && data[next * 4 + 3] >= 8) {
            visited[next] = 1;
            queue.push(next);
          }
        }
      }
    }
    if (size >= 4) sizes.push(size);
  }
  sizes.sort((a, b) => b - a);
  const pixelCount = sizes.reduce((sum, size) => sum + size, 0);
  return {
    pixelCount,
    significantParts: sizes.length,
    largestRatio: pixelCount ? sizes[0] / pixelCount : 0,
  };
}

function smoothstep(edge0, edge1, value) {
  const t = Math.max(0, Math.min(1, (value - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
}
