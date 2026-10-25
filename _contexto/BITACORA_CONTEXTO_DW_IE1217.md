# Bitácora de contexto — Data Warehouse I.E.P. N° 1217 "Jorge Basadre Grohmann"

**Curso:** Business Intelligence · Ingeniería de Sistemas · UPeU
**Cliente:** I.E.P. N° 1217 "Jorge Basadre Grohmann" · Chaclacayo · UGEL 06
**Versión vigente del ETL:** v6.5 (25/10/2026): dimensiones y hechos según la matriz de métricas y dimensiones v2.2 (canon): DimCurso (curso + tipo + competencia, con fila «Todo el curso»), DimNivelAcademico y cuatro hechos (FacMatricula, FacSesion, FacEntregaMaterial, FacLogroCompetencia); cifras verificadas sin cambio. v6.4 y anteriores quedan como etiquetas.
**Última actualización de esta bitácora:** 25/10/2026
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
| Script 07: control de lotes + job de SQL Server Agent | ✅ Job recreado (v5.2) · primera ejecución exitosa el 13/10/2026 (lote 4: 600 / 769 / 44 815 + 581) |
| Script 08: calendario de cargas por proceso | 🟨 Diseño propuesto, esperando confirmar ventanas y frecuencias |
| Catálogo métricas → indicadores → KPI (`Metricas_KPI_DW_IE1217.xlsx`) | ✅ Entregado (42 filas: 22 métricas cargadas en los scripts, 20 indicadores/KPI planificados para Power BI) |
| Capa de KPI en Power BI (DAX) | 🟨 Siguiente fase; criterio aprobado por el ingeniero |
| Matriz bus, V2 y mapeo (`docs/insumos/Metricas_y_Dimensiones.xlsx`) | ✅ v2.0 del 13/10/2026: matriz previa al ETL rotulada por concepto + mapeo origen → DW con nombres reales (D23) |
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
| SQL Server Agent | En ejecución desde el 13/10/2026. Su inicio estaba en Manual: dejarlo en Automático (Configuration Manager) |
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
- ✅ Primera ejecución exitosa: lote 4, 13/10/2026 13:45 (disparado por el horario del Agente), 12 s, los 10 pasos en éxito y «Exitoso» en `ctl.vw_HistorialLotes` con 600 / 769 / 44 815 + 581.
- Lotes 1–3 (06/10/2026) fallaron en «01 Staging»: no existía `C:\BI_IE1217\logs` («Unable to open Step output file»). El 13/10/2026 se crearon `C:\BI_IE1217\scripts` y `logs`, se copiaron los scripts con nombres fijos, se dieron los permisos de 12.4 y se recreó el job con el 07 (cada 15 minutos). El Agente quedó en ejecución.

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
- **Estado:** ✅ verificado el 13/10/2026. Antes se respaldó la base (`DW_IE1217_pre_v5_2_20261013.bak`, carpeta de backup por defecto de la instancia, verificado con `RESTORE VERIFYONLY`). Resultado de 03 y 06: 28 competencias + fila -1, 0 competencias con área inexistente, 0 FK entre dimensiones, `AreaKey` eliminada; 44 815 en el hecho + 581 en bitácora (264 / 198 / 87 / 32), 379 sin evidencia, mismos registros y promedios por bimestre. 04 y 05 sin cambios (600 / 769).

### 6.10 Matriz de métricas y dimensiones v2.0 (13/10/2026) — D23
- Archivo: `docs/insumos/Metricas_y_Dimensiones.xlsx` (Git) y `Metricas_y_Dimensiones_v2.1.xlsx` (Drive). La versión anterior pasó a `docs/insumos/versiones antiguas/`.
- **v2.1 (13/10/2026):** (1) el grano va **por medida**, como granularidad: una palabra + nivel de jerarquía (Matrícula–Año, Sección–Año, Asignación–Mes, Docente–Mes, Asignación–Año, Calificación–Bimestre, Estudiante–Bimestre), pedido del profesor; (2) corrige la observación de «% de estudiantes con bajo rendimiento»: «alguna área menor a 11» es la propuesta P5 (opción 2); lo pendiente es elegir entre las opciones 1, 2 y 3.
- **Dos versiones del archivo (D24):** la **interna** (Git, `docs/insumos/Metricas_y_Dimensiones.xlsx`) conserva fórmulas, observaciones, estado de definición, leyenda, comentarios técnicos y control de versiones. La **pública** (Drive, `Metricas_y_Dimensiones_v2.1.xlsx`, copia local en `D:\BI_IE1217_respaldo\publica\`) solo tiene Matriz bus, V2 y Mapeo, con fórmula y observación cortas y **Estado = Script SQL** (métrica calculada en el ETL) **o Power BI** (indicador/KPI en DAX); omite retraso promedio, recepción oportuna y cobertura (propuestas no pedidas). La v2.0 quedó en `docs/insumos/versiones antiguas/`.
- Hojas: **Matriz bus** (3 procesos × 10 dimensiones), **V2** (31 medidas × atributos, reemplaza a la V1), **Mapeo origen-DW** (43 filas, reemplaza a la Hoja 5) y **Control de versiones**.
- Nombres del mapeo comprobados contra `INFORMATION_SCHEMA` de `DW_IE1217` (202 columnas, 0 diferencias).
- Versionado del documento: nombre fijo en Git; en Drive con la versión en el nombre; v2.1… para correcciones menores, v3.0 para cambios de estructura.

### 6.11 Guía de exposición (13/10/2026)
- `docs/guias_detalles/Guia_Exposicion_DW_IE1217.docx` (8 páginas): orden de la exposición, contexto y alcance, Matriz BI, matriz bus y granularidad, arquitectura, scripts 01–07 con cifras verificadas, automatización (07 verificado, 08 propuesto), Power BI, pendientes P1–P5, preguntas probables y glosario.
- Revisión de la Matriz BI: 10 observaciones registradas como P12 (resueltas en 6.12).
- Guía v2 (13/10/2026): Matriz BI V.3 con tabla «antes → ahora», grano por medida (palabra + nivel) y versión pública/interna con Estado Script SQL / Power BI. La v1 queda en `docs/guias_detalles/versiones antiguas/`.

### 6.12 Matriz BI V.3 (13/10/2026) — D25
- `docs/insumos/Matriz_BI_Gestion_de_ProcesosV.3.xlsx` (Drive: misma versión en la carpeta del proyecto). La V.2 pasa a `docs/insumos/versiones antiguas/` y a `Extra/Versiones antiguas` en Drive.
- Regla: **no se toca la estructura**; se corrigen fórmulas y se agregan notas breves entre paréntesis (gris, cursiva, tamaño 8).
- Cambios: pendientes = solicitadas − validadas − rechazadas (sigue KPI); tiempo promedio de validación ÷ solicitudes con fecha de solicitud y de revisión (→ Indicador); rendimiento promedio ÷ notas con evidencia (→ Indicador); incidencias = sesiones reprogramadas «(aproximación…)»; fila nueva KPI «% de docentes con retraso» «(umbral por definir (P4))»; información requerida 2.0 reescrita; 3.0 y 5.0 «(fuera del alcance del DW)»; Frecuencia y Responsable «(propuesta)»; guía de lectura con el nombre de la matriz al lado.
- Se conservan las filas y columnas ocultas del original (Meta, Frecuencia y Responsable siguen en columnas ocultas N–P).

### 6.13 Rediseño dimensional en 6 fases (desde el 19/10/2026) — D26
- **Observación del profesor:** en la matriz bus había dimensiones con **un solo atributo** (Área: Nombre; Escala de logro: Nivel). Causa: la matriz mostraba solo los atributos que usaba alguna medida, y no la dimensión completa con su jerarquía.
- **Plan acordado** (cada fase sale solo de la anterior y no se pasa a la siguiente sin aprobación):
  1. Matriz BI.
  2. Matriz bus con el nivel de jerarquía por proceso.
  3. Grano atómico por hecho y nivel de lectura por medida.
  4. Fichas de dimensión según Kimball.
  5. Hechos y mapeo origen → DW.
  6. Actualización de los scripts y verificación.

  Regla: **nada inventado**; cada elemento declara de qué paso anterior o de qué campo de CSV sale.
- **Hallazgos en los encabezados de los CSV** (19/10/2026), a usar en las fases 2–4:
  - `sesiones.csv` trae `Bimestre`, `EstadoSesion` y `MotivoNoDictada`.
  - `secciones.csv` trae `Anio` y `Aforo` por año.
  - `materiales.csv` permite una dimensión Material (Tipo de material → Material). Hoy textos y cuadernos son columnas separadas del hecho.
  - En `DimMotivoRechazo`, la **Categoría** y **EsSubsanable** las deriva el ETL con reglas LIKE: no vienen de la fuente.
  - `DimEscalaLogro` es una regla de calificación: no viene de ningún CSV.
  - Los materiales anuales están guardados en las filas de marzo de `FacPreparacion` (granos mezclados).
- **Fase 1 terminada:** Matriz BI **V.4**.
  - Plantilla: la misma, más las columnas «Origen del dato (CSV · campo)» y «Sustento». Se muestran Comparación, Respuesta BI, Meta, Frecuencia y Responsable.
  - Medidas: 35 (1.0: 10; 2.0: 16; 4.0: 9).
  - Hojas nuevas: «Definiciones acordadas» y «Cambios V.3 → V.4».
  - Sale «Matrículas pendientes».
  - Entran: rechazadas, % de cobertura de vacantes, vacantes disponibles, % de docentes con retraso (en horarios y en material), retraso promedio, variación del rendimiento y notas con evidencia.

### 6.14 ETL v6.0: dimensiones según la matriz v2.1 (20/10/2026) — D27
- **Base:** la hoja V2 de `Metricas_y_Dimensiones_v2.1.xlsx` del equipo, **solo lo visible**. Las columnas ocultas D (Grano), Y (Periodo · Año escolar) y AE (Motivo) no se tomaron en cuenta. Periodo académico no se implementa.
- **Dimensiones nuevas** (el CSV completo sigue en staging):
  - **Tiempo:** año, año escolar, mes, bimestre y fecha. El bimestre sale de los cierres oficiales y del inicio de clases (primera sesión: 17/03/2025 y 16/03/2026). 2026-III queda "sin cierre".
  - **Estudiante:** código, nombre, sexo y fecha de nacimiento (la edad se calcula).
  - **Docente:** código, nombre, sexo y condición.
  - **Sección:** ciclo, grado y sección.
  - **Área:** código y nombre.
  - **Competencia:** área, tipo, competencia **y nivel de logro**: una fila por competencia × nivel, 140 filas.
  - **Tipo de matrícula:** tipo, vía, fase y estado.
  - **Motivo de rechazo:** solo la categoría.
- **Eliminadas:** DimPeriodoAcademico y DimEscalaLogro. FacLogroCompetencia queda sin PeriodoKey, AreaKey ni EscalaKey.
- **Verificación:** respaldo `DW_IE1217_pre_v6_0_20261020.bak`; se ejecutaron 03, 02, 04, 05 y 06. Las cifras son idénticas a la v5.2:
  - 600 matrículas (579 / 21) · 769 filas de preparación · 6 352 sesiones · 44 815 notas + 581 en bitácora · 379 sin evidencia.
  - Niveles: C 7 040 · B 14 668 · A 17 707 · AD 5 021.
  - 0 duplicados de grano · 0 FK entre dimensiones.
- **Advertencia registrada:** la categoría del motivo la asigna el ETL con reglas de texto; el motivo literal solo queda en staging (`stg.MotivoRechazoCategoria`).
- **Pendiente para alinear con la propuesta de rediseño (fases 2–6):** preparación sigue siendo un solo hecho con granos mes/año; el cupo sigue dentro de FacMatricula; la Matriz BI V.4 tiene medidas que la v2.1 no lista.

### 6.15 ETL v6.1: matriz v2.1 corregida por el equipo (20/10/2026) — D28
- **Base:** `Metricas_y_Dimensiones_v2.1.xlsx` modificada por el equipo el 20/10/2026: Tiempo = Año, Bimestre, Mes y Día; el grupo «Cursos» (Cursos, Competencia, Actividad) reemplaza a Área y Nivel de logro; se quita Motivo de rechazo.
- **Acuerdos de la sesión:**
  - «Actividad» se reemplaza por **Tipo de competencia** (Específica 26 / Transversal 2): ningún CSV tiene actividades ni tareas; la nota se registra por competencia y bimestre, y las sesiones (Unidad 1–2, «Sesión n») son por área, no por competencia.
  - **Nivel de logro** sale del modelo: el CSV no lo trae (solo la nota 0–20; 148 notas vienen en letra) y ninguna pregunta de la matriz lo pide. La escala queda como regla del 06. Si se pide el calificativo literal, es una columna calculada en Power BI desde la nota.
  - **Motivo de rechazo** se elimina: las rechazadas se cuentan, no se analizan por motivo.
  - **Bimestre** también en preparación, para cruzarla con aprendizajes (*drill-across*).
  - Notas por sesión: ⛔ no existen en el origen. Generarlas en el conjunto sintético queda como 🟨 ampliación posible después de cerrar la v6.1 (deben derivarse de las notas bimestrales para cuadrar).
- **Cambios:** DimTiempo sin AnioEscolar, EsCierreBimestre ni EsFilaEspecial; DimCompetencia 28 + 1 filas; FacLogroCompetencia sin conteos de nivel ni CompetenciaAprobada; FacPreparacion con `TramoTiempoKey` (mes dentro del bimestre); FacMatricula sin MotivoKey; se eliminan DimMotivoRechazo y stg.MotivoRechazoCategoria.
- **Verificación:** respaldo `DW_IE1217_pre_v6_1_20261020.bak`; se ejecutaron 03, 04, 05 y 06. Comparado contra el respaldo: 0 diferencias nota por nota y totales de preparación idénticos.
  - 600 matrículas (579 / 21) · 6 352 sesiones · 879 filas de preparación (549 + 330; mayo de 2025 se parte en I y II) · 44 815 notas + 581 en bitácora · 379 sin evidencia · 148 letras convertidas.
  - 0 fechas de cierre distintas del oficial · 0 FK entre dimensiones.
- **Advertencias:** las sesiones solo cubren mar–jun 2025 y mar–may 2026, así que el cruce preparación × notas por bimestre solo tiene ambos lados en 2025-I, 2025-II y 2026-I. El Excel v2.1 aún debe corregirse: fila 6 («Se analiza por motivo de rechazo»), Actividad → Tipo de competencia, marcar Bimestre (y Año en aprendizajes), grano de preparación «Mes y bimestre», y las hojas Matriz bus y Mapeo origen-DW.


### 6.16 ETL v6.2: hechos solo con las medidas de la matriz y un grano por hecho (20/10/2026) — D29
- **Criterio del equipo:** igual que en las dimensiones, el hecho guarda solo lo que responde las preguntas. Regla aplicada: medida marcada «Script SQL» en la V2 → columna del hecho con el nombre del Excel; marcada «Power BI» → se calcula en el modelo.
- **Contraste con Kimball** (video de la sesión): los hechos reflejan prioridades del negocio, «no agregar todo por agregarlo»; un hecho tiene claves y valores numéricos; los porcentajes no se guardan (no son aditivos): se guardan numerador y denominador. Las marcas de calidad no son medidas del negocio: quedan en los controles del ETL y en staging. Matiz: si mañana se pide una medida recortada (p. ej. horas pedagógicas), hay que tocar el ETL; el CSV completo sigue en staging.
- **Granos separados** («stay true to the grain»): cupo y vacantes ocupadas (sección + año) pasan de FacMatricula a **FacCupoSeccion**; los materiales (anuales) pasan de FacPreparacion a **FacEntregaMaterial**. Desaparece el MAX por aula y la fila de marzo con material.
- **Columnas:** FacMatricula 22 → 13 · FacCupoSeccion 5 · FacPreparacion 42 → 9 · FacEntregaMaterial 7 · FacLogroCompetencia 17 → 8.
- **Verificación:** respaldo `DW_IE1217_pre_v6_2_20261020.bak`; se ejecutaron 04, 05 y 06; 0 diferencias fila por fila contra la v6.1 en las cinco tablas. 600 matrículas (579 / 21) · ocupación 96,33 % / 96,67 % · 879 filas de sesiones · 100 asignaciones con material (61,97 % / 70,28 % a tiempo) · 44 815 notas + 581 · 379 sin evidencia.
- **Pendientes del Excel:** «Incidencias de programación» dice = reprogramadas (228), pero P16 acordó reprogramadas + no dictadas (557): elegir. «Vacantes ocupadas» (fila 11) debe ir con grano sección + año y sin las dimensiones de estudiante. Agregar FacCupoSeccion y FacEntregaMaterial a la matriz bus.

### 6.17 ETL v6.3: una tabla de hechos por proceso (23/10/2026) — D30
- **Decisión del equipo:** por ahora, un hecho por proceso (Matrícula, Preparación, Aprendizajes). Se deshace la separación de la v6.2: el cupo y las vacantes ocupadas vuelven a FacMatricula y los materiales a FacPreparacion (fila de marzo, NULL en los demás meses). FacCupoSeccion y FacEntregaMaterial se eliminan.
- **Costo conocido (Kimball):** se vuelven a mezclar granos. Regla de uso: el cupo se suma con MAX por año + sección; el material se suma solo donde no es NULL. Defensa en la sustentación: la matriz ubica esas medidas dentro de los procesos de Matrícula y Preparación. La separación queda como 🟨 mejora posible.
- **Columnas:** FacMatricula 15 · FacPreparacion 11 · FacLogroCompetencia 8.
- **Verificación:** respaldo `DW_IE1217_pre_v6_3_20261023.bak`; se ejecutaron 04, 05 y 06; 0 diferencias fila por fila contra la v6.2 (matrícula, cupo, sesiones, material y notas). Cifras: 600 (579 / 21) · ocupación 96,33 % / 96,67 % · 879 filas de preparación · material a tiempo 61,97 % / 70,28 % · 44 815 notas + 581 · 379 sin evidencia.
- **Operación:** el 23/10 el servicio de SQL Server estaba detenido tras reiniciar el equipo; se inicia con `Start-Service MSSQLSERVER` (PowerShell como administrador).

### 6.18 ETL v6.4: preparación en dos hechos, sesiones y materiales (25/10/2026) — D31
- **Decisión del equipo:** el proceso 2.0 se divide en dos hechos por su naturaleza y grano distintos. Medidas acordadas: % de docentes con retraso en horarios, % de docentes con retraso en la entrega de material, % de cumplimiento de horarios, % de materiales entregados a tiempo, sesiones programadas, sesiones dictadas en horario, sesiones dictadas con retraso, incidencias de programación, docentes con sesiones programadas, docentes con retraso en horarios, materiales por entregar, materiales entregados a tiempo, docentes con material por entregar y docentes con entregas fuera de plazo.
- **Hechos:** `FacSesion` (antes FacPreparacion; asignación + mes + bimestre) y `FacEntregaMaterial` (asignación + año; fecha = inicio de clases). Guardan solo los conteos aditivos; los % y los conteos de docentes (DISTINCTCOUNT de DocenteKey) van en Power BI.
- **Definiciones aplicadas:** incidencias = reprogramadas + no dictadas (P16); docente con retraso en horarios = menos del 80 % de sus sesiones del mes en horario (P4); docente con entregas fuera de plazo = al menos un ejemplar tarde o no entregado en el año (P14), calculado como por entregar − a tiempo > 0. Sale `MinutosRetraso` (no está en la lista acordada).
- **Verificación:** respaldo `DW_IE1217_pre_v6_4_20261025.bak`; se ejecutó el 05; 0 diferencias contra la v6.3. 879 filas de sesiones · 100 de material · en horario 83,38 % / 83,41 % · con retraso 266 / 198 · incidencias 329 / 228 · docentes con retraso por mes 2–6 de 15 (13 % a 40 %) · material a tiempo 61,97 % / 70,28 %.
- **⚠️ Observación:** con P14, los 9 docentes con material tienen al menos un ejemplar fuera de plazo en ambos años: el % de docentes con retraso en la entrega sale 100 % siempre y no distingue a nadie. Conviene un umbral (p. ej. menos del 80 % de sus ejemplares a tiempo), igual que en horarios. ⏳ Pendiente del equipo.
- **07:** el control de filas usa FacSesion y cuenta FacEntregaMaterial; el job debe recrearse ejecutando el 07 cuando se use el Agent.
- **Matriz de métricas y dimensiones v2.2** (sobre la v2.1 que modificó el equipo el 25/10): el hecho de preparación se divide en «Sesiones» y «Entrega de material»; se ajustan las «x» según el grano de cada medida (matrícula sin bimestre; cupo y vacantes solo con sección y año; sesiones con docente, sección, curso y año/bimestre/mes; material con docente, sección, curso y año; aprendizajes con año y bimestre); los % y conteos de personas pasan a «Power BI» y las métricas base a «Script SQL»; las observaciones se realinean con su medida (se quitan «motivo de rechazo» y «regla por confirmar»); la matriz bus queda con 4 hechos y las dimensiones actuales. La fila «Suma de notas obtenidas» sigue oculta, como la dejó el equipo, pero la usa el rendimiento promedio. La hoja «Mapeo origen-DW» sigue desactualizada (describe la v5.2).
- **06:** «Competencias sin evidencia» sale de la matriz y entra «Notas con evidencia»: `CompetenciasSinEvidencia` pasa a `NotasConEvidencia`. 0 diferencias contra la v6.3; 44 436 con evidencia, 379 sin evidencia; rendimiento promedio 13,618.

### 6.19 ETL v6.5: dimensiones con los grupos de la matriz v2.2 (25/10/2026) — D32
- **Observación del equipo:** el DW tenía DimArea y DimCompetencia, pero el canon (matriz v2.2) tiene un solo grupo «Cursos» (Curso, Tipo de competencia, Competencia), y «Nivel académico» en lugar de «Sección».
- **Contraste con Kimball:** la respuesta de libro para hechos de grano distinto es una dimensión conformada con su versión reducida (*shrunken rollup*): eso eran DimCompetencia + DimArea. Pero en Power BI un solo filtro de curso no cortaba sesiones y notas a la vez sin relacionar dimensiones entre sí (prohibido por D21). Se elige **una sola DimCurso** con dos niveles de fila: competencia (para notas) y «Todo el curso» (para sesiones y material). Sigue siendo estrella, coincide con el canon y un filtro de curso sirve para los tres hechos. Filtrar sesiones por competencia da vacío: correcto, la sesión no registra competencia.
- **Cambios:** DimCurso (CursoKey, CursoID = AreaID, Curso = NombreArea, TipoCompetencia, CompetenciaID, Competencia; 40 filas); DimNivelAcademico (Ciclo, Grado, Sección; sale NombreGrado; 11 filas). En los hechos: NivelAcademicoKey y CursoKey.
- **Verificación:** respaldo `DW_IE1217_pre_v6_5_20261025.bak`; se ejecutaron 03–06; comparación por claves naturales contra la v6.4: 0 diferencias en los cuatro hechos; 0 FK entre dimensiones.
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
| D21 | `DimCompetencia` **sin `AreaKey` ni FK a `DimArea`**; el área va desnormalizada (`AreaID`, `NombreArea`). La relación área-hecho queda en `FacLogroCompetencia.AreaKey` | El profesor exige modelo en estrella: las dimensiones no se relacionan entre sí. Única violación encontrada | ✅ Verificado el 13/10/2026: 03 y 06 ejecutados, cifras idénticas a v5.1 |
| D22 | **Versionado con Git** (repositorio privado en GitHub): nombres de archivo fijos y sin número de versión; cada versión es una etiqueta (`v5.1`, `v5.2`); commits con formato `tipo(área): descripción`; los datos del colegio nunca se suben | Evitar archivos con número de versión, reenvíos y versiones mezcladas (D20); saber qué versión corrió cada quien | ✅ Publicado el 13/10/2026 en GitHub (`Aquino45/bi-jorgebasadre-dw-ie1217`, etiquetas `v5.1` y `v5.2`) |
| D23 | La matriz de métricas y dimensiones es un documento **previo al ETL**: dimensiones y atributos rotulados por concepto (nombre técnico solo como comentario), fórmulas en palabras, estado de definición (Acordada / Propuesta / Pendiente / Parcial / No medible) y sin cifras de la carga. Se excluyen las 5 métricas que agregó el ETL (días hasta SIAGIE, TIC, recursos, niveles de logro, competencias aprobadas) y los procesos 3.0 y 5.0. El mapeo origen → DW sí usa nombres reales | Pedido del equipo para la sustentación | ✅ Aplicado en v2.0 (13/10/2026) |
| D24 | Dos versiones de Métricas y Dimensiones: **interna** (Git, con anotaciones) y **pública** (Drive, solo lo esencial). Grano **por medida** como granularidad (una palabra + nivel de jerarquía). En la pública, Estado binario: **Script SQL** / **Power BI** | Pedido del profesor (granularidad) y del equipo (versión limpia para presentar) | ✅ Aplicado en v2.1 (13/10/2026) |
| D32 | ETL **v6.5**: DimCurso única (curso + tipo + competencia, con fila «Todo el curso») y DimNivelAcademico, según el canon v2.2 | La matriz v2.2 es el canon; un solo filtro de curso para los tres hechos sin relacionar dimensiones | ✅ Verificado (25/10/2026) |
| D31 | ETL **v6.4**: preparación en dos hechos (FacSesion por mes + bimestre; FacEntregaMaterial por año) con las medidas acordadas; % y conteos de docentes en Power BI | Decisión del equipo (25/10/2026): sesiones y materiales tienen naturaleza y grano distintos | ✅ Verificado (25/10/2026) |
| D30 | ETL **v6.3**: una tabla de hechos por proceso; cupo y vacantes en FacMatricula, materiales en FacPreparacion | Decisión del equipo (23/10/2026); se acepta el grano mezclado con reglas de suma (MAX por aula; material solo donde no es NULL) | ✅ Verificado (23/10/2026) |
| D29 | ETL **v6.2**: los hechos guardan solo las medidas «Script SQL» de la matriz, con sus nombres; cinco hechos, uno por grano (FacCupoSeccion y FacEntregaMaterial nuevos) | Pedido del equipo (20/10/2026) y regla de Kimball de no mezclar granos | ✅ Verificado (20/10/2026) |
| D28 | ETL **v6.1** según la matriz v2.1 corregida: Tiempo = fecha, año, mes, bimestre; Competencia = curso + tipo + competencia (sin nivel de logro); sin Motivo de rechazo; preparación por mes + bimestre | Cambios del equipo en la matriz (20/10/2026); el origen no trae nivel ni actividades; cruce por bimestre | ✅ Verificado (20/10/2026) |
| D27 | ETL **v6.0** según la matriz v2.1 visible: menos atributos por dimensión, Competencia × Nivel de logro en una sola dimensión, bimestre oficial dentro de Tiempo, Motivo de rechazo solo con la categoría | Decisión del equipo (20/10/2026): el DW solo guarda lo que responde las preguntas; el profesor observó dimensiones con un solo atributo y Tiempo/Periodo duplicados | ✅ Verificado (20/10/2026) |
| D26 | Matriz BI **V.4** reconstruida desde la propia fila: cada medida sale de la pregunta, la comparación o la respuesta BI, y de un campo real de CSV (columnas Origen y Sustento). Definiciones acordadas: P2, P4, P5, P13, P14, P15 y P16 | Observación del profesor y regla «nada inventado»; base de la fase 2 (matriz bus) | ✅ Aplicado (19/10/2026) |
| D25 | Matriz BI **V.3** sin cambiar su estructura: se corrigen fórmulas (pendientes, tiempo de validación, rendimiento) y se agregan notas discretas entre paréntesis donde algo es aproximado, propuesto o está fuera de alcance; nueva fila KPI «% de docentes con retraso». La versión anterior se mueve a «versiones antiguas», nunca se borra. | Cumplir la revisión P12 sin rehacer el documento del equipo y dejando visible qué es propuesta. |

---

## 8. Decisiones pendientes

| N° | Tema | Situación y propuesta | Impacto |
|---|---|---|---|
| P1 | **Bimestre compartido** | ✅ Resuelto con D27 (v6.0) y D28 (v6.1): el bimestre de DimTiempo sale de los cierres oficiales, DimPeriodoAcademico ya no existe y FacPreparacion ya tiene el bimestre en su grano. Antes: `DimTiempo.Bimestre` se aproxima por mes y **no coincide** con los cierres oficiales de `DimPeriodoAcademico` (p. ej. 26–30/05/2025 figura como I y es II; octubre figura como IV y hasta el 24/10 es III). **Propuesta:** calcular `DimTiempo.Bimestre` desde `DimPeriodoAcademico` y agregar `PeriodoKey` a `FacPreparacion` con grano docente + área + sección + bimestre + mes. **Solo se puede resolver en el ETL**, no en Power BI. | Cambio de modelo (03 y 05) |
| P2 | **Matrícula «validada» y «solicitada»** | ✅ Acordado el 19/10/2026 (D26): solicitada = toda matrícula registrada; validada = aprobada. Antes: validada = aprobada; solicitadas = **todas las registradas** (300 por año). Con solicitudes de vacante (76) el % daría más de 100. Resultado: 579/600 = 96,5 %. | Definición en la matriz y en DAX |
| P3 | **Matrículas pendientes** | ✅ Resuelto en la V.4 (D26): se quita y entran rechazadas y % de cobertura de vacantes. Antes: ⛔ la fuente no tiene estado pendiente. Propuesta: reemplazar por **rechazadas** o **% de rechazo** y agregar el **% de ocupación** (la matriz lo nombra en la visualización pero no como KPI). | Matriz BI |
| P4 | **Docente con retraso** | ✅ Acordado el 19/10/2026 (D26): menos del 80 % de sus sesiones en horario en el mes. Antes: la pregunta del cliente es «% de docentes con retraso», pero las fórmulas son de sesiones. Falta fijar umbral (p. ej. menos del 80 % de sesiones en horario), periodo y denominador. | Medida DAX |
| P5 | **Estudiante aprobado / bajo rendimiento** | ✅ Acordado el 19/10/2026 (D26): opción 2 por área; bajo rendimiento = alguna área < 11; aprobado = todas las áreas ≥ 11. Antes: cada estudiante tiene ~26 notas por bimestre (una por competencia), así que hay que fijar cuál es «su nota». Opciones: **(1) por competencia** — bajo rendimiento si alguna competencia < 11; **(2) por área** — promedio de las competencias con evidencia de cada área y bajo rendimiento si alguna área < 11 (**propuesta**, coincide con cómo el colegio califica por área); **(3) promedio general** < 11. Con la opción 2 falta acordar si «aprobado» exige **todas las áreas ≥ 11** o solo promedio general ≥ 11. Bloquea: estudiantes < 11, estudiantes ≥ 11, % de bajo rendimiento, % de aprobados (y el indicador «nota del área por estudiante»). Los datos ya están completos en el hecho; solo falta la regla. | Medidas DAX |
| P6 | **Bitácora persistente para 04 y 05** | Hoy los 6 sin padrón, 9 duplicadas, 45 `-DUP` y 28 sin sección solo se ven en pantalla. Propuesta: reutilizar el patrón de `BitacoraNota`. | Opcional |
| P7 | **Meses de cobertura parcial** | Junio 2025 (109 sesiones) y mayo 2026 (435) están incompletos. Decidir si se filtran o se rotulan en el tablero. | Tablero |
| P8 | **Calendario de cargas (script 08)** | Ventanas y frecuencias propuestas en la sección 9; falta confirmarlas. Hacen falta las fechas **programadas** de cierre de bimestre del año en curso. | Automatización |
| P9 | **Columnas amarillas de la Matriz BI** | Frecuencia y Responsable llenados como 🟨 propuesta (V.3 y V.4), ahora visibles; la **Meta** la fija el colegio. | Matriz BI |
| P10 | **Detalle histórico de material** | El título, la observación y la fecha exacta de cada entrega solo quedan en staging. Decidir si basta. | Opcional |
| P11 | **Control de versiones de los scripts** | ✅ Resuelto con D22 (Git, nombres fijos, etiquetas). | — |
| P12 | **Corregir la Matriz BI** | ✅ Resuelto con D25 (V.3, 13/10/2026). Revisión del 13/10/2026: (1) tiempo promedio de validación debe dividir entre solicitudes con ambas fechas, no entre validadas; (2) «matrículas pendientes» no es KPI ni medible (P3) y su fórmula da rechazadas; (3) rendimiento promedio debe dividir entre notas con evidencia; (4) «Información requerida» de 2.0 repite la de 3.0; (5) la pregunta de 2.0 pide % de docentes con retraso sin KPI (P4); (6) incidencias de programación pide cruces que la fuente no trae; (7) no usa el nivel Indicador de su leyenda; (8) Meta, Frecuencia y Responsable vacías (P9); (9) 3.0 y 5.0 siguen en la matriz; (10) la guía de lectura usa otros nombres de columna. | Matriz BI |
| P13 | **Fecha del «día» de la matrícula** | ✅ Acordado el 19/10/2026 (D26): fecha de registro en SIAGIE (286 y 284 de 300); las rechazadas, por fecha de revisión. | Matriz BI, Power BI |
| P14 | **Docente con retraso en la entrega de material** | ✅ Acordado el 19/10/2026 (D26): al menos un ejemplar a destiempo o no entregado en el año. | Matriz BI, Power BI |
| P15 | **Denominador del retraso promedio** | ✅ Acordado el 19/10/2026 (D26): sesiones dictadas con retraso. | Matriz BI, Power BI |
| P16 | **Incidencias de programación** | ✅ Acordado el 19/10/2026 (D26): sesiones reprogramadas + no dictadas, según `EstadoSesion` (230 + 332 en la fuente; 520 con motivo). | Matriz BI, ETL |

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
| `01`–`07` | ✅ v6.5 (D32): verificada el 25/10/2026 (v6.5 cambia 03–06; v6.4 cambió 05, 06 y 07; 02 sin cambios) |
| Versiones anteriores | Etiqueta `v5.1` en Git. Copia en `D:\BI_IE1217_respaldo\v5.1_scripts\` (fuera del repo, verificada contra el tag). No usar archivos sueltos con número de versión |
| `Guia_ETL_3_datamarts_IE1217_v5_1.docx` | ✅ Vigente (sustituye al PDF v5) |
| `Guia_ETL_3_datamarts_IE1217_v5.pdf` | Histórico |
| `docs/insumos/Matriz_BI_Gestion_de_ProcesosV.4.xlsx` | ✅ Vigente (D26, 19/10/2026). V.2 y V.3 en `docs/insumos/versiones antiguas/`. Falta subirla a Drive (Chrome no estaba disponible); en Drive sigue la V.3 hasta entonces |
| `Metricas_y_Dimensiones.xlsx` v2.1 interna (Matriz bus, V2, Mapeo origen-DW, Control de versiones) | ✅ Vigente (13/10/2026). V1 y v2.0 en `docs/insumos/versiones antiguas/`; versión pública en Drive (D24) |
| `docs/guias_detalles/Guia_Exposicion_DW_IE1217.docx` | ✅ Guía de exposición v2 (13/10/2026; v1 en `versiones antiguas/`): orden de la sustentación, Matriz BI, matriz bus, arquitectura, scripts, automatización, Power BI, pendientes, preguntas probables y glosario |
| `Metricas_KPI_DW_IE1217.xlsx` | ✅ Catálogo de métricas → KPI (13/10/2026) |
| `BITACORA_CONTEXTO_DW_IE1217.md` | Este documento |

---

## 15. Próximos pasos sugeridos (en orden)
1. ✅ Hecho el 13/10/2026: job recreado y lote 4 «Exitoso». Falta decidir si el job queda cada 15 minutos (demostración) o diario (`@Frecuencia = N'DIARIO'` en el 07).
2. Rediseño en 6 fases (6.13): ✅ fase 1 (Matriz BI V.4). Siguen la fase 2 (matriz bus con niveles), la 3 (grano; resuelve P1 y los granos mezclados de preparación), la 4 (fichas de dimensión), la 5 (hechos y mapeo) y la 6 (scripts).
3. ✅ P1 resuelto en la v6.1 (preparación por mes + bimestre). Falta corregir el Excel v2.1 (ver 6.15) y la guía de exposición, que aún menciona Periodo académico y Escala de logro.
4. Confirmar ventanas y frecuencias y escribir el script 08 (P8).
5. ✅ Hecho el 13/10/2026: V1 → V2 y Hoja 5 → Mapeo origen-DW (`Metricas_y_Dimensiones.xlsx` v2.0).
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