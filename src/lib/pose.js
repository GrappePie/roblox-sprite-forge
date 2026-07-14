import sharp from "sharp";

/**
 * Crea un mapa de pose tipo OpenPose para condicionar un frame sin introducir
 * ropa, color o accesorios ajenos al avatar.
 */
export async function createPoseGuide(frame, { renderResolution = 512 } = {}) {
  const size = clampInteger(renderResolution, 256, 1536, 512);
  const geometry = calculatePoseGeometry(frame, size);
  const stroke = Math.max(4, Math.round(size * 0.012));
  const joint = Math.max(3, Math.round(size * 0.007));
  const headRadius = size * 0.045;
  const points = [
    point(geometry.head.x, geometry.head.y + headRadius * 0.25),
    geometry.neck,
    geometry.rightShoulder,
    geometry.rightElbow,
    geometry.rightHand,
    geometry.leftShoulder,
    geometry.leftElbow,
    geometry.leftHand,
    geometry.rightHip,
    geometry.rightKnee,
    geometry.rightFoot,
    geometry.leftHip,
    geometry.leftKnee,
    geometry.leftFoot,
    point(geometry.head.x + headRadius * 0.35, geometry.head.y),
    point(geometry.head.x - headRadius * 0.35, geometry.head.y),
    point(geometry.head.x + headRadius * 0.72, geometry.head.y + headRadius * 0.05),
    point(geometry.head.x - headRadius * 0.72, geometry.head.y + headRadius * 0.05),
  ];
  // Orden y colores usados por el preprocesador OpenPose de ControlNet 1.1.
  const limbs = [
    [1, 2], [1, 5], [2, 3], [3, 4], [5, 6], [6, 7],
    [1, 8], [8, 9], [9, 10], [1, 11], [11, 12], [12, 13],
    [1, 0], [0, 14], [14, 16], [0, 15], [15, 17], [2, 16], [5, 17],
  ];
  const colors = [
    "#FF0000", "#FF5500", "#FFAA00", "#FFFF00", "#AAFF00", "#55FF00",
    "#00FF00", "#00FF55", "#00FFAA", "#00FFFF", "#00AAFF", "#0055FF",
    "#0000FF", "#5500FF", "#AA00FF", "#FF00FF", "#FF00AA", "#FF0055", "#FF0000",
  ];
  const lines = limbs.map(([from, to], index) => {
    const a = points[from];
    const b = points[to];
    return `<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}" stroke="${colors[index]}" stroke-width="${stroke}" stroke-linecap="round" />`;
  }).join("\n");
  const dots = points.map((p, index) =>
    `<circle cx="${p.x}" cy="${p.y}" r="${joint}" fill="${colors[index % colors.length]}" />`
  ).join("\n");
  const svg = `
    <svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" xmlns="http://www.w3.org/2000/svg">
      <rect width="${size}" height="${size}" fill="#000000" />
      ${lines}
      ${dots}
    </svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

export function calculatePoseGeometry(frame, size = 512) {
  const count = Math.max(2, Number(frame?.frameCount) || 4);
  const index = Math.max(1, Number(frame?.frameIndex) || 1);
  const phase = ((index - 1) / count) * Math.PI * 2;
  const progress = count <= 1 ? 1 : (index - 1) / (count - 1);
  const clipKey = frame?.clip?.key ?? "idle";
  const isRun = clipKey === "run";
  const isLocomotion = clipKey === "walk" || isRun;
  const isJump = clipKey === "jump";
  const isFall = clipKey === "fall";
  const isClimb = clipKey === "climb";
  const isAirborne = isJump || isFall;
  const direction = frame?.direction?.key ?? "down";
  const isSide = direction === "left" || direction === "right";
  const isDiagonal = direction.includes("left") || direction.includes("right");
  const facingSign = direction.includes("left") ? -1 : 1;
  const widthScale = isSide ? 0.5 : isDiagonal ? 0.78 : 1;
  const centerX = size * 0.5;
  const groundY = size * 0.86;
  const bodyBob = isLocomotion
    ? -Math.abs(Math.sin(phase)) * size * (isRun ? 0.026 : 0.014)
    : isAirborne
      ? 0
      : isClimb
        ? -Math.abs(Math.sin(phase)) * size * 0.012
        : -Math.sin(phase) * size * 0.009;
  const head = point(centerX + (isSide ? facingSign * size * 0.018 : 0), size * 0.24 + bodyBob);
  const neck = point(centerX, size * 0.36 + bodyBob);
  const hip = point(centerX, size * 0.59 + bodyBob);
  const shoulderHalf = size * 0.115 * widthScale;
  const sideDepth = isSide ? size * 0.022 : 0;
  const leftShoulder = point(centerX - shoulderHalf, neck.y + sideDepth);
  const rightShoulder = point(centerX + shoulderHalf, neck.y - sideDepth);

  const gait = isLocomotion ? Math.cos(phase) : 0;
  const armTravel = isLocomotion ? size * (isRun ? 0.16 : 0.105) * gait * facingSign : 0;
  const legTravel = isLocomotion ? size * (isRun ? 0.205 : 0.135) * gait * facingSign : 0;
  const idleHand = isLocomotion ? 0 : Math.sin(phase) * size * 0.008;
  const airborneArmSpread = isFall ? size * (0.05 + progress * 0.025) : size * 0.035;
  const airborneHandY = isJump
    ? size * (0.56 - progress * 0.16)
    : isFall
      ? size * (0.47 + progress * 0.08)
      : null;
  const climbReach = Math.sin(phase);
  const leftClimbHandY = size * (0.43 + climbReach * 0.09);
  const rightClimbHandY = size * (0.43 - climbReach * 0.09);
  const leftElbow = point(
    leftShoulder.x - armTravel * 0.45 - (isAirborne ? airborneArmSpread * 0.45 : 0),
    isAirborne ? airborneHandY + size * 0.045 : isClimb ? leftClimbHandY + size * 0.045 : size * 0.49 + bodyBob,
  );
  const rightElbow = point(
    rightShoulder.x + armTravel * 0.45 + (isAirborne ? airborneArmSpread * 0.45 : 0),
    isAirborne ? airborneHandY + size * 0.045 : isClimb ? rightClimbHandY + size * 0.045 : size * 0.49 + bodyBob,
  );
  const leftHand = point(
    leftShoulder.x - armTravel + idleHand - (isAirborne ? airborneArmSpread : 0),
    isAirborne ? airborneHandY : isClimb ? leftClimbHandY : size * 0.64 + bodyBob,
  );
  const rightHand = point(
    rightShoulder.x + armTravel - idleHand + (isAirborne ? airborneArmSpread : 0),
    isAirborne ? airborneHandY : isClimb ? rightClimbHandY : size * 0.64 + bodyBob,
  );

  const baseGap = size * 0.055 * widthScale;
  const hipGap = Math.max(size * 0.012, baseGap * 0.52);
  const leftHip = point(centerX - hipGap, hip.y);
  const rightHip = point(centerX + hipGap, hip.y);
  const liftScale = isRun ? 0.115 : 0.065;
  const leftLift = isLocomotion ? Math.max(0, Math.sin(phase)) * size * liftScale : 0;
  const rightLift = isLocomotion ? Math.max(0, -Math.sin(phase)) * size * liftScale : 0;
  const airborneFootY = isJump
    ? size * (0.83 - Math.sin(progress * Math.PI * 0.8) * 0.12)
    : isFall
      ? size * (0.74 + progress * 0.09)
      : null;
  const airborneFootSpread = isJump ? size * 0.035 : size * (0.06 - progress * 0.02);
  const leftClimbFootY = size * (0.79 - climbReach * 0.065);
  const rightClimbFootY = size * (0.79 + climbReach * 0.065);
  const leftFoot = point(
    isAirborne ? centerX - baseGap - airborneFootSpread : centerX - baseGap + legTravel,
    isAirborne ? airborneFootY : isClimb ? leftClimbFootY : groundY - leftLift,
  );
  const rightFoot = point(
    isAirborne ? centerX + baseGap + airborneFootSpread : centerX + baseGap - legTravel,
    isAirborne ? airborneFootY + (isJump ? size * 0.012 : 0) : isClimb ? rightClimbFootY : groundY - rightLift,
  );
  const leftKnee = point(
    (leftHip.x + leftFoot.x) / 2 - (isAirborne ? size * 0.035 : legTravel * 0.12),
    isAirborne
      ? (leftHip.y + leftFoot.y) / 2 - size * 0.025
      : isClimb
        ? (leftHip.y + leftFoot.y) / 2 + size * 0.025
        : size * 0.72 + bodyBob - leftLift * 0.32,
  );
  const rightKnee = point(
    (rightHip.x + rightFoot.x) / 2 + (isAirborne ? size * 0.035 : legTravel * 0.12),
    isAirborne
      ? (rightHip.y + rightFoot.y) / 2 - size * 0.025
      : isClimb
        ? (rightHip.y + rightFoot.y) / 2 + size * 0.025
        : size * 0.72 + bodyBob - rightLift * 0.32,
  );

  return {
    ground: point(centerX, groundY + size * 0.018),
    head, neck, hip, leftHip, rightHip,
    leftShoulder, rightShoulder,
    leftElbow, rightElbow,
    leftHand, rightHand,
    leftKnee, rightKnee,
    leftFoot, rightFoot,
  };
}

function point(x, y) {
  return { x: Math.round(x), y: Math.round(y) };
}

function clampInteger(value, minimum, maximum, fallback) {
  const number = Number(value);
  if (!Number.isInteger(number)) return fallback;
  return Math.max(minimum, Math.min(maximum, number));
}
