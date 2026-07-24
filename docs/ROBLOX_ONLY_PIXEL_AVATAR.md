# Roblox-only Pixel Avatar prototype

## Honest result

Roblox currently does **not** expose a supported API that copies the pixels
rendered by a `ViewportFrame` into an `EditableImage`. `ViewportFrame` has
rendering and lighting properties, but no pixel-read or capture method.
`EditableImage:ReadPixelsBuffer()` can only read pixels already contained in an
`EditableImage`; it cannot use a `ViewportFrame` as its source.

The prototype now separates that unsolved animated-raster problem from a
solvable first target: a **real pixel image made from the player's public avatar
thumbnail**. Roblox loads the 420×420 avatar thumbnail into an `EditableImage`,
then the client:

- crops the transparent thumbnail margin and fits the silhouette back into the
  canvas without changing its aspect ratio;
- downsamples to 32×32, 48×48, 64×64, 80×80 or 96×96 with a box filter using premultiplied
  alpha;
- applies a hard alpha threshold;
- builds a deterministic 24-color adaptive palette from the avatar itself,
  preserving uncommon identity colors without scattered texture noise;
- retains a controlled fraction of tiny high-chroma accents before palette
  fitting, so eyes and characteristic trim survive the box reduction;
- fits separate adaptive palettes to the head and body regions so skin, hair
  and face details do not compete with the outfit for the same colors;
- removes fully isolated occupancy pixels and keeps the one-pixel silhouette
  outline cardinal rather than diagonally thick;
- creates a one-pixel silhouette outline morphologically; and
- displays the result with `ResamplerMode.Pixelated` nearest-neighbor scaling.

This mode is genuinely rasterized pixel art, but it is a static avatar pose. It
does not pretend to solve arbitrary real-time animation. The second functional
mode remains a **retro 3D visual replica**:

## Pure-Luau procedural chibi mode

`Chibi procedural` is a separate 128×256 generator that runs entirely in the
Roblox client. It uses the pixelized Roblox avatar as identity input, then:

- separates the visible head and body regions;
- analyzes a stable body centerline and non-overlapping semantic outfit regions;
- projects torso, sleeve, midriff, skirt, leg and boot RGB into independent
  procedural masks whose alpha defines the final chibi anatomy;
- recovers compact high-contrast outfit accents after the area-sampled base
  transfer, so symbols, stripes and garment panels can survive;
- analyzes crown, side and tip hair regions instead of choosing the largest
  global color bucket;
- builds a canonical rounded-bob head from procedural back-hair, face, side,
  fringe, bang and tip masks;
- draws layered anime eyes, highlights, lashes, blush and a curved mouth;
- extracts compact accessory components outside the protected source-face
  region with eight-neighbour connectivity, merges compatible 1–3 px
  fragments, pairs symmetric pieces and projects them inversely to seven
  canonical head anchors;
- converts each retained accessory into a normalized occupancy descriptor
  with contour, holes, aspect, orientation, symmetry and regional color roles;
- renders distinctive accessories with their measured silhouette
  (`ShapePreserving`), uses source-conditioned paired templates when useful
  (`TemplateAssisted`) and reserves triangles/ellipses for unstable
  observations (`PrimitiveFallback`);
- composites accessories in independent back, side and front depth buffers;
- retains a spatial hair-core and four-label color map so secondary hair
  distribution remains coherent instead of becoming a checker pattern;
- builds the hair dome and a continuous seven-tip fringe from reusable masks;
- isolates the central connected skirt source from side hands/skin and repairs
  only transparent shoulder holes without overwriting valid sleeve stripes;
- keeps the old copied head only in `LegacyCopiedHead` and as a low-confidence
  fallback;
- writes the finished composition to a new `EditableImage`.

This is not an external AI call and does not contact the local Sprite Forge
server or ComfyUI. It is a deterministic procedural renderer written in Luau.
The current milestone produces one static frontal pose. Its output is designed
as the master image for a later cached animation atlas.

- Roblox loads the player's public `HumanoidDescription`.
- A visual-only model is created with the same rig type as the playable
  character.
- Accessories, layered clothing, textures, body proportions and colors remain
  recognizable.
- Scripts, sounds, particles, trails, beams and physical interactions are
  removed from the replica.
- Materials and untextured part colors are simplified.
- A configurable dark `Highlight` supplies the silhouette outline.
- Animation tracks are mirrored by asset ID and sampled at the selected visual
  rate.
- The generated `Humanoid` is replaced by `AnimationController` + `Animator`,
  preventing the visual rig from re-enabling character collisions.
- The original character is hidden locally while a replica is active.

The comparison mode called **Pixelado experimental** uses a low-resolution
`SurfaceGui` containing a `ViewportFrame`. It demonstrates the platform limit:
the result is softened by Roblox's 3D renderer and is explicitly labelled
`NO ES PIXEL ART REAL`.

## Studio hierarchy

```text
ReplicatedStorage
└── PixelAvatar
    ├── PixelAvatarConfig
    ├── PixelAvatarUtils
    ├── ThumbnailPixelator
    ├── ProceduralImageFinalizer
    ├── ProceduralRaster
    ├── ProceduralChibiOutfitAnalyzer
    ├── ProceduralChibiBody
    ├── HairColorAnalyzer
    ├── ProceduralChibiFace
    ├── ProceduralChibiHeadAnalyzer
    ├── ProceduralChibiAccessory
    ├── ProceduralChibiAccessoryCompletion
    ├── ProceduralChibiHead
    ├── ProceduralChibiSelfTest
    └── ProceduralChibiRenderer

StarterPlayer
└── StarterPlayerScripts
    └── PixelAvatarController
```

The old Sprite Forge atlas client/server are disabled by the installer, not
deleted. The Roblox-only prototype does not contact ComfyUI, a local web server,
an external API or a generative model.

## Install or update

Keep the target place open in Roblox Studio with the MCP plugin connected, then
run:

```powershell
node scripts/install-roblox-only-pixel-avatar.js
```

The installer replaces only the `ReplicatedStorage.PixelAvatar` package and
`StarterPlayerScripts.PixelAvatarController`.

## Comparison panel

The panel in the lower-left corner provides:

- `Original`
- `Thumbnail pixel real`
- `Chibi procedural`
- `Pixelado experimental`
- `Estilizado retro 3D`
- outline on/off
- 32×32, 48×48, 64×64, 80×80 and 96×96 raster/experimental resolutions
- 8, 12, 15 and 30 Hz visual update rates
- current technique
- approximate display FPS
- visual replica part count
- average update time
- a compatibility warning

## Central configuration

Edit `ReplicatedStorage.PixelAvatar.PixelAvatarConfig` in Studio or
`studio-prototype/PixelAvatarConfig.lua` in the repository:

```lua
PixelResolution = Vector2.new(96, 96)
PaletteLevels = 6
OutlineEnabled = true
OutlineThickness = 1
UpdateRate = 15
RenderDistance = 100
UsePixelatedSampling = true
ThumbnailChannelLevels = 4
ThumbnailPaletteSize = 24
ThumbnailHeadPaletteSize = 18
ThumbnailBodyPaletteSize = 24
ThumbnailAccentPreservation = 0.28
ThumbnailAlphaThreshold = 28
ThumbnailOutlineRadius = 1
ThumbnailCropPadding = 0.025
ThumbnailHeadRatio = 0.43
ThumbnailCleanIsolatedPixels = true
ProceduralChibiSize = Vector2.new(128, 256)
ProceduralChibiEyeColor = Color3.fromRGB(116, 88, 168)
ProceduralChibiPaletteSize = 48
ProceduralChibiAlphaThreshold = 48
ProceduralChibiHeadHeightRatio = 0.41
ProceduralChibiHeadWidthRatio = 0.82
ProceduralChibiHeadWidthAuto = true
ProceduralChibiHairSecondaryMinimumCoverage = 0.04
ProceduralChibiAccessoryMinimumConfidence = 0.35
ProceduralChibiMaxAccessoryComponents = 16
ProceduralChibiHeadFallbackEnabled = true
ProceduralChibiDebugStage = "Final"
ProceduralChibiRunSelfTest = true
```

`ThumbnailPaletteSize` controls the avatar-specific palette. The older
`ThumbnailChannelLevels` remains as a fallback for callers that omit the
palette size. Head and body palette sizes can be tuned independently.
`ThumbnailHeadRatio` controls the automatic regional split, while
`ThumbnailCropPadding` leaves breathing room around the detected silhouette.
The preview uses the largest integer display scale that fits, preventing uneven
pixel widths at 80×80 and 96×96. The 128×256 procedural image is shown at
exactly 2× (256×512), with pixelated sampling. In Studio, the stage button
cycles through the body diagnostics plus `HeadSource`, `HairClusters`,
`HairCore`, `HairLabelMap`, `HairMasks`, `AccessoryRawCandidates`,
`AccessoryMergedGroups`, `AccessoryAnchors`, the three accessory depth layers,
`FringeMask`, `SkirtSourceMask`, `ShoulderRepair`, `HeadWithoutAccessories`,
`HeadComposite`, `LegacyCopiedHead`, `BeforeFace`, `FinalBeforeQuantize` and
`Final`. With `ProceduralChibiHeadWidthAuto`, hair-core aspect selects a
0.74–0.82 head-width ratio; disabling it restores the explicit ratio override.
`ProceduralChibiRunSelfTest` runs only in Studio and validates a synthetic
black/yellow/rainbow/skin/green-purple/boot outfit and two synthetic head
palettes through the actual regional pipelines. It also verifies that copied
thumbnail eyes cannot return as accessories. `ThumbnailOutlineRadius` controls the actual
raster outline. `OutlineThickness`
is retained as a design setting, but Roblox `Highlight` does
not expose a thickness property. The supported controls are outline color and
transparency. `UsePixelatedSampling` cannot affect a `ViewportFrame`; nearest
neighbor sampling only applies when an actual image exists.

La regularización estructural añade `HairLabelMapRaw`,
`HairLabelMapRegularized`, `HairColorMasses`, `ProtectedFacialFeatures`,
`FrontAccessoryAllowed`, `SideAccessoryAllowed`,
`AccessorySelectedPerZone`, `AccessoryPairLayout`,
`AccessoryCompositeBeforeClipping`, `AccessoryCompositeAfterClipping`,
`AccessoryShapeOccupancy`, `AccessoryContours`, `AccessoryHoles`,
`AccessoryColorRoles`, `AccessoryRenderModes`, `AccessoryShapePreserving`,
`AccessoryTemplateAssisted`, `AccessoryPrimitiveFallback`,
`AccessoryFinalLayout`,
`SleeveBandDescriptors`, `SleevesStructured`, `LowerGarmentPalette`,
`LowerGarmentSubregions` y `BodyStructured`. Los accesorios usan anchors
normalizados, cuotas por zona y supresión de máximos no solapados. Los adornos
frontales pueden sobresalir del flequillo sin invadir ojos o boca. El cabello
se reduce a etiquetas categóricas limpias, las mangas a 3–7 bandas
longitudinales y la falda se proyecta por separado en cintura, paneles y
volante inferior.

La segunda pasada de regularización deja de componer el `labelMap` sobre el
cabello final. El mapa categórico se conserva como diagnóstico, mientras que la
imagen usa una base Primary y un máximo pequeño de masas Secondary, Highlight
y Shadow. Los accesorios calculan posición respecto de `sourceBounds`, tamaño
por área relativa, simplifican su paleta, preservan huecos y compiten por
presupuestos de cobertura y colisión en el espacio destino. Las parejas
comparten alineación estilística sin forzar tamaños idénticos.

Las métricas separan los conteos `ShapePreserving`, `TemplateAssisted` y
`PrimitiveFallback`; también informan huecos preservados o perdidos, error
medio de aspecto y colores fuente/finales. Los buffers de diagnóstico son
resultados raster reales, no alias del compuesto final.

La segmentación de accesorios usa ahora dos niveles. `AccessoryCoreSeeds`
contiene únicamente semillas de alto contraste; `AccessorySupportMask`
permite recuperar localmente bordes claros, sombras y colores parecidos a piel
o cabello sin incorporar la cara ni la corona completa. Cada semilla crece
dentro de una región limitada y produce `AccessoryCompletedClusters`.

El layout clasifica la geometría como `PointedTop`, `SideShell`, `Linear`,
`StackedLinear`, `Compact` o `Complex`. Antes de rasterizar, cada pieza pasa
por `FitBoundsInsideSafeCanvas`: primero se traslada, después se reduce solo si
es necesario y se rechaza si no puede conservarse. La validación final informa
proporción visible, huecos posteriores, error de aspecto, unión con el cabello,
solapamiento facial y píxeles fuera del lienzo. El contorno oscuro se añade
fuera de la ocupación para conservar el borde cromático interior.

El cuerpo también se interpreta mediante descriptores: las bandas de manga se
pintan en el eje local hombro-puño, el torso usa una base limpia más uno o dos
emblemas, la falda divide primero la fuente en cintura, paneles y volante,
conserva su secuencia regional al generar entre cuatro y siete paneles, y las botas se dividen
en puño, caña y pie con recuperación de paleta por pareja. El límite de 48
colores es un máximo; el finalizador puede detenerse antes cuando los buckets
restantes pesan poco o son perceptualmente redundantes.

Lower `PaletteLevels` for stronger color stepping on untextured body parts.
Textured accessories and layered clothing retain their original textures so the
player stays recognizable. Lower `UpdateRate` for a more visibly stepped
animation and lower client work. Lower `RenderDistance` to cull remote replicas
sooner.

## Lifecycle and performance

- Each visible player gets one retro replica and one reusable experimental
  replica; they are not cloned per frame.
- Pose/animation work is throttled by `UpdateRate`.
- The controller supports all currently visible players and watches new players.
- Respawn destroys the previous session and creates exactly one replacement.
- Player removal disconnects per-player connections and destroys both replicas.
- Parts are non-collidable, non-queryable, non-touchable, massless and
  client-only.
- The original avatar is restored whenever the selected replica is unavailable
  or beyond `RenderDistance`.

## Verified Roblox APIs

The implementation was checked against the official Engine API reference:

- `ViewportFrame` renders 3D content and has no capture/read method.
- `WorldModel` supports animated humanoid joints inside a `ViewportFrame`.
- `Players:GetHumanoidDescriptionFromUserIdAsync()` returns the equipped public
  avatar description.
- `Players:CreateHumanoidModelFromDescriptionAsync()` creates the matching
  visual rig.
- `ImageLabel.ResampleMode = Enum.ResamplerMode.Pixelated` is nearest-neighbor
  sampling for the generated thumbnail image.
- `Players:GetUserThumbnailAsync()` supplies the public 420×420 avatar render.
- `AssetService:CreateEditableImageAsync(Content.fromUri(...))` can load the
  non-asset thumbnail URI.
- `EditableImage:ReadPixelsBuffer()` and `WritePixelsBuffer()` operate on an
  `EditableImage`, not a rendered viewport.
- `Highlight` supports configurable outline color/transparency but not outline
  thickness.
- `SurfaceGui.CanvasSize` supplies the fixed comparison canvas and
  `MaxDistance` supplies a render limit.

## Required Studio security setting

The experience must enable **Game Settings > Security > Allow Mesh / Image
APIs**. If it is disabled, the thumbnail mode preserves the original character
and shows a specific warning instead of crashing. Published experiences also
need to satisfy Roblox's access requirements for `EditableImage`.

## Remaining animated path

Within current Roblox runtime capabilities, real-time pixel-perfect
rasterization of an arbitrary animated avatar is not available. The thumbnail
mode proves the visual language first; a true animated sprite result would
still require one of these approaches:
pre-rendered/uploaded images, an offline generation pipeline, or a manually
authored sprite system. The retro 3D mode remains the animated, fully in-Roblox
comparison fallback.
