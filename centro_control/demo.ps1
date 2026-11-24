# Centro de control del ETL - I.E. 1217. Prepara la entrada (CSV), ordena el arranque del job y LEE el estado.
# Vive en el repositorio (centro_control\) y trabaja sobre C:\BI_IE1217, que deja listo instalar_o_actualizar.cmd.
# El ETL lo ejecuta SQL Server Agent con su propio servicio. Si esa PC no tiene Agente (Express) o esta detenido,
# ofrece el modo directo: los mismos pasos, con sqlcmd, desde esta ventana.
param([string]$Accion = '', [int]$Lote = 0, [string]$Servidor = '')
$ErrorActionPreference = 'Stop'
$raiz = 'C:\BI_IE1217'   # ruta comun del equipo: es la que usan el 01 (BULK INSERT) y el job del 07
$repo = Split-Path -Parent $PSScriptRoot
$data = "$raiz\data"; $lotes = "$raiz\lotes"; $base = "$lotes\00_base"; $logs = "$raiz\logs"
$job = 'ETL_IE1217_Carga'; $utf8 = New-Object Text.UTF8Encoding($false)
$interactivo = ($Accion -eq '')
$pasosEtl = '01_staging', '02_diagnostico', '03_dimensiones', '04_fac_matricula', '05_fac_preparacion', '06_fac_aprendizajes'

# Lo que dejo anotado el instalador (servidor, version, huellas). Si falta, se busca el SQL Server de esta PC.
$inst = $null
if (Test-Path "$raiz\instalado.json") { try { $inst = Get-Content "$raiz\instalado.json" -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $inst = $null } }
if (-not $Servidor) { $Servidor = $env:BI_IE1217_SERVIDOR }
if (-not $Servidor -and $inst -and $inst.servidor) { $Servidor = $inst.servidor }
if (-not $Servidor) {
  $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { ($_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*') -and $_.Status -eq 'Running' })
  if ($svc.Count -gt 0) { $Servidor = if ($svc[0].Name -eq 'MSSQLSERVER') { 'localhost' } else { 'localhost\' + $svc[0].Name.Substring(6) } } else { $Servidor = 'localhost' }
}
$svcAgente = if ($Servidor -match '\\(.+)$') { 'SQLAgent$' + $Matches[1] } else { 'SQLSERVERAGENT' }
$usuarioSql = if ($env:BI_IE1217_USUARIO) { $env:BI_IE1217_USUARIO } elseif ($inst -and $inst.usuarioSql) { "$($inst.usuarioSql)" } else { '' }
$claveSql = ''
if ($usuarioSql) {
  $sec = Read-Host "Clave de $usuarioSql en $Servidor" -AsSecureString
  $claveSql = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
$cadena = New-Object Data.SqlClient.SqlConnectionStringBuilder
$cadena['Data Source'] = $Servidor; $cadena['TrustServerCertificate'] = $true
if ($usuarioSql) { $cadena['User ID'] = $usuarioSql; $cadena['Password'] = $claveSql } else { $cadena['Integrated Security'] = $true }

function Sql($q, $bd = 'DW_IE1217') {
  $cadena['Initial Catalog'] = $bd
  $cn = New-Object Data.SqlClient.SqlConnection $cadena.ConnectionString
  $da = New-Object Data.SqlClient.SqlDataAdapter($q, $cn); $da.SelectCommand.CommandTimeout = 300
  $t = New-Object Data.DataTable; [void]$da.Fill($t); return ,$t
}
function Huella($ruta) { (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash.ToLower() }
function Titulo($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Aviso($t) { Write-Host $t -ForegroundColor Yellow }
function Bien($t) { Write-Host $t -ForegroundColor Green }
function Mal($t) { Write-Host $t -ForegroundColor Red }
function Preguntar($t, $def = '') { if (-not $interactivo) { return $def }; $r = Read-Host $(if ($def -ne '') { "$t [$def]" } else { $t }); if ($r -eq '') { $def } else { $r.Trim() } }
function Confirmar($t) { if (-not $interactivo) { return $true }; (Read-Host "$t (S/N)") -match '^[sS]' }
function Lineas($ruta) { [IO.File]::ReadAllLines($ruta, [Text.Encoding]::UTF8) }
function Filas($ruta) { @(Lineas $ruta | Where-Object { $_.Trim() -ne '' }).Count - 1 }
function Agregar($ruta, $filas) {
  $b = [IO.File]::ReadAllBytes($ruta); $pre = if ($b.Length -gt 0 -and $b[$b.Length - 1] -ne 10) { "`n" } else { '' }
  [IO.File]::AppendAllText($ruta, $pre + (($filas -join "`n") + "`n"), $utf8)
}
# Los datos del colegio llegan hasta una fecha de corte (la ultima sesion cargada). Lo que se registra a mano se fecha
# a partir de ahi, no con la fecha de la PC: asi cae dentro del calendario academico que conoce el DW.
function Corte {
  $m = Lineas "$data\sesiones.csv" | Select-Object -Skip 1 | ForEach-Object { $p = $_.Split(';'); if ($p.Count -gt 3 -and $p[3] -match '^2026-\d\d-\d\d$') { $p[3] } } | Sort-Object | Select-Object -Last 1
  if ($m) { [datetime]::ParseExact($m, 'yyyy-MM-dd', $null) } else { [datetime]'2026-05-08' }
}
function EsFinDeSemana($d) { $d.DayOfWeek -eq [DayOfWeek]::Saturday -or $d.DayOfWeek -eq [DayOfWeek]::Sunday }
function SiguienteHabil($d) { do { $d = $d.AddDays(1) } while (EsFinDeSemana $d); $d }
$ultimoCierre = '2026-07-31'   # ultimo cierre de bimestre de 2026 declarado en el 03 (DimTiempo)
function CuidarHorario {
  $e = EstadoJob
  if (-not ($e.Existe -and $e.Habilitado -and $e.Agente -eq 'Running')) { return }
  Aviso 'El job corre solo cada 15 minutos y puede cargar este cambio antes de que tu lo lances.'
  if ($interactivo -and (Confirmar 'Pausar ese horario mientras pruebas (al salir te pregunto si lo reanudas)')) { Horario $false }
}
# Como se reconoce una fila ya cargada: por su codigo (primer campo), salvo las notas, que no tienen codigo propio
# y se identifican por anio + bimestre + estudiante + area + competencia.
function ClaveFila($archivo, $linea) {
  $p = $linea.Split(';')
  if ($archivo -eq 'notas_competencias.csv' -and $p.Count -gt 5) { return (($p[0], $p[1], $p[2], $p[4], $p[5] | ForEach-Object { $_.Trim().ToUpper() }) -join '|') }
  $p[0].Trim()
}
# Vacantes libres por aula de 2026 = cupo - ocupadas en el DW - aprobadas que ya estan en el CSV y aun no se cargaron.
function VacantesLibres {
  $r = @{}
  foreach ($f in (Sql "SELECT n.CodigoCorto, MAX(f.CupoMaximoAula) AS Cupo, SUM(f.VacantesOcupadas) AS Ocupadas FROM dm_matricula.FacMatricula f JOIN dw.DimNivelAcademico n ON n.NivelAcademicoKey = f.NivelAcademicoKey WHERE f.AnioEscolar = 2026 GROUP BY n.CodigoCorto").Rows) { $r["$($f.CodigoCorto)"] = [pscustomobject]@{ Cupo = [int]$f.Cupo; Libres = [int]$f.Cupo - [int]$f.Ocupadas } }
  $conocidas = @{}; Lineas "$base\matricula.csv" | Select-Object -Skip 1 | ForEach-Object { $conocidas[$_.Split(';')[0].Trim()] = 1 }
  foreach ($f in (Sql "SELECT MatriculaID FROM dm_matricula.FacMatricula WHERE AnioEscolar = 2026").Rows) { $conocidas["$($f.MatriculaID)".Trim()] = 1 }
  Lineas "$data\matricula.csv" | Select-Object -Skip 1 | ForEach-Object {
    $p = $_.Split(';')
    if ($p.Count -gt 13 -and -not $conocidas.ContainsKey($p[0].Trim()) -and $p[13].Trim() -eq 'Aprobado' -and $p[3].Trim().ToUpper() -match '^SEC-2026-(\d[A-Z])$' -and $r.ContainsKey($Matches[1])) { $r[$Matches[1]].Libres-- }
  }
  $r
}
function Limpia($s) { ($s -replace '[;\r\n\t]', ' ').Trim() }

function Totales {
  $t = Sql @"
SELECT (SELECT SUM(MatriculasSolicitadas) FROM dm_matricula.FacMatricula) AS [Matriculas en el hecho],
       (SELECT SUM(MatriculasValidadas) FROM dm_matricula.FacMatricula) AS [Matriculas validadas],
       (SELECT SUM(SesionesProgramadas) FROM dm_preparacion.FacSesion) AS [Sesiones programadas],
       (SELECT SUM(SesionesDictadasHorario) FROM dm_preparacion.FacSesion) AS [Sesiones en horario],
       (SELECT SUM(MaterialesPorEntregar) FROM dm_preparacion.FacEntregaMaterial) AS [Materiales por entregar],
       (SELECT COUNT(*) FROM dm_aprendizajes.FacLogroCompetencia) AS [Notas en el hecho],
       (SELECT COUNT(*) FROM stg.BitacoraNota) AS [Notas en bitacora],
       (SELECT COUNT(*) FROM dw.DimEstudiante WHERE EstudianteKey > 0) AS [Estudiantes (dimension)],
       (SELECT COUNT(*) FROM stg.Matricula) AS [Staging: matricula],
       (SELECT COUNT(*) FROM stg.Sesion) AS [Staging: sesiones],
       (SELECT COUNT(*) FROM stg.NotaCompetencia) AS [Staging: notas]
"@
  $o = [ordered]@{}; foreach ($c in $t.Columns) { $o[$c.ColumnName] = [long]$t.Rows[0][$c.ColumnName] }; $o
}
function EstadoJob {
  $srv = (Sql "SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT) AS Edicion, CASE WHEN OBJECT_ID(N'DW_IE1217.ctl.LoteETL') IS NULL THEN 0 ELSE 1 END AS Ctl" 'master').Rows[0]
  $express = ($srv.Edicion -eq 4); $ag = ''
  if ($express) { $ag = 'no disponible (Express)' }
  else {
    try { $ag = "$((Sql "SELECT TOP (1) status_desc FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' OR servicename LIKE N'Agente SQL Server%'" 'master').Rows[0].status_desc)" } catch { $ag = '' }
    if (-not $ag) { $ag = "$((Get-Service $svcAgente -ErrorAction SilentlyContinue).Status)" }
    if (-not $ag) { $ag = 'desconocido' }
  }
  $t = if ($express) { New-Object Data.DataTable } else { Sql "SELECT j.enabled, (SELECT COUNT(*) FROM msdb.dbo.sysjobactivity a WHERE a.job_id = j.job_id AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL) AS corriendo FROM msdb.dbo.sysjobs j WHERE j.name = N'$job'" 'msdb' }
  [pscustomobject]@{ Existe = ($t.Rows.Count -gt 0); Habilitado = ($t.Rows.Count -gt 0 -and $t.Rows[0].enabled -eq 1); Corriendo = ($t.Rows.Count -gt 0 -and $t.Rows[0].corriendo -gt 0); Agente = $ag; Express = $express; Ctl = ($srv.Ctl -eq 1) }
}
function ScriptsDeC {
  # El job ejecuta las copias de C:\BI_IE1217\scripts: se comparan con las del repositorio por su huella.
  $dif = @(($pasosEtl + '07_job_sql_agent') | Where-Object { -not (Test-Path "$raiz\scripts\$_.sql") -or -not (Test-Path "$repo\scripts\$_.sql") -or (Huella "$raiz\scripts\$_.sql") -ne (Huella "$repo\scripts\$_.sql") })
  if ($dif.Count -eq 0) { 'iguales a los del repositorio' } else { "DISTINTOS del repositorio ($($dif -join ', ')): ejecutar instalar_o_actualizar.cmd" }
}

function VerEstado {
  Titulo 'Estado'
  $e = EstadoJob
  "Servidor: $Servidor   |   Instalado: $(if ($inst) { "$($inst.version) el $($inst.fecha)" } else { 'sin registro (ejecutar instalar_o_actualizar.cmd)' })"
  "Scripts de C:\BI_IE1217\scripts: $(ScriptsDeC)"
  "Agente SQL: $($e.Agente)   |   Job: $(if (-not $e.Existe) { 'no existe (instalar_o_actualizar.cmd -ConJob)' } elseif ($e.Corriendo) { 'CORRIENDO' } else { 'en espera' })   |   Horario cada 15 min: $(if ($e.Habilitado) { 'ACTIVO' } else { 'en pausa' })"
  if ($e.Express) { Aviso 'Esta instancia es Express y no trae Agente: el ETL se lanza en modo directo (opcion 5).' }
  elseif ($e.Agente -ne 'Running') { Aviso 'El Agente SQL no esta iniciado: opcion 8 para iniciarlo, o la opcion 5 ofrece el modo directo.' }
  Titulo 'Archivos de entrada (filas en data\ frente al estado base)'
  foreach ($f in 'matricula.csv', 'estudiantes.csv', 'apoderados.csv', 'sesiones.csv', 'notas_competencias.csv', 'materiales.csv', 'entrega_materiales.csv') {
    $a = Filas "$data\$f"; $b = Filas "$base\$f"; $d = $a - $b
    '{0,-24} {1,7}   base {2,7}   {3}' -f $f, $a, $b, $(if ($d -eq 0) { 'igual' } elseif ($d -gt 0) { "+$d" } else { "$d" })
  }
  Titulo 'Publicado en el DW'
  $t = Totales; foreach ($k in $t.Keys) { '{0,-26} {1,8:N0}' -f $k, $t[$k] }
  if (-not $e.Ctl) { ''; 'Sin historial de corridas: las tablas de control (ctl) las crea el 07, que necesita Agente.'; return }
  Titulo 'Ultimas corridas'
  Sql "SELECT TOP (5) LoteID, Origen, CONVERT(varchar(16), Inicio, 120) AS Inicio, DuracionSeg AS Seg, Estado, ISNULL(PasoFallido, '') AS PasoFallido FROM ctl.vw_HistorialLotes ORDER BY LoteID DESC" | Format-Table -AutoSize | Out-String | Write-Host
}

function ListaLotes { @(Get-ChildItem $lotes -Directory | Where-Object { $_.Name -ne '00_base' -and (Test-Path "$($_.FullName)\lote.json") } | Sort-Object Name) }
function LeerLote($dir) { $j = Get-Content "$($dir.FullName)\lote.json" -Raw -Encoding UTF8 | ConvertFrom-Json; $j | Add-Member Carpeta $dir.FullName -PassThru }
function ElegirLote {
  # Todo lo que se muestra va con Write-Host: lo que devuelve la funcion es solo el lote elegido.
  $l = ListaLotes
  if ($l.Count -eq 0) { Write-Host 'No hay lotes en C:\BI_IE1217\lotes: ejecuta instalar_o_actualizar.cmd.' -ForegroundColor Yellow; return $null }
  if ($Lote -gt 0) { if ($Lote -le $l.Count) { return LeerLote $l[$Lote - 1] }; Write-Host "No existe el lote $Lote (hay $($l.Count))." -ForegroundColor Red; return $null }
  Titulo 'Lotes disponibles'
  for ($i = 0; $i -lt $l.Count; $i++) {
    $j = LeerLote $l[$i]
    Write-Host (' {0}. {1}' -f ($i + 1), $j.nombre) -ForegroundColor White
    Write-Host ('    {0}' -f $j.descripcion) -ForegroundColor DarkGray
  }
  Write-Host ''
  $n = Preguntar "Numero de lote, del 1 al $($l.Count) (Enter para volver)"
  if ($n -eq '') { return $null }
  if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $l.Count) { Write-Host "Ese numero no esta en la lista: elige del 1 al $($l.Count)." -ForegroundColor Red; return $null }
  LeerLote $l[[int]$n - 1]
}
function ResumenLote($lt, [switch]$Aplicar) {
  if (-not $lt) { $script:R = 0; return }
  Titulo $lt.nombre; $lt.descripcion; ''
  # Un lote con matriculas aprobadas solo entra si caben en las vacantes que quedan (otro lote o un registro manual pudo ocuparlas).
  $am = @($lt.acciones | Where-Object { $_.modo -eq 'agregar' -and $_.archivo -eq 'matricula.csv' })
  if ($am.Count -gt 0) {
    $ya = @{}; Lineas "$data\matricula.csv" | Select-Object -Skip 1 | ForEach-Object { $ya[$_.Split(';')[0].Trim()] = 1 }
    $pide = @{}
    Lineas "$($lt.Carpeta)\$($am[0].origen)" | Select-Object -Skip 1 | ForEach-Object { $p = $_.Split(';'); if ($p.Count -gt 13 -and -not $ya.ContainsKey($p[0].Trim()) -and $p[13].Trim() -eq 'Aprobado' -and $p[3].Trim().ToUpper() -match '^SEC-2026-(\d[A-Z])$') { $pide[$Matches[1]] = 1 + [int]$pide[$Matches[1]] } }
    if ($pide.Count -gt 0) {
      $lib = VacantesLibres
      $sin = @($pide.Keys | Where-Object { $lib.ContainsKey($_) -and $pide[$_] -gt $lib[$_].Libres } | Sort-Object)
      if ($sin.Count -gt 0) {
        Mal "Este lote no entra ahora: no quedan vacantes suficientes en $($sin -join ', ') (las ocupo un registro manual u otro lote)."
        'Vuelve al estado base (opcion 9) y aplicalo antes del registro manual.'
        $script:R = 0; return
      }
    }
  }
  if ($Aplicar) { CuidarHorario }
  $pend = 0
  foreach ($a in $lt.acciones) {
    $dest = "$data\$($a.archivo)"
    if ($a.modo -eq 'agregar') {
      $nuevas = @(Lineas "$($lt.Carpeta)\$($a.origen)" | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' })
      $arch = $a.archivo; $claves = @{}; Lineas $dest | Select-Object -Skip 1 | ForEach-Object { $claves[(ClaveFila $arch $_)] = 1 }
      $faltan = @($nuevas | Where-Object { -not $claves.ContainsKey((ClaveFila $arch $_)) })
      $omitidas = 0
      if ($a.archivo -eq 'sesiones.csv') {
        # Una sesion se identifica por fecha + docente + curso + seccion. Si data\ ya tiene una igual con otro codigo
        # (un registro manual), el 05 rechaza la carga entera: esas filas del lote no se agregan.
        $nat = @{}; Lineas $dest | Select-Object -Skip 1 | ForEach-Object { $p = $_.Split(';'); if ($p.Count -gt 6) { $nat[(($p[3], $p[4], $p[5], $p[6] | ForEach-Object { $_.Trim().ToUpper() }) -join '|')] = 1 } }
        $libres = @($faltan | Where-Object { $p = $_.Split(';'); -not $nat.ContainsKey((($p[3], $p[4], $p[5], $p[6] | ForEach-Object { $_.Trim().ToUpper() }) -join '|')) })
        $omitidas = $faltan.Count - $libres.Count; $faltan = $libres
      }
      '{0,-24} filas del lote {1,5} | ya estaban {2,5} | NUEVAS {3,5}' -f $a.archivo, $nuevas.Count, ($nuevas.Count - $faltan.Count - $omitidas), $faltan.Count
      if ($omitidas -gt 0) { Aviso "   Se omiten $omitidas filas: data\ ya tiene una sesion del mismo docente, curso, seccion y fecha (registro manual)." }
      if ($a.archivo -eq 'sesiones.csv' -and $faltan.Count -gt 0) { $f = $faltan | ForEach-Object { $_.Split(';')[3] } | Sort-Object; "   fechas: del $($f[0]) al $($f[-1])" }
      $pend += $faltan.Count
      if ($Aplicar -and $faltan.Count -gt 0) { Agregar $dest $faltan }
    } elseif ($a.modo -eq 'recortar') {
      $ls = Lineas $dest; $queda = [int][Math]::Floor(($ls.Count - 1) * $a.porcentaje / 100)
      '{0,-24} tiene {1} filas | quedaria en {2} ({3} %)' -f $a.archivo, ($ls.Count - 1), $queda, $a.porcentaje
      $pend += 1
      if ($Aplicar) { [IO.File]::WriteAllText($dest, (($ls[0..$queda] -join "`n") + "`n"), $utf8) }
    }
  }
  ''; "Resultado esperado: $($lt.esperado)"
  if ($pend -eq 0) { Aviso 'Este lote ya esta aplicado: no hay nada nuevo que agregar.' }
  elseif ($Aplicar) { Bien 'Lote aplicado en data\. Falta cargarlo (opcion 5).' }
  $script:R = $pend
}

function Seguir($desde) {
  $pasos = Sql "SELECT s.step_id, s.step_name FROM msdb.dbo.sysjobsteps s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = N'$job' ORDER BY s.step_id" 'msdb'
  $fin = $false; $vueltas = 0
  while (-not $fin -and $vueltas -lt 300) {
    Start-Sleep -Milliseconds 1500; $vueltas++
    $h = Sql "SELECT h.step_id, h.run_status, h.run_duration FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$job' AND h.instance_id > $desde" 'msdb'
    $hecho = @{}; foreach ($r in $h.Rows) { $hecho[[int]$r.step_id] = $r }
    $fin = $hecho.ContainsKey(0)
    if ($interactivo) { Clear-Host }
    if ($interactivo -or $fin) {
      Titulo "Job $job (lo ejecuta SQL Server Agent)"
      $actualMarcado = $false
      foreach ($p in $pasos.Rows) {
        $id = [int]$p.step_id
        if ($hecho.ContainsKey($id)) { $st = if ($hecho[$id].run_status -eq 1) { 'OK     ' } else { 'FALLO  ' }; $seg = '{0,3}s' -f [int]$hecho[$id].run_duration }
        elseif (-not $fin -and -not $actualMarcado) { $st = 'en curso'; $seg = ''; $actualMarcado = $true }
        else { $st = if ($fin) { '-      ' } else { 'pendiente' }; $seg = '' }
        $color = if ($st -like 'OK*') { 'Green' } elseif ($st -like 'FALLO*') { 'Red' } elseif ($st -eq 'en curso') { 'Yellow' } else { 'DarkGray' }
        Write-Host ('{0,2}. {1,-24} {2,-9} {3}' -f $id, $p.step_name, $st, $seg) -ForegroundColor $color
      }
    }
  }
  if (-not $fin) { Aviso 'El job sigue corriendo; revisa el estado en un momento.'; $script:Exito = $false; return }
  ResumenCorrida
}
function ResumenCorrida {
  $l = (Sql "SELECT TOP (1) LoteID, Estado, DuracionSeg, ISNULL(PasoFallido, '') AS PasoFallido, ISNULL(Mensaje, '') AS Mensaje FROM ctl.LoteETL ORDER BY LoteID DESC").Rows[0]
  ''
  $script:Exito = ($l.Estado -eq 'Exitoso')
  if ($l.Estado -eq 'Exitoso') { Bien "Lote $($l.LoteID): EXITOSO en $($l.DuracionSeg) s." }
  else { Mal "Lote $($l.LoteID): $($l.Estado.ToUpper()) en el paso «$($l.PasoFallido)»."; $m = "$($l.Mensaje)"; $i = $m.IndexOf('Msg '); if ($i -lt 0) { $i = [Math]::Max(0, $m.Length - 600) }; Write-Host ($m.Substring($i, [Math]::Min(600, $m.Length - $i))) -ForegroundColor DarkYellow }
}
function CorrerSql($argumentos) {
  # sqlcmd con las mismas opciones que usa el job (07). Devuelve el codigo de salida y deja el texto en $script:Salida.
  $aut = @(if ($usuarioSql) { '-U', $usuarioSql } else { '-E' })
  if ($usuarioSql) { $env:SQLCMDPASSWORD = $claveSql }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $script:Salida = (& sqlcmd.exe -S $Servidor @aut -C -b -I -x -W -f 65001 @argumentos 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $cod = $LASTEXITCODE; $ErrorActionPreference = $prev
  if ($usuarioSql) { Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue }
  $cod
}
function Directo($ctl) {
  # Los mismos diez pasos del job, en el mismo orden, con sqlcmd desde esta ventana. Queda en el historial como 'Manual'.
  if (-not (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue)) { Mal 'No se encuentra sqlcmd: instalar las herramientas de linea de comandos de SQL Server.'; $script:Exito = $false; return }
  $dir = if (@($pasosEtl | Where-Object { -not (Test-Path "$raiz\scripts\$_.sql") }).Count -eq 0) { "$raiz\scripts" } else { "$repo\scripts" }
  $pasos = New-Object Collections.Generic.List[object]
  if ($ctl) { $pasos.Add(@('Iniciar lote', 'Q', "EXEC ctl.usp_IniciarLote @Origen = N'Manual';")) }
  $pasos.Add(@('01 Staging', 'F', '01_staging'))
  if ($ctl) { $pasos.Add(@('Validar staging', 'Q', 'EXEC ctl.usp_ValidarStaging @CaidaMaximaPct = 50;')) }
  foreach ($p in $pasosEtl | Select-Object -Skip 1) { $pasos.Add(@(($p.Substring(0, 2) + ' ' + (Get-Culture).TextInfo.ToTitleCase(($p -replace '^\d+_(fac_)?', ''))), 'F', $p)) }
  if ($ctl) { $pasos.Add(@('Validar y cerrar lote', 'Q', 'EXEC ctl.usp_CerrarLote;')) }
  Titulo "ETL en modo directo (sqlcmd contra $Servidor, scripts de $dir)"
  if (-not (Test-Path $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
  $script:Exito = $true; $i = 0
  foreach ($p in $pasos) {
    $i++; $t0 = Get-Date
    if ($p[1] -eq 'Q') { $cod = CorrerSql @('-d', 'DW_IE1217', '-Q', $p[2]) }
    else { $log = "$logs\directo_$($p[2]).log"; $cod = CorrerSql @('-i', "$dir\$($p[2]).sql", '-o', $log); if ($cod -ne 0 -and (Test-Path $log)) { $script:Salida = (Get-Content $log -Tail 25 -Encoding UTF8) -join "`n" } }
    $seg = [int]((Get-Date) - $t0).TotalSeconds
    if ($cod -eq 0) { Write-Host ('{0,2}. {1,-24} OK        {2,3}s' -f $i, $p[0], $seg) -ForegroundColor Green; continue }
    Write-Host ('{0,2}. {1,-24} FALLO     {2,3}s' -f $i, $p[0], $seg) -ForegroundColor Red
    $script:Exito = $false; $msj = "$($script:Salida)"; if ($msj.Length -gt 3500) { $msj = $msj.Substring($msj.Length - 3500) }
    if ($ctl -and $i -eq 1) { Write-Host $msj -ForegroundColor DarkYellow; $ctl = $false; break }
    if ($ctl) { [void](CorrerSql @('-d', 'DW_IE1217', '-Q', "EXEC ctl.usp_RegistrarFallo @Paso = N'$($p[0])', @Mensaje = N'$((($msj -replace '[\r\n"]+', ' ') -replace "'", "''"))';")) }
    else { Write-Host $msj -ForegroundColor DarkYellow }
    break
  }
  ''
  if ($ctl) { ResumenCorrida } elseif ($script:Exito) { Bien 'Carga completa.' }
}
function Lanzar([switch]$SoloDirecto) {
  $e = EstadoJob; $script:Exito = $false
  $porJob = (-not $SoloDirecto -and $e.Existe -and $e.Agente -eq 'Running')
  if (-not $porJob -and -not $SoloDirecto) {
    if ($e.Express) { Aviso 'Esta instancia es Express: no hay Agente ni job. Se usa el modo directo.' }
    elseif (-not $e.Existe) { Aviso 'El job no existe en este servidor (se crea con instalar_o_actualizar.cmd -ConJob).' }
    else { Aviso "El Agente SQL no esta iniciado ($($e.Agente)). Opcion 8 para iniciarlo." }
    if (-not (Confirmar 'Ejecutar los mismos pasos en modo directo, con sqlcmd desde esta ventana')) { return }
  }
  if ($porJob -and $e.Corriendo) { Aviso 'El job ya esta corriendo (lo disparo su horario). Se muestra su avance.' }
  $antes = Totales
  if ($porJob) {
    $desde = [long](Sql "SELECT ISNULL(MAX(h.instance_id), 0) AS n FROM msdb.dbo.sysjobhistory h" 'msdb').Rows[0].n
    if (-not $e.Corriendo) { [void](Sql "EXEC msdb.dbo.sp_start_job @job_name = N'$job'" 'msdb') }
    Seguir $desde
  } else { Directo $e.Ctl }
  if ($script:Exito) { LimpiarDimensiones }
  $despues = Totales
  Titulo 'Antes y despues'
  foreach ($k in $antes.Keys) { $d = $despues[$k] - $antes[$k]; $txt = '{0,-26} {1,8:N0} -> {2,8:N0}   {3}' -f $k, $antes[$k], $despues[$k], $(if ($d -eq 0) { 'sin cambio' } elseif ($d -gt 0) { "+$d" } else { "$d" }); if ($d -eq 0) { Write-Host $txt -ForegroundColor DarkGray } else { Write-Host $txt -ForegroundColor White } }
  ''; 'Para verlo en el tablero: en Power BI, Inicio > Actualizar.'
}

function Calidad {
  Titulo 'Calidad del ultimo lote cargado (lectura)'
  Sql @"
SELECT N'Matriculas' AS Proceso, (SELECT COUNT(*) FROM stg.Matricula) AS Origen, (SELECT COUNT(*) FROM dm_matricula.FacMatricula) AS Publicado,
       (SELECT COUNT(*) FROM stg.Matricula) - (SELECT COUNT(*) FROM dm_matricula.FacMatricula) AS NoPublicado, N'duplicadas o sin estudiante en el padron' AS Motivo
UNION ALL SELECT N'Sesiones', (SELECT COUNT(*) FROM stg.Sesion), (SELECT SUM(SesionesProgramadas) FROM dm_preparacion.FacSesion),
       (SELECT COUNT(*) FROM stg.Sesion) - (SELECT SUM(SesionesProgramadas) FROM dm_preparacion.FacSesion), N'copias -DUP o seccion inexistente'
UNION ALL SELECT N'Notas', (SELECT COUNT(*) FROM stg.NotaCompetencia), (SELECT COUNT(*) FROM dm_aprendizajes.FacLogroCompetencia),
       (SELECT COUNT(*) FROM stg.BitacoraNota), N'ver bitacora por motivo'
"@ | Format-Table -AutoSize | Out-String | Write-Host
  Titulo 'Bitacora de notas por motivo'
  Sql "SELECT Motivo, COUNT(*) AS Filas FROM stg.BitacoraNota GROUP BY Motivo ORDER BY Filas DESC" | Format-Table -AutoSize | Out-String | Write-Host
  Titulo 'Alertas del diagnostico sobre el origen'
  Sql @"
SELECT N'Registro en SIAGIE anterior a la solicitud' AS Alerta, COUNT(*) AS Registros FROM stg.Matricula
WHERE COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRegistroSiagie)), 103), TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRegistroSiagie)), 105), TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaRegistroSiagie)), 10), 23))
    < COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSolicitud)), 103), TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSolicitud)), 105), TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaSolicitud)), 10), 23))
UNION ALL SELECT N'Doble matricula del mismo estudiante en el anio', COUNT(*) FROM (SELECT 1 AS x FROM stg.Matricula GROUP BY LTRIM(RTRIM(CodigoEstudiante)), Anio HAVING COUNT(*) > 1) q
UNION ALL SELECT N'Matriculas sin estudiante en el padron', COUNT(*) FROM stg.Matricula m WHERE NOT EXISTS (SELECT 1 FROM stg.Estudiante e WHERE LTRIM(RTRIM(e.CodigoEstudiante)) = LTRIM(RTRIM(m.CodigoEstudiante)))
UNION ALL SELECT N'Sesiones con seccion inexistente', COUNT(*) FROM stg.Sesion s WHERE NOT EXISTS (SELECT 1 FROM stg.Seccion x WHERE LTRIM(RTRIM(x.SeccionID)) = LTRIM(RTRIM(s.SeccionID)))
UNION ALL SELECT N'Sesiones con minutos de retraso negativos', COUNT(*) FROM stg.Sesion WHERE TRY_CONVERT(INT, MinutosRetraso) < 0
"@ | Format-Table -AutoSize | Out-String | Write-Host
  $dg = Get-ChildItem $logs -Filter '*02_diagnostico*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  "El reporte completo de cada paso esta en $logs (un log por script; el mas reciente del diagnostico: $(if ($dg) { $dg.Name } else { 'ninguno todavia' }))."
  if ($dg -and $interactivo -and (Confirmar "Abrir $($dg.Name) en el Bloc de notas")) { Start-Process notepad $dg.FullName }
}

function RegistrarMatricula {
  Titulo 'Registrar una matricula (anio escolar 2026, traslado en fase complementaria)'
  $ref = SiguienteHabil (Corte)
  "Los datos llegan al $((Corte).ToString('dd/MM/yyyy')): la matricula se fecha con registro en SIAGIE el $($ref.ToString('dd/MM/yyyy'))."
  $au = Sql "SELECT n.CodigoCorto, MAX(f.CupoMaximoAula) AS Cupo, SUM(f.VacantesOcupadas) AS Ocupadas FROM dm_matricula.FacMatricula f JOIN dw.DimNivelAcademico n ON n.NivelAcademicoKey = f.NivelAcademicoKey WHERE f.AnioEscolar = 2026 GROUP BY n.CodigoCorto ORDER BY n.CodigoCorto"
  ($au.Rows | ForEach-Object { "$($_.CodigoCorto): $($_.Cupo - $_.Ocupadas) libres" }) -join '   '
  $aula = (Preguntar 'Aula (por ejemplo 3B)' '3B').ToUpper()
  if ($aula -notmatch '^[1-5][AB]$') { Mal 'Aula no valida.'; $script:R = $false; return }
  $ap = Limpia (Preguntar 'Apellido paterno' 'Demo'); $am = Limpia (Preguntar 'Apellido materno' 'Prueba'); $no = Limpia (Preguntar 'Nombres' 'Estudiante')
  $sx = (Preguntar 'Sexo (M/F)' 'F').ToUpper(); if ($sx -notin 'M', 'F') { $sx = 'F' }
  $fn = Preguntar 'Fecha de nacimiento (AAAA-MM-DD)' '2012-05-10'; $tmp = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($fn, 'yyyy-MM-dd', $null, 'None', [ref]$tmp)) { Mal 'Fecha no valida.'; $script:R = $false; return }
  $estado = if ((Preguntar 'Estado: 1 Aprobado, 2 Rechazado' '1') -eq '2') { 'Rechazado' } else { 'Aprobado' }
  $obs = if ($estado -eq 'Rechazado') { Limpia (Preguntar 'Motivo del rechazo' 'Documentacion incompleta') } else { '' }
  if ($estado -eq 'Aprobado') {
    $v = (VacantesLibres)[$aula]; $cupo = if ($v) { $v.Cupo } else { 30 }; $libres = if ($v) { $v.Libres } else { $cupo }
    if ($libres -le 0) { Mal "El aula $aula no tiene vacantes ($cupo de $cupo, contando lo ya agregado al CSV). Elige otra aula o registrala como rechazada."; $script:R = $false; return }
  }
  $maxCod = (Lineas "$data\estudiantes.csv" | Select-Object -Skip 1 | ForEach-Object { $c = $_.Split(';')[0].Trim(); if ($c -match '^121720260090\d\d$') { [long]$c } } | Measure-Object -Maximum).Maximum
  $maxMat = (Lineas "$data\matricula.csv" | Select-Object -Skip 1 | ForEach-Object { if ($_.Split(';')[0] -match '^MAT-2026-(9\d{3})$') { [int]$Matches[1] } } | Measure-Object -Maximum).Maximum
  # Rangos reservados al registro manual (codigo 121720260090xx, MAT-2026-9xxx): no chocan con los lotes, que numeran desde el ultimo real.
  if (-not $maxCod) { $maxCod = 12172026009000 }; if (-not $maxMat) { $maxMat = 9000 }
  $cod = [string]($maxCod + 10); $mid = 'MAT-2026-{0:0000}' -f ($maxMat + 1)
  $f = { param($d) $x = $ref.AddDays($d); while (EsFinDeSemana $x) { $x = $x.AddDays(-1) }; $x.ToString('yyyy-MM-dd') }
  $le = ($cod, ('7{0:0000000}' -f (Get-Random -Maximum 9999999)), $ap, $am, $no, $fn, $sx, 'Castellano', 'Catolica', 'SIS', 0, '', 'Registro manual', 'Chaclacayo', '150107', 'Urbana', 'A pie', 15, 'Ambos padres', 1, 1, 2026, 'Registro manual (demostracion)') -join ';'
  $siagie = if ($estado -eq 'Aprobado') { & $f 0 } else { '' }; $asig = if ($estado -eq 'Aprobado') { & $f -1 } else { '' }
  $lm = ($mid, 2026, $cod, "SEC-2026-$aula", $aula[0], $aula[1], 'Traslado', 'Solicitud de vacante', 'Complementaria', (& $f -6), (& $f -2), $asig, $siagie, $estado, $obs, 'Traslado', $(if ($estado -eq 'Aprobado') { 'CT-2026-{0:0000}' -f ($maxMat + 1) } else { '' }), 'PER-007') -join ';'
  ''; "Estudiante nuevo: $cod  $ap $am, $no"; "Matricula:        $mid  aula $aula  $estado  (solicitud $(& $f -6), revision $(& $f -2))"
  'No se registra apoderado: el diagnostico (02) contara un estudiante mas sin apoderado.'
  CuidarHorario
  if (-not (Confirmar 'Agregar a estudiantes.csv y matricula.csv')) { $script:R = $false; return }
  Agregar "$data\estudiantes.csv" @($le); Agregar "$data\matricula.csv" @($lm)
  Bien "Agregado. Esperado tras el job: matriculas +1$(if ($estado -eq 'Aprobado') { ', vacantes ocupadas +1 en ' + $aula } else { ' (rechazada: no ocupa vacante)' }). Buscalo en Power BI por el codigo $cod."
  $script:R = $true
}
function RegistrarSesion {
  Titulo 'Registrar una sesion de clase (anio 2026)'
  $doc = Sql "SELECT DocenteID, NombreCompleto FROM dw.DimDocente WHERE DocenteKey > 0 ORDER BY DocenteID"
  foreach ($r in $doc.Rows) { "$($r.DocenteID)  $($r.NombreCompleto)" }
  $d = (Preguntar 'Codigo del docente' "$($doc.Rows[0].DocenteID)").ToUpper()
  $asg = @(Lineas "$data\carga_horaria.csv" | Select-Object -Skip 1 | ForEach-Object { $p = $_.Split(';'); if ($p[0].Trim() -eq '2026' -and $p[1].Trim().ToUpper() -eq $d) { [pscustomobject]@{ Area = $p[2].Trim().ToUpper(); Seccion = $p[3].Trim().ToUpper() } } })
  if ($asg.Count -eq 0) { Mal 'Ese docente no tiene carga horaria en 2026.'; $script:R = $false; return }
  for ($i = 0; $i -lt $asg.Count; $i++) { "$($i + 1). $($asg[$i].Area)  $($asg[$i].Seccion)" }
  $n = Preguntar 'Numero de curso y seccion' '1'; if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $asg.Count) { Mal 'Opcion no valida.'; $script:R = $false; return }
  $a = $asg[[int]$n - 1]
  "Los datos llegan al $((Corte).ToString('dd/MM/yyyy')). El calendario del DW tiene cierres de bimestre de 2026 hasta el 31/07/2026."
  $fe = Preguntar 'Fecha de la sesion (AAAA-MM-DD)' (SiguienteHabil (Corte)).ToString('yyyy-MM-dd'); $tmp = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($fe, 'yyyy-MM-dd', $null, 'None', [ref]$tmp) -or $tmp.Year -ne 2026) { Mal 'La fecha debe ser de 2026 (AAAA-MM-DD).'; $script:R = $false; return }
  if (EsFinDeSemana $tmp) { Mal 'Esa fecha cae en fin de semana: no hay clases.'; $script:R = $false; return }
  if ($fe -gt $ultimoCierre) { Mal 'Esa fecha pasa del 31/07/2026, el ultimo cierre de bimestre declarado en el DW: quedaria en un bimestre que no corresponde.'; $script:R = $false; return }
  $ls = Lineas "$data\sesiones.csv"
  if (@($ls | Where-Object { $p = $_.Split(';'); $p.Count -gt 6 -and $p[3] -eq $fe -and $p[4].Trim().ToUpper() -eq $d -and $p[5].Trim().ToUpper() -eq $a.Area -and $p[6].Trim().ToUpper() -eq $a.Seccion }).Count -gt 0) { Mal 'Ya existe una sesion de ese docente, curso y seccion en esa fecha (el job la rechazaria).'; $script:R = $false; return }
  $op = Preguntar 'Estado: 1 Dictada, 2 Dictada con retraso, 3 Reprogramada, 4 No dictada' '1'
  $est = @{ '1' = 'Dictada'; '2' = 'Dictada con retraso'; '3' = 'Reprogramada'; '4' = 'No dictada' }[$op]; if (-not $est) { $est = 'Dictada' }
  $min = if ($est -eq 'Dictada con retraso') { $m = Preguntar 'Minutos de retraso' '15'; if ($m -match '^\d+$' -and [int]$m -gt 0) { [int]$m } else { 15 } } else { 0 }
  $mot = if ($est -eq 'No dictada') { Limpia (Preguntar 'Motivo' 'Licencia del docente') } else { '' }
  $max = ($ls | Select-Object -Skip 1 | ForEach-Object { if ($_.Split(';')[0] -match '^SES-(9\d{5})$') { [int]$Matches[1] } } | Measure-Object -Maximum).Maximum; if (-not $max) { $max = 900000 }   # rango reservado al registro manual
  $id = 'SES-{0:000000}' -f ($max + 1); $bim = if ($fe -le '2026-05-22') { 1 } elseif ($fe -le '2026-07-31') { 2 } else { 3 }
  $fila = ($id, 2026, $bim, $fe, $d, $a.Area, $a.Seccion, 'Registro manual', 'Sesion registrada a mano', 2, $est, $mot, $min, 2, 2, 0) -join ';'
  ''; "Sesion $id  $fe  $d  $($a.Area)  $($a.Seccion)  $est"
  CuidarHorario
  if (-not (Confirmar 'Agregar a sesiones.csv')) { $script:R = $false; return }
  Agregar "$data\sesiones.csv" @($fila)
  Bien "Agregada. Esperado tras el job: sesiones programadas +1$(switch ($est) { 'Dictada' { ', en horario +1' } 'Dictada con retraso' { ', con retraso +1' } default { ', incidencias +1' } })."
  $script:R = $true
}
function LimpiarDimensiones {
  # El ETL nunca borra miembros de las dimensiones. Tras volver al estado base quedan los que agregaron los lotes
  # (estudiantes y combinaciones de tipo de matricula) sin ningun hecho: se retiran para recuperar las cifras verificadas.
  foreach ($f in 'estudiantes.csv', 'matricula.csv') { if ((Filas "$data\$f") -ne (Filas "$base\$f")) { return } }
  $t = Sql @"
SET NOCOUNT ON;
DECLARE @e INT, @t INT;
DELETE d FROM dw.DimEstudiante AS d
WHERE d.EstudianteKey > 0
  AND NOT EXISTS (SELECT 1 FROM stg.Estudiante e WHERE LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(e.CodigoEstudiante, NCHAR(160), N''), CHAR(9), N''), CHAR(13), N''))) = d.CodigoEstudiante)
  AND NOT EXISTS (SELECT 1 FROM dm_matricula.FacMatricula f WHERE f.EstudianteKey = d.EstudianteKey)
  AND NOT EXISTS (SELECT 1 FROM dm_aprendizajes.FacLogroCompetencia f WHERE f.EstudianteKey = d.EstudianteKey);
SET @e = @@ROWCOUNT;
DELETE t FROM dw.DimTipoMatricula AS t
WHERE t.TipoMatriculaKey > 0 AND NOT EXISTS (SELECT 1 FROM dm_matricula.FacMatricula f WHERE f.TipoMatriculaKey = t.TipoMatriculaKey);
SET @t = @@ROWCOUNT;
SELECT @e AS Estudiantes, @t AS Tipos;
"@
  $r = $t.Rows[0]; if ($r.Estudiantes + $r.Tipos -gt 0) { Bien "Estado base: se retiraron de las dimensiones $($r.Estudiantes) estudiantes y $($r.Tipos) tipos de matricula que habian agregado los lotes." }
}
function Horario($activar) { if (-not (EstadoJob).Existe) { Aviso 'El job no existe en este servidor: no hay horario que cambiar.'; return }; [void](Sql "EXEC msdb.dbo.sp_update_job @job_name = N'$job', @enabled = $(if ($activar) { 1 } else { 0 })" 'msdb'); if ($activar) { Aviso 'Horario ACTIVO: el job correra solo cada 15 minutos.' } else { Bien 'Horario en pausa: el job solo corre cuando lo lances desde aqui.' } }
function Agente {
  $s = Get-Service $svcAgente -ErrorAction SilentlyContinue
  if (-not $s) { Aviso "No existe el servicio $svcAgente en esta PC (instancia Express o servidor remoto). El ETL se puede lanzar en modo directo (opcion 5)."; return }
  if ($s.Status -eq 'Running') { Bien 'El Agente SQL ya esta iniciado.'; return }
  try { Start-Service $svcAgente; Bien 'Agente SQL iniciado.' }
  catch { Mal 'No se pudo iniciar (hace falta permiso de administrador).'; "Abre demo.cmd con clic derecho > Ejecutar como administrador, o inicia el servicio $svcAgente desde services.msc." }
}
function VolverBase {
  Titulo 'Volver al estado base'
  if (-not (Confirmar 'Se reemplazan los CSV de data\ por los de lotes\00_base. Continuar')) { $script:R = $false; return }
  Copy-Item "$base\*.csv" $data -Force; Bien 'Archivos restaurados. Falta recargar (opcion 5) para que el DW vuelva a las cifras verificadas.'; $script:R = $true
}

if (-not (Test-Path $base) -or -not (Test-Path "$data\matricula.csv")) { Mal "C:\BI_IE1217 no esta preparado (falta data\ o lotes\00_base). Ejecuta primero instalar_o_actualizar.cmd, en la raiz del repositorio."; exit 1 }
try { [void](Sql 'SELECT 1' 'master') } catch { Mal "No se pudo conectar a '$Servidor': $($_.Exception.InnerException.Message)"; 'Revisa que el servicio de SQL Server este iniciado, o indica otro: demo.cmd -Servidor NOMBRE'; exit 1 }
if ("$((Sql "SELECT DB_ID(N'DW_IE1217') AS id" 'master').Rows[0].id)" -eq '') { Mal "En '$Servidor' no existe DW_IE1217. Ejecuta primero instalar_o_actualizar.cmd."; exit 1 }
switch ($Accion.ToLower()) {
  'estado'  { VerEstado; exit }
  'resumen' { ResumenLote (ElegirLote); exit }
  'aplicar' { ResumenLote (ElegirLote) -Aplicar; exit }
  'lanzar'  { Lanzar; exit }
  'directo' { Lanzar -SoloDirecto; exit }
  'calidad' { Calidad; exit }
  'base'    { VolverBase; exit }
  'limpiar' { LimpiarDimensiones; exit }
  'agente'  { Agente; exit }
  'pausar'  { Horario $false; exit }
  'reanudar' { Horario $true; exit }
}
while ($true) {
  Write-Host ''; Write-Host '===== CENTRO DE CONTROL DEL ETL - I.E. 1217 =====' -ForegroundColor Cyan
  ' 1. Ver estado y conteos'
  ' 2. Resumen previo de un lote'
  ' 3. Aplicar un lote'
  ' 4. Registro manual (matricula o sesion)'
  ' 5. Lanzar el ETL y seguirlo paso a paso (job del Agente; si no hay, modo directo)'
  ' 6. Calidad: diagnostico, descartes y bitacora'
  ' 7. Pausar o reanudar el horario de 15 minutos'
  ' 8. Iniciar el Agente SQL'
  ' 9. Volver al estado base'
  ' 0. Salir'
  $o = Read-Host 'Opcion'
  try {
    switch ($o) {
      '1' { VerEstado }
      '2' { $l = ElegirLote; if ($l) { ResumenLote $l } }
      '3' { $l = ElegirLote; if ($l) { ResumenLote $l; if ($script:R -gt 0 -and (Confirmar 'Aplicar este lote')) { ResumenLote $l -Aplicar; if (Confirmar 'Lanzar el ETL ahora') { Lanzar } } } }
      '4' { $t = Read-Host '1 Matricula, 2 Sesion'; $script:R = $false; if ($t -eq '2') { RegistrarSesion } else { RegistrarMatricula }; if ($script:R -and (Confirmar 'Lanzar el ETL ahora')) { Lanzar } }
      '5' { Lanzar }
      '6' { Calidad }
      '7' { $e = EstadoJob; Horario (-not $e.Habilitado) }
      '8' { Agente }
      '9' { $script:R = $false; VolverBase; if ($script:R -and (Confirmar 'Lanzar el ETL ahora')) { Lanzar } }
      '0' { $e = EstadoJob; if ($e.Existe -and -not $e.Habilitado -and (Confirmar 'El horario de 15 minutos esta en pausa. Reanudarlo antes de salir')) { Horario $true }; exit }
    }
  } catch { Mal "Error: $($_.Exception.Message)" }
}
