import test from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import {
  animateCanonicalCell,
  hasStableMotionTopology,
  hasVerticalBodyContinuity,
} from "../src/lib/motion.js";

test("anima el maestro sin inventar colores ni cambiar el tamano", async () => {
  const master = await sharp({
    create: { width: 32, height: 32, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 12, height: 24, channels: 4, background: "#ff3366" } }, left: 10, top: 4 },
  ]).png().toBuffer();
  const frame = { frameIndex: 2, frameCount: 4, clip: { key: "walk" } };
  const animated = await animateCanonicalCell(master, frame);
  const [masterMeta, animatedMeta] = await Promise.all([sharp(master).metadata(), sharp(animated).metadata()]);
  assert.equal(animatedMeta.width, masterMeta.width);
  assert.equal(animatedMeta.height, masterMeta.height);
  assert.notDeepEqual(animated, master);
  const colors = await sharp(animated).ensureAlpha().raw().toBuffer();
  for (let index = 0; index < colors.length; index += 4) {
    if (colors[index + 3] === 0) continue;
    assert.deepEqual([...colors.subarray(index, index + 3)], [255, 51, 102]);
  }
});

test("la carrera no es solamente la caminata reproducida más rápido", async () => {
  const master = await sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 14, height: 18, channels: 4, background: "#eeeeee" } }, left: 17, top: 7 },
    { input: { create: { width: 6, height: 20, channels: 4, background: "#cc6666" } }, left: 17, top: 23 },
    { input: { create: { width: 6, height: 20, channels: 4, background: "#6666cc" } }, left: 25, top: 23 },
  ]).png().toBuffer();
  const common = { frameIndex: 2, frameCount: 8, direction: { key: "right" } };
  const walk = await animateCanonicalCell(master, { ...common, clip: { key: "walk" } });
  const run = await animateCanonicalCell(master, { ...common, clip: { key: "run" } });
  assert.notDeepEqual(run, walk);
  assert.equal(await hasVerticalBodyContinuity(run), true);
});

test("rechaza un frame partido en dos masas grandes", async () => {
  const master = await sharp({
    create: { width: 32, height: 32, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 12, height: 24, channels: 4, background: "#ff3366" } }, left: 10, top: 4 },
  ]).png().toBuffer();
  const broken = await sharp({
    create: { width: 32, height: 32, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 12, height: 10, channels: 4, background: "#ff3366" } }, left: 10, top: 3 },
    { input: { create: { width: 12, height: 10, channels: 4, background: "#ff3366" } }, left: 10, top: 19 },
  ]).png().toBuffer();
  assert.equal(await hasStableMotionTopology(master, broken), false);
  assert.equal(await hasVerticalBodyContinuity(master), true);
  assert.equal(await hasVerticalBodyContinuity(broken), false);
});

test("mantiene una silueta conectada en todas las fases de un ciclo de ocho frames", async () => {
  const master = await sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 14, height: 18, channels: 4, background: "#ff3366" } }, left: 17, top: 8 },
    { input: { create: { width: 6, height: 19, channels: 4, background: "#ff3366" } }, left: 17, top: 24 },
    { input: { create: { width: 6, height: 19, channels: 4, background: "#ff3366" } }, left: 25, top: 24 },
  ]).png().toBuffer();
  for (let frameIndex = 1; frameIndex <= 8; frameIndex += 1) {
    const animated = await animateCanonicalCell(master, {
      frameIndex,
      frameCount: 8,
      clip: { key: "walk" },
    });
    const { data, info } = await sharp(animated).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    assert.equal(countOpaqueComponents(data, info.width, info.height), 1, `frame ${frameIndex}`);
  }
});

test("mantiene cabeza y torso pixel-identicos durante la caminata", async () => {
  const master = await sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 18, height: 12, channels: 4, background: "#ff6633" } }, left: 15, top: 5 },
    { input: { create: { width: 16, height: 15, channels: 4, background: "#3366ff" } }, left: 16, top: 17 },
    { input: { create: { width: 6, height: 13, channels: 4, background: "#ffcc99" } }, left: 17, top: 31 },
    { input: { create: { width: 6, height: 13, channels: 4, background: "#ffcc99" } }, left: 25, top: 31 },
  ]).png().toBuffer();
  const animated = await animateCanonicalCell(master, {
    frameIndex: 2,
    frameCount: 8,
    clip: { key: "walk" },
    direction: { key: "down" },
  });
  const [source, target] = await Promise.all([
    sharp(master).ensureAlpha().raw().toBuffer(),
    sharp(animated).ensureAlpha().raw().toBuffer(),
  ]);
  const width = 48;
  const bob = -1;
  for (let y = 5; y <= 29; y += 1) {
    const sourceStart = (y * width) * 4;
    const targetStart = ((y + bob) * width) * 4;
    assert.deepEqual(
      target.subarray(targetStart, targetStart + width * 4),
      source.subarray(sourceStart, sourceStart + width * 4),
      `fila superior ${y}`,
    );
  }
});

test("el perfil lateral divide la silueta existente en vez de duplicarla", async () => {
  const master = await sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 16, height: 20, channels: 4, background: "#3366ff" } }, left: 16, top: 7 },
    { input: { create: { width: 8, height: 18, channels: 4, background: "#ffcc99" } }, left: 20, top: 26 },
  ]).png().toBuffer();
  const animated = await animateCanonicalCell(master, {
    frameIndex: 1,
    frameCount: 8,
    clip: { key: "walk" },
    direction: { key: "left" },
  });
  const [source, target] = await Promise.all([
    sharp(master).ensureAlpha().raw().toBuffer(),
    sharp(animated).ensureAlpha().raw().toBuffer(),
  ]);
  assert.ok(countOpaquePixels(target) <= countOpaquePixels(source) * 1.15);
});

test("las dos piernas laterales conservan grosor y la lejana queda sombreada", async () => {
  const master = await sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 8, height: 24, channels: 4, background: "#333333" } }, left: 20, top: 5 },
    { input: { create: { width: 12, height: 18, channels: 4, background: "#775533" } }, left: 16, top: 26 },
    // Accesorio bajo que antes desplazaba el eje usado para cortar las piernas.
    { input: { create: { width: 13, height: 5, channels: 4, background: "#33cc66" } }, left: 28, top: 31 },
  ]).png().toBuffer();
  const animated = await animateCanonicalCell(master, {
    frameIndex: 1,
    frameCount: 8,
    clip: { key: "walk" },
    direction: { key: "left" },
  });
  const target = await sharp(animated).ensureAlpha().raw().toBuffer();
  const nearBounds = selectedColorBounds(target, 48, 48, [119, 85, 51]);
  const farBounds = selectedColorBounds(target, 48, 48, [86, 61, 37]);
  assert.ok(nearBounds && nearBounds.right - nearBounds.left + 1 >= 4, JSON.stringify(nearBounds));
  assert.ok(farBounds && farBounds.right - farBounds.left + 1 >= 4, JSON.stringify(farBounds));
});

test("frente y espalda alternan profundidad sin abrir las piernas", async () => {
  const master = await createColoredLegMaster();
  const animated = await animateCanonicalCell(master, {
    frameIndex: 1,
    frameCount: 8,
    clip: { key: "walk" },
    direction: { key: "down" },
  });
  const [sourceBounds, targetBounds] = await Promise.all([
    lowerOpaqueBounds(master, 31),
    lowerOpaqueBounds(animated, 31),
  ]);
  assert.equal(targetBounds.left, sourceBounds.left);
  assert.equal(targetBounds.right, sourceBounds.right);
});

test("las diagonales reflejadas conservan la misma fase anatómica", async () => {
  const rightMaster = await createColoredLegMaster();
  const leftMaster = await sharp(rightMaster).flop().png().toBuffer();
  for (let frameIndex = 1; frameIndex <= 8; frameIndex += 1) {
    const frame = { frameIndex, frameCount: 8, clip: { key: "walk" } };
    const [rightAnimated, leftAnimated] = await Promise.all([
      animateCanonicalCell(rightMaster, { ...frame, direction: { key: "down_right" } }),
      animateCanonicalCell(leftMaster, { ...frame, direction: { key: "down_left" } }),
    ]);
    const [rightRaw, mirroredLeftRaw] = await Promise.all([
      sharp(rightAnimated).ensureAlpha().raw().toBuffer(),
      sharp(leftAnimated).flop().ensureAlpha().raw().toBuffer(),
    ]);
    const alphaDifferences = countAlphaMaskDifferences(rightRaw, mirroredLeftRaw);
    assert.ok(alphaDifferences <= 8, JSON.stringify({ frameIndex, alphaDifferences }));
  }
});

test("la pierna diagonal lejana sigue legible y unida bajo la cadera", async () => {
  const master = await createColoredLegMaster();
  for (let frameIndex = 1; frameIndex <= 8; frameIndex += 1) {
    const animated = await animateCanonicalCell(master, {
      frameIndex,
      frameCount: 8,
      clip: { key: "walk" },
      direction: { key: "down_right" },
    });
    const raw = await sharp(animated).ensureAlpha().raw().toBuffer();
    const red = dominantColorProfile(raw, 48, "red");
    const blue = dominantColorProfile(raw, 48, "blue");
    assert.equal(red.components, 1, JSON.stringify({ frameIndex, red }));
    assert.equal(blue.components, 1, JSON.stringify({ frameIndex, blue }));
    assert.ok(red.averageDominant >= 240, JSON.stringify({ frameIndex, red }));
    assert.ok(blue.averageDominant >= 240, JSON.stringify({ frameIndex, blue }));
  }
});

test("la elevación diagonal escala con la resolución del sprite", async () => {
  const smallMaster = await createColoredLegMaster();
  const largeMaster = await sharp(smallMaster).resize({ width: 96, height: 96, kernel: "nearest" }).png().toBuffer();
  const frame = {
    frameIndex: 3,
    frameCount: 8,
    clip: { key: "walk" },
    direction: { key: "down_right" },
  };
  const [smallAnimated, largeAnimated] = await Promise.all([
    animateCanonicalCell(smallMaster, frame),
    animateCanonicalCell(largeMaster, frame),
  ]);
  const [smallSource, smallTarget, largeSource, largeTarget] = await Promise.all([
    sharp(smallMaster).ensureAlpha().raw().toBuffer(),
    sharp(smallAnimated).ensureAlpha().raw().toBuffer(),
    sharp(largeMaster).ensureAlpha().raw().toBuffer(),
    sharp(largeAnimated).ensureAlpha().raw().toBuffer(),
  ]);
  const smallLift = colorCentroidY(smallSource, 48, [51, 102, 255])
    - colorCentroidY(smallTarget, 48, [51, 102, 255]);
  const largeLift = colorCentroidY(largeSource, 96, [51, 102, 255])
    - colorCentroidY(largeTarget, 96, [51, 102, 255]);
  assert.ok(smallLift >= 0.75, JSON.stringify({ smallLift, largeLift }));
  assert.ok(largeLift >= smallLift + 0.75, JSON.stringify({ smallLift, largeLift }));
});

test("los brazos alternan en oposición sin arrastrar accesorios", async () => {
  const master = await sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 8, height: 7, channels: 4, background: "#444444" } }, left: 20, top: 1 },
    { input: { create: { width: 8, height: 22, channels: 4, background: "#444444" } }, left: 20, top: 8 },
    { input: { create: { width: 5, height: 16, channels: 4, background: "#ff3333" } }, left: 15, top: 18 },
    { input: { create: { width: 5, height: 16, channels: 4, background: "#3366ff" } }, left: 28, top: 18 },
    { input: { create: { width: 5, height: 13, channels: 4, background: "#ffcc99" } }, left: 18, top: 30 },
    { input: { create: { width: 5, height: 13, channels: 4, background: "#ffcc99" } }, left: 25, top: 30 },
    { input: { create: { width: 5, height: 12, channels: 4, background: "#33cc66" } }, left: 5, top: 20 },
  ]).png().toBuffer();
  const animated = await animateCanonicalCell(master, {
    frameIndex: 1,
    frameCount: 8,
    clip: { key: "walk" },
    direction: { key: "down" },
  });
  const [source, target] = await Promise.all([
    sharp(master).ensureAlpha().raw().toBuffer(),
    sharp(animated).ensureAlpha().raw().toBuffer(),
  ]);
  const sourceLeftArmY = colorCentroidY(source, 48, [255, 51, 51]);
  const targetLeftArmY = colorCentroidY(target, 48, [255, 51, 51]);
  const sourceRightArmY = colorCentroidY(source, 48, [51, 102, 255]);
  const targetRightArmY = colorCentroidY(target, 48, [51, 102, 255]);
  assert.ok(targetLeftArmY < sourceLeftArmY, JSON.stringify({ sourceLeftArmY, targetLeftArmY }));
  assert.ok(targetRightArmY > sourceRightArmY, JSON.stringify({ sourceRightArmY, targetRightArmY }));
  assert.equal(colorCentroidY(target, 48, [51, 204, 102]), colorCentroidY(source, 48, [51, 204, 102]));
});

test("el perfil anima un solo brazo completo sin dejar una copia inmóvil", async () => {
  const master = await sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 8, height: 26, channels: 4, background: "#444444" } }, left: 20, top: 6 },
    // Dos colores permiten detectar si una sola manga se parte por el centro.
    { input: { create: { width: 3, height: 15, channels: 4, background: "#ff3333" } }, left: 23, top: 18 },
    { input: { create: { width: 3, height: 15, channels: 4, background: "#3366ff" } }, left: 26, top: 18 },
    { input: { create: { width: 6, height: 4, channels: 4, background: "#ffcc99" } }, left: 23, top: 32 },
    { input: { create: { width: 4, height: 12, channels: 4, background: "#775533" } }, left: 21, top: 32 },
    { input: { create: { width: 4, height: 12, channels: 4, background: "#775533" } }, left: 25, top: 32 },
  ]).png().toBuffer();
  const animated = await animateCanonicalCell(master, {
    frameIndex: 1,
    frameCount: 8,
    clip: { key: "walk" },
    direction: { key: "left" },
  });
  const target = await sharp(animated).ensureAlpha().raw().toBuffer();
  assert.equal(countSelectedColorComponents(target, 48, 48, [[255, 51, 51], [51, 102, 255]]), 1);
});

async function createColoredLegMaster() {
  return sharp({
    create: { width: 48, height: 48, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite([
    { input: { create: { width: 16, height: 22, channels: 4, background: "#33cc99" } }, left: 16, top: 6 },
    { input: { create: { width: 6, height: 18, channels: 4, background: "#ff3333" } }, left: 17, top: 26 },
    { input: { create: { width: 6, height: 18, channels: 4, background: "#3366ff" } }, left: 25, top: 26 },
  ]).png().toBuffer();
}

async function lowerOpaqueBounds(buffer, fromY) {
  const { data, info } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let left = info.width;
  let right = -1;
  for (let y = fromY; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      if (data[(y * info.width + x) * 4 + 3] < 8) continue;
      left = Math.min(left, x);
      right = Math.max(right, x);
    }
  }
  return { left, right };
}

function colorCentroidX(data, width, color, fromY) {
  let sum = 0;
  let count = 0;
  for (let index = 0; index < data.length; index += 4) {
    const pixel = index / 4;
    if (Math.floor(pixel / width) < fromY) continue;
    if (data[index] !== color[0] || data[index + 1] !== color[1] || data[index + 2] !== color[2] || data[index + 3] < 8) continue;
    sum += pixel % width;
    count += 1;
  }
  return sum / count;
}

function colorCentroidY(data, width, color) {
  let sum = 0;
  let count = 0;
  for (let index = 0; index < data.length; index += 4) {
    if (data[index] !== color[0] || data[index + 1] !== color[1] || data[index + 2] !== color[2] || data[index + 3] < 8) continue;
    sum += Math.floor((index / 4) / width);
    count += 1;
  }
  return sum / count;
}

function countOpaquePixels(data) {
  let count = 0;
  for (let index = 3; index < data.length; index += 4) {
    if (data[index] >= 8) count += 1;
  }
  return count;
}

function countAlphaMaskDifferences(left, right) {
  let differences = 0;
  for (let index = 3; index < left.length; index += 4) {
    if ((left[index] >= 8) !== (right[index] >= 8)) differences += 1;
  }
  return differences;
}

function countOpaqueComponents(data, width, height) {
  const visited = new Uint8Array(width * height);
  let count = 0;
  for (let start = 0; start < width * height; start += 1) {
    if (visited[start] || data[start * 4 + 3] < 8) continue;
    const queue = [start];
    visited[start] = 1;
    let size = 0;
    while (queue.length) {
      const current = queue.pop();
      size += 1;
      const x = current % width;
      const y = Math.floor(current / width);
      for (let offsetY = -1; offsetY <= 1; offsetY += 1) {
        for (let offsetX = -1; offsetX <= 1; offsetX += 1) {
          if (!offsetX && !offsetY) continue;
          const nextX = x + offsetX;
          const nextY = y + offsetY;
          if (nextX < 0 || nextX >= width || nextY < 0 || nextY >= height) continue;
          const next = nextY * width + nextX;
          if (!visited[next] && data[next * 4 + 3] >= 8) {
            visited[next] = 1;
            queue.push(next);
          }
        }
      }
    }
    if (size >= 4) count += 1;
  }
  return count;
}

function countSelectedColorComponents(data, width, height, colors) {
  const selected = new Uint8Array(width * height);
  for (let pixel = 0; pixel < selected.length; pixel += 1) {
    const index = pixel * 4;
    if (data[index + 3] < 8) continue;
    if (colors.some((color) => data[index] === color[0] && data[index + 1] === color[1] && data[index + 2] === color[2])) {
      selected[pixel] = 1;
    }
  }
  const visited = new Uint8Array(selected.length);
  let components = 0;
  for (let start = 0; start < selected.length; start += 1) {
    if (!selected[start] || visited[start]) continue;
    components += 1;
    const queue = [start];
    visited[start] = 1;
    while (queue.length) {
      const current = queue.pop();
      const x = current % width;
      const y = Math.floor(current / width);
      for (let offsetY = -1; offsetY <= 1; offsetY += 1) {
        for (let offsetX = -1; offsetX <= 1; offsetX += 1) {
          if (!offsetX && !offsetY) continue;
          const nextX = x + offsetX;
          const nextY = y + offsetY;
          if (nextX < 0 || nextX >= width || nextY < 0 || nextY >= height) continue;
          const next = nextY * width + nextX;
          if (!selected[next] || visited[next]) continue;
          visited[next] = 1;
          queue.push(next);
        }
      }
    }
  }
  return components;
}

function dominantColorProfile(data, width, dominant) {
  const selected = new Uint8Array(data.length / 4);
  let dominantTotal = 0;
  let count = 0;
  for (let pixel = 0; pixel < selected.length; pixel += 1) {
    const index = pixel * 4;
    const red = data[index];
    const green = data[index + 1];
    const blue = data[index + 2];
    if (data[index + 3] < 8) continue;
    const matches = dominant === "red"
      ? red > green * 2 && red > blue * 2
      : blue > green * 1.5 && blue > red * 1.5;
    if (!matches) continue;
    selected[pixel] = 1;
    dominantTotal += dominant === "red" ? red : blue;
    count += 1;
  }
  const visited = new Uint8Array(selected.length);
  let components = 0;
  for (let start = 0; start < selected.length; start += 1) {
    if (!selected[start] || visited[start]) continue;
    components += 1;
    const queue = [start];
    visited[start] = 1;
    while (queue.length) {
      const current = queue.pop();
      const x = current % width;
      const y = Math.floor(current / width);
      for (let offsetY = -1; offsetY <= 1; offsetY += 1) {
        for (let offsetX = -1; offsetX <= 1; offsetX += 1) {
          if (!offsetX && !offsetY) continue;
          const nextX = x + offsetX;
          const nextY = y + offsetY;
          if (nextX < 0 || nextX >= width || nextY < 0 || nextY >= selected.length / width) continue;
          const next = nextY * width + nextX;
          if (!selected[next] || visited[next]) continue;
          visited[next] = 1;
          queue.push(next);
        }
      }
    }
  }
  return {
    count,
    components,
    averageDominant: dominantTotal / Math.max(1, count),
  };
}

function selectedColorBounds(data, width, height, color) {
  const bounds = { left: width, right: -1, top: height, bottom: -1 };
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const index = (y * width + x) * 4;
      if (data[index + 3] < 8) continue;
      if (data[index] !== color[0] || data[index + 1] !== color[1] || data[index + 2] !== color[2]) continue;
      bounds.left = Math.min(bounds.left, x);
      bounds.right = Math.max(bounds.right, x);
      bounds.top = Math.min(bounds.top, y);
      bounds.bottom = Math.max(bounds.bottom, y);
    }
  }
  return bounds.right >= bounds.left ? bounds : null;
}
