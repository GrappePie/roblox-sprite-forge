import { createHash } from "node:crypto";
import { AppError } from "./errors.js";
import { fetchBuffer, fetchJson, sleep } from "./http.js";

const USERS_API = "https://users.roblox.com";
const AVATAR_API = "https://avatar.roblox.com";
const THUMBNAILS_API = "https://thumbnails.roblox.com";

/**
 * Acepta @Username, Username, ID numérico o URL pública de perfil.
 * @param {string} raw
 * @returns {{kind: "id", id: number} | {kind: "username", username: string}}
 */
export function parseRobloxIdentity(raw) {
  if (typeof raw !== "string") return invalidIdentity();
  let value = raw.trim();
  if (!value) return invalidIdentity();

  const profileMatch = value.match(
    /(?:https?:\/\/)?(?:www\.)?roblox\.com\/users\/(\d+)(?:\/profile)?(?:[/?#].*)?$/i,
  );
  if (profileMatch) return { kind: "id", id: toSafeUserId(profileMatch[1]) };

  value = value.replace(/^@+/, "");
  if (/^\d+$/.test(value)) return { kind: "id", id: toSafeUserId(value) };

  if (!/^[A-Za-z0-9_]{3,20}$/.test(value)) {
    throw new AppError(
      "El username debe tener entre 3 y 20 caracteres y usar letras, números o guion bajo.",
      { status: 400, code: "invalid_roblox_username" },
    );
  }
  return { kind: "username", username: value };
}

/** @param {string} input */
export async function getRobloxAvatarBundle(input) {
  const identity = parseRobloxIdentity(input);
  const resolved = identity.kind === "id" ? { id: identity.id } : await resolveUsername(identity.username);
  const [profile, avatar, thumbnailUrl] = await Promise.all([
    getUserProfile(resolved.id),
    getAvatarDetails(resolved.id),
    getAvatarThumbnail(resolved.id),
  ]);

  const assets = Array.isArray(avatar.assets) ? avatar.assets : [];
  const bundle = {
    user: {
      id: profile.id,
      username: profile.name,
      displayName: profile.displayName,
      description: profile.description ?? "",
      isBanned: Boolean(profile.isBanned),
      profileUrl: `https://www.roblox.com/users/${profile.id}/profile`,
    },
    avatar: {
      avatarType: avatar.playerAvatarType ?? avatar.avatarType ?? "Unknown",
      assetCount: assets.length,
      assets: assets.slice(0, 60).map((asset) => ({
        id: asset.id,
        name: safeLabel(asset.name),
        type: safeLabel(asset.assetType?.name ?? asset.assetType ?? "Asset"),
      })),
      bodyColors: avatar.bodyColors ?? null,
      scales: avatar.scales ?? null,
    },
    thumbnailUrl,
  };
  bundle.appearanceFingerprint = getAvatarAppearanceFingerprint(bundle);
  return bundle;
}

/**
 * Stable fingerprint of the visible Roblox avatar configuration.
 * Profile text, display name and thumbnail URL are intentionally excluded.
 * @param {object} bundle
 */
export function getAvatarAppearanceFingerprint(bundle) {
  const avatar = bundle?.avatar ?? {};
  const normalized = {
    avatarType: String(avatar.avatarType ?? "Unknown"),
    assets: (Array.isArray(avatar.assets) ? avatar.assets : [])
      .map((asset) => ({ id: Number(asset.id), type: String(asset.type ?? "Asset") }))
      .sort((a, b) => a.id - b.id || a.type.localeCompare(b.type)),
    bodyColors: sortObject(avatar.bodyColors),
    scales: sortObject(avatar.scales),
  };
  return createHash("sha256")
    .update(JSON.stringify(normalized))
    .digest("hex")
    .slice(0, 24);
}

async function resolveUsername(username) {
  const { body } = await fetchJson(
    `${USERS_API}/v1/usernames/users`,
    {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ usernames: [username], excludeBannedUsers: false }),
    },
    { service: "Roblox Users", timeoutMs: 15_000, retries: 2 },
  );
  const user = body?.data?.[0];
  if (!user?.id) {
    throw new AppError(`No se encontró el usuario @${username}.`, {
      status: 404,
      code: "roblox_user_not_found",
    });
  }
  return user;
}

async function getUserProfile(userId) {
  const { body, status } = await fetchJson(
    `${USERS_API}/v1/users/${userId}`,
    { headers: { accept: "application/json" } },
    {
      service: "Roblox Users",
      timeoutMs: 15_000,
      allowStatuses: [404],
      retries: 2,
    },
  );
  if (status === 404 || !body?.id) {
    throw new AppError(`No se encontró un usuario con ID ${userId}.`, {
      status: 404,
      code: "roblox_user_not_found",
    });
  }
  return body;
}

async function getAvatarDetails(userId) {
  const { body } = await fetchJson(
    `${AVATAR_API}/v1/users/${userId}/avatar`,
    { headers: { accept: "application/json" } },
    { service: "Roblox Avatar", timeoutMs: 20_000, retries: 2 },
  );
  if (!body || typeof body !== "object") {
    throw new AppError("Roblox no devolvió los datos del avatar.", {
      status: 502,
      code: "roblox_avatar_unavailable",
    });
  }
  return body;
}

async function getAvatarThumbnail(userId) {
  for (const size of ["720x720", "420x420"]) {
    for (let attempt = 0; attempt < 7; attempt += 1) {
      const params = new URLSearchParams({
        userIds: String(userId),
        size,
        format: "Png",
        isCircular: "false",
      });
      const { body, status } = await fetchJson(
        `${THUMBNAILS_API}/v1/users/avatar?${params}`,
        { headers: { accept: "application/json" } },
        { service: "Roblox Thumbnails", timeoutMs: 20_000, retries: 1, allowStatuses: [400] },
      );
      if (status === 400) break;
      const thumbnail = body?.data?.[0];
      if (thumbnail?.state === "Completed" && thumbnail.imageUrl) return thumbnail.imageUrl;
      if (["Blocked", "Error"].includes(thumbnail?.state)) break;
      await sleep(650 + attempt * 250);
    }
  }
  throw new AppError("Roblox todavía no pudo generar la miniatura del avatar.", {
    status: 503,
    code: "roblox_thumbnail_pending",
  });
}

/** @param {string} thumbnailUrl */
export async function downloadRobloxThumbnail(thumbnailUrl) {
  let url;
  try {
    url = new URL(thumbnailUrl);
  } catch {
    throw new AppError("Roblox devolvió una URL de imagen inválida.", {
      status: 502,
      code: "invalid_thumbnail_url",
    });
  }
  const hostname = url.hostname.toLowerCase();
  const allowed =
    url.protocol === "https:" &&
    (hostname === "rbxcdn.com" ||
      hostname.endsWith(".rbxcdn.com") ||
      hostname === "roblox.com" ||
      hostname.endsWith(".roblox.com"));
  if (!allowed) {
    throw new AppError("Roblox devolvió un host de imagen no permitido.", {
      status: 502,
      code: "thumbnail_host_not_allowed",
    });
  }
  return fetchBuffer(
    url,
    { headers: { accept: "image/png,image/webp,image/jpeg" } },
    { service: "Roblox CDN", timeoutMs: 30_000, maxBytes: 16 * 1024 * 1024, retries: 2 },
  );
}

function invalidIdentity() {
  throw new AppError("Debes indicar un username, ID o URL de perfil de Roblox.", {
    status: 400,
    code: "invalid_roblox_identity",
  });
}

function toSafeUserId(value) {
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw new AppError("El ID de Roblox no es válido.", {
      status: 400,
      code: "invalid_roblox_user_id",
    });
  }
  return id;
}

function safeLabel(value) {
  return String(value ?? "")
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/[<>`{}]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 100);
}

function sortObject(value) {
  if (Array.isArray(value)) return value.map(sortObject);
  if (!value || typeof value !== "object") return value ?? null;
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sortObject(item)]),
  );
}
