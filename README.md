# Data Warehouse I.E.P. N° 1217 — ETL

Proyecto del curso de Business Intelligence (UPeU). Carga tres datamarts (matrícula, preparación curricular y aprendizajes) en SQL Server, base `DW_IE1217`.

## Versión vigente

**v6.5.2** (verificada el 27/10/2026): seis dimensiones (DimTiempo, DimEstudiante, DimDocente, DimNivelAcademico, DimCurso, DimTipoMatricula) y cuatro hechos (FacMatricula, FacSesion, FacEntregaMaterial, FacLogroCompetencia), según la matriz de métricas y dimensiones v2.3. El historial de cambios está en [CHANGELOG.md](CHANGELOG.md).
Para ver todas las versiones: `git tag`.

## Estructura

- `scripts/`: ETL en orden. 01 staging · 02 diagnóstico (solo lectura) · 03 dimensiones · 04 matrícula · 05 preparación · 06 aprendizajes · 07 job de SQL Server Agent.
- `docs/`: guías e insumos (matriz BI, métricas).
- `_contexto/`: bitácora del proyecto. Es la fuente de verdad del estado, las decisiones (D) y los pendientes (P).
- `instalar_o_actualizar.ps1` (y `.cmd`): instala o actualiza la base en tu PC y compara las cifras.

## Instalar o actualizar (cada integrante)

Cada uno tiene su propio SQL Server, su propia base `DW_IE1217` y su propio `C:\BI_IE1217`: nada se comparte entre PCs.

1. `git pull` (todos en la misma versión: no mezclar versiones).
2. Los CSV no están en el repositorio (datos del colegio). Van en `C:\BI_IE1217\data`, con permiso de lectura para `NT Service\MSSQLSERVER`.
3. Doble clic en `instalar_o_actualizar.cmd`. El script:
   - muestra la versión del repositorio y comprueba los 17 CSV;
   - respalda `DW_IE1217` si ya existe (y verifica el respaldo);
   - ejecuta `scripts/01` a `06` en orden y se detiene en el primer error (logs en `C:\BI_IE1217\logs`);
   - compara las cifras con las verificadas (600 matrículas, 6 352 sesiones, 44 815 notas + 581 en la bitácora…). Si alguna sale distinta, revisa tus CSV o tu versión.

Opciones (desde una consola en la carpeta del repositorio):

| Comando | Para qué |
| --- | --- |
| `.\instalar_o_actualizar.cmd -UsuarioSql sa` | Usar un login SQL en vez de Windows (pide la clave) |
| `.\instalar_o_actualizar.cmd -ConJob` | Además actualiza el job del Agente (ver abajo). La primera vez, en una consola de administrador |
| `.\instalar_o_actualizar.cmd -SoloVerificar` | No carga nada: solo compara las cifras |
| `.\instalar_o_actualizar.cmd -SinRespaldo` | Omite el respaldo |

### Job de SQL Server Agent (opcional)

El job `ETL_IE1217_Carga` (script 07) **no lee el repositorio**: ejecuta las copias de `C:\BI_IE1217\scripts`. Con cada versión nueva hay que actualizarlas y recrear el job; `-ConJob` lo hace (mueve las copias anteriores a `C:\BI_IE1217\scripts\versiones antiguas\`). La edición Express no trae Agente.

## Ejecución manual

01 → 02 → 03 → 04 → 05 → 06 en SSMS, cada uno completo con F5 y sin texto seleccionado. Con una base que ya existe basta del 03 al 06.

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

Las reglas de trabajo, las decisiones (D01–D34) y los pendientes (P1–P22) están en `_contexto/BITACORA_CONTEXTO_DW_IE1217.md`.
