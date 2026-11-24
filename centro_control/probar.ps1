# Casos de prueba del centro de control y del job. Ejecuta los flujos de la demostracion de principio a fin y compara
# el resultado con lo esperado. Al terminar deja los CSV y el DW en el estado base y el horario como lo encontro.
# Uso:  powershell -ExecutionPolicy Bypass -File centro_control\probar.ps1     (tarda unos 5 minutos)
param([string]$Servidor = '')
$ErrorActionPreference = 'Stop'
$demo = Join-Path $PSScriptRoot 'demo.ps1'; $repo = Split-Path -Parent $PSScriptRoot
$raiz = 'C:\BI_IE1217'; $data = "$raiz\data"
if (-not $Servidor -and (Test-Path "$raiz\instalado.json")) { $Servidor = (Get-Content "$raiz\instalado.json" -Raw -Encoding UTF8 | ConvertFrom-Json).servidor }
if (-not $Servidor) { $Servidor = 'localhost' }
function Q($sql, $bd = 'DW_IE1217') {
  $cn = New-Object Data.SqlClient.SqlConnection "Server=$Servidor;Database=$bd;Integrated Security=True;TrustServerCertificate=True"
  $da = New-Object Data.SqlClient.SqlDataAdapter($sql, $cn); $da.SelectCommand.CommandTimeout = 120; $t = New-Object Data.DataTable; [void]$da.Fill($t); return ,$t
}
function D([string[]]$argumentos, [string[]]$teclas) {
  $extra = if ($Servidor) { @('-Servidor', $Servidor) } else { @() }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  if ($teclas) { $o = $teclas | powershell -NoProfile -ExecutionPolicy Bypass -File $demo @argumentos @extra 2>&1 } else { $o = powershell -NoProfile -ExecutionPolicy Bypass -File $demo @argumentos @extra 2>&1 }
  $ErrorActionPreference = $prev; ($o | ForEach-Object { "$_" }) -join "`n"
}
function Cifras {
  $r = (Q @"
SELECT (SELECT COUNT(*) FROM dm_matricula.FacMatricula) AS mat, (SELECT SUM(MatriculasValidadas) FROM dm_matricula.FacMatricula) AS val,
       (SELECT SUM(SesionesProgramadas) FROM dm_preparacion.FacSesion) AS ses, (SELECT COUNT(*) FROM dm_preparacion.FacEntregaMaterial) AS ent,
       (SELECT COUNT(*) FROM dm_aprendizajes.FacLogroCompetencia) AS notas, (SELECT COUNT(*) FROM stg.BitacoraNota) AS bit,
       (SELECT COUNT(*) FROM dw.DimEstudiante WHERE EstudianteKey > 0) AS est, (SELECT COUNT(*) FROM dw.DimTipoMatricula WHERE TipoMatriculaKey > 0) AS tipos
"@).Rows[0]
  "mat=$($r.mat) val=$($r.val) ses=$($r.ses) ent=$($r.ent) notas=$($r.notas) bit=$($r.bit) est=$($r.est) tipos=$($r.tipos)"
}
function Filas($f) { @([IO.File]::ReadAllLines("$data\$f") | Where-Object { $_.Trim() -ne '' }).Count - 1 }
function UltimoLote { $r = (Q "SELECT TOP (1) LoteID, Origen, Estado, ISNULL(PasoFallido, '') AS Paso, ISNULL(Mensaje, '') AS Mensaje FROM ctl.LoteETL ORDER BY LoteID DESC").Rows[0]; $r }
function Horario { [int](Q "SELECT enabled FROM dbo.sysjobs WHERE name = N'ETL_IE1217_Carga'" 'msdb').Rows[0].enabled }
function Debe($condicion, $detalle) { if (-not $condicion) { throw $detalle } }
$script:res = New-Object Collections.Generic.List[object]
function Caso($id, $nombre, [scriptblock]$b) {
  $t0 = Get-Date
  try { & $b; $ok = $true; $det = '' } catch { $ok = $false; $det = "$($_.Exception.Message)" }
  $script:res.Add([pscustomobject]@{ Caso = $id; Prueba = $nombre; Resultado = $(if ($ok) { 'OK' } else { 'FALLA' }); Detalle = $det })
  Write-Host ('{0}  {1,-5}  {2}  ({3:0}s){4}' -f $id, $(if ($ok) { 'OK' } else { 'FALLA' }), $nombre, ((Get-Date) - $t0).TotalSeconds, $(if ($det) { "`n        $det" } else { '' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
$BASE = 'mat=600 val=579 ses=6352 ent=100 notas=44815 bit=581 est=373 tipos=10'
$agente = "$((Q "SELECT TOP (1) status_desc FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' OR servicename LIKE N'Agente SQL Server%'" 'master').Rows[0].status_desc)"
$horarioInicial = Horario
Write-Host "Servidor: $Servidor | Agente: $agente | horario al empezar: $(if ($horarioInicial) { 'activo' } else { 'en pausa' })" -ForegroundColor Cyan
$origenEsperado = if ($agente -eq 'Running') { 'SQL Agent' } else { 'Manual' }

Caso 'C01' 'Punto de partida: pausar el horario, volver a base y recargar' {
  [void](D 'pausar'); Debe ((Horario) -eq 0) 'el horario no quedo en pausa'
  [void](D 'base'); $o = D 'lanzar'; Debe ($o -match 'EXITOSO') "la recarga no termino bien: $($o.Substring([Math]::Max(0, $o.Length - 300)))"
  $c = Cifras; Debe ($c -eq $BASE) "cifras base distintas: $c"
}
Caso 'C02' 'Estado: scripts de C iguales al repositorio y conteos visibles' {
  $o = D 'estado'; Debe ($o -match 'iguales a los del repositorio') 'los scripts de C no coinciden con el repositorio'; Debe ($o -match 'Matriculas en el hecho\s+600') 'no muestra las 600 matriculas'
}
Caso 'C03' 'Resumen previo del lote 2: informa 5 nuevas y no toca los archivos' {
  $o = D 'resumen', '2'; Debe ($o -match 'matricula\.csv.*NUEVAS\s+5') 'no informa 5 matriculas nuevas'; Debe ((Filas 'matricula.csv') -eq 615) 'el resumen modifico matricula.csv'
}
Caso 'C04' 'Aplicar el lote 2: los CSV crecen y el DW todavia no cambia' {
  [void](D 'aplicar', '2'); Debe ((Filas 'matricula.csv') -eq 620 -and (Filas 'estudiantes.csv') -eq 384) 'los CSV no tienen las 5 filas nuevas'
  $c = Cifras; Debe ($c -eq $BASE) "el DW cambio antes de lanzar: $c"
}
Caso 'C05' "Lanzar: corre el job ($origenEsperado), cierra exitoso y publica el lote 2" {
  $o = D 'lanzar'; Debe ($o -match 'EXITOSO') 'el lote no cerro exitoso'
  $l = UltimoLote; Debe ($l.Estado -eq 'Exitoso' -and $l.Origen -eq $origenEsperado) "ultimo lote: $($l.Estado) / $($l.Origen)"
  $c = Cifras; Debe ($c -eq 'mat=605 val=583 ses=6352 ent=100 notas=44815 bit=581 est=378 tipos=11') "cifras: $c"
  $b = [int](Q "SELECT SUM(f.VacantesOcupadas) AS n FROM dm_matricula.FacMatricula f JOIN dw.DimNivelAcademico n ON n.NivelAcademicoKey = f.NivelAcademicoKey WHERE f.AnioEscolar = 2026 AND n.CodigoCorto = N'3B'").Rows[0].n; Debe ($b -eq 30) "3B deberia quedar en 30 y esta en $b"
}
Caso 'C06' 'Reaplicar el lote 2: avisa que ya esta aplicado y no duplica' {
  $o = D 'aplicar', '2'; Debe ($o -match 'ya esta aplicado') 'no aviso que ya estaba aplicado'; Debe ((Filas 'matricula.csv') -eq 620) 'duplico filas'
}
Caso 'C07' 'Registro manual en un aula llena (3B): lo rechaza' {
  $o = D @() @('4', '1', '3B', '', '', '', '', '', '1', '0', 'N'); Debe ($o -match 'no tiene vacantes') 'no rechazo el aula llena'; Debe ((Filas 'matricula.csv') -eq 620) 'agrego la matricula pese al rechazo'
}
Caso 'C08' 'Registro manual de matricula en 3A: codigo reservado y fechas dentro de los datos' {
  $o = D @() @('4', '1', '3A', 'Prueba', 'Demo', 'Ana', 'F', '2012-01-05', '1', 'S', 'N', '0', 'N'); Debe ($o -match 'MAT-2026-9001') 'no uso el rango reservado MAT-2026-9xxx'
  Debe ($o -match 'solicitud 2026-05-') 'la solicitud no quedo en mayo de 2026'; Debe ((Filas 'matricula.csv') -eq 621) 'no agrego la fila'
}
Caso 'C09' 'Registro manual de sesion: codigo reservado y fecha habil siguiente al corte' {
  $o = D @() @('4', '2', '', '1', '', '2', '', 'S', 'N', '0', 'N'); Debe ($o -match 'SES-900001\s+2026-05-11') 'no creo SES-900001 el 11/05/2026'; Debe ((Filas 'sesiones.csv') -eq 6426) 'no agrego la fila'
}
Caso 'C10' 'Sesion repetida, en fin de semana o fuera del calendario: las rechaza' {
  $o = D @() @('4', '2', '', '1', '2026-05-11', '0', 'N'); Debe ($o -match 'Ya existe una sesion') 'acepto una sesion repetida'
  $o = D @() @('4', '2', '', '1', '2026-05-16', '0', 'N'); Debe ($o -match 'fin de semana') 'acepto un sabado'
  $o = D @() @('4', '2', '', '1', '2026-11-23', '0', 'N'); Debe ($o -match 'pasa del 31/07/2026') 'acepto una fecha fuera del calendario'
  Debe ((Filas 'sesiones.csv') -eq 6426) 'agrego alguna de las tres'
}
Caso 'C11' 'Cargar los registros manuales por el job' {
  $o = D 'lanzar'; Debe ($o -match 'EXITOSO') 'el lote no cerro exitoso'; $c = Cifras; Debe ($c -eq 'mat=606 val=584 ses=6353 ent=100 notas=44815 bit=581 est=379 tipos=11') "cifras: $c"
}
Caso 'C12' 'Lote integral con 3A ya llena: se niega a aplicarlo y no toca nada' {
  $o = D 'aplicar', '4'; Debe ($o -match 'no entra ahora') 'no se nego a aplicar el lote'; Debe ((Filas 'matricula.csv') -eq 621 -and (Filas 'notas_competencias.csv') -eq 45396) 'modifico archivos'
}
Caso 'C13' 'Numero de lote que no existe: lo dice y vuelve al menu' {
  $o = D @() @('2', '7', '0', 'N'); Debe ($o -match 'no esta en la lista') 'no aviso del numero invalido'; Debe ($o -match '4\. Lote integral') 'no listo los lotes con su numero'
}
Caso 'C14' 'Volver a base y recargar: cifras verificadas y dimensiones limpias' {
  [void](D 'base'); $o = D 'lanzar'; Debe ($o -match 'EXITOSO') 'la recarga no termino bien'; Debe ($o -match 'se retiraron de las dimensiones 6 estudiantes') 'no limpio los 6 estudiantes agregados'
  $c = Cifras; Debe ($c -eq $BASE) "cifras: $c"
}
Caso 'C15' 'Lotes 1, 2 y 4 juntos: una sola carga mueve los tres datamarts' {
  $o = D 'aplicar', '1'; Debe ($o -match 'NUEVAS\s+983') 'el lote 1 no trajo 983 filas'
  [void](D 'aplicar', '2'); $o = D 'aplicar', '4'; Debe ($o -match 'notas_competencias\.csv.*NUEVAS\s+156') 'el lote 4 no trajo 156 notas'
  $o = D 'lanzar'; Debe ($o -match 'EXITOSO') "el lote no cerro exitoso: $((UltimoLote).Paso)"
  $c = Cifras; Debe ($c -eq 'mat=613 val=589 ses=7442 ent=110 notas=44971 bit=581 est=386 tipos=11') "cifras: $c"
  $j = [int](Q "SELECT ISNULL(SUM(f.SesionesProgramadas), 0) AS n FROM dm_preparacion.FacSesion f JOIN dw.DimTiempo t ON t.TiempoKey = f.TramoTiempoKey WHERE t.Anio = 2026 AND t.Mes = 6").Rows[0].n; Debe ($j -eq 109) "junio de 2026 deberia tener 109 sesiones y tiene $j"
  $m = [int](Q "SELECT MAX(x.o - x.c) AS n FROM (SELECT SUM(VacantesOcupadas) AS o, MAX(CupoMaximoAula) AS c FROM dm_matricula.FacMatricula WHERE AnioEscolar = 2026 GROUP BY NivelAcademicoKey) x").Rows[0].n; Debe ($m -le 0) 'alguna aula quedo por encima de su cupo'
}
Caso 'C16' 'Modo directo (sqlcmd, sin el Agente): mismos pasos y mismas cifras' {
  $o = D 'directo'; Debe ($o -match 'modo directo') 'no uso el modo directo'; Debe ($o -match 'EXITOSO') 'no cerro exitoso'
  $l = UltimoLote; Debe ($l.Origen -eq 'Manual') "origen del lote: $($l.Origen)"; $c = Cifras; Debe ($c -eq 'mat=613 val=589 ses=7442 ent=110 notas=44971 bit=581 est=386 tipos=11') "cifras: $c"
}
Caso 'C17' 'Archivo incompleto (lote 3): el job se detiene y lo publicado queda intacto' {
  [void](D 'aplicar', '3'); $o = D 'lanzar'; Debe ($o -match 'FALLIDO') 'el job no fallo'
  $l = UltimoLote; Debe ($l.Estado -eq 'Fallido' -and $l.Paso -match 'Validar staging' -and $l.Mensaje -match '51072') "lote: $($l.Estado) / $($l.Paso)"
  $c = Cifras; Debe ($c -eq 'mat=613 val=589 ses=7442 ent=110 notas=44971 bit=581 est=386 tipos=11') "lo publicado cambio: $c"
}
Caso 'C18' 'Despues del fallo: volver a base y recargar funciona a la primera' {
  [void](D 'base'); $o = D 'lanzar'; Debe ($o -match 'EXITOSO') 'la recarga no termino bien'; $c = Cifras; Debe ($c -eq $BASE) "cifras: $c"
}
Caso 'C19' 'Job ya en marcha: el seguimiento se engancha y no lanza otro' {
  if ($agente -ne 'Running') { throw 'sin Agente iniciado no se puede probar' }
  $antes = (UltimoLote).LoteID; [void](Q "EXEC msdb.dbo.sp_start_job @job_name = N'ETL_IE1217_Carga'" 'msdb')
  $o = D 'lanzar'; Debe ($o -match 'ya esta corriendo') 'no detecto que el job ya corria'; Debe ($o -match 'EXITOSO') 'no mostro el resultado'
  Start-Sleep -Seconds 3; $n = (UltimoLote).LoteID - $antes; Debe ($n -eq 1) "se crearon $n lotes en lugar de 1"
}
Caso 'C20' 'Calidad: muestra origen frente a publicado, bitacora y alertas' {
  $o = D 'calidad'; Debe ($o -match 'Bitacora de notas por motivo' -and $o -match 'SIAGIE anterior a la solicitud') 'faltan secciones'; Debe ($o -notmatch 'Error:') 'devolvio un error'
}
Caso 'C21' 'Horario: pausar, reanudar y la pregunta al salir' {
  [void](D 'reanudar'); Debe ((Horario) -eq 1) 'reanudar no lo activo'; [void](D 'pausar'); Debe ((Horario) -eq 0) 'pausar no lo detuvo'
  [void](D @() @('0', 'S')); Debe ((Horario) -eq 1) 'al salir con S no lo reanudo'
  [void](D 'pausar'); $o = D @() @('0', 'N'); Debe ((Horario) -eq 0) 'al salir con N lo cambio'
}
Caso 'C22' 'Los CSV de C quedaron identicos a las huellas del repositorio' {
  $mal = @(); foreach ($l in [IO.File]::ReadAllLines("$repo\datos_base.sha256")) { if ($l -match '^([0-9a-f]{64})\s+(\S+)$') { if ((Get-FileHash "$data\$($Matches[2])" -Algorithm SHA256).Hash.ToLower() -ne $Matches[1]) { $mal += $Matches[2] } } }
  Debe ($mal.Count -eq 0) "distintos: $($mal -join ', ')"
}
Caso 'C23' 'Instalador -SoloPreparar: sin errores y con las cifras verificadas' {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $o = (powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\instalar_o_actualizar.ps1" -SoloPreparar -Servidor $Servidor 2>&1 | ForEach-Object { "$_" }) -join "`n"; $ErrorActionPreference = $prev
  Debe ($o -notmatch '   XX  ') 'el instalador informo un error'; Debe ($o -notmatch 'cifra\(s\) distinta') 'alguna cifra no coincide'; Debe ($o -match 'Anotado en') 'no escribio instalado.json'
}
[void](D $(if ($horarioInicial) { 'reanudar' } else { 'pausar' }))
$f = @($script:res | Where-Object { $_.Resultado -ne 'OK' }).Count
Write-Host ''; Write-Host "Resultado: $($script:res.Count - $f) de $($script:res.Count) casos correctos. Horario dejado $(if ($horarioInicial) { 'activo' } else { 'en pausa' }), como estaba." -ForegroundColor $(if ($f) { 'Yellow' } else { 'Green' })
$script:res | Export-Csv "$raiz\logs\pruebas_centro_control.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ';'
exit $f
