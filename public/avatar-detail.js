const TALL_ACCESSORY_PATTERN = /\b(?:antennae?|antlers?|bunny ears?|rabbit ears?|long ears?|horns?|top hat|tall hat)\b/i;

export function getAvatarDetailRecommendation(bundle) {
  const avatar = bundle?.avatar ?? {};
  const scales = avatar.scales ?? {};
  const height = finiteScale(scales.height, 0.9);
  const width = finiteScale(scales.width, 1);
  const heightToWidth = height / Math.max(0.1, width);
  const tallAccessory = (avatar.assets ?? []).some((asset) => (
    ["Hat", "HairAccessory"].includes(asset?.type)
    && TALL_ACCESSORY_PATTERN.test(String(asset?.name ?? ""))
  ));
  const tallBody = height >= 1;
  const slenderBody = width <= 0.8 && heightToWidth >= 1.4;
  const needsHighDetail = tallBody || slenderBody || tallAccessory;

  return {
    needsHighDetail,
    recommendedCellSize: needsHighDetail ? 144 : null,
    recommendedRenderResolution: needsHighDetail ? 1024 : null,
    height,
    width,
    heightToWidth,
    reasons: [
      tallBody ? "tall-body" : null,
      slenderBody ? "slender-body" : null,
      tallAccessory ? "tall-accessory" : null,
    ].filter(Boolean),
  };
}

function finiteScale(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}
