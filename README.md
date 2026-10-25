# Data Warehouse I.E.P. N° 1217 — ETL

Proyecto del curso de Business Intelligence (UPeU). Carga tres datamarts (matrícula, preparación curricular y aprendizajes) en SQL Server, base `DW_IE1217`.

## Versión vigente

**v6.5** (dimensiones y hechos según la matriz de métricas y dimensiones v2.2: DimCurso, DimNivelAcademico y cuatro hechos; etiqueta `v6.5`). El historial de cambios está en [CHANGELOG.md](CHANGELOG.md).
Para ver todas las versiones: `git tag`.

## Estructura

- `scripts/`: ETL en orden. 01 staging · 02 diagnóstico (solo lectura) · 03 dimensiones · 04 matrícula · 05 preparación · 06 aprendizajes · 07 job de SQL Server Agent.
- `docs/`: guías e insumos (matriz BI, métricas).
- `_contexto/`: bitácora del proyecto. Es la fuente de verdad del estado, las decisiones (D) y los pendientes (P).

## Antes de ejecutar

1. `git pull`, y elige la versión: `git checkout v5.2` (o quédate en `main`).
2. Copia `scripts/*.sql` a `C:\BI_IE1217\scripts`.
3. Los CSV no están en el repositorio. Van en `C:\BI_IE1217\data`.

## Orden de ejecución

- Manual: 01 → 02 → 03 → 04 → 05 → 06, cada uno con F5 y sin texto seleccionado.
- Automático: job `ETL_IE1217_Carga` (script 07).

## Convenciones

### Commits

Formato: `tipo(área): descripción en imperativo`

- `fix`: corrección · `feat`: capacidad nueva · `docs`: documentación · `refactor`: sin cambio de resultados · `chore`: mantenimiento.
- Ejemplos: `fix(dw): quitar AreaKey de DimCompetencia (D21)` · `docs(bitacora): registrar resultado de la primera carga`
- Un commit = un cambio lógico.

### Versiones

- Cada versión es una etiqueta anotada (`v5.1`, `v5.2`, …). Los archivos no llevan número de versión en su nombre.
- Se etiqueta solo lo que se ejecutó y verificó en SQL Server. Anota la fecha y las cifras en `CHANGELOG.md`.
- El trabajo en curso va a `main` sin etiqueta hasta verificarse.

### Ramas

- Cambios chicos: commit directo a `main`.
- Cambios grandes o de modelo: rama `feature/nombre` y luego merge o Pull Request.

## Qué no va al repositorio

- `data_sinte/`, `data/` y `*.rar`: contienen datos de estudiantes (DNI, nombres, notas).
- Temporales de Office (`~$*`).

## Reglas y decisiones

Las reglas de trabajo, las decisiones (D01–D22) y los pendientes (P1–P11) están en `_contexto/BITACORA_CONTEXTO_DW_IE1217.md`.
