# Sprite Forge Roblox Studio prototype

This prototype keeps the real Roblox `Humanoid` and character root for controls,
camera, physics, and replication. On each client it hides the registered 3D avatar
with `LocalTransparencyModifier` and renders the matching generated atlas through
one `BillboardGui`. With `SpriteForgeRuntime.UseEditableImage = false` (the
default), it reuses a pool of horizontal UI pixel runs and needs no restricted
image permission. If Mesh/Image API access is enabled later, setting that
attribute to `true` switches to one `EditableImage` atlas.

The current atlas registry contains user `1021056267` (`YukiManju`) and the output
from job `215dae25-0c0a-4614-9508-682dc7948570`. Other users remain as normal 3D
avatars until the local server returns an atlas matching their current appearance
fingerprint. When an appearance changes, the server creates one new generation
and keeps the 3D avatar visible while that job is pending.

Studio hierarchy installed by the local installer:

- `ReplicatedStorage.SpriteForgeRuntime.AtlasMetadata`
- `ReplicatedStorage.SpriteForgeRuntime.AtlasChunks.Row00` through `Row15`
- `StarterPlayer.StarterPlayerScripts.SpriteForgePixelAvatarClient`
- `ServerScriptService.SpriteForgeDynamicAvatarServer`

The old `YukiSprite*` client and server scripts are disabled, not deleted.

## Roblox-only live paper avatar experiment

`LivePixelAvatarPOC.client.lua` is a disposable Paper Mario-style experiment. Install it
as `StarterPlayerScripts.LivePixelAvatarPOC` in a separate test place. It clones
the local avatar into a `WorldModel`, mirrors `Motor6D`, `AnimationConstraint`,
and `Bone` transforms, and draws the clone as a camera-facing paper cutout through
a fixed-size `SurfaceGui`.

The in-game panel switches among 144x216, 192x288, and 256x384 canvas sizes.
Keys `1`, `2`, and `3` select the same quality levels; `H` toggles between the
paper proxy and the original avatar. `P` enables or disables an eight-direction
paper turn: the card compresses horizontally, changes direction at its thinnest
point, and expands again. A client-only contact shadow follows the floor beneath
the avatar and fades while airborne.

This mode deliberately keeps the live `ViewportFrame` instead of rasterizing it.
That preserves layered clothing, faces, hair, UGC textures, and animation without
ComfyUI, screenshots, generated atlases, or Mesh/Image API access. The dormant
raycast/`EditableImage` experiment remains in the file for comparison, guarded by
`PAPER_MODE`, but it does no per-frame work while paper mode is active.

## Structured Roblox-only comparison prototype

The maintained successor to the disposable POC is split into:

- `PixelAvatarConfig.lua`
- `PixelAvatarUtils.lua`
- `ThumbnailPixelator.lua`
- `ProceduralImageFinalizer.lua`
- `ProceduralRaster.lua`
- `ProceduralChibiBody.lua`
- `HairColorAnalyzer.lua`
- `ProceduralChibiFace.lua`
- `ProceduralChibiSelfTest.lua`
- `ProceduralChibiRenderer.lua`
- `PixelAvatarController.client.lua`

Install it in the connected place with `npm run studio:install-roblox-only`.
It provides Original, unsupported low-resolution ViewportFrame, and functional
retro 3D comparison modes. See
[`../docs/ROBLOX_ONLY_PIXEL_AVATAR.md`](../docs/ROBLOX_ONLY_PIXEL_AVATAR.md) for
the verified platform limitation, controls, lifecycle, and tuning notes.
