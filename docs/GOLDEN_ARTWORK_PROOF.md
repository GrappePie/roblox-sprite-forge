# Golden Artwork flat proof

This milestone validates art direction before rigging. It deliberately keeps
four responsibilities separate:

- `MockStylizationProvider` proves transport, cache, validation, layer ordering
  and transform animation. Its block mannequin is not an artistic result.
- `ProceduralFallbackRenderer` supplies immediate temporary feedback while a
  curated result is missing or loading.
- `GoldenArtworkProvider` loads a previously validated RGBA illustration and
  displays it as the single `CharacterFlat` layer.
- The real illustration is authored outside Roblox. No LocalScript contains an
  API key and the importer does not upload anything.

`CharacterFlat` has no rig or clips. Automatic layer separation, idle, walk and
jump remain intentionally postponed until the flat design is approved.

## Export an authoring request

```powershell
npm run stylizer:export-request -- --user-id 1021056267
```

Optional author-controlled references can be copied at export time:

```powershell
npm run stylizer:export-request -- `
  --user-id 1021056267 `
  --style-reference C:\path\style-reference.png `
  --avatar-reference C:\path\avatar-reference.png
```

The command uses Roblox's public avatar and thumbnail endpoints and creates:

```text
stylization-requests/<fingerprint>/
├── request.json
├── humanoid-description.json
├── avatar-thumbnail.png
├── headshot.png
├── style-reference.png       # manual when not passed
├── avatar-reference.png      # manual when not passed
└── ARTWORK_REQUIREMENTS.md
```

Node cannot serialize the live Studio `HumanoidDescription`, so the JSON file
records the public asset IDs, body colors and scales instead of inventing an
unsupported API.

## Required canonical artwork

Place `canonical.png` in the request directory. It must be exactly 256×512
RGBA, transparent, full-body, front-facing and neutral. It must preserve:

- hair shape and colors, ears and headphones;
- all hair ornaments and the large right-side accessory;
- the torso star, multicolor sleeves and exposed midriff;
- the skirt, visible legs and boots.

It must have transparent margins around every part and contain no ground
shadow, scenery, text, invented prop or new accessory.

## Import and validate

```powershell
npm run stylizer:import-result -- `
  --request stylization-requests/<fingerprint>/request.json `
  --image stylization-requests/<fingerprint>/canonical.png
```

The importer rejects a bad PNG signature, wrong dimensions, unsupported schema
or style versions, mismatched fingerprints, missing alpha, effectively opaque
backgrounds and artwork touching a canvas edge. It reports dimensions, RGB
color count, alpha coverage, visible bounds, margins and SHA-256 hashes.

The output is:

```text
stylization-results/<fingerprint>/
├── canonical.png
├── canonical-128x256.png
├── package.json
├── package.bin
└── validation-report.json
```

`package.bin` stores the decoded 256×512 master RGBA bytes losslessly plus a
derived 128×256 version with at most 48 RGB colors. The master is never
quantized or replaced.

## Install and compare in Studio

```powershell
npm run studio:install-roblox-only
```

The installer verifies the package hash and embeds validated RGBA data into
chunked ModuleScripts. `GoldenArtworkProvider` decodes those chunks once,
creates a flat `SpritePackage`, and `LayeredSpriteRenderer` creates exactly one
`EditableImage`. Per-frame updates never recreate it.

For the explicit missing-result test:

```powershell
npm run studio:install-roblox-only -- --skip-golden
```

The panel exposes:

- Original avatar;
- Procedural fallback;
- Mock package;
- Golden artwork;
- Golden artwork 128×256;
- Golden artwork 256×512.

The default is Golden artwork, never the mock. The runtime keeps the procedural
fallback visible through `Fingerprinting → Loading → MissingGoldenArtwork`, or
replaces it only after the imported package validates and its renderer is
already visible. Cache entries are keyed by the live Roblox appearance
fingerprint; an imported result may be selected by its user ID, then is rebound
to that live fingerprint without changing any RGBA pixel.
