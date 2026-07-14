# Verificación del proyecto

Fecha: 2026-07-13

Se comprobó el paquete desde una copia limpia, sin `node_modules` preinstalado:

```bash
npm ci
npm run verify
npm audit --omit=dev
```

Resultados:

- Instalación limpia completada correctamente.
- 22 archivos JavaScript pasaron la comprobación de sintaxis.
- 11 módulos internos pasaron la comprobación de importaciones.
- 17 pruebas automatizadas aprobadas; 0 fallos.
- La integración simulada de ComfyUI cubrió diagnóstico, subida de referencia, envío del workflow, consulta del historial, descarga del resultado e interrupción.
- El procesamiento de imagen cubrió eliminación de chroma, transparencia, recorte, alineación, celdas, hoja configurable de 16 filas, clips idle/walk, atlas de ocho direcciones y ZIP.
- `npm audit --omit=dev`: 0 vulnerabilidades conocidas en ese momento.

## Límite de esta verificación

Una validación completa requiere generar los clips configurados con una RTX y los pesos de FLUX.2 Klein. El primer paso en la computadora de destino debe ser:

```bash
npm run doctor
```

Después conviene generar primero un trabajo de prueba a 512 × 512 y cuatro pasos.
