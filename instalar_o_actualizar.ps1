<#
.SYNOPSIS
  Instala o actualiza el DW_IE1217 en la PC de cada integrante del equipo.

.DESCRIPTION
  1. Muestra la version del repositorio (etiqueta Git).
  2. Prepara C:\BI_IE1217, que es lo unico que leen el ETL y el job:
       data\     los 17 CSV. Si el repositorio tiene data_sinte\ (no va en
                 Git), se copian de ahi; si no, se usan los que ya esten en C.
                 Se comparan con las huellas del equipo (datos_base.sha256).
       scripts\  copias de scripts\01 a 07 del repositorio (las ejecuta el
                 job). Las que cambiaron pasan a "versiones antiguas".
       lotes\    00_base (CSV intactos) y los lotes de demostracion.
       logs\     un log por script.
  3. Respalda DW_IE1217 si ya existe (BACKUP + RESTORE VERIFYONLY).
  4. Ejecuta scripts\01 a 06 en orden y se detiene en el primer error.
  5. Compara las cifras con las verificadas del lote actual (CHANGELOG).
  6. Con -ConJob: da los permisos al Agente y recrea el job con el 07.
  7. Anota en C:\BI_IE1217\instalado.json que version quedo instalada, en
     que servidor y con que huellas. Lo lee centro_control\demo.cmd.
  Nada se borra: lo reemplazado pasa a una carpeta "versiones antiguas".

.EXAMPLE
  .\instalar_o_actualizar.ps1                       # busca solo el SQL Server de esta PC
  .\instalar_o_actualizar.ps1 -Elegir               # muestra la lista de instancias para elegir
  .\instalar_o_actualizar.ps1 -Servidor localhost\SQLEXPRESS   # usa una instancia concreta
  .\instalar_o_actualizar.ps1 -UsuarioSql sa        # login SQL (pide la clave)
  .\instalar_o_actualizar.ps1 -ConJob               # ademas actualiza el job
  .\instalar_o_actualizar.ps1 -SoloVerificar        # no carga nada: solo compara cifras
  .\instalar_o_actualizar.ps1 -SoloPreparar         # prepara C:\BI_IE1217 sin recargar la base
  .\instalar_o_actualizar.ps1 -RestaurarDatos       # data\ vuelve a los CSV base (p. ej. tras un lote de demostracion)
  .\instalar_o_actualizar.ps1 -ActualizarHuellas    # quien mantiene los CSV: regenera datos_base.sha256 desde data_sinte\
#>
[CmdletBinding()]
param(
    [string]$Servidor   = '',          # vacio = buscar la instancia de esta PC
    [switch]$Elegir,
    [string]$UsuarioSql = '',
    [switch]$ConJob,
    [switch]$SinRespaldo,
    [switch]$SoloVerificar,
    [switch]$SoloPreparar,
    [switch]$RestaurarDatos,
    [switch]$ActualizarHuellas
)

$ErrorActionPreference = 'Stop'
$Repo     = $PSScriptRoot
$Scripts  = Join-Path $Repo 'scripts'
$Base     = 'C:\BI_IE1217'      # ruta comun del equipo: la usan el 01 (BULK INSERT) y el job del 07
$Data     = Join-Path $Base 'data'
$JobDir   = Join-Path $Base 'scripts'
$LogDir   = Join-Path $Base 'logs'
$Lotes    = Join-Path $Base 'lotes'
$BaseLote = Join-Path $Lotes '00_base'
$Fuente   = Join-Path $Repo 'data_sinte'          # copia local de los CSV (no va en Git)
$Huellas  = Join-Path $Repo 'datos_base.sha256'   # huellas SHA-256 de los CSV del equipo (si va en Git)
$Centro   = Join-Path $Repo 'centro_control'
$Registro = Join-Path $Base 'instalado.json'
$Sql7     = '01_staging','02_diagnostico','03_dimensiones','04_fac_matricula','05_fac_preparacion','06_fac_aprendizajes','07_job_sql_agent'
$Sello    = Get-Date -Format 'yyyyMMdd_HHmm'
$Csv = 'institucion','areas_curriculares','competencias','docentes','personal','secciones',
       'carga_horaria','estudiantes','apoderados','matricula','asistencia','notas_competencias',
       'sesiones','monitoreo_docente','materiales','entrega_materiales','convivencia'

function Paso($t)  { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "   OK  $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "   !!  $t" -ForegroundColor Yellow }
function Falla($t) { Write-Host "   XX  $t" -ForegroundColor Red; exit 1 }
function Huella($ruta) { (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash.ToLower() }
function Carpeta($d) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
function Completa($d) { (Test-Path $d) -and (@($Csv | Where-Object { -not (Test-Path (Join-Path $d "$_.csv")) }).Count -eq 0) }
# Copia un archivo solo si falta o cambio; el anterior pasa a "versiones antiguas\<fecha>" (nunca se borra).
function Poner($origen, $destino) {
    if (Test-Path $destino) {
        if ((Huella $origen) -eq (Huella $destino)) { return $false }
        $va = Join-Path (Split-Path $destino -Parent) "versiones antiguas\$Sello"
        Carpeta $va; Move-Item -LiteralPath $destino -Destination $va -Force
    }
    Copy-Item -LiteralPath $origen -Destination $destino; return $true
}

if ($ActualizarHuellas) {
    Paso 'Huellas de los CSV (datos_base.sha256)'
    if (-not (Completa $Fuente)) { Falla "Faltan CSV en ${Fuente}: no se pueden calcular las huellas." }
    $lin = foreach ($n in ($Csv | Sort-Object)) { (Huella (Join-Path $Fuente "$n.csv")) + '  ' + "$n.csv" }
    [IO.File]::WriteAllText($Huellas, (($lin -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Ok "Escritas $($Csv.Count) huellas en $Huellas. Subelas a Git junto con el cambio de datos y avisa al equipo."
    exit 0
}

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
foreach ($n in $Sql7) {
    if (-not (Test-Path (Join-Path $Scripts "$n.sql"))) { Falla "Falta scripts\$n.sql en el repositorio." }
}
Ok 'Scripts 01 a 07 presentes'

# ---------------------------------------------------------------------------
$EstadoDatos = 'sin verificar'; $Distintos = @()
if (-not $SoloVerificar) {
    Paso 'Carpetas de trabajo (C:\BI_IE1217)'
    foreach ($d in $Base, $Data, $JobDir, $LogDir, $Lotes) { Carpeta $d }
    Ok 'data, scripts, lotes y logs listas'

    Paso 'Datos'
    $esperada = @{}
    if (Test-Path $Huellas) {
        foreach ($l in [IO.File]::ReadAllLines($Huellas)) { if ($l -match '^([0-9a-f]{64})\s+(\S+)$') { $esperada[$Matches[2]] = $Matches[1] } }
    } else { Aviso 'No esta datos_base.sha256 en el repositorio: no se puede comprobar que tus CSV sean los del equipo.' }

    # De donde salen los CSV base: data_sinte\ del repositorio si esta completa; si no, lotes\00_base de una instalacion anterior.
    $Origen = if (Completa $Fuente) { $Fuente } elseif (Completa $BaseLote) { $BaseLote } else { $null }
    if ($Origen -eq $Fuente) {
        $malos = @($Csv | Where-Object { $esperada.ContainsKey("$_.csv") -and (Huella (Join-Path $Fuente "$_.csv")) -ne $esperada["$_.csv"] })
        if ($esperada.Count -gt 0 -and $malos.Count -eq 0) { Ok 'data_sinte\ del repositorio: los 17 CSV coinciden con las huellas del equipo' }
        elseif ($malos.Count -gt 0) { Aviso ("data_sinte\ tiene CSV distintos de los del equipo: " + ($malos -join ', ') + '. Pide el paquete vigente (o, si tu los actualizaste, usa -ActualizarHuellas).') }
    } elseif ($Origen) { Ok 'Sin data_sinte\ en el repositorio: se toma como base lotes\00_base de la instalacion anterior' }
    else { Aviso 'Sin data_sinte\ en el repositorio: se usan los CSV que ya esten en C:\BI_IE1217\data' }

    # data\: lo que lee el 01. Lo que falta se copia; lo distinto no se pisa sin -RestaurarDatos.
    $faltan = @(); $copiados = 0
    foreach ($n in $Csv) {
        $dst = Join-Path $Data "$n.csv"
        if (-not (Test-Path $dst)) {
            if ($Origen) { Copy-Item -LiteralPath (Join-Path $Origen "$n.csv") -Destination $dst; $copiados++ } else { $faltan += "$n.csv" }
            continue
        }
        $ref = if ($Origen) { Huella (Join-Path $Origen "$n.csv") } elseif ($esperada.ContainsKey("$n.csv")) { $esperada["$n.csv"] } else { $null }
        if ($ref -and (Huella $dst) -ne $ref) { $Distintos += "$n.csv" }
    }
    if ($faltan.Count -gt 0) { Falla ("Faltan CSV en ${Data}: " + ($faltan -join ', ') + ". Pide el paquete al equipo (no va en Git) y descomprimelo en $Fuente o en $Data.") }
    if ($copiados -gt 0) { Ok "$copiados CSV copiados a $Data" }
    if ($Distintos.Count -gt 0 -and $RestaurarDatos -and $Origen) {
        foreach ($f in $Distintos) { [void](Poner (Join-Path $Origen $f) (Join-Path $Data $f)) }
        Ok ("Restaurados a la base: " + ($Distintos -join ', ') + " (los anteriores, en $Data\versiones antiguas\$Sello)")
        $Distintos = @()
    }
    if ($Distintos.Count -gt 0) {
        $EstadoDatos = 'modificados'
        Aviso ("data\ no esta en el estado base: " + ($Distintos -join ', ') + '.')
        Aviso 'Es lo normal si aplicaste un lote de demostracion o un registro manual. Se cargan tal como estan; para volver a la base: -RestaurarDatos.'
    } elseif ($Origen -or $esperada.Count -gt 0) { $EstadoDatos = 'base'; Ok '17 CSV presentes en data\ y en el estado base' }
    else { Ok '17 CSV presentes en data\ (sin referencia para compararlos)' }

    # lotes\00_base y lotes de demostracion (los usa centro_control\demo.cmd)
    $paraBase = if ($Origen -eq $Fuente) { $Fuente } elseif (-not $Origen -and $Distintos.Count -eq 0) { $Data } else { $null }
    if ($paraBase) { Carpeta $BaseLote; $n0 = 0; foreach ($n in $Csv) { if (Poner (Join-Path $paraBase "$n.csv") (Join-Path $BaseLote "$n.csv")) { $n0++ } }; if ($n0 -gt 0) { Ok "lotes\00_base actualizado ($n0 archivos)" } }
    if ((Completa $BaseLote) -and (Test-Path (Join-Path $Centro 'gen_lotes.ps1'))) {
        try { $r = & (Join-Path $Centro 'gen_lotes.ps1') -Raiz $Base; Ok ("Lotes de demostracion listos en ${Lotes}: " + (@(Get-ChildItem $Lotes -Directory | Where-Object { $_.Name -match '^\d\d_' -and $_.Name -ne '00_base' }).Count)) }
        catch { Aviso "No se pudieron generar los lotes de demostracion: $($_.Exception.Message)" }
    } else { Aviso 'Sin lotes\00_base no se generan los lotes de demostracion (el ETL funciona igual).' }

    Paso 'Scripts del job (C:\BI_IE1217\scripts)'
    $act = @($Sql7 | Where-Object { Poner (Join-Path $Scripts "$_.sql") (Join-Path $JobDir "$_.sql") })
    if ($act.Count -gt 0) { Ok ("Actualizados desde el repositorio: " + ($act -join ', ')) } else { Ok 'Iguales a los del repositorio' }
}

if (-not $SoloVerificar -and -not $SoloPreparar) {
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
$dif = 0; $HayBase = $true
if ($SoloPreparar) { $HayBase = ("$((Sql "SELECT CASE WHEN DB_ID('DW_IE1217') IS NULL THEN 0 ELSE 1 END;") | Select-Object -First 1)".Trim() -eq '1') }
if ($HayBase) {
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
foreach ($linea in (Sql $q 'DW_IE1217')) {
    $c = "$linea".Split('|'); if ($c.Count -lt 3) { continue }
    if ($c[1].Trim() -eq $c[2].Trim()) { Ok ("{0,-30} {1}" -f $c[0], $c[1]) }
    else { $dif++; Aviso ("{0,-30} {1} (esperado {2})" -f $c[0], $c[1], $c[2]) }
}
if ($dif -gt 0 -and $EstadoDatos -eq 'modificados') { Aviso "$dif cifra(s) distinta(s): es lo esperado, porque data\ no esta en el estado base (ver arriba)." }
elseif ($dif -gt 0 -and $SoloPreparar) { Aviso "$dif cifra(s) distinta(s): la base no se recargo en esta corrida (-SoloPreparar)." }
elseif ($dif -gt 0) { Aviso "$dif cifra(s) distinta(s): revisa que tus CSV sean los del equipo y que estes en la ultima version." }
} else { Paso 'Cifras'; Aviso 'DW_IE1217 todavia no existe: ejecuta el instalador sin -SoloPreparar para crearla.' }

# ---------------------------------------------------------------------------
if ($ConJob) {
    Paso 'Job de SQL Server Agent'
    $ed = (Sql "SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT);") | Select-Object -First 1
    if ("$ed".Trim() -eq '4') { Falla 'Esta instancia es Express: no trae SQL Server Agent.' }
    foreach ($d in $JobDir, $LogDir) { Carpeta $d }
    foreach ($n in $Sql7) { [void](Poner (Join-Path $Scripts "$n.sql") (Join-Path $JobDir "$n.sql")) }
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

# ---------------------------------------------------------------------------
if (-not $SoloVerificar) {
    $h = [ordered]@{}; foreach ($n in $Sql7) { $h["$n.sql"] = Huella (Join-Path $JobDir "$n.sql") }
    $reg = [ordered]@{
        version    = "$tag"
        fecha      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        servidor   = $Servidor
        usuarioSql = $UsuarioSql
        agente     = ($AgenteSvc -replace '^NT SERVICE\\', '')
        repo       = $Repo
        datos      = $EstadoDatos
        baseCargada = [bool](-not $SoloPreparar)
        cifrasDistintas = $dif
        scripts    = $h
    }
    [IO.File]::WriteAllText($Registro, ($reg | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Paso 'Registro de instalacion'
    Ok "Anotado en $Registro"
    if (Test-Path (Join-Path $Centro 'demo.cmd')) { Write-Host "   Centro de control del ETL (lotes, job y seguimiento): $(Join-Path $Centro 'demo.cmd')" -ForegroundColor Gray }
}

Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue
Paso 'Listo'
