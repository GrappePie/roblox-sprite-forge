export const DIRECTIONS = Object.freeze([
  { key: "down", row: 0, label: "frente", instruction: "front view, facing directly toward the viewer" },
  { key: "down_left", row: 1, label: "diagonal inferior izquierda", instruction: "three-quarter front view, facing diagonally toward the viewer and screen-left at a 45 degree angle" },
  { key: "left", row: 2, label: "izquierda", instruction: "strict side profile, facing screen-left" },
  { key: "up_left", row: 3, label: "diagonal superior izquierda", instruction: "three-quarter back view, facing diagonally away from the viewer and screen-left at a 45 degree angle" },
  { key: "up", row: 4, label: "espalda", instruction: "back view, facing directly away from the viewer" },
  { key: "up_right", row: 5, label: "diagonal superior derecha", instruction: "three-quarter back view, facing diagonally away from the viewer and screen-right at a 45 degree angle" },
  { key: "right", row: 6, label: "derecha", instruction: "strict side profile, facing screen-right" },
  { key: "down_right", row: 7, label: "diagonal inferior derecha", instruction: "three-quarter front view, facing diagonally toward the viewer and screen-right at a 45 degree angle" },
]);

export const CLIPS = Object.freeze([
  { key: "idle", rowOffset: 0, label: "idle" },
  { key: "walk", rowOffset: 1, label: "caminar" },
  { key: "run", rowOffset: 2, label: "correr" },
  { key: "jump", rowOffset: 3, label: "saltar" },
  { key: "fall", rowOffset: 4, label: "caer" },
  { key: "climb", rowOffset: 5, label: "escalar" },
  { key: "idle_alt", rowOffset: 6, label: "idle alternativo" },
  { key: "swim_idle", rowOffset: 7, label: "flotar en agua" },
  { key: "swim", rowOffset: 8, label: "nadar a nivel" },
  { key: "swim_up", rowOffset: 9, label: "nadar hacia arriba" },
  { key: "swim_down", rowOffset: 10, label: "nadar hacia abajo" },
]);

const STYLE_INSTRUCTIONS = Object.freeze({
  handheld: "Classic colorful handheld-console RPG overworld sprite: compact chibi proportions, readable silhouette, modest shading and a cohesive limited palette.",
  minimal: "Minimal retro RPG sprite: simple chunky pixel clusters, strongly reduced detail, tiny readable face, flat shading and a strict small palette.",
  detailed: "Detailed 32-bit-era pixel sprite: crisp deliberate pixel clusters, richer controlled shading and recognizable accessories while remaining readable at game size.",
});

export function getClipFrameCounts({
  framesPerAnimation = 4,
  idleFramesPerAnimation = framesPerAnimation,
} = {}) {
  const baseCount = normalizeFrameCount(framesPerAnimation, [2, 4, 6, 8], 4);
  const idleCount = normalizeFrameCount(
    idleFramesPerAnimation,
    [2, 4, 6, 8, 12, 16],
    baseCount,
  );
  return Object.freeze(Object.fromEntries(CLIPS.map((clip) => [
    clip.key,
    clip.key === "idle" || clip.key === "idle_alt" || clip.key === "swim_idle"
      ? idleCount
      : baseCount,
  ])));
}

export function getFramePlan({
  framesPerAnimation = 4,
  idleFramesPerAnimation = framesPerAnimation,
} = {}) {
  const frameCounts = getClipFrameCounts({ framesPerAnimation, idleFramesPerAnimation });
  return DIRECTIONS.flatMap((direction) =>
    CLIPS.flatMap((clip) => {
      const count = frameCounts[clip.key];
      return Array.from({ length: count }, (_, index) => ({
        direction,
        clip,
        frameIndex: index + 1,
        frameCount: count,
        row: direction.row * CLIPS.length + clip.rowOffset,
        column: index,
        key: `${direction.key}_${clip.key}_${index + 1}`,
      }));
    }),
  );
}

export function buildFramePrompt({
  bundle,
  direction,
  clip,
  frameIndex,
  frameCount,
  notes = "",
  chromaHex = "#FF00FF",
  cellSize = 64,
  style = "handheld",
  referenceKind = "roblox",
}) {
  const safeNotes = sanitizeNotes(notes);
  const referenceInstruction = buildReferenceInstruction(referenceKind);
  const secondaryReferenceInstruction = buildSecondaryReferenceInstruction(referenceKind);
  const phaseInstruction = buildPhaseInstruction(clip.key, frameIndex, frameCount);
  const timelineInstruction = buildTimelineInstruction(clip.key, frameIndex, frameCount);
  const swimming = clip.key.startsWith("swim");

  return [
    referenceInstruction,
    secondaryReferenceInstruction,
    `Required view: ${direction.instruction}. Keep this camera direction absolutely fixed across the entire clip.`,
    `Animation clip: ${clip.key}. ${timelineInstruction}`,
    phaseInstruction,
    `Character metadata: ${buildIdentityDescription(bundle)}.`,
    buildAccessoryGuardrails(bundle),
    safeNotes ? `Creator notes: ${safeNotes}.` : "",
    STYLE_INSTRUCTIONS[style] ?? STYLE_INSTRUCTIONS.handheld,
    `The sprite must remain readable after reduction to a ${cellSize} by ${cellSize} pixel cell.`,
    `Preserve the exact same character design in every frame: identical face, hair shape and length, clothing, colors, accessories, body proportions, outline thickness, pixel density and silhouette scale${swimming ? ". Keep the torso center registered across this swimming clip" : " and ground baseline"}.`,
    "Use true pixel-art construction: crisp grid-aligned pixel clusters, hard edges, no anti-aliasing, no vector-smooth curves, no painterly texture and no high-resolution anime illustration style.",
    swimming
      ? "Show the complete body from the highest equipped feature to the soles of both feet. Center the floating body around a stable torso anchor with comfortable empty margin. There is no ground baseline and no foot may touch a floor."
      : "Show the complete body from the highest equipped feature to the soles of both feet. Center it upright with comfortable empty margin and a stable ground baseline.",
    `Fill EVERY background pixel with perfectly uniform solid ${chromaHex}, including all four corners and spaces between limbs.`,
    "No floor, shadow, glow, scenery, text, label, user interface, border, sprite sheet, extra character, duplicate body, alternate outfit or unequipped decorative object.",
  ].filter(Boolean).join("\n");
}

const SPRITE_VIEW_TOKENS = Object.freeze({
  down: "PixelartFSS",
  down_left: "PixelartFSS",
  left: "PixelartLSS",
  up_left: "PixelartBSS",
  up: "PixelartBSS",
  up_right: "PixelartBSS",
  right: "PixelartRSS",
  down_right: "PixelartFSS",
});

export function buildPoseAnimationPrompt({
  bundle,
  direction,
  clip,
  frameIndex,
  frameCount,
  chromaHex = "#FF00FF",
  notes = "",
}) {
  const phaseInstruction = buildPhaseInstruction(clip.key, frameIndex, frameCount);
  const timelineInstruction = buildTimelineInstruction(clip.key, frameIndex, frameCount);
  return [
    SPRITE_VIEW_TOKENS[direction.key] ?? "PixelartFSS",
    "exactly one isolated full-body pixel art RPG character",
    `${direction.instruction}; preserve this exact viewing direction`,
    `animation ${clip.key}; ${timelineInstruction}`,
    phaseInstruction,
    "The img2img source is the approved canonical sprite. Preserve its exact identity, hair, clothes, colors, accessories, proportions, scale, outline and ground position.",
    "Follow the OpenPose control image exactly for shoulders, elbows, wrists, hips, knees, ankles and body height. Change the pose, not the character design.",
    buildAccessoryGuardrails(bundle),
    `Character metadata: ${buildIdentityDescription(bundle)}.`,
    sanitizeNotes(notes) ? `Creator notes: ${sanitizeNotes(notes)}.` : "",
    `uniform solid ${chromaHex} background, crisp hard pixel edges, no antialiasing, no shadow`,
  ].filter(Boolean).join("\n");
}

export function buildPoseAnimationNegativePrompt() {
  return [
    "sprite sheet, multiple characters, duplicate body, extra limbs, missing limbs",
    "static standing pose, fashion pose, crossed legs, fused legs, identical frame",
    "wrong direction, camera rotation, perspective change, cropped feet, cropped head",
    "new outfit, changed hair, changed colors, invented ears, invented tail, motion trail",
    "background scene, floor, shadow, glow, text, UI, border",
    "smooth vector art, painting, blurry, antialiasing, high resolution illustration",
  ].join(", ");
}

export function buildAccessoryGuardrails(bundle) {
  const assets = bundle?.avatar?.assets ?? [];
  const named = assets.filter((asset) => asset?.name).length;
  return [
    `Accessory evidence policy: the Roblox reference image is primary evidence and the ${named} equipped-item names are secondary evidence.`,
    "Preserve every feature unmistakably visible on the avatar even when it is integrated into another item and its catalog name does not describe it, such as ears built into a hood or a tail built into clothing.",
    "A feature may be drawn when it is clearly visible in the reference OR explicitly supported by equipped metadata. If neither source supports it, do not invent it.",
    "Only draw a tail when its attachment and tail-like silhouette are unmistakably visible in the Roblox reference or named by an equipped item. Never reinterpret long hair, loose clothing, jacket hems, sleeves, shadows or motion trails as a tail.",
  ].filter(Boolean).join(" ");
}

export function buildIdentityDescription(bundle) {
  const assets = bundle?.avatar?.assets ?? [];
  const namedAssets = assets.filter((asset) => asset?.name).slice(0, 32).map((asset) => `${asset.name}${asset.type ? ` (${asset.type})` : ""}`);
  const bodyColors = bundle?.avatar?.bodyColors
    ? Object.entries(bundle.avatar.bodyColors).slice(0, 12).map(([key, value]) => `${key}=${value}`)
    : [];
  return [
    `username @${bundle?.user?.username ?? "unknown"}`,
    `avatar rig ${bundle?.avatar?.avatarType ?? "Unknown"}`,
    namedAssets.length ? `equipped items: ${namedAssets.join(", ")}` : "equipped item names unavailable",
    bodyColors.length ? `body colors: ${bodyColors.join(", ")}` : "",
  ].filter(Boolean).join("; ").slice(0, 2_400);
}

function buildReferenceInstruction(referenceKind) {
  if (referenceKind === "studio-avatar") {
    return [
      "The reference is an authentic in-engine render of the user's currently equipped Roblox avatar.",
      "Transform that exact avatar into exactly ONE isolated game sprite while preserving its visible geometry, asymmetric accessories, clothing layers, hair, face, colors and proportions.",
      "This is a pure style conversion: preserve the reference's exact camera angle, body rotation, head rotation and silhouette. Do not rotate the avatar toward a cardinal view.",
      "Stylize it as deliberate pixel art; do not preserve the smooth 3D rendering, lighting gradients, polygons or plastic material appearance.",
    ].join(" ");
  }
  if (referenceKind === "studio-turntable") {
    return [
      "The first reference is an authentic in-engine render of the equipped avatar at the newly requested 45-degree camera angle; it is the absolute source of truth for camera direction, visible geometry, sidedness and asymmetric accessories.",
      "The second reference is the immediately preceding approved pixel-art direction master; use it only for pixel-art language, palette, outline weight, proportions, sprite scale and identity continuity.",
      "Produce the requested new direction, not a copy of either camera angle and never a redesign.",
    ].join(" ");
  }
  if (referenceKind === "turntable") {
    return [
      "The reference image is the immediately preceding approved direction master in a character turntable.",
      "Rotate that exact same character by precisely 45 degrees into the requested view; this is a camera turn, never a redesign.",
      "Keep the exact face construction, hair geometry, outfit pieces, colors, accessories, body proportions, outline weight, pixel density, sprite scale and ground baseline.",
      "Reveal or hide only the surfaces physically required by the 45-degree rotation. Do not add, remove, reinterpret or swap any feature.",
    ].join(" ");
  }
  if (referenceKind === "continuity") {
    return [
      "The reference image is the immediately preceding approved animation frame.",
      "Treat it as strict continuity: advance the motion by exactly one small phase while preserving every non-moving pixel-level design decision.",
      "Do not restart the pose, redesign the character, change the camera, change scale, add secondary motion trails or add any feature absent from the reference.",
    ].join(" ");
  }
  if (referenceKind === "direction-master") {
    return [
      "The reference image is the approved idle master for this exact character and viewing direction.",
      "Preserve identity, outfit, colors, hairstyle, equipped accessories, proportions, outline, pixel density, silhouette and camera direction.",
      "Begin the requested animation clip by changing only the limb positions and tiny body bob required for its first phase.",
    ].join(" ");
  }
  return [
    "Transform the single Roblox avatar in the reference image into exactly ONE isolated game sprite.",
    "Preserve only its recognizable equipped outfit, dominant colors, hair, head design, silhouette and visible worn items.",
    "Infer hidden surfaces conservatively; never invent an accessory to fill empty space.",
  ].join(" ");
}

function buildSecondaryReferenceInstruction(referenceKind) {
  if (referenceKind === "studio-avatar") return "There is no pose-control input for this canonical identity frame; follow the authentic 3D avatar reference directly.";
  if (referenceKind === "studio-turntable") {
    return "Copy the first reference's current camera direction and physically visible surfaces, but copy only the second reference's approved pixel style. Never reuse the second reference's old camera angle and never copy smooth 3D shading into the final sprite.";
  }
  return "Pose-control reference: a second input image is an abstract colored skeleton. Copy ONLY its joint layout, limb angles, foot positions and body bob. Do not copy its colors, black background, circles, lines or proportions as character design.";
}

function buildIdlePhaseInstruction(frameIndex, frameCount) {
  const phase = ((frameIndex - 1) / frameCount) * Math.PI * 2;
  const breath = Math.sin(phase);
  if (Math.abs(breath) < 0.2) {
    return "Idle phase: neutral resting pose at the loop midpoint. Both feet stay planted in exactly the same pixels; arms remain relaxed. Preserve a living but nearly still silhouette. The idle must still be visibly animated at final size; do not return a pixel-identical copy of the preceding frame.";
  }
  if (breath > 0) {
    return "Idle phase: subtle inhale. Raise the chest, head and shoulders by only about one final pixel with a tiny natural hair/clothing response. Both feet remain locked to the ground; no stepping and no limb swing. The result must be visibly different from the preceding frame without changing identity.";
  }
  return "Idle phase: subtle exhale. Settle the chest, head and shoulders by only about one final pixel with a tiny natural hair/clothing response. Both feet remain locked to the ground; no stepping and no limb swing. The result must be visibly different from the preceding frame without changing identity.";
}

function buildWalkPhaseInstruction(frameIndex, frameCount) {
  const phase = (frameIndex - 1) / frameCount;
  const sector = Math.round(phase * 8) % 8;
  const phases = [
    "left-foot contact: screen-left leg clearly forward with heel planted, screen-right leg clearly back; screen-right arm forward and screen-left arm back; body slightly low",
    "left loading response: weight moves onto the front left foot, both knees bend slightly, rear right heel lifts; opposite arms continue their swing",
    "first passing pose: left leg travels back under the hips while right leg passes forward with a bent knee; feet visibly different from contact; body at its highest point",
    "right leg extension: right lower leg reaches forward toward its next contact while left leg pushes behind; arm swing approaches its opposite extreme",
    "right-foot contact: screen-right leg clearly forward with heel planted, screen-left leg clearly back; screen-left arm forward and screen-right arm back; body slightly low",
    "right loading response: weight moves onto the front right foot, both knees bend slightly, rear left heel lifts; opposite arms continue their swing",
    "second passing pose: right leg travels back under the hips while left leg passes forward with a bent knee; feet visibly different from contact; body at its highest point",
    "left leg extension: left lower leg reaches forward toward the loop's first contact while right leg pushes behind; arm swing returns toward the starting extreme",
  ];
  return `Walk phase: ${phases[sector]}. Make the gait readable at game scale with clear alternating leg separation, opposite arm swing and a restrained one-to-two-pixel body bob. The leg silhouette MUST visibly differ from the preceding frame: at least one foot must change horizontal position and the contact leg must alternate across the loop. A repeated standing pose is unacceptable. This is locomotion, not a static fashion pose.`;
}

function buildRunPhaseInstruction(frameIndex, frameCount) {
  const phase = (frameIndex - 1) / frameCount;
  const sector = Math.round(phase * 8) % 8;
  const phases = [
    "left-foot strike: the left foot reaches forward beneath the body while the right leg extends strongly behind; right arm drives forward and left arm drives back; torso leans slightly into the run",
    "left support: weight compresses over the left leg, rear right foot lifts quickly and both elbows remain clearly bent; body reaches its lowest point",
    "first flight: the left leg pushes behind while the right knee drives forward; neither leg may look planted and the body rises",
    "right reach: right lower leg opens toward the next strike while the left leg trails; arm swing approaches its opposite extreme",
    "right-foot strike: the right foot reaches forward beneath the body while the left leg extends strongly behind; left arm drives forward and right arm drives back; torso keeps its forward intent",
    "right support: weight compresses over the right leg, rear left foot lifts quickly and both elbows remain clearly bent; body reaches its lowest point",
    "second flight: the right leg pushes behind while the left knee drives forward; neither leg may look planted and the body rises",
    "left reach: left lower leg opens toward the loop's first strike while the right leg trails; arm swing returns toward the starting extreme",
  ];
  return `Run phase: ${phases[sector]}. This must read as running rather than a faster walk: use a longer stride, higher knee drive, stronger opposite arm pump, brief flight phases and a slightly larger but controlled body rise. Preserve the character and keep every limb connected. No motion trails or duplicated limbs.`;
}

function buildJumpPhaseInstruction(frameIndex, frameCount) {
  const progress = frameCount <= 1 ? 1 : (frameIndex - 1) / (frameCount - 1);
  if (progress < 0.25) {
    return "Jump phase: forceful takeoff. Extend both legs from the ground, lift the feet cleanly and drive the arms upward or forward according to the equipped Roblox jump animation. Keep the torso connected and the complete silhouette readable.";
  }
  if (progress < 0.65) {
    return "Jump phase: rising through the air. Bend the knees naturally beneath the body, keep both feet visibly airborne and preserve the equipped animation's arm pose. This is ascent, not walking and not a duplicated-limb motion trail.";
  }
  return "Jump phase: approach the apex. Upward momentum is slowing; keep a compact airborne silhouette that transitions naturally into the first fall frame. Do not plant either foot and do not restart the takeoff pose.";
}

function buildFallPhaseInstruction(frameIndex, frameCount) {
  const progress = frameCount <= 1 ? 0 : (frameIndex - 1) / (frameCount - 1);
  if (progress < 0.35) {
    return "Fall phase: leave the jump apex and begin descending. Open the legs slightly from the tucked ascent pose and balance the arms according to the equipped Roblox fall animation. Both feet remain airborne.";
  }
  if (progress < 0.75) {
    return "Fall phase: clear downward travel. Keep the torso stable, limbs connected and feet separated enough to read at game scale; prepare the legs for landing without touching the ground.";
  }
  return "Fall phase: late descent and landing preparation. Lower the feet beneath the hips and soften both knees so the next grounded idle, walk or run frame can receive the character naturally. Do not include the landing itself in this frame.";
}

function buildClimbPhaseInstruction(frameIndex, frameCount) {
  const phase = (frameIndex - 1) / frameCount;
  const sector = Math.round(phase * 8) % 8;
  const phases = [
    "left hand reaches to the next rung while the right foot pushes upward; right hand and left foot support the body",
    "weight rises through the right foot and the torso stays close to the ladder; left hand closes on its rung",
    "left hand and right foot support the body while the right knee lifts toward the next rung",
    "right hand begins its upward reach as the left foot prepares to push",
    "right hand reaches to the next rung while the left foot pushes upward; left hand and right foot support the body",
    "weight rises through the left foot and the torso remains centered; right hand closes on its rung",
    "right hand and left foot support the body while the left knee lifts toward the next rung",
    "left hand begins its upward reach as the right foot prepares to push back into frame 1",
  ];
  return `Climb phase: ${phases[sector]}. Make the ladder gait readable with alternating hands and feet, bent knees and a small controlled vertical body rise. Keep all limbs connected, the torso centered on the same ladder axis and the viewing direction fixed. The ladder itself is environment and must not be drawn inside the sprite.`;
}

function buildSwimIdlePhaseInstruction(frameIndex, frameCount) {
  const phase = (frameIndex - 1) / frameCount;
  const sector = Math.round(phase * 8) % 8;
  const phases = [
    "neutral buoyant pose with the chest supported and hands beginning to sweep outward",
    "hands press gently outward while the knees bend a little beneath the hips",
    "left hand and right foot provide the clearer support beat while the opposite limbs recover",
    "the body rises subtly as both hands return toward the torso",
    "opposite buoyant beat with the hands beginning another outward sweep",
    "hands press gently outward while the feet separate just enough to tread water",
    "right hand and left foot provide the clearer support beat while the opposite limbs recover",
    "the body settles subtly back into the first neutral pose",
  ];
  return `Swimming idle phase: ${phases[sector]}. Keep the avatar afloat in place with a calm, seamless tread-water cycle. Move arms and legs alternately, keep every limb connected and register the torso to the same center. No floor, walking, standing, duplicated limbs, bubbles or drawn water.`;
}

function buildSwimPhaseInstruction(frameIndex, frameCount, pitch) {
  const phase = (frameIndex - 1) / frameCount;
  const sector = Math.round(phase * 8) % 8;
  const pitches = {
    swim_up: "Angle the complete connected body upward about 30 degrees, with the head leading and feet trailing.",
    swim_down: "Angle the complete connected body downward about 30 degrees, with the head leading and feet trailing.",
    swim: "Keep the complete connected body approximately horizontal through the water.",
  };
  const phases = [
    "left arm reaches forward while right arm finishes its backward pull; right leg extends as left knee begins to recover",
    "left hand catches the water and the right arm starts recovering; the legs pass through a narrow alternating position",
    "left arm pulls beneath the torso while right arm travels forward; left leg extends and right knee bends",
    "left arm finishes its pull as the right hand approaches entry; the alternating kick reaches its opposite extreme",
    "right arm reaches forward while left arm finishes its backward pull; left leg extends as right knee begins to recover",
    "right hand catches the water and the left arm starts recovering; the legs pass through a narrow alternating position",
    "right arm pulls beneath the torso while left arm travels forward; right leg extends and left knee bends",
    "right arm finishes its pull as the left hand approaches entry; the alternating kick returns toward frame 1",
  ];
  return `Active swimming phase: ${phases[sector]}. ${pitches[pitch] ?? pitches.swim} Use a readable alternating stroke and kick, keep the torso registered, and keep every arm and leg connected. Do not create extra limbs, motion trails, standing feet, floor, bubbles or drawn water.`;
}

function buildTimelineInstruction(clipKey, frameIndex, frameCount) {
  if (clipKey === "jump") {
    return `This is frame ${frameIndex} of ${frameCount} in a one-shot ascent. Frames advance from takeoff to apex; frame ${frameCount} must transition into fall frame 1 and must not loop back to jump frame 1.`;
  }
  if (clipKey === "fall") {
    return `This is frame ${frameIndex} of ${frameCount} in an airborne descent. The sequence may hold or repeat while the character remains airborne, and its late frames must transition naturally into a grounded clip on landing.`;
  }
  if (clipKey === "climb") {
    return `This is frame ${frameIndex} of ${frameCount} in a seamless vertical ladder cycle. Hands and feet must alternate exactly once across the loop, and frame ${frameCount} must return naturally to frame 1.`;
  }
  if (clipKey === "swim_idle") {
    return `This is frame ${frameIndex} of ${frameCount} in a seamless stationary tread-water loop. The torso stays registered while alternating limbs return naturally from frame ${frameCount} to frame 1.`;
  }
  if (clipKey.startsWith("swim")) {
    return `This is frame ${frameIndex} of ${frameCount} in a seamless active swimming stroke. Arms and legs alternate exactly once across the loop, and frame ${frameCount} must return naturally to frame 1 without changing body pitch.`;
  }
  return `This is frame ${frameIndex} of ${frameCount} in a seamless loop; frame ${frameCount} must flow naturally back into frame 1.`;
}

function buildPhaseInstruction(clipKey, frameIndex, frameCount) {
  if (clipKey === "idle" || clipKey === "idle_alt") return buildIdlePhaseInstruction(frameIndex, frameCount);
  if (clipKey === "run") return buildRunPhaseInstruction(frameIndex, frameCount);
  if (clipKey === "jump") return buildJumpPhaseInstruction(frameIndex, frameCount);
  if (clipKey === "fall") return buildFallPhaseInstruction(frameIndex, frameCount);
  if (clipKey === "climb") return buildClimbPhaseInstruction(frameIndex, frameCount);
  if (clipKey === "swim_idle") return buildSwimIdlePhaseInstruction(frameIndex, frameCount);
  if (clipKey.startsWith("swim")) return buildSwimPhaseInstruction(frameIndex, frameCount, clipKey);
  return buildWalkPhaseInstruction(frameIndex, frameCount);
}

function sanitizeNotes(value) {
  return String(value ?? "").replace(/[\u0000-\u001F\u007F]/g, " ").replace(/\s+/g, " ").trim().slice(0, 800);
}

function normalizeFrameCount(value, allowed, fallback) {
  const count = Number(value);
  return allowed.includes(count) ? count : fallback;
}
