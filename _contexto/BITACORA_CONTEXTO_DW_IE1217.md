# Bitácora de contexto — Data Warehouse I.E.P. N° 1217 "Jorge Basadre Grohmann"

**Curso:** Business Intelligence · Ingeniería de Sistemas · UPeU
**Cliente:** I.E.P. N° 1217 "Jorge Basadre Grohmann" · Chaclacayo · UGEL 06
**Versión vigente del ETL:** v5.2, publicada como etiqueta en Git (03, 06 y 07 corregidos el 13/10/2026 · 01, 02, 04 y 05 sin cambios desde v5.1)
**Última actualización de esta bitácora:** 13/10/2026
**Carga verificada en SQL Server:** 24/09/2026

> **Para qué sirve este documento.** Retomar el proyecto en cualquier momento (personas o Claude) sin reconstruir la historia: qué existe, qué se verificó, qué se decidió y por qué, qué cambió entre versiones y qué falta decidir.
>
> **Convención de estados usada en todo el documento:**
> - ✅ **Verificado** — ejecutado en SQL Server y comprobado con cifras.
> - 🟦 **Implementado** — existe en los scripts, pero falta una comprobación final.
> - 🟨 **Propuesto** — diseñado o recomendado, aún no implementado ni aprobado.
> - ⏳ **Pendiente de decisión** — requiere acuerdo del equipo o del cliente.
> - ⛔ **No medible** — la fuente no trae el dato; no se debe inventar.

---

## 1. Resumen ejecutivo

| Tema | Estado |
|---|---|
| ETL 01→06 v5.1 (staging, diagnóstico, dimensiones, tres hechos) | ✅ Ejecutado de punta a punta y cuadrado con el origen |
| Tres datamarts (matrícula, preparación, aprendizajes) | ✅ Cargados en `DW_IE1217` |
| Guía de lectura y sustentación v5.1 (Word) | ✅ Entregada, con cifras verificadas |
| Script 07: control de lotes + job de SQL Server Agent | ✅ Job creado (10 pasos verificados) · 🟦 primera ejecución del job pendiente de reportar |
| Script 08: calendario de cargas por proceso | 🟨 Diseño propuesto, esperando confirmar ventanas y frecuencias |
| Catálogo métricas → indicadores → KPI (`Metricas_KPI_DW_IE1217.xlsx`) | ✅ Entregado (42 filas: 22 métricas cargadas en los scripts, 20 indicadores/KPI planificados para Power BI) |
| Capa de KPI en Power BI (DAX) | 🟨 Siguiente fase; criterio aprobado por el ingeniero |
| Matriz bus (hoja V1) y mapeo (Hoja 5) del Excel | ⏳ Desactualizados respecto del modelo; hay que reescribirlos |
| Definiciones de KPI ambiguas (validada, pendientes, docente con retraso, estudiante aprobado) | ⏳ Pendientes de acuerdo |

**Idea central para la sustentación:** el DW entrega **métricas atómicas y verificadas**; los **indicadores y KPI** se construyen en el modelo semántico de Power BI. Si el colegio redefine un KPI, se ajusta una medida DAX sin recargar datos.

---

## 2. Alcance

### 2.1 Dentro del alcance

| N° | Proceso del mapa | Datamart | Hecho |
|---|---|---|---|
| 1.0 | Gestionar la matrícula (y vacantes) | `dm_matricula` | `FacMatricula` |
| 2.0 | Preparar las condiciones para la gestión de los aprendizajes (sesiones + materiales) | `dm_preparacion` | `FacPreparacion` |
| 4.0 | Gestionar los aprendizajes | `dm_aprendizajes` | `FacLogroCompetencia` |

### 2.2 Fuera del alcance

- **3.0 Desempeño docente** y **5.0 Convivencia escolar**: sus CSV (`MonitoreoDocente`, `Convivencia`) **entran a staging**, pero **no tienen datamart**. No se proponen KPI de estos procesos salvo pedido expreso.
- Observación para el futuro: los datos de monitoreo docente (rúbricas) no coinciden con las métricas que la matriz pide para 3.0 (unidades planificadas/ejecutadas, horas de refuerzo). Si algún día se amplía el alcance, habría que conseguir otra fuente.

---

## 3. Entorno técnico

| Elemento | Valor |
|---|---|
| Motor | SQL Server 2025 (17.0.1135.8), instancia `localhost` |
| Herramienta | SSMS (con IntelliSense y GitHub Copilot visibles) |
| Inicio de sesión usado | `sa` (autenticación SQL) |
| Logins existentes | `sa` y la cuenta de Windows del equipo de desarrollo (ninguno del colegio; no borrar ninguno) |
| Base del proyecto | `DW_IE1217` |
| Otra base | `pruebas` (de la prueba de instalación; prescindible) |
| Carpeta de datos | `C:\BI_IE1217\data` (17 CSV + `_catalogo_defectos.csv`) |
| Carpeta de scripts (para el job) | `C:\BI_IE1217\scripts` |
| Carpeta de logs (para el job) | `C:\BI_IE1217\logs` |
| SQL Server Agent | Aparecía como «Agent XPs deshabilitado» (servicio detenido); hay que iniciarlo en modo Automático |
| Codificación de scripts | UTF-8 **con BOM** (para que SSMS y sqlcmd lean bien la ñ) |

---

## 4. Arquitectura del modelo (v5.1)

### 4.1 Capas y esquemas

| Esquema | Rol | Contenido |
|---|---|---|
| `stg` | Aterrizaje: el dato tal como llegó, para auditar | 17 tablas crudas (casi todo `NVARCHAR`) + `stg.BitacoraNota` (la crea el 06) |
| `dw` | Dimensiones **conformadas** compartidas | 10 dimensiones |
| `dm_matricula` | Datamart 1.0 | `FacMatricula` |
| `dm_preparacion` | Datamart 2.0 | `FacPreparacion` |
| `dm_aprendizajes` | Datamart 4.0 | `FacLogroCompetencia` |
| `ctl` | Control de lotes del job (script 07) | `LoteETL`, `ConteoLote`, `vw_HistorialLotes`, procedimientos |

**Por qué un solo DW con esquemas y no tres bases:** arquitectura en bus de Kimball. Los datamarts comparten dimensiones conformadas; «el estudiante 60» es la misma fila en matrícula y en aprendizajes. Tres copias de `DimEstudiante` podrían desincronizarse. Si se pide que cada datamart sea autocontenido, se pueden crear **vistas** por esquema (`dm_matricula.DimEstudiante` → `dw.DimEstudiante`) sin duplicar datos. 🟨 (opcional, no implementado)

### 4.2 Scripts y orden de ejecución

| Paso | Archivo | Qué hace | Reejecución |
|---|---|---|---|
| 01 | `01_staging.sql` | Crea `DW_IE1217` (si no existe) y `stg`; borra y recarga las 17 tablas con BULK INSERT (`;`, UTF-8, LF) | Recarga total de staging |
| 02 | `02_diagnostico.sql` | Perfila la suciedad del origen. **No corrige nada.** | Libre |
| 03 | `03_dimensiones.sql` | Crea y carga las 10 dimensiones con MERGE / INSERT condicional (v5.2: `DimCompetencia` sin `AreaKey`, D21) | No borra dimensiones; actualiza |
| 04 | `04_fac_matricula.sql` | Carga `FacMatricula` (DELETE + INSERT en transacción) | Recarga total del hecho |
| 05 | `05_fac_preparacion.sql` | Carga `FacPreparacion` | Recarga total del hecho |
| 06 | `06_fac_aprendizajes.sql` | Carga `FacLogroCompetencia` y `stg.BitacoraNota` (v5.2: compara área por `AreaID`) | Recarga total del hecho y la bitácora |
| 07 | `07_job_sql_agent.sql` | Control de lotes (`ctl`) + job `ETL_IE1217_Carga` (apunta a 03 y 06 v5.2) | Idempotente (borra y recrea el job) |

Flujo en una línea: **copiar → revisar → hacer catálogos → llenar los tres archivadores**. La parte común (01, 02, 03) se hace una vez y luego hay **un script por hecho**; los tres hechos son independientes entre sí y solo comparten las dimensiones.

### 4.3 Dimensiones (`dw`)

| Dimensión | Nota de diseño |
|---|---|
| `DimTiempo` | Calendario 2024–2027 + filas especiales **-1 = no aplica** y **-2 = no registrado**. Su columna `Bimestre` se **aproxima por mes** (ver decisión pendiente P1). |
| `DimEstudiante` | **SCD tipo 1** (reemplaza atributos, sin historial). 373 alumnos + fila -1. Guarda `FechaNacimiento`; la edad se deriva. |
| `DimDocente` | Códigos limpios. No carga `FechaNacimiento` aunque `stg.Docente` la trae. |
| `DimSeccion` | 1A … 5B, **sin año** en su identidad (10 + fila -1 = 11 filas). El aforo anual se guarda en el hecho. |
| `DimArea` | Equivale a «Curso» en la matriz. |
| `DimCompetencia` | Competencias por área. **Sin FK a `DimArea` desde v5.2 (D21):** el área va desnormalizada en `AreaID` y `NombreArea`. |
| `DimPeriodoAcademico` | Año-bimestre con **fechas oficiales de cierre**: 2025 → 23/05, 01/08, 24/10, 19/12; 2026 → 22/05, 31/07; 2026-III sin fecha (abierto al corte 15/09/2026). |
| `DimEscalaLogro` | Vigesimal → letra: C 0–10, B 11–13, A 14–17, AD 18–20; fila -1 = sin evidencia. |
| `DimTipoMatricula` | Dimensión **chatarra**: tipo + vía + fase + estado. Desde v5.1 usa la **vía corregida**. |
| `DimMotivoRechazo` | Motivo y categoría del rechazo. |

### 4.4 Hechos y granos

| Hecho | Grano | Medidas principales |
|---|---|---|
| `FacMatricula` | **Estudiante + año escolar** (con sección del año). 4 roles de fecha contra `DimTiempo`: solicitud, revisión, asignación, SIAGIE. | `MatriculasRegistradas`, `SolicitudesVacante`, `MatriculasAprobadas`, `MatriculasRechazadas`, `VacantesOcupadas`, `DiasValidacion`, `CasosConValidacion`, `DiasHastaSiagie`, `CasosConDiasHastaSiagie`, `AforoSeccionSnapshot`, `ViaCorregida` |
| `FacPreparacion` | **Docente + área + sección + año + mes** | Sesiones programadas / dictadas / en horario, minutos de retraso, reprogramadas, recursos, TIC; materiales por entregar / a tiempo / tarde / no entregados, textos, cuadernos, registros, recibidos 14 días antes, recepción sin fecha |
| `FacLogroCompetencia` | **Estudiante + competencia + bimestre** | `NotaVigesimal` (NULL si sin evidencia), `EscalaKey`, `CompetenciasRegistradas`, `EvaluadaConEvidencia`, `SinEvidencia`, `EnInicioC`, `EnProcesoB`, `LogroEsperadoA`, `LogroDestacadoAD`, `CompetenciaAprobada` (a nivel competencia), `NotaDesdeLetra`, `NotaRedondeada`, `BimestreCorregido`, `CompetenciaCorregida`, `DocenteCorregido` |

**Regla de oro de conteo:** personas con `DISTINCTCOUNT(EstudianteKey)`, nunca filas de competencia; aforo con `MAX` por año + sección antes de sumar; nunca mezclar NULL con 0.

---

## 5. Cifras verificadas (ejecución del 24/09/2026)

> No cambiar estas cifras sin una nueva ejecución.

### 5.1 Staging (01)
- 17 tablas en OK · **145 305 filas** (sin cabeceras).
- Ejemplos: `estudiantes.csv` 379 · `matricula.csv` 615 · `sesiones.csv` 6 425 · `entrega_materiales.csv` 200 · `notas_competencias.csv` 45 396.

### 5.2 Dimensiones (03)
- `DimEstudiante`: 373 + fila -1 · `DimSeccion`: 11 filas (10 + -1) · pruebas de limpieza en cero.

### 5.3 Matrícula (04)

| Año | Matrículas | Solicitudes de vacante | Aprobadas | Rechazadas | Vacantes | Ocupación | Días validación |
|---|---|---|---|---|---|---|---|
| 2025 | 300 | 76 | 289 | 11 | 300 | 96,33 % | 18,43 |
| 2026 | 300 | 76 | 290 | 10 | 300 | 96,67 % | 11,06 |

- 615 − 9 duplicadas − 6 sin padrón = **600** · 579 aprobadas · 21 rechazadas.
- 224 ratificaciones por año con fecha de solicitud en **-1 (no aplica)**.
- 300 vacantes = 10 aulas × 30.
- SIAGIE sin registro: 2025 = 11 rechazadas + 3 aprobadas con fecha inválida; 2026 = 10 + 6.
- Días de validación coherentes con el cronograma oficial (2025: 16/12/2024 → 17/01/2025 ≈ 18 días; 2026 más corto ≈ 11).

### 5.4 Preparación (05)

| Año | Filas | Sesiones | En horario | % horario | Reg. material | Por entregar | A tiempo |
|---|---|---|---|---|---|---|---|
| 2025 | 439 | 3 730 | 3 110 | 83,38 % | 100 | 2 890 | 1 791 |
| 2026 | 330 | 2 622 | 2 187 | 83,41 % | 100 | 2 900 | 2 038 |

- **769 filas** · 6 425 − 45 `-DUP` − 28 sin sección (`9Z`) = **6 352 sesiones válidas** · 0 fechas de sesión inválidas.
- **21 cantidades «a tiempo» reconstruidas** · **6 docentes corregidos** por carga horaria.
- 110 filas por mes = 110 asignaciones de carga horaria por año.
- Inicio de clases (fecha mayoritaria): **17/03/2025** y **16/03/2026**.

### 5.5 Aprendizajes (06)
- Reconciliación: **45 396 = 44 815 (hecho) + 581 (bitácora)**.
- Bitácora: duplicado en el grano 264 · nota inexistente o fuera de rango 198 · competencia incompatible con área 87 · competencia desconocida 32.
- Ningún «estudiante fuera del padrón», «sin matrícula aprobada» ni «periodo desconocido».
- **379 sin evidencia** (el catálogo de defectos decía 380; uno menos tras deduplicar, como se anticipaba).
- 6 periodos con notas (2025 B1–B4, 2026 B1–B2).

| Año | Bim. | Registradas | Evaluadas | Sin evid. | Letras conv. | Redondeadas | Promedio |
|---|---|---|---|---|---|---|---|
| 2025 | 1 | 7 466 | 7 401 | 65 | 39 | 47 | 13,26 |
| 2025 | 2 | 7 457 | 7 404 | 53 | 26 | 34 | 13,53 |
| 2025 | 3 | 7 457 | 7 400 | 57 | 16 | 34 | 13,72 |
| 2025 | 4 | 7 452 | 7 383 | 69 | 24 | 33 | 13,97 |
| 2026 | 1 | 7 498 | 7 449 | 49 | 17 | 43 | 13,50 |
| 2026 | 2 | 7 485 | 7 399 | 86 | 26 | 41 | 13,73 |

### 5.6 Automatización (07)
- ✅ Job `ETL_IE1217_Carga` creado con 10 pasos y su flujo de éxito/fallo comprobado en `msdb`.
- 🟦 Primera ejecución con `sp_start_job` y lote «Exitoso» en `ctl.vw_HistorialLotes`: **pendiente de reportar**.

---

## 6. Bitácora cronológica de cambios

### 6.1 Antes de la v5 (contexto)
- Se partió de un diseño de cinco procesos con cinco hechos y una bitácora general `stg.RechazosCalidad`.
- Se redujo el alcance a **tres datamarts con un hecho cada uno** (1.0, 2.0, 4.0). La v5 conservó la bitácora persistente solo para notas (`stg.BitacoraNota`).

### 6.2 Versión 5 (24/09/2026, guía PDF original)
- Seis scripts 01–06, guía de lectura en PDF (15 páginas) con cifras «esperadas» pendientes de comprobar.
- Errores encontrados al ejecutarla: truncado en `DimSeccion.Ciclo` (2628) y `SUM` sobre BIT en el 04 (8117).

### 6.3 Auditoría y versión 5.1

| Script | Cambio | Motivo | ¿Cambia datos? |
|---|---|---|---|
| 01 | Encabezado: 17 CSV (decía 15) y explicación de la escala de notas | Comentarios desactualizados; la escala contradecía el modelo | No |
| 02 | Conteo de espacios al final con `DATALENGTH` | Con `<>` SQL Server ignora el espacio final: el conteo salía siempre 0 | Solo el diagnóstico |
| 02 | Nota corregida sobre espacios y JOIN | El espacio final normal no rompe `=` en SQL Server; sí el inicial, el tabulador y U+00A0 (y en Power BI sí importa) | No |
| 03 | `DimSeccion.Ciclo` a `NVARCHAR(20)` + `ALTER` automático si la tabla ya existe | «No definido» (11 caracteres) no cabía en 10 → error 2628 | No (solo permite cargar la fila -1) |
| 03 | `DimTipoMatricula` con **vía corregida** por tipo de estudiante | El 04 busca la combinación corregida; con la vía cruda podía no existir → THROW 51004 | Sí (combinaciones) |
| 03 | Padrón duplicado: se queda la **fila más completa** con desempate fijo | `FechaCarga` es igual para todo el BULK INSERT: la elección era al azar | Sí (atributos de 6 alumnos) |
| 03 | DNI con más de 8 dígitos se conserva y se marca inválido | Antes se recortaba a 8 y quedaba como válido | Sí (marca) |
| 03 | «Ã±» → **ñ** (antes «n») en apellidos y nombres | Unificar «Muñoz»/«Munoz» | Sí (texto) |
| 04, 05, 06 | `DROP TABLE IF EXISTS` de las `#temporales` al iniciar | Reejecutar en la misma pestaña fallaba con «There is already an object named #…» | No |
| 04 | El detalle del THROW 51004 muestra también fechas fuera de `DimTiempo` | Antes el error podía quedar sin causa visible | No |
| 05 | THROW renumerados: 51060 → 51049, 51061 → 51050 (rango 51049–51059) | Chocaban con los códigos del 06 | No |
| 06 | Nota **vacía (NULL)** = sin evidencia | BULK INSERT guarda la celda vacía como NULL y el 06 solo reconocía `''`: iban a la bitácora | Sí (reparto hecho / bitácora) |
| 06 | Comparación **binaria** del código de competencia | Con intercalación CI, «cp-05» pasaba como literal; se resolvía mal el desempate de duplicados | Sí (marca y desempate) |
| 04, 06 | **v5.1b:** `SUM(CAST(col AS INT))` sobre columnas BIT (`ViaCorregida`, `NotaDesdeLetra`, `NotaRedondeada`) | Error 8117 de compilación: el lote entero no se ejecutaba | No |
| Todos | Guardados en UTF-8 con BOM | Lectura correcta de la ñ en SSMS y sqlcmd | No |

**Dudas de la primera revisión que resultaron ya resueltas en la v5:** la bandera `NotaDesdeLetra` ya existía; el 05 ya une las combinaciones de sesiones y materiales antes del LEFT JOIN (no se pierde material); el 04 ya manda la fecha SIAGIE de los rechazados a -2.

### 6.4 Reinstalación desde cero
- Se borró `DW_IE1217` y se volvió a cargar todo con la v5.1. Se confirmó que no existía ningún login del colegio (solo `sa` y la cuenta de Windows).
- Incidencias del proceso, todas resueltas: error 4060 al conectar (la conexión pedía la base borrada), base que seguía visible (el Explorador de objetos no se refrescaba), IntelliSense marcando errores falsos, ejecución parcial por texto seleccionado.

### 6.5 Guía v5.1 (Word)
- `Guia_ETL_3_datamarts_IE1217_v5_1.docx`, 18 páginas, mismo formato que la original.
- Cambios: estado «verificado» en portada; sección 02 con archivos v5_1, ejecución con SQLCMD y tabla de cambios; resultados reales en 04–10; nuevos hallazgos; errores reales en la sección 12; «Empezar de cero» en la 13; nuevas preguntas y números verificados en la 14. «No inventar una métrica» pasó a la sección 11.

### 6.6 Script 07: automatización
- Esquema `ctl` con `LoteETL`, `ConteoLote`, `fn_LoteActual`, `usp_IniciarLote`, `usp_ValidarStaging`, `usp_CerrarLote`, `usp_RegistrarFallo` y la vista `vw_HistorialLotes`.
- Job de 10 pasos: iniciar lote → 01 → **validar staging (freno)** → 02 → 03 → 04 → 05 → 06 → validar y cerrar → registrar fallo.
- Programación por defecto: **cada 15 minutos** (era el ejemplo de la práctica). Para operación real: diaria o por calendario (ver 6.7).
- Se corrigió antes de entregarlo: los parámetros de `EXEC` no admiten expresiones (se precalculan `@Cmd` y `@Log`) y el borrado del job quedó fuera de la transacción.

### 6.7 Script 08 (propuesto, no implementado)
- Calendario de cargas por proceso en una tabla `ctl.CalendarioCarga`, un job por datamart y un job **planificador** diario (00:05) que activa o desactiva los jobs según la ventana del día. El job 07 quedaría como recarga completa manual. Detalle en la sección 9.

### 6.8 Catálogo de métricas, indicadores y KPI (13/10/2026)
- Se entregó `Metricas_KPI_DW_IE1217.xlsx` (una hoja, solo título y datos): 42 filas con proceso, nombre, nivel (Métrica / Indicador / KPI), dónde vive (script 04, 05, 06 o Power BI), columna o fórmula y estado.
- Se aclaró que el DW tiene métricas que la matriz no pide: `DiasHastaSiagie` (04), recursos y uso de TIC (05), niveles de logro C/B/A/AD y `CompetenciaAprobada` por competencia (06).
- Se explicó P5 al detalle (sección 8) para llevarlo al equipo.

### 6.9 Corrección v5.2 (13/10/2026) — D21
- **Motivo:** el profesor exige un modelo en estrella sin relaciones entre tablas de dimensión. La única violación encontrada fue `DimCompetencia.AreaKey` con FK a `DimArea`.
- **03 v5.2:** quita `AreaKey` y su FK de `DimCompetencia`; conserva `AreaID` y `NombreArea`. Incluye un bloque idempotente que elimina FK y columna en `DW_IE1217` ya cargada, y una prueba de integridad nueva (esperado 0).
- **06 v5.2:** la validación «Competencia incompatible con área» compara `AreaID` (binario) en lugar de `AreaKey`. Mismo criterio que D15.
- **07 v5.2:** apunta a 03 v5.2 y 06 v5.2. Hay que volver a crear el job (el script es idempotente).
- **Sin cambios:** 01, 02, 04 y 05 siguen en v5.1.
- **Orden de ejecución:** 03 v5.2 → 06 v5.2. No hace falta re-ejecutar 04 ni 05.
- **Versionado:** los archivos ya no llevan número de versión; la versión es la etiqueta Git (D22).
- **Estado:** 🟦 implementado y **no ejecutado**. Las cifras no se dan por verificadas hasta la re-ejecución (esperado: 87 incompatibles, 28 competencias, 0 área inexistente).

---

## 7. Decisiones tomadas (con su porqué)

| N° | Decisión | Por qué | Estado |
|---|---|---|---|
| D01 | Tres datamarts, **un hecho por proceso**; dimensiones comunes en `dw` | Requisito del curso; bus de Kimball | ✅ |
| D02 | Sesiones y materiales en **un solo hecho** (`FacPreparacion`), agregados al mismo grano mensual antes de unirlos | Límite de un hecho por datamart; unir fila contra fila multiplicaría ejemplares | ✅ |
| D03 | Aprendizajes por **competencia**, no por área; el área se calcula al consultar | Diagnóstico accionable y preserva los sin evidencia | ✅ |
| D04 | **No guardar porcentajes** en los hechos; solo numeradores y denominadores | Los porcentajes no se pueden sumar ni re-agregar | ✅ |
| D05 | Claves de tiempo especiales **-1 no aplica / -2 no registrado**; nunca NULL en la clave | Causas distintas; un NULL perdería filas en los JOIN | ✅ |
| D06 | Nota sin evidencia = `NotaVigesimal` NULL, `EscalaKey` -1, `SinEvidencia` = 1; **nunca 0 ni C** | No calificar lo que no se evaluó | ✅ |
| D07 | Se guarda la **nota vigesimal** y la letra se deriva con `DimEscalaLogro` | Conserva el detalle y muestra el calificativo oficial | ✅ |
| D08 | Letra suelta («A») → punto medio del rango (15,5) con bandera `NotaDesdeLetra` | Usable en promedios, pero se puede excluir | ✅ |
| D09 | Solo dos estados de matrícula (Aprobado / Rechazado) con motivo; los rechazados **no generan registros** en otros procesos | Así lo trae la fuente | ✅ |
| D10 | `DimSeccion` sin año; aforo anual en `AforoSeccionSnapshot` | Comparar la misma sección entre años | ✅ |
| D11 | `DimEstudiante` **SCD tipo 1** | No hay requisito de historial; la fuente no trae versiones | ✅ |
| D12 | El docente responsable sale de la **carga horaria**, no del código del archivo | «DOC-O3» era DOC-012, DOC-007 y DOC-004; corregir la O por cero lo habría atribuido mal | ✅ |
| D13 | Las **fechas ilegibles no se adivinan**: van a -2, la fila entra y queda fuera del cálculo de días | Principio de no inventar datos | ✅ |
| D14 | Material asignado al **mes de entrega (marzo)**; meses sin material quedan NULL, no 0 | Falta de programa ≠ entregó cero | ✅ |
| D15 | Ante duplicados de nota, gana el código escrito **tal cual** (comparación binaria); el otro va a la bitácora | Desempate determinista y trazable | ✅ |
| D16 | Recarga **total** por lote (DELETE + INSERT en transacción), **sin CDC ni SCD 2** | La fuente son CSV completos, no una base transaccional; diferencia explícita con el ejemplo FarmaVida | ✅ |
| D17 | **Freno** antes de los hechos: si una tabla de staging llega vacía o cae más del 50 % frente a la última corrida exitosa, el job se detiene | Un CSV incompleto borraría historia en la recarga total | 🟦 (implementado en 07) |
| D18 | **Métricas en el DW, KPI en Power BI** | Propuesta del ingeniero; ya era el diseño (D04) | ✅ acordado |
| D19 | KPI de recepción a 14 días: denominador **sin** las entregas sin fecha de recepción | No se sabe si esas 5 llegaron tarde | 🟨 para el DAX |
| D20 | Todo el equipo usa **solo v5.1**; no mezclar versiones | El 04 v5.1 depende del 03 v5.1; el 04 y el 06 v5 fallan con 8117 | ✅ (superada en parte por D21: 03, 06 y 07 pasan a v5.2) |
| D21 | `DimCompetencia` **sin `AreaKey` ni FK a `DimArea`**; el área va desnormalizada (`AreaID`, `NombreArea`). La relación área-hecho queda en `FacLogroCompetencia.AreaKey` | El profesor exige modelo en estrella: las dimensiones no se relacionan entre sí. Única violación encontrada | 🟦 Implementado en 03 v5.2 y 06 v5.2 · sin ejecutar |
| D22 | **Versionado con Git** (repositorio privado en GitHub): nombres de archivo fijos y sin número de versión; cada versión es una etiqueta (`v5.1`, `v5.2`); commits con formato `tipo(área): descripción`; los datos del colegio nunca se suben | Evitar archivos con número de versión, reenvíos y versiones mezcladas (D20); saber qué versión corrió cada quien | 🟦 Commits y etiquetas locales el 13/10/2026 · falta subir a GitHub |

---

## 8. Decisiones pendientes

| N° | Tema | Situación y propuesta | Impacto |
|---|---|---|---|
| P1 | **Bimestre compartido** | `DimTiempo.Bimestre` se aproxima por mes y **no coincide** con los cierres oficiales de `DimPeriodoAcademico` (p. ej. 26–30/05/2025 figura como I y es II; octubre figura como IV y hasta el 24/10 es III). **Propuesta:** calcular `DimTiempo.Bimestre` desde `DimPeriodoAcademico` y agregar `PeriodoKey` a `FacPreparacion` con grano docente + área + sección + bimestre + mes. **Solo se puede resolver en el ETL**, no en Power BI. | Cambio de modelo (03 y 05) |
| P2 | **Matrícula «validada» y «solicitada»** | Propuesta: validada = aprobada; solicitadas = **todas las registradas** (300 por año). Con solicitudes de vacante (76) el % daría más de 100. Resultado: 579/600 = 96,5 %. | Definición en la matriz y en DAX |
| P3 | **Matrículas pendientes** | ⛔ La fuente no tiene estado pendiente. Propuesta: reemplazar por **rechazadas** o **% de rechazo** y agregar el **% de ocupación** (la matriz lo nombra en la visualización pero no como KPI). | Matriz BI |
| P4 | **Docente con retraso** | La pregunta del cliente es «% de docentes con retraso», pero las fórmulas son de sesiones. Falta fijar umbral (p. ej. menos del 80 % de sesiones en horario), periodo y denominador. | Medida DAX |
| P5 | **Estudiante aprobado / bajo rendimiento** | Cada estudiante tiene ~26 notas por bimestre (una por competencia), así que hay que fijar cuál es «su nota». Opciones: **(1) por competencia** — bajo rendimiento si alguna competencia < 11; **(2) por área** — promedio de las competencias con evidencia de cada área y bajo rendimiento si alguna área < 11 (**propuesta**, coincide con cómo el colegio califica por área); **(3) promedio general** < 11. Con la opción 2 falta acordar si «aprobado» exige **todas las áreas ≥ 11** o solo promedio general ≥ 11. Bloquea: estudiantes < 11, estudiantes ≥ 11, % de bajo rendimiento, % de aprobados (y el indicador «nota del área por estudiante»). Los datos ya están completos en el hecho; solo falta la regla. | Medidas DAX |
| P6 | **Bitácora persistente para 04 y 05** | Hoy los 6 sin padrón, 9 duplicadas, 45 `-DUP` y 28 sin sección solo se ven en pantalla. Propuesta: reutilizar el patrón de `BitacoraNota`. | Opcional |
| P7 | **Meses de cobertura parcial** | Junio 2025 (109 sesiones) y mayo 2026 (435) están incompletos. Decidir si se filtran o se rotulan en el tablero. | Tablero |
| P8 | **Calendario de cargas (script 08)** | Ventanas y frecuencias propuestas en la sección 9; falta confirmarlas. Hacen falta las fechas **programadas** de cierre de bimestre del año en curso. | Automatización |
| P9 | **Columnas amarillas de la Matriz BI** | Meta, Frecuencia y Responsable del dato siguen vacías. | Matriz BI |
| P10 | **Detalle histórico de material** | El título, la observación y la fecha exacta de cada entrega solo quedan en staging. Decidir si basta. | Opcional |
| P11 | **Control de versiones de los scripts** | ✅ Resuelto con D22 (Git, nombres fijos, etiquetas). | — |

---

## 9. Diseño propuesto del script 08 (calendario de cargas)

**Problema:** SQL Agent no expresa «de diciembre a marzo de cada año», y las fechas del colegio cambian cada año.

**Solución propuesta:**
1. Tabla `ctl.CalendarioCarga` con ventanas por proceso (desde, hasta, frecuencia), actualizada una vez al año con el calendario oficial.
2. Un job por datamart (`Carga_Matricula`, `Carga_Preparacion`, `Carga_Aprendizajes`): cada uno recarga staging y dimensiones, solo su hecho, y valida solo sus tablas.
3. Job planificador diario (00:05) que activa o desactiva cada job según la ventana del día.
4. `ETL_IE1217_Carga` queda como recarga completa manual.
5. Horas separadas (22:00, 22:30, 23:00) y bloqueo si hay otro lote en curso.

| Proceso | Ventana propuesta | Frecuencia | Fundamento |
|---|---|---|---|
| Matrícula | 1/12 → 31/03 | Diaria 22:00 | Solicitudes desde diciembre, revisión en enero, asignación y SIAGIE hasta el inicio de clases |
| Preparación (materiales) | Inicio de clases −21 → +7 días | Diaria 22:30 | Recepción ≥ 14 días antes; entrega en la primera semana |
| Preparación (sesiones) | Inicio de clases → cierre del IV bimestre | Semanal (viernes 22:30) | Sesiones durante todo el año |
| Aprendizajes | Cada cierre de bimestre −7 → +7 días | Diaria 23:00 | Ventana calculada desde `DimPeriodoAcademico` |

Frase para la sustentación: *«Cada datamart se carga en la ventana en que su proceso genera datos. El calendario es un dato, no código.»*

---

## 10. Alineación con la Matriz BI y la matriz bus

### 10.1 Cobertura de KPI y métricas (procesos 1.0, 2.0 y 4.0)

| Proceso | Indicador | Cálculo | Estado |
|---|---|---|---|
| 1.0 | Matrículas solicitadas | `SUM(MatriculasRegistradas)` | ✅ (con P2) |
| 1.0 | Matrículas validadas | `SUM(MatriculasAprobadas)` | ✅ (con P2) |
| 1.0 | % de matrículas validadas | aprobadas / registradas | ✅ (con P2) |
| 1.0 | Días de validación | `SUM(DiasValidacion)` | ✅ |
| 1.0 | Tiempo promedio de validación | días / `CasosConValidacion` | ✅ |
| 1.0 | Cupo máximo por aula | `MAX(AforoSeccionSnapshot)` por año + sección | ✅ |
| 1.0 | Matrículas pendientes | — | ⛔ (P3) |
| 2.0 | Sesiones programadas | `SUM(SesionesProgramadas)` | ✅ |
| 2.0 | Sesiones dictadas en horario | `SUM(SesionesDictadasHorario)` | ✅ |
| 2.0 | % de cumplimiento de horarios | en horario / programadas | ✅ |
| 2.0 | Minutos de retraso acumulados | `SUM(MinutosRetraso)` | ✅ |
| 2.0 | Materiales programados | `SUM(MaterialesPorEntregar)` (ejemplares) | ✅ |
| 2.0 | Materiales entregados a tiempo | `SUM(MaterialesEntregadosATiempo)` | ✅ |
| 2.0 | % de materiales entregados | a tiempo / programados | ✅ |
| 2.0 | Incidencias de programación | `SesionesReprogramadas` como aproximación | ◐ Parcial: no hay cruces ni cambios de horario |
| 4.0 | Rendimiento promedio | `AVERAGE(NotaVigesimal)` | ✅ |
| 4.0 | Suma de notas obtenidas | `SUM(NotaVigesimal)` | ✅ |
| 4.0 | Total de estudiantes evaluados | `DISTINCTCOUNT(EstudianteKey)` con evidencia | ✅ |
| 4.0 | Estudiantes con nota < 11 | depende de la regla | ⏳ (P5) |
| 4.0 | Estudiantes con nota ≥ 11 | depende de la regla | ⏳ (P5) |
| 4.0 | % de bajo rendimiento | depende de la regla | ⏳ (P5) |
| 4.0 | % de aprobados | depende de la regla | ⏳ (P5) |

**Balance:** 16 listos · 4 dependen de una sola definición · 1 parcial · 1 no medible.

**Niveles según la leyenda de la Matriz BI:** Métrica (trabajador) → en el datamart · Indicador (rango medio) → medida DAX que combina métricas · KPI (gerencia) → medida DAX con meta y semáforo.

### 10.1b Catálogo por capa (fuente: `Metricas_KPI_DW_IE1217.xlsx`)

| Capa | Dónde | Filas | Estado |
|---|---|---|---|
| Métricas (numeradores y denominadores) | Scripts 04 (8), 05 (9), 06 (5) | 22 | ✅ Cargadas y verificadas |
| Indicadores y KPI | Power BI (DAX) | 20 | 12 🟨 planificados · 6 ⏳ pendientes (1 por P4, 5 por P5) · 1 ◐ parcial (incidencias = reprogramadas) · 1 ⛔ no medible (pendientes de matrícula) |

KPI nuevos propuestos que no estaban en la matriz: **% de ocupación de vacantes**, **% de rechazo** (reemplaza a pendientes), **% de recepción oportuna** (D19), **retraso promedio por sesión** y **cobertura de evaluación**.

**Lo que Power BI no puede resolver:** datos que no existen en la fuente (pendientes, cruces de horario) y el bimestre oficial en preparación (P1), porque la fila mensual ya viene sumada.

### 10.2 Ajustes necesarios en los documentos del Excel
- **Hoja V1 (matriz bus):**
  - Marcar 3.0 y 5.0 como fuera de alcance.
  - Corregir los granos (aprendizajes: competencia + bimestre; preparación: docente + área + sección + bimestre + mes).
  - Renombrar Aula → **Sección** y Curso → **Área**; agregar Competencia, Periodo, Escala, Tipo de matrícula y Motivo de rechazo.
  - Marcar Estudiante en matrícula y Docente + Área en preparación.
  - Renombrar la columna «Grano» a «Nivel temporal de análisis».
- **Hoja 5 (mapeo):** reescribirla completa con nombres reales de CSV, tablas y campos, indicando regla, clave de unión, tratamiento de nulos y script responsable. Hoy usa `DimAula`, `DimCurso`, `FactPreparacionCurricular`, `FactDesempenoDocente`, `FechaValidacion` (en la fuente es `FechaRevision`) y guarda `PorcentajeCumplimiento` en un hecho, lo que contradice D04.
- **Matriz BI:**
  - Aplicar P2, P3 y P4.
  - Expresar materiales en **ejemplares**.
  - Definir con qué fecha se responde «¿cuántas matrículas al día?» (las ratificaciones no tienen fecha de solicitud).

---

## 11. Hallazgos de datos útiles para la sustentación

- **Fechas de solicitud -2 (21):** 19 venían vacías y 2 eran texto corrupto (`24//2//1`, `26-/2-10/0`). Casi todas son de matrículas aprobadas; quedan fuera del promedio de días.
- **Fechas de material corruptas** (`25-/2-17/0`, `26-/2-16/0`) se asignaron al inicio de clases del año. En esas 5 filas la fecha de recepción también vino vacía.
- **Docentes:** «DOC-O3» → DOC-012 / DOC-007 / DOC-004; «DOC-05» → DOC-012 / DOC-007; «DOC-999» → DOC-005.
- **Sesiones sin asignación:** las 28 apuntan a la sección inexistente `9Z`; las de 2026 dicen `SEC-2025-9Z` (suciedad doble).
- **Duplicados de notas (264 vs 260 copias):** 7 son códigos sucios (`CP-O3`, `cp-05`, `CP 07`) que coincidieron con la misma nota bien escrita. La explicación más probable del resto es que unas pocas copias eran de notas ya inválidas y cayeron en otro motivo, porque el 06 valida la nota antes de deduplicar. La reconciliación prueba que ninguna fila se perdió.
- **Efecto de la limpieza:** cumplimiento de sesiones sobre el origen sucio (bloque 8 del 02) = 82,43 %; sobre el hecho limpio = 83,38 % / 83,41 %.
- **Cobertura de sesiones:** el archivo termina a inicios de junio de 2025 y en mayo de 2026.
- **Promedio de notas ascendente** a lo largo de 2025 (13,26 → 13,97).

---

## 12. Operación

### 12.1 Ejecución manual
- Cada script en **su propia pestaña**, completo con **F5** y **sin texto seleccionado** (si hay selección, SSMS ejecuta solo esa parte).
- Revisar la pestaña **Mensajes** y la barra inferior («ejecutada correctamente» vs. «completada con errores»). La **Lista de errores de IntelliSense no cuenta**; Ctrl+Shift+R actualiza su caché.
- Si la base ya existe, basta correr del 03 al 06.

### 12.2 Todo de golpe (modo SQLCMD)
```sql
:on error exit
:r "C:\BI_IE1217\scripts\01_staging.sql"
:r "C:\BI_IE1217\scripts\02_diagnostico.sql"
:r "C:\BI_IE1217\scripts\03_dimensiones.sql"
:r "C:\BI_IE1217\scripts\04_fac_matricula.sql"
:r "C:\BI_IE1217\scripts\05_fac_preparacion.sql"
:r "C:\BI_IE1217\scripts\06_fac_aprendizajes.sql"
```

### 12.3 Empezar de cero
```sql
USE master;
GO
IF DB_ID('DW_IE1217') IS NOT NULL
BEGIN
    ALTER DATABASE DW_IE1217 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DW_IE1217;
END
GO
```
- No borrar los CSV ni los logins (`sa` y la cuenta de Windows).
- Si sale el error 4060 al conectar, poner `master` como base en la ventana de conexión.

### 12.4 Requisitos del job (07)
1. Iniciar **SQL Server Agent** en modo Automático (Configuration Manager).
2. Copiar 01–06 v5_1 a `C:\BI_IE1217\scripts` y crear `C:\BI_IE1217\logs`.
3. Permisos (CMD como administrador):
   ```
   icacls "C:\BI_IE1217\scripts" /grant "NT SERVICE\SQLSERVERAGENT:(OI)(CI)R"
   icacls "C:\BI_IE1217\data"    /grant "NT SERVICE\SQLSERVERAGENT:(OI)(CI)R"
   icacls "C:\BI_IE1217\logs"    /grant "NT SERVICE\SQLSERVERAGENT:(OI)(CI)M"
   ```
   La carpeta **data** también lo necesita: con autenticación de Windows, el BULK INSERT lee el archivo con la cuenta del Agente.
4. Verificar `sqlcmd -?` en CMD.

El job ejecuta: `sqlcmd -E -C -b -I -x -W -f 65001 -i <script>`.

### 12.5 Uso del job
```sql
EXEC msdb.dbo.sp_start_job @job_name = N'ETL_IE1217_Carga';
SELECT TOP (10) * FROM DW_IE1217.ctl.vw_HistorialLotes ORDER BY LoteID DESC;
EXEC msdb.dbo.sp_help_jobhistory @job_name = N'ETL_IE1217_Carga', @mode = N'FULL';
EXEC msdb.dbo.sp_update_job @job_name = N'ETL_IE1217_Carga', @enabled = 0;  -- pausar
```
**Pruebas demostrativas:**
- **Fallo registrado:** renombrar un CSV y lanzar el job → «01 Staging» Fallido.
- **Freno:** tras una corrida exitosa, recortar a la mitad `matricula.csv` → se detiene en «Validar staging» con los hechos intactos.

### 12.6 Errores típicos y su solución

| Síntoma | Causa | Solución |
|---|---|---|
| Decenas de «Nombre de columna no válido» en «Archivos varios» | IntelliSense revisa antes de que existan las tablas | Ignorar; Ctrl+Shift+R |
| Solo pestaña Mensajes, sin «filas afectadas» | Había texto seleccionado | Quitar la selección y F5 |
| 2628 truncado en `Ciclo` | `DimSeccion` v5 | 03 v5.1 |
| 8117 SUM sobre BIT | 04 / 06 v5 | v5.1 |
| «There is already an object named #…» | Temporales de la corrida anterior | v5.1 o reabrir la pestaña |
| 4060 al conectar | La conexión pide una base borrada | Conectar a `master` |
| «Database is currently in use» | Conexiones abiertas | «Cerrar conexiones existentes» o `SINGLE_USER WITH ROLLBACK IMMEDIATE` |
| Error 5 / «Access is denied» en BULK INSERT | Permisos de lectura | Dar lectura a la cuenta del servicio (y a la del Agente si corre el job) |
| THROW 51049–51059 | Reglas del 05 | Leer el SELECT previo al THROW |
| THROW 51060–51066 | Reglas del 06 | Revisar periodo, catálogos, duplicados, `#Conflictos` |
| THROW 51070–51075 | Control de lotes (07) | Ver `ctl.vw_HistorialLotes` y el log del paso |

### 12.7 Códigos de error por script
- **04:** 5100x · **05:** 51049–51059 · **06:** 51060–51066 · **07 (`ctl`):** 51070–51075.

---

## 13. Advertencias para Power BI
- `FacMatricula` tiene **4 fechas** contra `DimTiempo`: una sola relación activa; las otras tres inactivas con `USERELATIONSHIP`.
- Personas con `DISTINCTCOUNT(EstudianteKey)`; aforo con `MAX` por año + sección y luego sumar.
- NULL ≠ 0: material de abril en adelante es NULL (no hubo programa); las notas sin evidencia son NULL.
- Meses incompletos: junio 2025 y mayo 2026.
- Filas especiales -1 / -2 en las dimensiones: decidir si se ocultan o se rotulan.

---

## 14. Archivos del proyecto

| Archivo | Estado |
|---|---|
| `01_staging.sql`, `02_diagnostico.sql`, `04_fac_matricula.sql`, `05_fac_preparacion.sql` | ✅ Vigentes sin cambios (v5.1 / v5.1b) |
| `03_dimensiones.sql`, `06_fac_aprendizajes.sql`, `07_job_sql_agent.sql` | 🟦 v5.2 (D21, D22): pendiente de re-ejecutar y subir a GitHub |
| Versiones anteriores | Etiqueta `v5.1` en Git. Copia en `D:\BI_IE1217_respaldo\v5.1_scripts\` (fuera del repo, verificada contra el tag). No usar archivos sueltos con número de versión |
| `Guia_ETL_3_datamarts_IE1217_v5_1.docx` | ✅ Vigente (sustituye al PDF v5) |
| `Guia_ETL_3_datamarts_IE1217_v5.pdf` | Histórico |
| `Matriz_BI_Gestion_de_ProcesosV.2` | ⏳ Requiere ajustes (P2, P3, P4, P9) |
| `Metricas y Dimensiones` (V1, Hoja 5) | ⏳ Desactualizado; usar como plantilla a corregir, no como fuente de verdad |
| `Metricas_KPI_DW_IE1217.xlsx` | ✅ Catálogo de métricas → KPI (13/10/2026) |
| `BITACORA_CONTEXTO_DW_IE1217.md` | Este documento |

---

## 15. Próximos pasos sugeridos (en orden)
1. Subir el repo a GitHub (`git push -u origin main --tags`) y re-ejecutar 03 v5.2 y 06 v5.2 (o el job v5.2) sobre `DW_IE1217` y comprobar: 87 filas incompatibles sin cambio, 28 competencias y 0 competencias con área inexistente. Después, reportar la primera ejecución del job (lote Exitoso con 600 / 769 / 44 815).
2. Cerrar con el equipo P1, P2, P3, P4 y P5 (para P5, elegir entre las tres opciones de la sección 8).
3. Si se aprueba P1, ajustar el 03 y el 05 y volver a verificar.
4. Confirmar ventanas y frecuencias y escribir el script 08 (P8).
5. Reescribir la hoja V1 y la Hoja 5 con el modelo real.
6. Construir el catálogo de medidas DAX (métricas → indicadores → KPI con meta) y el modelo en Power BI.
7. Que cada integrante replique la carga y compare con la sección 5.

---

## 16. Reglas de trabajo acordadas
- Distinguir siempre lo **verificado**, lo **propuesto** y lo **pendiente**; nunca presentar una propuesta como resultado.
- **No inventar métricas** que el origen no trae (por ejemplo, «incidencias de programación» solo se aproxima con reprogramadas, y se dice así).
- **Respetar el grano**: personas con `DISTINCTCOUNT`, aforo con `MAX` antes de sumar, no mezclar NULL con 0.
- Consultar antes de cambios estructurales al modelo.
- El mapeo debe usar nombres reales de CSV, tablas y campos, e indicar regla, clave de unión, tratamiento de nulos y script responsable.
- Si falta un dato para decidir, preguntarlo en vez de suponerlo.

---

## 17. Prompt para iniciar la siguiente sesión

> Retomamos el proyecto BI de la I.E. 1217. Lee primero `BITACORA_CONTEXTO_DW_IE1217.md` del proyecto (es la fuente de verdad: estados, cifras verificadas, decisiones D01–D20 y pendientes P1–P10).
> Estado al 13/10/2026: ETL 01–06 v5.1 verificado; job 07 creado (falta reportar su primera ejecución); catálogo `Metricas_KPI_DW_IE1217.xlsx` entregado (22 métricas en el DW, 20 indicadores/KPI para Power BI).
> Novedades desde la última sesión: [completar — p. ej. resultado del job, decisiones del equipo sobre P1–P5].
> Lo que quiero hacer hoy: [completar — p. ej. catálogo de medidas DAX, script 08, reescribir V1 y Hoja 5].
> Recuerda: distinguir verificado / propuesto / pendiente, no inventar métricas, respetar el grano, y mantener sincronizadas la bitácora del proyecto y la local (`D:\bi-claudio\_contexto\`).