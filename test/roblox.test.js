import test from "node:test";
import assert from "node:assert/strict";
import {
  downloadRobloxThumbnail,
  getAvatarAppearanceFingerprint,
  getRobloxAvatarBundle,
  parseRobloxIdentity,
} from "../src/lib/roblox.js";

test("acepta username con arroba", () => {
  assert.deepEqual(parseRobloxIdentity("@YukiManju"), {
    kind: "username",
    username: "YukiManju",
  });
});

test("acepta ID numérico", () => {
  assert.deepEqual(parseRobloxIdentity("1021056267"), { kind: "id", id: 1021056267 });
});

test("acepta URL de perfil", () => {
  assert.deepEqual(parseRobloxIdentity("https://www.roblox.com/users/1021056267/profile"), {
    kind: "id",
    id: 1021056267,
  });
});

test("rechaza usernames inválidos", () => {
  assert.throws(() => parseRobloxIdentity("nombre con espacios"), /username/i);
});

test("resuelve un username y normaliza los datos públicos del avatar", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url === "https://users.roblox.com/v1/usernames/users") {
      return jsonResponse({ data: [{ id: 1021056267, name: "YukiManju" }] });
    }
    if (url === "https://users.roblox.com/v1/users/1021056267") {
      return jsonResponse({
        id: 1021056267,
        name: "YukiManju",
        displayName: "Yuki",
        description: "perfil de prueba",
        isBanned: false,
      });
    }
    if (url === "https://avatar.roblox.com/v1/users/1021056267/avatar") {
      return jsonResponse({
        playerAvatarType: "R15",
        assets: [
          { id: 1, name: "Black Cat Ears", assetType: { name: "Hat" } },
          { id: 2, name: "White Hoodie", assetType: { name: "Shirt" } },
        ],
        bodyColors: { headColorId: 1 },
        scales: { height: 1 },
      });
    }
    if (url.startsWith("https://thumbnails.roblox.com/v1/users/avatar?")) {
      return jsonResponse({
        data: [{ state: "Completed", imageUrl: "https://tr.rbxcdn.com/avatar-test.png" }],
      });
    }
    throw new Error(`Solicitud inesperada: ${url}`);
  };

  try {
    const bundle = await getRobloxAvatarBundle("@YukiManju");
    assert.equal(bundle.user.id, 1021056267);
    assert.equal(bundle.user.username, "YukiManju");
    assert.equal(bundle.avatar.avatarType, "R15");
    assert.equal(bundle.avatar.assetCount, 2);
    assert.deepEqual(bundle.avatar.assets[0], {
      id: 1,
      name: "Black Cat Ears",
      type: "Hat",
    });
    assert.equal(bundle.thumbnailUrl, "https://tr.rbxcdn.com/avatar-test.png");
    assert.match(bundle.appearanceFingerprint, /^[0-9a-f]{24}$/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("la huella de apariencia ignora el orden pero cambia con los objetos", () => {
  const base = {
    avatar: {
      avatarType: "R15",
      assets: [{ id: 2, type: "Hat" }, { id: 1, type: "Shirt" }],
      bodyColors: { torso: 1, head: 2 },
      scales: { height: 1, width: 0.9 },
    },
  };
  const reordered = {
    avatar: {
      ...base.avatar,
      assets: [...base.avatar.assets].reverse(),
      bodyColors: { head: 2, torso: 1 },
    },
  };
  assert.equal(getAvatarAppearanceFingerprint(base), getAvatarAppearanceFingerprint(reordered));
  assert.notEqual(
    getAvatarAppearanceFingerprint(base),
    getAvatarAppearanceFingerprint({
      avatar: { ...base.avatar, assets: [...base.avatar.assets, { id: 3, type: "Hair" }] },
    }),
  );
});

test("solo permite descargar miniaturas desde dominios de Roblox", async () => {
  await assert.rejects(
    downloadRobloxThumbnail("https://example.com/avatar.png"),
    (error) => error?.code === "thumbnail_host_not_allowed",
  );
});

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
