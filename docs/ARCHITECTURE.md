# Arquitectura

## Componentes

```text
Browser
  │ JSON / PNG
  ▼
Node.js + Express
  ├── Roblox client
  ├── Job queue (concurrency = 1)
  ├── ComfyUI client
  └── Sharp post-processing
          │
          ▼
      ComfyUI local
          │
          ▼
    FLUX.2 Klein 4B
```

## Decisiones principales

### Un frame por workflow

Pedir una cuadrícula completa en una sola imagen suele producir tamaños y diseños inconsistentes. El proyecto genera cada celda por separado.

### Maestro por dirección

Cada dirección usa dos filas: `idle` y `walk`. El primer idle se genera desde el avatar de Roblox y actúa como maestro. Los frames posteriores se generan secuencialmente desde el frame inmediatamente anterior; `walk` comienza desde el maestro y luego también se encadena. Esto conserva el estilo, la vista y la continuidad de movimiento, incluidas las cuatro diagonales.

### Chroma dinámico

Se elige uno de cinco colores según su distancia con los píxeles visibles del avatar. Después de generar, el postprocesado detecta el color dominante real del borde y hace flood fill para producir transparencia.

### Línea base determinista

Sharp recorta cada personaje, lo escala con vecino más cercano y alinea los pies en la parte inferior de una celda fija. Esto evita saltos producidos únicamente por cambios de encuadre.

## Módulos

- `src/lib/roblox.js`: resolución de username, perfil, avatar y miniatura.
- `src/lib/comfy.js`: diagnóstico, carga de referencias, cola de prompt, polling y descarga.
- `src/lib/workflow.js`: grafo API de FLUX.2 Klein.
- `src/lib/prompt.js`: vistas, clips, fases de animación, guardas de accesorios y prompts.
- `src/lib/postprocess.js`: chroma, recorte, cuantización y atlas.
- `src/lib/jobs.js`: cola, persistencia, cancelación y empaquetado.
- `src/server.js`: API HTTP y frontend.
