param(
  [Parameter(Mandatory=$true)]
  [string]$ComfyRoot
)

$ErrorActionPreference = "Stop"
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  throw "Se necesita curl.exe para descargar los modelos."
}
$ComfyRoot = (Resolve-Path $ComfyRoot).Path
$Files = @(
  @{
    Path = Join-Path $ComfyRoot "models\text_encoders\qwen_3_4b.safetensors"
    Url = "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
  },
  @{
    Path = Join-Path $ComfyRoot "models\diffusion_models\flux-2-klein-4b-fp8.safetensors"
    Url = "https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8/resolve/main/flux-2-klein-4b-fp8.safetensors"
  },
  @{
    Path = Join-Path $ComfyRoot "models\vae\flux2-vae.safetensors"
    Url = "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
  },
  @{
    Path = Join-Path $ComfyRoot "models\checkpoints\PixelartSpritesheet_V.1.ckpt"
    Url = "https://huggingface.co/Onodofthenorth/SD_PixelArt_SpriteSheet_Generator/resolve/main/PixelartSpritesheet_V.1.ckpt"
  },
  @{
    Path = Join-Path $ComfyRoot "models\controlnet\control_v11p_sd15_openpose.pth"
    Url = "https://huggingface.co/lllyasviel/ControlNet-v1-1/resolve/main/control_v11p_sd15_openpose.pth"
  }
)

Write-Host "Los archivos son grandes. Revisa las licencias de sus páginas antes de continuar." -ForegroundColor Yellow
foreach ($File in $Files) {
  $Directory = Split-Path $File.Path
  $Partial = "$($File.Path).part"
  New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  if ((Test-Path $File.Path) -and ((Get-Item $File.Path).Length -gt 0)) {
    Write-Host "Ya existe: $($File.Path)" -ForegroundColor Green
    continue
  }
  Remove-Item $File.Path -Force -ErrorAction SilentlyContinue
  Write-Host "Descargando: $($File.Path)"
  & curl.exe -L --fail --retry 3 --retry-delay 2 --continue-at - --output $Partial $File.Url
  if ($LASTEXITCODE -ne 0) { throw "curl fallo al descargar $($File.Url)" }
  if (-not (Test-Path $Partial) -or (Get-Item $Partial).Length -le 0) {
    throw "La descarga quedo vacia: $($File.Url)"
  }
  Move-Item -Force $Partial $File.Path
}
Write-Host "Modelos preparados. Reinicia ComfyUI y ejecuta npm run doctor." -ForegroundColor Green
