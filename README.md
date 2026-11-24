# Data Warehouse I.E.P. N° 1217 — ETL

Proyecto del curso de Business Intelligence (UPeU). Carga tres datamarts (matrícula, preparación curricular y aprendizajes) en SQL Server, base `DW_IE1217`.

> **Datos sintéticos.** Los CSV de `data_sinte/` fueron generados con IA para este curso. Los DNI, códigos, nombres, direcciones, teléfonos, notas y registros son ficticios: no corresponden a estudiantes, apoderados, docentes ni personal reales de la institución. Cualquier coincidencia con una persona real es casual.

## Versión vigente

**v6.5.2** (verificada el 27/10/2026): seis dimensiones (DimTiempo, DimEstudiante, DimDocente, DimNivelAcademico, DimCurso, DimTipoMatricula) y cuatro hechos (FacMatricula, FacSesion, FacEntregaMaterial, FacLogroCompetencia), según la matriz de métricas y dimensiones v2.3. El historial de cambios está en [CHANGELOG.md](CHANGELOG.md).
Para ver todas las versiones: `git tag`.

## Estructura

- `scripts/`: ETL en orden. 01 staging · 02 diagnóstico (solo lectura) · 03 dimensiones · 04 matrícula · 05 preparación · 06 aprendizajes · 07 job de SQL Server Agent.
- `docs/`: guías e insumos (matriz BI, métricas).
- `_contexto/`: bitácora del proyecto. Es la fuente de verdad del estado, las decisiones (D) y los pendientes (P).
- `instalar_o_actualizar.ps1` (y `.cmd`): prepara `C:\BI_IE1217`, instala o actualiza la base en tu PC y compara las cifras.
- `centro_control/`: `demo.cmd`, el centro de control del ETL (lotes de demostración, registro manual, lanzamiento y seguimiento del job). Trabaja sobre `C:\BI_IE1217`.
- `data_sinte/`: los 17 CSV de origen (sintéticos) y su diccionario de datos.
- `datos_base.sha256`: huellas SHA-256 de esos 17 CSV; el instalador comprueba con ellas que nadie cargue archivos modificados.

## Instalar o actualizar (cada integrante)

Cada uno tiene su propio SQL Server, su propia base `DW_IE1217` y su propio `C:\BI_IE1217`: nada se comparte entre PCs.

1. `git pull` (todos en la misma versión: no mezclar versiones).
2. Los CSV vienen en el repositorio, en `data_sinte\` (datos sintéticos): no hay que pedirlos ni copiarlos a mano.
3. Doble clic en `instalar_o_actualizar.cmd`. El script:
   - muestra la versión del repositorio y comprueba que tus 17 CSV sean los del equipo (`datos_base.sha256`);
   - prepara `C:\BI_IE1217`: `data\` (los CSV que lee el ETL), `scripts\` (copias de `scripts/01` a `07`, las que ejecuta el job), `lotes\` (estado base y lotes de demostración) y `logs\`. Lo que reemplaza pasa a una carpeta `versiones antiguas`; no borra nada;
   - respalda `DW_IE1217` si ya existe (y verifica el respaldo);
   - ejecuta `scripts/01` a `06` en orden y se detiene en el primer error (logs en `C:\BI_IE1217\logs`);
   - compara las cifras con las verificadas (600 matrículas, 6 352 sesiones, 44 815 notas + 581 en la bitácora…). Si alguna sale distinta, revisa tus CSV o tu versión;
   - anota en `C:\BI_IE1217\instalado.json` la versión instalada, el servidor y las huellas.

`C:\BI_IE1217` es la misma ruta en todas las PC porque el script 01 y el job la usan; el repositorio puede estar en cualquier carpeta. En `C:\BI_IE1217` no se edita nada a mano.

Opciones (desde una consola en la carpeta del repositorio):

| Comando | Para qué |
| --- | --- |
| `.\instalar_o_actualizar.cmd -Elegir` | Muestra las instancias de SQL Server iniciadas en tu PC y te deja elegir (sin opciones, el instalador usa la única que encuentre) |
| `.\instalar_o_actualizar.cmd -Servidor localhost\SQLEXPRESS` | Usa una instancia concreta (con nombre o remota) |
| `.\instalar_o_actualizar.cmd -UsuarioSql sa` | Usar un login SQL en vez de Windows (pide la clave) |
| `.\instalar_o_actualizar.cmd -ConJob` | Además actualiza el job del Agente (ver abajo). La primera vez, en una consola de administrador |
| `.\instalar_o_actualizar.cmd -SoloVerificar` | No carga nada: solo compara las cifras |
| `.\instalar_o_actualizar.cmd -SinRespaldo` | Omite el respaldo |
| `.\instalar_o_actualizar.cmd -SoloPreparar` | Prepara `C:\BI_IE1217` sin recargar la base |
| `.\instalar_o_actualizar.cmd -RestaurarDatos` | Devuelve `data\` a los CSV base (por ejemplo, después de un lote de demostración) |
| `.\instalar_o_actualizar.cmd -ActualizarHuellas` | Solo quien cambia los CSV del equipo: regenera `datos_base.sha256` desde `data_sinte\` |

### Job de SQL Server Agent (opcional)

El job `ETL_IE1217_Carga` (script 07) **no lee el repositorio**: ejecuta las copias de `C:\BI_IE1217\scripts`. El instalador las actualiza en cada corrida (las anteriores pasan a `C:\BI_IE1217\scripts\versiones antiguas\`); `-ConJob` además da los permisos al Agente y recrea el job. La edición Express no trae Agente.

### Centro de control del ETL (demostración)

`centro_control\demo.cmd`, después de haber corrido el instalador una vez. Usa el servidor que anotó el instalador (o `demo.cmd -Servidor NOMBRE`).

- Estado: servidor, versión instalada, si los scripts de `C:\BI_IE1217\scripts` son los del repositorio, Agente, job, filas de los CSV y conteos publicados.
- Lotes de demostración (sesiones nuevas, matrículas nuevas, archivo incompleto y un lote integral que mueve los tres datamarts) con resumen previo de cuántos registros son nuevos; registro manual de una matrícula o una sesión. Todo entra por los CSV de `data\` y pasa por el ETL completo.
- Lanzar y seguir: arranca el job del Agente y muestra cada paso. Si la PC no tiene Agente (Express) o está detenido, ofrece el **modo directo**: los mismos pasos con `sqlcmd` desde la ventana.
- Volver al estado base: restaura los CSV y, tras la recarga, retira de las dimensiones los estudiantes y tipos de matrícula que agregaron los lotes (es la única escritura directa del centro de control sobre el DW; el ETL nunca borra miembros de dimensiones).

Los lotes cambian las cifras verificadas mientras están aplicados: antes de comparar cifras o de sustentar, volver al estado base.

Para comprobar que todo funciona en tu PC: `powershell -ExecutionPolicy Bypass -File centro_control\probar.ps1` ejecuta 23 casos de prueba (unos 3 minutos) y deja todo en el estado base.

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

- `data/`, `*.rar`, `*.zip` y los Excel de `data_sinte/`: copias de trabajo y paquetes. De `data_sinte/` solo se versionan los 17 CSV sintéticos y su diccionario.
- `*.pbix` y la caché de Power BI (`.pbi/cache.abf`): guardan una copia de los datos cargados y configuración personal.
- Temporales de Office (`~$*`).

## Reglas y decisiones

Las reglas de trabajo, las decisiones (D01–D34) y los pendientes (P1–P22) están en `_contexto/BITACORA_CONTEXTO_DW_IE1217.md`.
