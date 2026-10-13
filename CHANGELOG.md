# Changelog

## v5.2 — 13/10/2026 (sin ejecutar todavía)

### Corregido
- `dw.DimCompetencia` ya no tiene `AreaKey` ni la FK a `dw.DimArea`. El modelo debe ser estrella (D21).
- 06: la validación «Competencia incompatible con área» compara `AreaID` en lugar de `AreaKey`.

### Cambiado
- Los scripts ya no llevan número de versión en el nombre (`03_dimensiones.sql`, etc.). La versión es la etiqueta.
- 07: el job apunta a los nombres nuevos.
- Se agregan README, CHANGELOG y la bitácora de contexto.

### Pendiente de verificar
- Re-ejecutar 03 y 06 sobre `DW_IE1217`. Esperado: 87 filas incompatibles sin cambio, 28 competencias, 0 con área inexistente.

## v5.1 — 24/09/2026 (verificado)

- Primera carga completa de 01 a 06 contra el origen.
- Cifras: 600 matrículas (579 aprobadas, 21 rechazadas); 769 filas de preparación y 6 352 sesiones válidas; 45 396 notas = 44 815 en el hecho + 581 en bitácora.
- Corrige los errores de la v5: truncado en `DimSeccion.Ciclo` (2628), `SUM` sobre BIT (8117) y códigos THROW repetidos entre 05 y 06.
