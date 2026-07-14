import test from "node:test";
import assert from "node:assert/strict";
import { getAvatarDetailRecommendation } from "../public/avatar-detail.js";

test("recomienda 128px para un avatar Roblox alto y delgado", () => {
  const recommendation = getAvatarDetailRecommendation({
    avatar: {
      scales: { height: 1.05, width: 0.7 },
      assets: [],
    },
  });
  assert.equal(recommendation.needsHighDetail, true);
  assert.equal(recommendation.recommendedCellSize, 128);
  assert.equal(recommendation.recommendedRenderResolution, 1024);
  assert.ok(recommendation.reasons.includes("tall-body"));
  assert.ok(recommendation.reasons.includes("slender-body"));
});

test("detecta orejas y accesorios verticales aunque la escala corporal sea normal", () => {
  const recommendation = getAvatarDetailRecommendation({
    avatar: {
      scales: { height: 0.9, width: 0.85 },
      assets: [{ type: "Hat", name: "White Fluffy Bunny Ears" }],
    },
  });
  assert.equal(recommendation.needsHighDetail, true);
  assert.ok(recommendation.reasons.includes("tall-accessory"));
});

test("mantiene los valores normales para una silueta compacta", () => {
  const recommendation = getAvatarDetailRecommendation({
    avatar: {
      scales: { height: 0.9, width: 0.8 },
      assets: [{ type: "Hat", name: "Beanie" }],
    },
  });
  assert.equal(recommendation.needsHighDetail, false);
  assert.equal(recommendation.recommendedCellSize, null);
});
