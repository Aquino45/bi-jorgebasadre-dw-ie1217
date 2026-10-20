# Changelog

## v6.1 — 20/10/2026 (verificado)

Ajustes a la matriz v2.1 que hizo el equipo el 20/10/2026: Tiempo sin año escolar, el grupo «Cursos» (curso, competencia, tipo de competencia) en lugar de Área + Nivel de logro, y sin Motivo de rechazo.

### Cambiado
- `DimTiempo`: fecha, año, mes y bimestre. Salen `AnioEscolar` (era igual al año), `EsCierreBimestre` y `EsFilaEspecial` (las filas −1 y −2 se reconocen por la clave).
- `DimCompetencia` vuelve a una fila por competencia (28 + fila −1): curso (`AreaID`, `NombreArea`), tipo de competencia y competencia. El nivel de logro sale del modelo: ninguna pregunta de la Matriz BI lo pide y el origen solo trae la nota.
- `FacLogroCompetencia`: guarda la clave de la competencia; sin `EnInicioC`, `EnProcesoB`, `LogroEsperadoA`, `LogroDestacadoAD` ni `CompetenciaAprobada`. La escala C/B/A/AD queda solo en el 06, para traducir las 148 notas escritas en letra. `FechaCierreKey` es el último día del bimestre de la fecha informada.
- `FacPreparacion`: el grano suma el bimestre. `MesTiempoKey` pasa a `TramoTiempoKey` (primer día del mes dentro de su bimestre). Mayo de 2025 se parte en I y II Bimestre: 879 filas (549 + 330). Resuelve P1.
- `FacMatricula`: sin `MotivoKey`.

### Eliminado
- `DimMotivoRechazo` y `stg.MotivoRechazoCategoria` (el motivo literal sigue en `stg.Matricula.Observacion`).

### Migración
- El 03 detecta una base v6.0 y recrea una sola vez los hechos y las dimensiones.

### Verificado el 20/10/2026 (respaldo previo `DW_IE1217_pre_v6_1_20261020.bak`)
- 600 matrículas (579 / 21), ocupación 96,33 % / 96,67 %; 6 352 sesiones, 200 registros de material, % en horario 83,38 % / 83,41 %; 44 815 notas + 581 en bitácora (264, 198, 87, 32); 379 sin evidencia; 148 letras convertidas.
- Comparación contra el respaldo v6.0: 0 diferencias nota por nota (estudiante + competencia + bimestre); totales de sesiones, horario, minutos de retraso y materiales idénticos.
- 0 fechas de cierre distintas del cierre oficial; 0 FK entre dimensiones.

## v6.0 — 20/10/2026 (verificado)

Dimensiones según la matriz de métricas y dimensiones v2.1 del equipo: el DW guarda solo lo que responde las preguntas de la Matriz BI; el CSV completo sigue en staging.

### Cambiado
- `DimTiempo`: año, año escolar, mes, bimestre y fecha. El bimestre sale de las fechas oficiales de cierre y del inicio de clases (resuelve P1); se quitan día de la semana, día hábil y periodo escolar aproximado.
- `DimCompetencia` une competencia y nivel de logro: una fila por competencia × nivel (S/E, C, B, A, AD), 140 filas. La regla nota → nivel vive ahí.
- `DimEstudiante` (código, nombre, sexo, fecha de nacimiento), `DimDocente` (código, nombre, sexo, condición), `DimSeccion` (ciclo, grado, sección), `DimArea` (código, nombre), `DimTipoMatricula` (tipo, vía, fase, estado).
- `DimMotivoRechazo` guarda solo la categoría; el motivo textual queda en `stg.MotivoRechazoCategoria`.
- `FacLogroCompetencia`: sin `PeriodoKey`, `AreaKey` ni `EscalaKey`; una sola clave de competencia × nivel. Grano: estudiante + competencia + fecha de cierre del bimestre.
- 02: el día hábil se calcula y el periodo escolar sale del bimestre de `DimTiempo`.

### Eliminado
- `DimPeriodoAcademico` y `DimEscalaLogro`.

### Migración
- El 03 detecta una base v5.x y recrea una sola vez los hechos y las dimensiones; el 04, 05 y 06 los vuelven a cargar.

### Verificado el 20/10/2026 (respaldo previo `DW_IE1217_pre_v6_0_20261020.bak`)
- Sin cambio en cifras: 600 matrículas (579 aprobadas, 21 rechazadas); 769 filas de preparación y 6 352 sesiones; 44 815 notas + 581 en bitácora (264, 198, 87, 32); 379 sin evidencia.
- Niveles: C 7 040 · B 14 668 · A 17 707 · AD 5 021. Rechazadas por categoría: documentaria 12, fuera de cronograma 4, identidad 3, duplicidad en SIAGIE 2.
- 0 duplicados en el grano, 0 notas con nivel incoherente, 0 FK entre dimensiones.

## v5.2 — 13/10/2026 (verificado)

### Corregido
- `dw.DimCompetencia` ya no tiene `AreaKey` ni la FK a `dw.DimArea`. El modelo debe ser estrella (D21).
- 06: la validación «Competencia incompatible con área» compara `AreaID` en lugar de `AreaKey`.

### Cambiado
- Los scripts ya no llevan número de versión en el nombre (`03_dimensiones.sql`, etc.). La versión es la etiqueta.
- 07: el job apunta a los nombres nuevos.
- Se agregan README, CHANGELOG y la bitácora de contexto.

### Verificado el 13/10/2026
- 03 y 06 ejecutados sobre `DW_IE1217`: 28 competencias, 0 con área inexistente, 0 FK entre dimensiones.
- Sin cambio en cifras: 44 815 en el hecho + 581 en bitácora (87 incompatibles), 379 sin evidencia; 04 y 05 intactos (600 / 769).
- Job recreado con los nombres nuevos. Primera ejecución: lote 4 «Exitoso» (13/10/2026 13:45, 12 s) con 600 / 769 / 44 815 + 581.

## v5.1 — 24/09/2026 (verificado)

- Primera carga completa de 01 a 06 contra el origen.
- Cifras: 600 matrículas (579 aprobadas, 21 rechazadas); 769 filas de preparación y 6 352 sesiones válidas; 45 396 notas = 44 815 en el hecho + 581 en bitácora.
- Corrige los errores de la v5: truncado en `DimSeccion.Ciclo` (2628), `SUM` sobre BIT (8117) y códigos THROW repetidos entre 05 y 06.
