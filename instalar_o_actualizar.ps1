<#
.SYNOPSIS
  Instala o actualiza el DW_IE1217 en la PC de cada integrante del equipo.

.DESCRIPTION
  1. Muestra la version del repositorio (etiqueta Git).
  2. Comprueba que esten los 17 CSV en C:\BI_IE1217\data (no van en Git).
  3. Respalda DW_IE1217 si ya existe (BACKUP + RESTORE VERIFYONLY).
  4. Ejecuta scripts\01 a 06 en orden y se detiene en el primer error.
  5. Compara las cifras con las verificadas del lote actual (CHANGELOG).
  6. Con -ConJob: actualiza las copias de C:\BI_IE1217\scripts (las
     anteriores pasan a "versiones antiguas") y recrea el job con el 07.

.EXAMPLE
  .\instalar_o_actualizar.ps1                       # busca solo el SQL Server de esta PC
  .\instalar_o_actualizar.ps1 -Elegir               # muestra la lista de instancias para elegir
  .\instalar_o_actualizar.ps1 -Servidor localhost\SQLEXPRESS   # usa una instancia concreta
  .\instalar_o_actualizar.ps1 -UsuarioSql sa        # login SQL (pide la clave)
  .\instalar_o_actualizar.ps1 -ConJob               # ademas actualiza el job
  .\instalar_o_actualizar.ps1 -SoloVerificar        # no carga nada: solo compara cifras
#>
[CmdletBinding()]
param(
    [string]$Servidor   = '',          # vacio = buscar la instancia de esta PC
    [switch]$Elegir,
    [string]$UsuarioSql = '',
    [switch]$ConJob,
    [switch]$SinRespaldo,
    [switch]$SoloVerificar
)

$ErrorActionPreference = 'Stop'
$Repo     = $PSScriptRoot
$Scripts  = Join-Path $Repo 'scripts'
$Base     = 'C:\BI_IE1217'
$Data     = Join-Path $Base 'data'
$JobDir   = Join-Path $Base 'scripts'
$LogDir   = Join-Path $Base 'logs'
$Sello    = Get-Date -Format 'yyyyMMdd_HHmm'
$Csv = 'institucion','areas_curriculares','competencias','docentes','personal','secciones',
       'carga_horaria','estudiantes','apoderados','matricula','asistencia','notas_competencias',
       'sesiones','monitoreo_docente','materiales','entrega_materiales','convivencia'

function Paso($t)  { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   OK  $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "   !!  $t" -ForegroundColor Yellow }
function Falla($t) { Write-Host "   XX  $t" -ForegroundColor Red; exit 1 }

# Argumentos comunes de sqlcmd (los mismos que usa el job del 07)
$Auth = @('-E')
if ($UsuarioSql) {
    $sec = Read-Host "Clave de $UsuarioSql" -AsSecureString
    $env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $Auth = @('-U', $UsuarioSql)
}
function Sql([string]$query, [string]$db = 'master') {
    # En PowerShell 5.1 el texto de error de sqlcmd con 'Stop' corta el script sin
    # explicacion: se captura aqui y se muestra con Falla.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & sqlcmd -S $Servidor @Auth -C -b -W -h -1 -s '|' -d $db -Q ("SET NOCOUNT ON; " + $query) 2>&1
    $code = $LASTEXITCODE; $ErrorActionPreference = $prev
    if ($code -ne 0) { Falla ("sqlcmd: " + (($out | ForEach-Object { "$_" }) -join ' ').Trim()) }
    return $out
}

function Probar([string]$s) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & sqlcmd -S $s @Auth -C -l 8 -b -h -1 -Q "SET NOCOUNT ON; SELECT 1" 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $prev
    return $ok
}

# ---------------------------------------------------------------------------
Paso 'Requisitos'
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { Falla 'No se encuentra sqlcmd. Instala las herramientas de linea de comandos de SQL Server.' }
Ok 'sqlcmd disponible'

# ---------------------------------------------------------------------------
Paso 'Servidor SQL Server'
$EsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$AgenteSvc = 'NT SERVICE\SQLSERVERAGENT'
if ($Servidor) {
    if (-not (Probar $Servidor)) { Falla "No se pudo conectar a '$Servidor'. Revisa el nombre de la instancia y que su servicio este iniciado." }
    Ok "Servidor indicado: $Servidor"
    if ($Servidor -match '\\(.+)$') { $AgenteSvc = 'NT SERVICE\SQLAgent$' + $Matches[1] }
} else {
    # Instancias instaladas en esta PC: MSSQLSERVER (predeterminada) o MSSQL$NOMBRE (con nombre)
    $inst = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' } | ForEach-Object {
        $n = if ($_.Name -eq 'MSSQLSERVER') { '' } else { $_.Name.Substring(6) }
        [pscustomobject]@{
            Servidor = if ($n) { "localhost\$n" } else { 'localhost' }
            Servicio = $_.Name
            Agente   = if ($n) { 'NT SERVICE\SQLAgent$' + $n } else { 'NT SERVICE\SQLSERVERAGENT' }
            Estado   = "$($_.Status)"
        } })
    if ($inst.Count -eq 0) { Falla 'No hay ningun SQL Server instalado en esta PC (no se encontro el servicio MSSQLSERVER ni MSSQL$...). Si usas uno remoto: -Servidor NOMBRE.' }
    foreach ($i in $inst | Where-Object { $_.Estado -ne 'Running' }) {
        if ($EsAdmin) {
            try { Start-Service -Name $i.Servicio -ErrorAction Stop; $i.Estado = 'Running'; Ok "Servicio $($i.Servicio) iniciado" }
            catch { Aviso "No se pudo iniciar $($i.Servicio): $($_.Exception.Message)" }
        } else {
            Aviso ("$($i.Servidor) esta detenido. Para usarlo, abre PowerShell como administrador y ejecuta: Start-Service '" + $i.Servicio + "'")
        }
    }
    $listas = @($inst | Where-Object { $_.Estado -eq 'Running' })
    if ($listas.Count -eq 0) { Falla 'Ninguna instancia de SQL Server esta iniciada. Iniciala (ver aviso) o ejecuta este instalador como administrador.' }
    $elegida = $listas[0]
    if ($listas.Count -gt 1 -or $Elegir) {
        Write-Host '   Instancias iniciadas en esta PC:'
        for ($k = 0; $k -lt $listas.Count; $k++) { Write-Host ("     [{0}] {1}" -f ($k + 1), $listas[$k].Servidor) }
        do { $op = Read-Host '   Numero de la instancia a usar' } until ($op -match '^\d+$' -and [int]$op -ge 1 -and [int]$op -le $listas.Count)
        $elegida = $listas[[int]$op - 1]
    }
    $Servidor = $elegida.Servidor; $AgenteSvc = $elegida.Agente
    if (-not (Probar $Servidor)) { Falla "El servicio de '$Servidor' esta iniciado pero no acepta la conexion. Prueba con -Servidor NOMBRE o revisa tu usuario en SQL Server." }
    Ok "Servidor encontrado: $Servidor"
}
Write-Host "   Usa este mismo nombre en Power BI (parametro Servidor): $Servidor" -ForegroundColor Gray
$ver = (Sql "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(30)) + ' ' + CAST(SERVERPROPERTY('Edition') AS NVARCHAR(60));") | Select-Object -First 1
Ok "SQL Server: $ver"
$tag = ''
if (Get-Command git -ErrorAction SilentlyContinue) {
    $tag = (& git -C $Repo describe --tags --always --dirty 2>$null)
    Ok "Version del repositorio: $tag"
    if ($tag -match '-dirty') { Aviso 'Hay cambios sin commit en el repositorio: se ejecutan tal como estan.' }
} else { Aviso 'git no esta instalado: no se puede mostrar la version.' }
foreach ($n in '01_staging','02_diagnostico','03_dimensiones','04_fac_matricula','05_fac_preparacion','06_fac_aprendizajes','07_job_sql_agent') {
    if (-not (Test-Path (Join-Path $Scripts "$n.sql"))) { Falla "Falta scripts\$n.sql en el repositorio." }
}
Ok 'Scripts 01 a 07 presentes'

# ---------------------------------------------------------------------------
if (-not $SoloVerificar) {
    Paso 'Datos (C:\BI_IE1217\data)'
    $faltan = @($Csv | Where-Object { -not (Test-Path (Join-Path $Data "$_.csv")) })
    if ($faltan.Count -gt 0) { Falla ("Faltan CSV en ${Data}: " + ($faltan -join ', ') + '. Pidelos al equipo (no van en Git).') }
    Ok '17 CSV presentes'

    Paso 'Respaldo'
    $existe = (Sql "SELECT CASE WHEN DB_ID('DW_IE1217') IS NULL THEN 0 ELSE 1 END;") | Select-Object -First 1
    if ("$existe".Trim() -eq '0') { Ok 'DW_IE1217 no existe todavia: el 01 la crea.' }
    elseif ($SinRespaldo) { Aviso 'Respaldo omitido por -SinRespaldo.' }
    else {
        $nombre = "DW_IE1217_pre_" + (($tag -replace '[^A-Za-z0-9._-]', '_')) + "_$Sello.bak"
        $r = Sql ("DECLARE @p NVARCHAR(400) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(300)) + N'\" + $nombre + "'; " +
                  "BACKUP DATABASE DW_IE1217 TO DISK = @p WITH INIT, CHECKSUM; RESTORE VERIFYONLY FROM DISK = @p WITH CHECKSUM; SELECT @p;")
        Ok ("Respaldo verificado: " + ($r | Select-Object -Last 1))
    }

    Paso 'Carga 01 a 06'
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    foreach ($n in '01_staging','02_diagnostico','03_dimensiones','04_fac_matricula','05_fac_preparacion','06_fac_aprendizajes') {
        $log = Join-Path $LogDir "manual_${n}_$Sello.log"
        $t0 = Get-Date
        & sqlcmd -S $Servidor @Auth -C -b -I -x -W -f 65001 -i (Join-Path $Scripts "$n.sql") -o $log
        $code = $LASTEXITCODE
        $s = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        if ($code -ne 0) {
            Write-Host (Get-Content $log -Tail 30 | Out-String)
            Falla "$n fallo (codigo $code). Log completo: $log. La base se puede restaurar desde el respaldo."
        }
        Ok "$n ($s s)"
    }
}

# ---------------------------------------------------------------------------
Paso 'Cifras (lote verificado: ver CHANGELOG)'
$q = @"
SELECT 'Matriculas en el hecho', COUNT(*), 600 FROM dm_matricula.FacMatricula
UNION ALL SELECT 'Matriculas validadas', SUM(MatriculasValidadas), 579 FROM dm_matricula.FacMatricula
UNION ALL SELECT 'Matriculas rechazadas', SUM(MatriculasRechazadas), 21 FROM dm_matricula.FacMatricula
UNION ALL SELECT 'Filas de FacSesion', COUNT(*), 879 FROM dm_preparacion.FacSesion
UNION ALL SELECT 'Sesiones programadas', SUM(SesionesProgramadas), 6352 FROM dm_preparacion.FacSesion
UNION ALL SELECT 'Filas de FacEntregaMaterial', COUNT(*), 100 FROM dm_preparacion.FacEntregaMaterial
UNION ALL SELECT 'Notas en el hecho', COUNT(*), 44815 FROM dm_aprendizajes.FacLogroCompetencia
UNION ALL SELECT 'Notas sin evidencia', COUNT(*) - SUM(NotasConEvidencia), 379 FROM dm_aprendizajes.FacLogroCompetencia
UNION ALL SELECT 'Filas en la bitacora de notas', COUNT(*), 581 FROM stg.BitacoraNota;
"@
$dif = 0
foreach ($linea in (Sql $q 'DW_IE1217')) {
    $c = "$linea".Split('|'); if ($c.Count -lt 3) { continue }
    if ($c[1].Trim() -eq $c[2].Trim()) { Ok ("{0,-30} {1}" -f $c[0], $c[1]) }
    else { $dif++; Aviso ("{0,-30} {1} (esperado {2})" -f $c[0], $c[1], $c[2]) }
}
if ($dif -gt 0) { Aviso "$dif cifra(s) distinta(s): revisa que tus CSV sean los del equipo y que estes en la ultima version." }

# ---------------------------------------------------------------------------
if ($ConJob) {
    Paso 'Job de SQL Server Agent'
    $ed = (Sql "SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT);") | Select-Object -First 1
    if ("$ed".Trim() -eq '4') { Falla 'Esta instancia es Express: no trae SQL Server Agent.' }
    foreach ($d in $JobDir, $LogDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    $viejos = @(Get-ChildItem $JobDir -File -Filter '*.sql')
    if ($viejos.Count -gt 0) {
        $dest = Join-Path $JobDir "versiones antiguas\$Sello"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $viejos | Move-Item -Destination $dest
        Ok "Copias anteriores movidas a $dest"
    }
    Copy-Item (Join-Path $Scripts '0*.sql') $JobDir
    Ok "Scripts 01 a 07 copiados a $JobDir"
    if ($EsAdmin) {
        & icacls $JobDir /grant "${AgenteSvc}:(OI)(CI)R" | Out-Null
        & icacls $Data   /grant "${AgenteSvc}:(OI)(CI)R" | Out-Null
        & icacls $LogDir /grant "${AgenteSvc}:(OI)(CI)M" | Out-Null
        Ok 'Permisos del Agente aplicados'
    } else { Aviso 'Sin permisos de administrador: si es la primera vez, abre PowerShell como administrador y vuelve a ejecutar con -ConJob.' }
    $log = Join-Path $LogDir "manual_07_job_$Sello.log"
    & sqlcmd -S $Servidor @Auth -C -b -I -x -W -f 65001 -i (Join-Path $JobDir '07_job_sql_agent.sql') -o $log
    if ($LASTEXITCODE -ne 0) { Write-Host (Get-Content $log -Tail 30 | Out-String); Falla "El 07 fallo. Log: $log" }
    Ok 'Job ETL_IE1217_Carga recreado (ver el log para los 10 pasos)'
}

Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue
Paso 'Listo'
