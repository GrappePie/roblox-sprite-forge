#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Uso: ./scripts/download-models.sh /ruta/a/ComfyUI"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Se necesita curl para descargar los modelos."
  exit 1
fi

COMFY_ROOT="$(cd "$1" && pwd)"
echo "Los archivos son grandes. Revisa las licencias de sus páginas antes de continuar."

download() {
  local url="$1"
  local target="$2"
  local partial="${target}.part"
  mkdir -p "$(dirname "$target")"
  if [[ -s "$target" ]]; then
    echo "Ya existe: $target"
    return
  fi
  rm -f "$target"
  echo "Descargando: $target"
  curl -L --fail --retry 3 --retry-delay 2 --continue-at - --output "$partial" "$url"
  if [[ ! -s "$partial" ]]; then
    echo "La descarga quedó vacía: $url" >&2
    exit 1
  fi
  mv -f "$partial" "$target"
}

download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" "$COMFY_ROOT/models/text_encoders/qwen_3_4b.safetensors"
download "https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8/resolve/main/flux-2-klein-4b-fp8.safetensors" "$COMFY_ROOT/models/diffusion_models/flux-2-klein-4b-fp8.safetensors"
download "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors" "$COMFY_ROOT/models/vae/flux2-vae.safetensors"
download "https://huggingface.co/Onodofthenorth/SD_PixelArt_SpriteSheet_Generator/resolve/main/PixelartSpritesheet_V.1.ckpt" "$COMFY_ROOT/models/checkpoints/PixelartSpritesheet_V.1.ckpt"
download "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth" "$COMFY_ROOT/models/controlnet/control_v11p_sd15_openpose.pth"

echo "Modelos preparados. Reinicia ComfyUI y ejecuta npm run doctor."
