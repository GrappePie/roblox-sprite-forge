# Roblox Sprite Forge Local

Aplicación web local que recibe un **username, ID o URL de Roblox**, obtiene la miniatura y los objetos equipados del avatar público, y utiliza **ComfyUI, FLUX.2 Klein y plantillas de pose** para generar clips `idle` y `walk` de ocho direcciones con preview jugable.

- No usa `OPENAI_API_KEY`.
- No consume créditos por imagen.
- Todo el procesamiento generativo se realiza en tu propia computadora.
- Los pesos del modelo no se incluyen en el ZIP porque ocupan varios gigabytes.

## Qué genera

El número de frames por animación se puede ajustar a 2, 4, 6 u 8. Con el valor recomendado de 8, la hoja contiene 128 frames organizados en 16 filas: una fila `idle` y otra `walk` por dirección.

| Filas | Dirección | Clips |
|---|---|---|
| 1–2 | Frente / abajo | idle + walk |
| 3–4 | Frente-izquierda | idle + walk |
| 5–6 | Izquierda | idle + walk |
| 7–8 | Espalda-izquierda | idle + walk |
| 9–10 | Espalda / arriba | idle + walk |
| 11–12 | Espalda-derecha | idle + walk |
| 13–14 | Derecha | idle + walk |
| 15–16 | Frente-derecha | idle + walk |

Para eliminar cambios de diseño, FLUX crea primero un sprite canónico por dirección. Por defecto, idle aplica una respiración mínima y caminar mueve las piernas como capas rígidas con apoyo, elevación y cruce alternados; cabeza, cabello, torso, ropa y accesorios permanecen intactos. Ningún frame vuelve a sintetizar el personaje. El workflow SD PixelArt + ControlNet permanece disponible con `ANIMATION_ENGINE=controlnet` para experimentar, pero no es el modo recomendado porque puede rediseñar al personaje cuando el denoise es alto.

Cada trabajo guarda algo parecido a esto:

```text
data/generated/<job-id>/
├── reference.png
├── reference-transparent.png
├── sheet.png
├── preview.png
├── sheet.json
├── manifest.json
├── roblox-sprites.zip
├── job.json
├── frames/
│   └── 128 PNG individuales con la configuración recomendada
└── raw/                    # solo si KEEP_RAW_FRAMES=true
```

## Requisitos

- Windows 10/11 o Linux.
- Node.js 20.11 o superior.
- ComfyUI actualizado y ejecutándose localmente.
- Una GPU NVIDIA con suficiente VRAM para la configuración elegida.
- Espacio libre para los cinco archivos de modelo (aproximadamente 15 GB en total).

La configuración inicial usa 512 × 512 para reducir el consumo de VRAM. En una RTX 5070 de escritorio puedes subir a 768 × 768 desde la interfaz para obtener más detalle.

## 1. Preparar ComfyUI

Instala o actualiza ComfyUI:

- https://www.comfy.org/download
- https://docs.comfy.org/installation/update_comfyui

En ComfyUI, abre **Workflow Templates** y busca:

```text
Flux.2 Klein 4B Distilled: Image Edit
```

La plantilla oficial utiliza estos archivos:

```text
ComfyUI/
└── models/
    ├── checkpoints/PixelartSpritesheet_V.1.ckpt
    ├── controlnet/control_v11p_sd15_openpose.pth
    ├── diffusion_models/
    │   └── flux-2-klein-4b-fp8.safetensors
    ├── text_encoders/
    │   └── qwen_3_4b.safetensors
    └── vae/
        └── flux2-vae.safetensors
```

Guía y plantilla oficiales:

- https://docs.comfy.org/tutorials/flux/flux-2-klein
- https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_flux2_klein_image_edit_4b_distilled.json

También se incluyen scripts opcionales de descarga. Revisa primero las licencias y condiciones de las páginas de cada modelo. Si Hugging Face solicita aceptar condiciones o iniciar sesión, usa la plantilla de ComfyUI o descarga el archivo manualmente desde el navegador.

### Windows PowerShell

```powershell
.\scripts\download-models.ps1 -ComfyRoot "C:\ComfyUI_windows_portable\ComfyUI"
```

### Linux

```bash
./scripts/download-models.sh /ruta/a/ComfyUI
```

Después reinicia ComfyUI y confirma que abra en:

```text
http://127.0.0.1:8188
```

## 2. Instalar el proyecto

Descomprime el ZIP y abre una terminal dentro de la carpeta.

```bash
npm ci
```

Copia la configuración:

**Windows**

```bat
copy .env.example .env
```

**Linux**

```bash
cp .env.example .env
```

Los nombres del `.env` deben coincidir exactamente con los archivos dentro de `ComfyUI/models`:

```dotenv
COMFYUI_URL=http://127.0.0.1:8188
COMFYUI_UNET=flux-2-klein-4b-fp8.safetensors
COMFYUI_TEXT_ENCODER=qwen_3_4b.safetensors
COMFYUI_VAE=flux2-vae.safetensors
COMFYUI_ANIMATION_CHECKPOINT=PixelartSpritesheet_V.1.ckpt
COMFYUI_ANIMATION_CONTROLNET=control_v11p_sd15_openpose.pth
```

## 3. Verificar ComfyUI

Con ComfyUI abierto:

```bash
npm run doctor
```

El diagnóstico comprueba:

- Conexión con ComfyUI.
- Presencia de los nodos utilizados por el workflow.
- Nombres de los cinco modelos configurados.
- GPU y VRAM informadas por ComfyUI, cuando están disponibles.

## 4. Iniciar la aplicación

```bash
npm start
```

Abre:

```text
http://127.0.0.1:3000
```

En Windows también puedes ejecutar:

```text
scripts\start-windows.bat
```

## Entradas aceptadas

```text
@YukiManju
YukiManju
1021056267
https://www.roblox.com/users/1021056267/profile
```

## Flujo interno

```text
username / ID
      ↓
APIs públicas de Roblox
      ↓
miniatura + datos del avatar
      ↓
8 sprites canónicos, uno por dirección, con FLUX.2
      ↓
plantillas idle/walk + locomoción determinista por capas
      ↓
eliminación automática del chroma
      ↓
recorte, línea base, reducción de paleta
      ↓
sheet.png + frames + atlas JSON + ZIP
```

La comunicación con ComfyUI usa las rutas locales:

```text
/upload/image
/prompt
/history/{prompt_id}
/view
/interrupt
```

El workflow incluido usa únicamente nodos del núcleo de ComfyUI; no requiere custom nodes.

## Ajustes recomendados

### RTX 5070 de escritorio

```text
Resolución IA: 768 × 768
Pasos: 4
Frame final: 64 × 64
Paleta: 64 colores
```

### Menos VRAM o RTX 5070 Laptop

```text
Resolución IA: 512 × 512
Pasos: 4
Frame final: 48 × 48 o 64 × 64
Paleta: 32 o 48 colores
```

### Más detalle

```text
Resolución IA: 1024 × 1024
Pasos: 6 u 8
Frame final: 96 × 96
```

Más pasos no garantizan más consistencia; el modelo destilado está pensado para trabajar con pocos pasos.

## Formato del atlas

`sheet.json` usa una estructura similar a TexturePacker:

```js
const atlas = await fetch("sheet.json").then((response) => response.json());
const idleDown = atlas.frames["down_idle_1.png"].frame;
```

`manifest.json` contiene una estructura sencilla para motores propios:

```json
{
  "animations": {
    "down_idle": ["down_idle_1", "down_idle_2", "down_idle_3", "down_idle_4"],
    "down_walk": ["down_walk_1", "down_walk_2", "down_walk_3", "down_walk_4"]
  }
}
```

## API local

```text
GET  /api/health
POST /api/avatar
GET  /api/jobs
POST /api/jobs
GET  /api/jobs/:id
POST /api/jobs/:id/cancel
GET  /outputs/:job-id/...
```

Ejemplo:

```bash
curl -X POST http://127.0.0.1:3000/api/jobs \
  -H "content-type: application/json" \
  -d '{
    "source": "@YukiManju",
    "cellSize": 64,
    "renderResolution": 512,
    "style": "handheld",
    "steps": 4,
    "paletteColors": 64
  }'
```

## Comandos útiles

```bash
npm run doctor   # revisa ComfyUI y los modelos
npm run studio:build    # compacta el atlas actual para Roblox Studio
npm run studio:install  # instala o actualiza el prototipo en el place conectado
npm run check    # comprueba sintaxis JavaScript
npm test         # ejecuta pruebas unitarias
npm run verify   # check + tests
npm run dev      # servidor con reinicio automático
```

## Prototipo jugable en Roblox Studio

El prototipo de `studio-prototype/` conserva el `Humanoid` y
`HumanoidRootPart` reales para controles, cámara, colisiones y replicación. El
cliente oculta únicamente la representación 3D del avatar registrado y muestra
el atlas pixel en un `BillboardGui`, seleccionando `idle` o `walk` y una de ocho
direcciones según `Humanoid.MoveDirection` y la cámara.

Mientras Sprite Forge, ComfyUI y el puente MCP de Studio estén abiertos, el
prototipo también sigue la apariencia pública del jugador automáticamente:

1. Calcula una huella estable con los accesorios, partes del cuerpo, colores y
   escalas equipados.
2. Reutiliza un set compatible si esa misma apariencia ya fue generada.
3. Si la huella cambió, captura el rig real desde ocho cámaras y genera un set
   nuevo de `idle` y `walk`.
4. Conserva el avatar 3D visible durante la espera y solo lo sustituye cuando
   Studio recibe el atlas que corresponde a la huella actual.

La captura usa un escenario de chroma **mate** (`SmoothPlastic`), iluminación
neutral sin postefectos y PNG sin pérdida. Las ocho vistas se pixelan
directamente desde el mismo rig y comparten una sola paleta; la IA no vuelve a
inventar un personaje independiente para cada dirección.

El transporte local predeterminado es
`ReplicatedStorage.SpriteForgeRuntime.DynamicAtlasTransport = "mcp"`. Por eso
no es necesario activar **Permitir las solicitudes HTTP** para probarlo en
Studio. Esta automatización es un flujo local de desarrollo; un servidor
publicado de Roblox no puede conectarse al MCP ni al ComfyUI de esta PC.

La configuración predeterminada no necesita activar **Permitir API de
malla/imagen**: reutiliza un pool de tramos horizontales de píxeles. Si esa API
se habilita más adelante, el atributo
`ReplicatedStorage.SpriteForgeRuntime.UseEditableImage` permite cambiar al modo
de una sola `EditableImage`.

## Estado de verificación

El proyecto se instaló desde una copia limpia y pasa `npm run verify`, incluidas
pruebas de integración simulada de ComfyUI, huella de apariencia, caché del
atlas dinámico y postprocesado/ZIP. Consulta
[`docs/VERIFICATION.md`](docs/VERIFICATION.md) para el detalle y el límite de
la prueba automatizada: la generación real también se valida en la computadora
que tenga ComfyUI, Roblox Studio y la GPU.

## Solución de problemas

### `ComfyUI desconectado`

Abre ComfyUI y verifica `http://127.0.0.1:8188`. Si usas otro puerto, cambia `COMFYUI_URL` en `.env`.

### Modelo faltante

El nombre configurado debe coincidir exactamente con el archivo dentro de `ComfyUI/models`. Ejecuta `npm run doctor` para ver cuál falta.

### Nodo faltante

Actualiza ComfyUI. El proyecto necesita, entre otros, `Flux2Scheduler`, `EmptyFlux2LatentImage` y `ReferenceLatent`.

### Memoria insuficiente

- Cambia la resolución a 512 × 512.
- Cierra aplicaciones que usen VRAM.
- Mantén cuatro pasos.
- Evita ejecutar otro workflow de ComfyUI al mismo tiempo.

### El fondo no se elimina bien

El programa elige un chroma que intenta evitar los colores del avatar y también detecta el color real dominante de los bordes. Si aún falla, prueba otra semilla o añade una indicación como:

```text
Keep the entire character far from every canvas edge and use a perfectly uniform background.
```

### Un accesorio cambia entre frames

Esto es una limitación normal de la generación de imágenes. Prueba:

- Una semilla distinta.
- Una resolución mayor.
- Una nota explícita describiendo el accesorio importante.
- Editar manualmente uno o dos frames finales en Aseprite.

## Seguridad y privacidad

- El servidor escucha en `127.0.0.1` por defecto.
- No almacena claves de OpenAI ni de Roblox.
- Solo consulta datos públicos del avatar.
- La descarga de miniaturas se limita a dominios de Roblox.
- Los resultados se borran después del periodo configurado con `JOB_RETENTION_HOURS`.

## Licencias

El código de este proyecto usa MIT. ComfyUI, FLUX.2 Klein, SD PixelArt SpriteSheet Generator, ControlNet, el encoder de texto y los VAE tienen sus propias licencias. Universal LPC mezcla licencias por recurso; conserva los créditos y revisa cada pieza antes de usarla como dataset o redistribuirla.
