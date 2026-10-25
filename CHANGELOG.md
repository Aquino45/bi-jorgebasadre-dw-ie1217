# Changelog

## v6.5 — 25/10/2026 (verificado)

Dimensiones con los nombres y grupos de la matriz de métricas y dimensiones v2.2 (canon del equipo).

### Cambiado
- **`dw.DimCurso`** reemplaza a `DimArea` y `DimCompetencia` (grupo «Cursos»: Curso, Tipo de competencia, Competencia). Una fila por competencia (28) y una fila «Todo el curso» por curso (11), más la fila −1. `Curso` = `NombreArea` de areas_curriculares.csv; `CursoID` = `AreaID`. FacSesion y FacEntregaMaterial apuntan a la fila «Todo el curso»; FacLogroCompetencia, a la de su competencia. Un solo filtro de curso corta los tres hechos, sin relaciones entre dimensiones.
- **`dw.DimNivelAcademico`** reemplaza a `DimSeccion` (ciclo, grado y sección; sale `NombreGrado`).
- En los hechos: `SeccionKey` → `NivelAcademicoKey`; `AreaKey` y `CompetenciaKey` → `CursoKey`.

### Verificado el 25/10/2026 (respaldo previo `DW_IE1217_pre_v6_5_20261025.bak`)
- Comparación por claves naturales contra la v6.4: 0 diferencias en matrícula, sesiones, material y notas.
- DimCurso 40 filas (26 específicas, 2 transversales, 11 «No aplica», −1); DimNivelAcademico 11; 0 FK entre dimensiones; bitácora de notas 581.

## v6.4 — 25/10/2026 (verificado)

Preparación curricular se divide en dos hechos (sesiones y materiales), con las medidas que acordó el equipo; el DW sigue la matriz de métricas y dimensiones v2.2. Quedan cuatro hechos.

### Cambiado
- `dm_preparacion.FacPreparacion` pasa a llamarse **`FacSesion`** (asignación + mes + bimestre, 879 filas): `SesionesProgramadas`, `SesionesDictadasHorario`, `SesionesDictadasRetraso`, `IncidenciasProgramacion` (= reprogramadas + no dictadas, P16). Sale `MinutosRetraso` (no está en la lista) y el material.
- 07: el control de filas del job usa `FacSesion` y cuenta también `FacEntregaMaterial`.
- `FacLogroCompetencia`: `CompetenciasSinEvidencia` pasa a **`NotasConEvidencia`** (1 si la competencia tiene nota), como pide la matriz v2.2 («Notas con evidencia», base del rendimiento promedio). La competencia sin evidencia sigue con nota NULL, nunca 0.

### Agregado
- **`dm_preparacion.FacEntregaMaterial`** (asignación + año, 100 filas; `FechaProgramadaKey` = inicio de clases): `MaterialesPorEntregar`, `MaterialesEntregadosATiempo`. Fuera de plazo = por entregar − a tiempo, sin columna propia.

### En Power BI (no se guardan)
- % de cumplimiento de horarios y % de materiales a tiempo.
- Docentes con sesiones programadas, con retraso en horarios (menos del 80 % en horario en el mes, P4), con material por entregar y con entregas fuera de plazo (al menos un ejemplar tarde o no entregado, P14), y sus %.

### Verificado el 25/10/2026 (respaldo previo `DW_IE1217_pre_v6_4_20261025.bak`)
- 0 diferencias contra la v6.3 en sesiones programadas, en horario y material.
- 6 352 sesiones: en horario 3 110 / 2 187 (83,38 % / 83,41 %), con retraso 266 / 198, incidencias 329 / 228 (2025 / 2026). Docentes con retraso por mes: 2 a 6 de 15.
- Material: 2 890 / 2 900 ejemplares por entregar, 61,97 % / 70,28 % a tiempo; 9 docentes con material, los 9 con entregas fuera de plazo.
- Notas: 0 diferencias contra la v6.3; 44 815 notas, 44 436 con evidencia, 379 sin evidencia; rendimiento promedio 13,618.

## v6.3 — 23/10/2026 (verificado)

Una tabla de hechos por proceso (decisión del equipo): se deshace la separación de granos de la v6.2. Las medidas siguen siendo solo las «Script SQL» de la matriz.

### Cambiado
- `FacMatricula` (15 columnas): vuelven `CupoMaximoAula` y `VacantesOcupadas`. El cupo se repite en cada matrícula del aula: MAX por año + sección antes de sumar.
- `FacPreparacion` (11 columnas): vuelven `MaterialesProgramados` y `MaterialesEntregadosATiempo`, en la fila de marzo (inicio de clases); NULL en los demás meses.

### Eliminado
- `dm_matricula.FacCupoSeccion` y `dm_preparacion.FacEntregaMaterial` (el 04 y el 05 los borran si existen).

### Verificado el 23/10/2026 (respaldo previo `DW_IE1217_pre_v6_3_20261023.bak`)
- 0 diferencias fila por fila contra la v6.2 en matrícula, cupo, sesiones, material y notas.
- 600 matrículas (579 / 21), ocupación 96,33 % / 96,67 %; 879 filas de preparación (6 352 sesiones, 83,38 % / 83,41 % en horario; material a tiempo 61,97 % / 70,28 %); 44 815 notas + 581 en bitácora; 379 sin evidencia.

## v6.2 — 20/10/2026 (verificado)

Hechos según la matriz v2.1: cada hecho guarda solo las medidas marcadas «Script SQL», con los nombres del Excel; los % y promedios («Power BI») se calculan en el modelo. Se separan los dos granos que estaban mezclados (Kimball: un grano por hecho).

### Agregado
- `dm_matricula.FacCupoSeccion` (sección + año, 20 filas): cupo máximo por aula y vacantes ocupadas. `AnioTiempoKey` = 1 de enero del año escolar.
- `dm_preparacion.FacEntregaMaterial` (docente + área + sección + año, 100 filas): materiales programados y entregados a tiempo; `FechaProgramadaKey` = inicio de clases.

### Cambiado
- `FacMatricula` (22 → 13 columnas): `MatriculasSolicitadas`, `MatriculasValidadas`, `MatriculasRechazadas`, `DiasValidacion`; roles de fecha solicitud, revisión y SIAGIE. Salen solicitudes de vacante, días hasta SIAGIE, contadores de casos, vía corregida, fecha de carga, rol de asignación, aforo y vacantes ocupadas (pasan a FacCupoSeccion).
- `FacPreparacion` (42 → 9 columnas): `SesionesProgramadas`, `SesionesDictadasHorario`, `MinutosRetraso`, `IncidenciasProgramacion` (= reprogramadas, como dice la matriz). Sin año ni mes (salen de `TramoTiempoKey`) y sin material.
- `FacLogroCompetencia` (17 → 8 columnas): `NotaVigesimal` y `CompetenciasSinEvidencia`. Salen registradas/evaluadas (en Power BI: COUNTROWS y COUNT de la nota), marcas de corrección y año.
- Los controles de calidad (vías corregidas, horas, recursos, TIC, letras convertidas, redondeos…) se calculan y muestran en cada script; ya no se guardan.
- Cada script elimina y recrea su hecho si encuentra la estructura anterior.

### Verificado el 20/10/2026 (respaldo previo `DW_IE1217_pre_v6_2_20261020.bak`)
- Comparación fila por fila contra la v6.1: 0 diferencias en matrícula, cupo, sesiones, material y notas.
- 600 matrículas (579 / 21), ocupación 96,33 % / 96,67 %; 879 filas de sesiones (6 352 sesiones, 83,38 % / 83,41 % en horario); 100 asignaciones con material (61,97 % / 70,28 % a tiempo); 44 815 notas + 581 en bitácora; 379 sin evidencia.

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
