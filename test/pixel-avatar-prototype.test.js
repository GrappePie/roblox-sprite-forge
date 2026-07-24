import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const config = fs.readFileSync("studio-prototype/PixelAvatarConfig.lua", "utf8");
const utils = fs.readFileSync("studio-prototype/PixelAvatarUtils.lua", "utf8");
const thumbnailPixelator = fs.readFileSync(
  "studio-prototype/ThumbnailPixelator.lua",
  "utf8",
);
const proceduralChibi = fs.readFileSync(
  "studio-prototype/ProceduralChibiRenderer.lua",
  "utf8",
);
const proceduralFinalizer = fs.readFileSync(
  "studio-prototype/ProceduralImageFinalizer.lua",
  "utf8",
);
const proceduralRaster = fs.readFileSync(
  "studio-prototype/ProceduralRaster.lua",
  "utf8",
);
const proceduralBody = fs.readFileSync(
  "studio-prototype/ProceduralChibiBody.lua",
  "utf8",
);
const proceduralOutfitAnalyzer = fs.readFileSync(
  "studio-prototype/ProceduralChibiOutfitAnalyzer.lua",
  "utf8",
);
const proceduralFace = fs.readFileSync(
  "studio-prototype/ProceduralChibiFace.lua",
  "utf8",
);
const proceduralHeadAnalyzer = fs.readFileSync(
  "studio-prototype/ProceduralChibiHeadAnalyzer.lua",
  "utf8",
);
const proceduralHead = fs.readFileSync(
  "studio-prototype/ProceduralChibiHead.lua",
  "utf8",
);
const hairColorAnalyzer = fs.readFileSync(
  "studio-prototype/HairColorAnalyzer.lua",
  "utf8",
);
const proceduralSelfTest = fs.readFileSync(
  "studio-prototype/ProceduralChibiSelfTest.lua",
  "utf8",
);
const controller = fs.readFileSync(
  "studio-prototype/PixelAvatarController.client.lua",
  "utf8",
);

test("Roblox-only pixel avatar keeps centralized requested settings", () => {
  for (const setting of [
    "PixelResolution",
    "PaletteLevels",
    "OutlineEnabled",
    "OutlineThickness",
    "UpdateRate",
    "RenderDistance",
    "UsePixelatedSampling",
    "ThumbnailChannelLevels",
    "ThumbnailPaletteSize",
    "ThumbnailHeadPaletteSize",
    "ThumbnailBodyPaletteSize",
    "ThumbnailAccentPreservation",
    "ThumbnailAlphaThreshold",
    "ThumbnailOutlineRadius",
    "ThumbnailCropPadding",
    "ThumbnailHeadRatio",
    "ThumbnailCleanIsolatedPixels",
    "ProceduralChibiSize",
    "ProceduralChibiEyeColor",
    "ProceduralChibiPaletteSize",
    "ProceduralChibiAlphaThreshold",
    "ProceduralChibiHeadHeightRatio",
    "ProceduralChibiHeadWidthRatio",
    "ProceduralChibiHeadWidthAuto",
    "ProceduralChibiHairSecondaryMinimumCoverage",
    "ProceduralChibiAccessoryMinimumConfidence",
    "ProceduralChibiMaxAccessoryComponents",
    "ProceduralChibiHeadFallbackEnabled",
    "ProceduralChibiDebugStage",
    "ProceduralChibiRunSelfTest",
    "ProceduralChibiDebugStages",
  ]) {
    assert.match(config, new RegExp(`\\b${setting}\\b`));
  }
  assert.match(config, /ExperimentalPixelCaptureSupported = false/);
});

test("visual clone is non-physical and strips active content", () => {
  assert.match(utils, /CanCollide = false/);
  assert.match(utils, /CanQuery = false/);
  assert.match(utils, /CanTouch = false/);
  assert.match(utils, /LuaSourceContainer/);
  assert.match(utils, /Sound/);
  assert.match(utils, /ParticleEmitter/);
  assert.match(utils, /GetHumanoidDescriptionFromUserIdAsync/);
  assert.match(utils, /CreateHumanoidModelFromDescriptionAsync/);
  assert.match(utils, /GetPlayingAnimationTracks/);
  assert.match(utils, /targetTrack\.TimePosition = sourceTrack\.TimePosition/);
  assert.match(utils, /Instance\.new\("AnimationController"\)/);
  assert.match(utils, /humanoid:Destroy\(\)/);
});

test("comparison controller exposes all requested modes and controls", () => {
  for (const text of [
    "Original",
    "Thumbnail pixel real",
    "Chibi procedural",
    "Pixelado experimental",
    "Estilizado retro 3D",
    "Contorno",
    "FPS aprox",
    "partes réplica",
    "actualización media",
    "NO ES PIXEL ART REAL",
  ]) {
    assert.ok(controller.includes(text), `missing comparison text: ${text}`);
  }
  for (const rate of [8, 12, 15, 30]) {
    assert.ok(config.includes(String(rate)), `missing update rate ${rate}`);
  }
  for (const size of [32, 48, 64, 80, 96]) {
    assert.ok(
      config.includes(`Vector2.new(${size}, ${size})`),
      `missing resolution ${size}x${size}`,
    );
  }
  assert.match(controller, /string\.format\("%dx%d"/);
});

test("procedural chibi renderer redraws a Roblox avatar entirely in Luau", () => {
  assert.match(proceduralChibi, /Enum\.ThumbnailType\.HeadShot/);
  assert.match(proceduralChibi, /Enum\.ThumbnailType\.AvatarThumbnail/);
  assert.match(proceduralChibi, /CreateEditableImageAsync/);
  assert.match(proceduralRaster, /SampleAreaPremultiplied/);
  assert.match(proceduralRaster, /premultipliedRed/);
  assert.match(proceduralRaster, /SourceOverPixel/);
  assert.match(proceduralRaster, /connectivity == 8/);
  assert.match(proceduralRaster, /ProjectComponentResampled/);
  assert.match(proceduralRaster, /FillEllipse/);
  assert.match(proceduralRaster, /FillRoundedPolygon/);
  assert.match(proceduralRaster, /SubtractMask/);
  assert.match(proceduralRaster, /ProjectRegionToMask/);
  assert.match(proceduralRaster, /MaskBounds/);
  assert.match(proceduralRaster, /FillPolygon/);
  assert.match(proceduralRaster, /MakeBodyBands/);
  assert.match(proceduralOutfitAnalyzer, /rowProfiles/);
  assert.match(proceduralOutfitAnalyzer, /FindAccentComponents/);
  assert.match(proceduralOutfitAnalyzer, /midriffUsesSkin/);
  assert.match(proceduralBody, /CreateMasks/);
  assert.match(proceduralBody, /leftArm/);
  assert.match(proceduralBody, /rightLeg/);
  assert.match(proceduralFace, /BackHairLayer/);
  assert.match(proceduralFace, /FaceLayer/);
  assert.match(proceduralFace, /FacialFeaturesLayer/);
  assert.match(proceduralFace, /FrontHairLayer/);
  assert.match(proceduralFace, /AccessoryLayer/);
  assert.match(proceduralChibi, /GetHumanoidDescriptionFromUserIdAsync/);
  assert.match(proceduralChibi, /SourceBody/);
  assert.match(proceduralChibi, /SourceRegions/);
  assert.match(proceduralChibi, /BodyMasks/);
  assert.match(proceduralChibi, /BodyProjected/);
  assert.match(proceduralChibi, /BodyAccents/);
  assert.match(proceduralChibi, /BodySingleCopy/);
  assert.match(proceduralChibi, /BodySegments/);
  assert.match(proceduralChibi, /BeforeFace/);
  assert.match(proceduralChibi, /BeforeFinalize/);
  assert.match(proceduralChibi, /HeadSource/);
  assert.match(proceduralChibi, /HairClusters/);
  assert.match(proceduralChibi, /HairMasks/);
  assert.match(proceduralChibi, /AccessoryCandidates/);
  for (const stage of [
    "HairCore", "HairLabelMap", "AccessoryRawCandidates",
    "AccessoryMergedGroups", "AccessoryAnchors", "AccessoryBackLayer",
    "AccessorySideLayer", "AccessoryFrontLayer", "FringeMask",
    "SkirtSourceMask", "ShoulderRepair", "FinalBeforeQuantize",
  ]) {
    assert.ok(proceduralChibi.includes(stage), `missing chibi diagnostic: ${stage}`);
  }
  assert.match(proceduralChibi, /HeadWithoutAccessories/);
  assert.match(proceduralChibi, /HeadComposite/);
  assert.match(proceduralChibi, /LegacyCopiedHead/);
  assert.match(proceduralHeadAnalyzer, /protectedFace/);
  assert.match(proceduralHeadAnalyzer, /ConnectedComponents/);
  assert.match(proceduralHeadAnalyzer, /AccessoryDepth/);
  assert.match(proceduralHeadAnalyzer, /AccessoryKind/);
  assert.match(proceduralHeadAnalyzer, /pairAccessories/);
  assert.match(proceduralHeadAnalyzer, /CanMergeComponents/);
  assert.match(proceduralHeadAnalyzer, /ZONE_LIMITS/);
  assert.doesNotMatch(proceduralHeadAnalyzer, /selectedZones/);
  for (const metric of [
    "candidatesByZone", "retainedByZone", "rejectedByOverlap",
    "rejectedByQuota", "rejectedAsDuplicate",
  ]) {
    assert.ok(proceduralHeadAnalyzer.includes(metric), `missing accessory metric: ${metric}`);
  }
  assert.match(proceduralHead, /CreateMasks/);
  assert.match(proceduralHead, /NORMALIZED_ANCHORS/);
  assert.match(proceduralHead, /pairMetrics/);
  assert.match(proceduralHead, /heightRatio/);
  assert.doesNotMatch(proceduralHead, /shiftX =/);
  assert.doesNotMatch(proceduralHead, /ClipToMask\(frontAccessories,\s*size,\s*masks\.frontHair\)/);
  for (const mask of [
    "frontAccessoryAllowed", "sideAccessoryAllowed", "backAccessoryAllowed",
    "protectedEyeMask", "protectedMouthMask", "protectedFacialFeaturesMask",
  ]) {
    assert.ok(proceduralHead.includes(mask), `missing canonical head mask: ${mask}`);
  }
  assert.match(proceduralHead, /secondaryReliable/);
  assert.match(hairColorAnalyzer, /primaryCoverage/);
  assert.match(hairColorAnalyzer, /secondaryCoverage/);
  assert.match(hairColorAnalyzer, /spatialSpan/);
  assert.match(hairColorAnalyzer, /hairCoreMask/);
  assert.match(hairColorAnalyzer, /labelMap/);
  assert.match(hairColorAnalyzer, /RegularizeHairLabelMap/);
  assert.match(hairColorAnalyzer, /rawLabelComponents/);
  assert.match(proceduralOutfitAnalyzer, /AnalyzeSleeveBands/);
  assert.match(proceduralBody, /masks\.waistband/);
  assert.match(proceduralBody, /masks\.upperPanels/);
  assert.match(proceduralBody, /masks\.lowerRuffle/);
  for (const stage of [
    "HairLabelMapRaw", "HairLabelMapRegularized", "HairColorMasses",
    "ProtectedFacialFeatures", "FrontAccessoryAllowed", "SideAccessoryAllowed",
    "AccessorySelectedPerZone", "AccessoryPairLayout",
    "AccessoryCompositeBeforeClipping", "AccessoryCompositeAfterClipping",
    "SleeveBandDescriptors", "SleevesStructured", "LowerGarmentPalette",
    "LowerGarmentSubregions", "BodyStructured",
  ]) {
    assert.ok(proceduralChibi.includes(stage), `missing regularization diagnostic: ${stage}`);
  }
  assert.doesNotMatch(hairColorAnalyzer, /primary = bucketColor\(buckets\[1\]\)/);
  assert.match(proceduralChibi, /xpcall/);
  assert.match(proceduralChibi, /headImage:Destroy/);
  assert.match(proceduralChibi, /avatarImage:Destroy/);
  assert.match(proceduralChibi, /WritePixelsBuffer/);
  assert.match(proceduralChibi, /Vector2/);
  assert.match(controller, /ProceduralChibiRenderer\.Create/);
  assert.match(controller, /Sin IA externa/);
  assert.match(config, /ProceduralChibiSize = Vector2\.new\(128, 256\)/);
});

test("procedural image is finalized only after composition with locked colors", () => {
  assert.match(proceduralChibi, /ImageFinalizer\.FinalizeWithMetrics/);
  assert.match(proceduralFinalizer, /PaletteSize/);
  assert.match(proceduralFinalizer, /LockedColors/);
  assert.match(proceduralFinalizer, /CountOpaqueColors/);
  assert.match(proceduralFinalizer, /ApplyExteriorOutline/);
  assert.match(proceduralFinalizer, /local exterior/);
  assert.match(proceduralFinalizer, /Vector2\.new\(-1, 0\)/);
  assert.match(proceduralFinalizer, /Vector2\.new\(1, 0\)/);
  assert.match(proceduralFinalizer, /Vector2\.new\(0, -1\)/);
  assert.match(proceduralFinalizer, /Vector2\.new\(0, 1\)/);
  assert.doesNotMatch(proceduralFinalizer, /Vector2\.new\(-1, -1\)/);
  assert.match(config, /ProceduralChibiPaletteSize = 48/);
  assert.match(config, /ProceduralChibiAlphaThreshold = 48/);
  assert.match(config, /ProceduralChibiHeadHeightRatio = 0\.41/);
  assert.match(controller, /OutlineEnabled = outlineEnabled/);
  assert.match(controller, /requestedColors=%d finalColors=%d stage=%s/);
  assert.match(controller, /\[ProceduralChibiSelfTest\] PASS/);
  assert.match(controller, /RunService:IsStudio\(\)/);
  assert.match(config, /ProceduralChibiRunSelfTest = true/);
});

test("procedural Luau self-test covers synthetic buffer behavior", () => {
  assert.match(proceduralSelfTest, /paletteMetrics\.paletteColors > 32/);
  assert.match(proceduralSelfTest, /bands\.torso\.maxY \+ 1 == bands\.hips\.minY/);
  assert.match(proceduralSelfTest, /Left arm mask is empty/);
  assert.match(proceduralSelfTest, /Legs touch at center/);
  assert.match(proceduralSelfTest, /FaceLayer did not create alpha/);
  assert.match(proceduralSelfTest, /Final color count exceeded requested limit/);
  assert.match(proceduralSelfTest, /Yellow torso symbol was lost/);
  assert.match(proceduralSelfTest, /Left arm is not angled outward/);
  assert.match(proceduralSelfTest, /outside canonical masks/);
  assert.match(proceduralSelfTest, /fallback ratio is unreasonable/);
  assert.match(proceduralSelfTest, /syntheticHead/);
  assert.match(proceduralSelfTest, /Secondary tip color was not detected/);
  assert.match(proceduralSelfTest, /Original dark eyes survived as accessory candidates/);
  assert.match(proceduralSelfTest, /BackHairLayer is empty/);
  assert.match(proceduralSelfTest, /Synthetic head unexpectedly used legacy fallback/);
  assert.match(proceduralSelfTest, /8-connectivity split diagonal pixels/);
  assert.match(proceduralSelfTest, /Compatible left\/right accessories were not paired/);
  assert.match(proceduralSelfTest, /Accessory inverse projection is too sparse/);
  assert.match(proceduralSelfTest, /Procedural fringe contains a wide gap/);
  assert.match(proceduralSelfTest, /Shoulder repair overwrote valid texture/);
  assert.match(proceduralSelfTest, /Central skirt component was not retained/);
  assert.match(proceduralSelfTest, /Multiple frontLeft accessories were discarded/);
  assert.match(proceduralSelfTest, /Hair label escaped hairCoreMask/);
  assert.match(proceduralSelfTest, /Five sleeve bands collapsed below four/);
  assert.match(proceduralSelfTest, /Fringe covers too much of the eyes/);
});

test("procedural head owns its alpha and keeps copied pixels debug-only", () => {
  assert.match(proceduralHead, /Face\.BackHairLayer/);
  assert.match(proceduralHead, /Face\.FaceLayer/);
  assert.match(proceduralHead, /Face\.FacialFeaturesLayer/);
  assert.match(proceduralHead, /Face\.FrontHairLayer/);
  assert.match(proceduralHead, /projectAccessories/);
  assert.match(proceduralRaster, /CardinalDilate/);
  assert.match(proceduralRaster, /CardinalErode/);
  assert.match(proceduralRaster, /ProjectComponent/);
  assert.match(proceduralRaster, /ProjectComponentResampled/);
  assert.match(proceduralHead, /backAccessories/);
  assert.match(proceduralHead, /sideAccessories/);
  assert.match(proceduralHead, /frontAccessories/);
  assert.doesNotMatch(proceduralHead, /\(x \+ y\) % 3/);
  assert.match(proceduralChibi, /stage == "LegacyCopiedHead"/);
  assert.match(proceduralChibi, /fallbackEnabled and lowConfidence/);
  assert.match(controller, /head procedural=%s/);
  assert.match(controller, /headFallback=%s/);
});

test("thumbnail pipeline performs real raster reduction and nearest-neighbor display", () => {
  assert.match(thumbnailPixelator, /GetUserThumbnailAsync/);
  assert.match(thumbnailPixelator, /Enum\.ThumbnailType\.AvatarThumbnail/);
  assert.match(thumbnailPixelator, /Enum\.ThumbnailSize\.Size420x420/);
  assert.match(thumbnailPixelator, /CreateEditableImageAsync\(Content\.fromUri/);
  assert.match(thumbnailPixelator, /ReadPixelsBuffer/);
  assert.match(thumbnailPixelator, /WritePixelsBuffer/);
  assert.match(thumbnailPixelator, /premultipliedR/);
  assert.match(thumbnailPixelator, /AlphaThreshold/);
  assert.match(thumbnailPixelator, /ChannelLevels/);
  assert.match(thumbnailPixelator, /buildAdaptivePalette/);
  assert.match(thumbnailPixelator, /strongestChroma/);
  assert.match(thumbnailPixelator, /findAlphaBounds/);
  assert.match(thumbnailPixelator, /headOccupied/);
  assert.match(thumbnailPixelator, /bodyOccupied/);
  assert.match(thumbnailPixelator, /cleanIsolatedOccupancy/);
  assert.match(thumbnailPixelator, /farthest-point seeds/);
  assert.match(thumbnailPixelator, /manhattanDistance/);
  assert.match(thumbnailPixelator, /OutlineRadius/);
  assert.match(controller, /ImageContent = Content\.fromObject/);
  assert.match(controller, /Enum\.ResamplerMode\.Pixelated/);
  assert.match(controller, /THUMBNAIL_PREVIEW_MAX/);
  assert.match(controller, /math\.floor\(THUMBNAIL_PREVIEW_MAX \/ resolution\.X\)/);
});

test("controller manages respawn, player cleanup, distance and throttling", () => {
  assert.match(controller, /CharacterAdded/);
  assert.match(controller, /CharacterRemoving/);
  assert.match(controller, /PlayerRemoving/);
  assert.match(controller, /destroySession/);
  assert.match(controller, /RenderDistance/);
  assert.match(controller, /1 \/ updateRate/);
  assert.match(controller, /session\.originalHidden ~= hideOriginal/);
  assert.match(controller, /GetPropertyChangedSignal\("LocalTransparencyModifier"\)/);
  assert.match(controller, /GetPropertyChangedSignal\(propertyName\)/);
});
