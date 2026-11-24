# Genera los lotes de demostracion a partir de lotes\00_base (los CSV del equipo, que deja el instalador).
# Lo ejecuta instalar_o_actualizar.ps1; el resultado es siempre el mismo para los mismos CSV.
param([string]$Raiz = 'C:\BI_IE1217')
$ErrorActionPreference = 'Stop'
$lotes = "$Raiz\lotes"; $base = "$lotes\00_base"
$utf8 = New-Object Text.UTF8Encoding($false)
function Guardar($ruta, $lineas) { [IO.File]::WriteAllText($ruta, (($lineas -join "`n") + "`n"), $utf8) }
foreach ($f in 'sesiones.csv', 'secciones.csv', 'estudiantes.csv', 'matricula.csv', 'apoderados.csv', 'notas_competencias.csv', 'materiales.csv', 'entrega_materiales.csv', 'carga_horaria.csv') { if (-not (Test-Path "$base\$f")) { throw "Falta $base\${f}: ejecutar instalar_o_actualizar.cmd." } }

# ---------- 01: sesiones del resto de mayo 2026 (11 al 29), copiando el patron de la semana del 4 al 8
$d1 = "$lotes\01_sesiones_mayo_2026"; New-Item -ItemType Directory -Force $d1 | Out-Null
$enc = [IO.File]::ReadAllLines("$base\sesiones.csv", [Text.Encoding]::UTF8)
$cab = $enc[0]
$secOk = @{}; Import-Csv "$base\secciones.csv" -Delimiter ';' -Encoding UTF8 | ForEach-Object { $secOk[$_.SeccionID.Trim().ToUpper()] = 1 }
$ses = Import-Csv "$base\sesiones.csv" -Delimiter ';' -Encoding UTF8
$maxId = ($ses | ForEach-Object { if ($_.SesionID -match '^SES-(\d+)') { [int]$Matches[1] } } | Measure-Object -Maximum).Maximum
$semana = $ses | Where-Object { $_.Anio -eq '2026' -and $_.FechaSesion -ge '2026-05-04' -and $_.FechaSesion -le '2026-05-08' -and $_.SesionID -notmatch '-DUP$' -and $secOk.ContainsKey($_.SeccionID.Trim().ToUpper()) } | Sort-Object FechaSesion, SesionID
$vistos = @{}; $out = New-Object Collections.Generic.List[string]; $n = $maxId
$cont = @{ Dictada = 0; Retraso = 0; Repro = 0; NoDict = 0 }
foreach ($salto in 7, 14, 21) {
  foreach ($s in $semana) {
    $f = ([datetime]$s.FechaSesion).AddDays($salto).ToString('yyyy-MM-dd')
    $k = "$f|$($s.DocenteID.Trim().ToUpper())|$($s.AreaID.Trim().ToUpper())|$($s.SeccionID.Trim().ToUpper())"
    if ($vistos.ContainsKey($k)) { continue }; $vistos[$k] = 1
    $e = $s.EstadoSesion.Trim().ToUpper(); $min = 0; [void][int]::TryParse($s.MinutosRetraso, [ref]$min); if ($min -lt 0) { $min = 0 }
    if ($e -like 'NO*DICT*') { $est = 'No dictada'; $cont.NoDict++; $min = 0 }
    elseif ($e -like 'REPRO*') { $est = 'Reprogramada'; $cont.Repro++; $min = 0 }
    elseif ($e -like 'DICT*RETRAS*' -or $min -gt 0) { $est = 'Dictada con retraso'; if ($min -eq 0) { $min = 10 }; $cont.Retraso++ }
    else { $est = 'Dictada'; $cont.Dictada++ }
    $mot = if ($est -eq 'No dictada') { if ($s.MotivoNoDictada.Trim()) { $s.MotivoNoDictada.Trim() } else { 'Licencia del docente' } } else { '' }
    $bim = if ($f -le '2026-05-22') { 1 } else { 2 }
    $n++; $id = 'SES-{0:000000}' -f $n
    $out.Add(($id, '2026', $bim, $f, $s.DocenteID.Trim().ToUpper(), $s.AreaID.Trim().ToUpper(), $s.SeccionID.Trim().ToUpper(), $s.UnidadDidactica, $s.TituloSesion, $s.HorasPedagogicas, $est, $mot, $min, 2, 2, 0) -join ';')
  }
}
$validas = $out.Count
# dos filas sucias a proposito: una copia (-DUP) y una seccion que no existe
$p = $out[0].Split(';'); $p[0] = $p[0] + '-DUP'; $out.Add($p -join ';')
$p = $out[1].Split(';'); $n++; $p[0] = 'SES-{0:000000}' -f $n; $p[6] = 'SEC-2026-9Z'; $out.Add($p -join ';')
Guardar "$d1\+sesiones.csv" (@($cab) + $out)
@{ nombre = 'Sesiones del 11 al 29 de mayo de 2026'
   descripcion = 'Tres semanas nuevas de sesiones. Trae dos filas sucias a proposito: una copia (-DUP) y una sesion en una seccion que no existe (9Z).'
   esperado = "Sesiones programadas: +$validas (en horario +$($cont.Dictada), con retraso +$($cont.Retraso), incidencias +$($cont.Repro + $cont.NoDict)). Descartadas por el 05: 1 duplicada y 1 sin seccion."
   acciones = @(@{ modo = 'agregar'; archivo = 'sesiones.csv'; origen = '+sesiones.csv' }) } | ConvertTo-Json -Depth 4 | Set-Content "$d1\lote.json" -Encoding UTF8
"01: $($out.Count) filas ($validas validas) | $($cont.Dictada) en horario, $($cont.Retraso) con retraso, $($cont.Repro + $cont.NoDict) incidencias"

# ---------- 02: cinco matriculas nuevas (fase complementaria) con sus estudiantes
$d2 = "$lotes\02_matriculas_nuevas"; New-Item -ItemType Directory -Force $d2 | Out-Null
$est = Import-Csv "$base\estudiantes.csv" -Delimiter ';' -Encoding UTF8
$mat = Import-Csv "$base\matricula.csv" -Delimiter ';' -Encoding UTF8
$maxCod = ($est | ForEach-Object { $c = $_.CodigoEstudiante.Trim(); if ($c -match '^12172026\d{6}$') { [long]$c } } | Measure-Object -Maximum).Maximum
$maxMat = ($mat | ForEach-Object { if ($_.MatriculaID -match '^MAT-2026-(\d+)') { [int]$Matches[1] } } | Measure-Object -Maximum).Maximum
# Cada fila: apellidos, nombres, sexo, nacimiento, grado, seccion, estado, observacion, 4 fechas (solicitud, revision,
# asignacion, SIAGIE), direccion, distrito, ubigeo, transporte, minutos, vive con, hermanos, internet, IE de procedencia,
# y su apoderado (nombres, sexo, parentesco, instruccion, ocupacion, telefono).
$nuevos = @(
  @('Quiroz', 'Benavides', 'Luciana', 'F', '2012-08-14', '3', 'B', 'Aprobado', '', '2026-05-11', '2026-05-14', '2026-05-18', '2026-05-20', 'Jr. Los Girasoles 214', 'Chaclacayo', '150107', 'A pie', 12, 'Ambos padres', 1, 1, 'I.E. N 1195 Cesar Vallejo', 'Rosa Elena', 'F', 'Madre', 'Secundaria completa', 'Comerciante', '987214305'),
  @('Zegarra', 'Palomino', 'Thiago', 'M', '2012-03-02', '3', 'B', 'Aprobado', '', '2026-05-11', '2026-05-15', '2026-05-19', '2026-05-21', 'Calle Las Retamas 458', 'Lurigancho-Chosica', '150118', 'Combi', 35, 'Solo madre', 2, 0, 'I.E. N 0027 San Antonio de Jicamarca', 'Carmen Julia', 'F', 'Madre', 'Superior tecnica', 'Tecnica en enfermeria', '946530178'),
  @('Cornejo', 'Villanueva', 'Emilia', 'F', '2012-11-23', '3', 'B', 'Aprobado', '', '2026-05-12', '2026-05-15', '2026-05-19', '2026-05-21', 'Av. Nicolas Ayllon 3120', 'Ate', '150103', 'Mototaxi', 25, 'Ambos padres', 0, 1, 'I.E. N 1190 Felipe Huaman Poma de Ayala', 'Luis Alberto', 'M', 'Padre', 'Secundaria completa', 'Conductor', '961407752'),
  @('Arevalo', 'Montoya', 'Gael', 'M', '2012-06-09', '3', 'A', 'Aprobado', '', '2026-05-12', '2026-05-18', '2026-05-20', '2026-05-04', 'Psje. Los Sauces 131', 'Chaclacayo', '150107', 'A pie', 10, 'Abuelos', 1, 0, 'I.E. N 1224 El Paraiso', 'Teresa', 'F', 'Abuela', 'Primaria completa', 'Ama de casa', '934881260'),
  @('Bustamante', 'Ocampo', 'Renata', 'F', '2011-09-30', '4', 'B', 'Rechazado', 'No presento la constancia de traslado', '2026-05-13', '2026-05-18', '', '', 'Calle Los Cedros 77', 'Lurigancho-Chosica', '150118', 'Combi', 40, 'Solo padre', 3, 1, 'I.E. N 1198 La Ribera', 'Jorge Enrique', 'M', 'Padre', 'Superior universitaria', 'Contador', '998123674')
)
$le = New-Object Collections.Generic.List[string]; $lm = New-Object Collections.Generic.List[string]; $la = New-Object Collections.Generic.List[string]; $i = 0
foreach ($x in $nuevos) {
  $i++; $cod = [string]($maxCod + 10 * $i); $mid = 'MAT-2026-{0:0000}' -f ($maxMat + $i); $ok = ($x[7] -eq 'Aprobado')
  $le.Add(($cod, ('7{0:0000000}' -f (1234567 + 111 * $i)), $x[0], $x[1], $x[2], $x[4], $x[3], 'Castellano', 'Catolica', 'SIS', 0, '', $x[13], $x[14], $x[15], 'Urbana', $x[16], $x[17], $x[18], $x[19], $x[20], 2026, $x[21]) -join ';')
  # traslado aprobado: lleva su constancia; el rechazado justamente no la presento
  $lm.Add(($mid, 2026, $cod, "SEC-2026-$($x[5])$($x[6])", $x[5], $x[6], 'Traslado', 'Solicitud de vacante', 'Complementaria', $x[9], $x[10], $x[11], $x[12], $x[7], $x[8], 'Traslado', $(if ($ok) { 'CT-2026-{0:0000}' -f ($maxMat + $i) } else { '' }), 'PER-007') -join ';')
  # apoderado: el padre lleva el apellido paterno del estudiante; madre y abuela, el materno
  $apP = if ($x[23] -eq 'M') { $x[0] } else { $x[1] }; $apM = @('Salas', 'Ramos', 'Chavez', 'Paredes', 'Luna')[$i - 1]
  $la.Add(($cod, ('4{0:0000000}' -f (2345678 + 137 * $i)), $apP, $apM, $x[22], $x[23], $x[24], $x[25], $x[26], $x[27], 1, $(if ($x[18] -in 'Ambos padres', 'Abuelos' -or ($x[18] -eq 'Solo madre' -and $x[24] -eq 'Madre') -or ($x[18] -eq 'Solo padre' -and $x[24] -eq 'Padre')) { 1 } else { 0 })) -join ';')
}
Guardar "$d2\+estudiantes.csv" (@([IO.File]::ReadAllLines("$base\estudiantes.csv", [Text.Encoding]::UTF8)[0]) + $le)
Guardar "$d2\+matricula.csv" (@([IO.File]::ReadAllLines("$base\matricula.csv", [Text.Encoding]::UTF8)[0]) + $lm)
Guardar "$d2\+apoderados.csv" (@([IO.File]::ReadAllLines("$base\apoderados.csv", [Text.Encoding]::UTF8)[0]) + $la)
@{ nombre = 'Cinco matriculas nuevas por traslado (mayo de 2026)'
   descripcion = 'Cinco estudiantes nuevos, con su apoderado y su matricula en fase complementaria. Una viene rechazada (no presento la constancia de traslado) y otra trae el registro en SIAGIE anterior a su solicitud (dato sucio a proposito).'
   esperado = 'Matriculas solicitadas 2026: +5 (validadas +4, rechazadas +1). Vacantes ocupadas +4: 3B pasa de 27 a 30 (aula llena) y 3A de 28 a 29. Estudiantes en la dimension +5. El diagnostico sube en 1 el conteo de SIAGIE anterior a la solicitud; los estudiantes sin apoderado no cambian.'
   acciones = @(@{ modo = 'agregar'; archivo = 'estudiantes.csv'; origen = '+estudiantes.csv' }, @{ modo = 'agregar'; archivo = 'apoderados.csv'; origen = '+apoderados.csv' }, @{ modo = 'agregar'; archivo = 'matricula.csv'; origen = '+matricula.csv' }) } | ConvertTo-Json -Depth 4 | Set-Content "$d2\lote.json" -Encoding UTF8
"02: $($lm.Count) matriculas y $($le.Count) estudiantes"

# ---------- 03: archivo incompleto (para mostrar el freno del job)
$d3 = "$lotes\03_archivo_incompleto"; New-Item -ItemType Directory -Force $d3 | Out-Null
@{ nombre = 'Archivo incompleto: sesiones.csv llega recortado al 40 %'
   descripcion = 'Simula una entrega defectuosa del origen. No agrega nada: recorta sesiones.csv.'
   esperado = 'El job debe DETENERSE en el paso 3 (Validar staging) con el error 51072 y los hechos publicados deben quedar intactos. Despues, usar «Volver al estado base».'
   acciones = @(@{ modo = 'recortar'; archivo = 'sesiones.csv'; porcentaje = 40 }) } | ConvertTo-Json -Depth 4 | Set-Content "$d3\lote.json" -Encoding UTF8
'03: listo'

# ---------- 04: lote integral (primera semana de junio de 2026). Mueve los tres datamarts en una sola carga.
# Numeracion propia, despues de la de los lotes 01 y 02, para que se puedan aplicar juntos sin chocar.
$d4 = "$lotes\04_integral_junio_2026"; New-Item -ItemType Directory -Force $d4 | Out-Null
$cabDe = { param($f) [IO.File]::ReadAllLines("$base\$f", [Text.Encoding]::UTF8)[0] }
$carga = @{}; Import-Csv "$base\carga_horaria.csv" -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Anio.Trim() -eq '2026' } | ForEach-Object { $carga["$($_.AreaID.Trim().ToUpper())|$($_.SeccionID.Trim().ToUpper())"] = $_.DocenteID.Trim().ToUpper() }
$secciones = @($secOk.Keys | Where-Object { $_ -like 'SEC-2026-*' } | Sort-Object)

# a) Sesiones del lunes 1 de junio: el horario del lunes 4 de mayo, cuatro semanas despues. El estado no se copia:
#    se reparte con una secuencia fija (unas 83 de cada 100 en horario), para no repetir a los mismos docentes con retraso.
$s4 = New-Object Collections.Generic.List[string]; $n4 = $maxId + 2000; $c4 = @{ Dictada = 0; Retraso = 0; Otras = 0 }; $k = 0
foreach ($s in ($semana | Where-Object { $_.FechaSesion -eq '2026-05-04' })) {
  $k++; $r = ($k * 37 + 11) % 100; $n4++
  if ($r -lt 83) { $e4 = 'Dictada'; $m4 = 0; $mo = ''; $c4.Dictada++ }
  elseif ($r -lt 91) { $e4 = 'Dictada con retraso'; $m4 = 5 + ($k % 4) * 5; $mo = ''; $c4.Retraso++ }
  elseif ($r -lt 96) { $e4 = 'Reprogramada'; $m4 = 0; $mo = ''; $c4.Otras++ }
  else { $e4 = 'No dictada'; $m4 = 0; $mo = 'Licencia del docente'; $c4.Otras++ }
  $s4.Add((('SES-{0:000000}' -f $n4), '2026', 2, '2026-06-01', $s.DocenteID.Trim().ToUpper(), $s.AreaID.Trim().ToUpper(), $s.SeccionID.Trim().ToUpper(), 'Unidad 3', 'Sesion de inicio de unidad', $s.HorasPedagogicas, $e4, $mo, $m4, 2, 2, 0) -join ';')
}
Guardar "$d4\+sesiones.csv" (@($cab) + $s4)

# b) Ocho solicitudes de traslado: seis entran en las vacantes que quedan (aun con el lote 02 aplicado) y dos se
#    rechazan porque su aula esta completa. Cada fila: apellidos, nombres, sexo, nacimiento, grado, seccion, estado,
#    4 fechas, direccion, distrito, ubigeo, transporte, minutos, vive con, hermanos, internet, IE de procedencia, apoderado.
$sinVacante = 'Sin vacante disponible en el aula solicitada'
$n8 = @(
  @('Huaman', 'Caceres', 'Valeria', 'F', '2014-01-19', '1', 'A', 'Aprobado', '2026-05-25', '2026-05-27', '2026-06-01', '2026-06-02', 'Jr. Las Magnolias 342', 'Chaclacayo', '150107', 'A pie', 10, 'Ambos padres', 1, 1, 'I.E. N 1195 Cesar Vallejo', 'Maria Luisa', 'F', 'Madre', 'Secundaria completa', 'Comerciante', '987650112'),
  @('Soto', 'Mendoza', 'Adrian', 'M', '2013-10-05', '1', 'B', 'Aprobado', '2026-05-25', '2026-05-27', '2026-06-01', '2026-06-02', 'Av. Los Laureles 918', 'Lurigancho-Chosica', '150118', 'Combi', 30, 'Solo madre', 2, 1, 'I.E. N 1198 La Ribera', 'Gloria', 'F', 'Madre', 'Superior tecnica', 'Auxiliar contable', '945118730'),
  @('Paucar', 'Rojas', 'Camila', 'F', '2012-04-27', '3', 'A', 'Aprobado', '2026-05-26', '2026-05-28', '2026-06-01', '2026-06-03', 'Calle Los Pinos 150', 'Chaclacayo', '150107', 'A pie', 15, 'Ambos padres', 0, 1, 'I.E. N 1224 El Paraiso', 'Victor Hugo', 'M', 'Padre', 'Secundaria completa', 'Electricista', '962440871'),
  @('Vargas', 'Tello', 'Mateo', 'M', '2011-07-15', '4', 'B', 'Aprobado', '2026-05-26', '2026-05-28', '2026-06-02', '2026-06-03', 'Psje. San Martin 64', 'Ate', '150103', 'Mototaxi', 25, 'Abuelos', 1, 0, 'I.E. N 1190 Felipe Huaman Poma de Ayala', 'Julia', 'F', 'Abuela', 'Primaria completa', 'Ama de casa', '931207654'),
  @('Leon', 'Aguirre', 'Sofia', 'F', '2010-12-03', '5', 'A', 'Aprobado', '2026-05-27', '2026-05-29', '2026-06-02', '2026-06-04', 'Av. Las Flores 477', 'Chaclacayo', '150107', 'A pie', 12, 'Ambos padres', 2, 1, 'I.E. N 0027 San Antonio de Jicamarca', 'Patricia', 'F', 'Madre', 'Superior universitaria', 'Docente', '998301245'),
  @('Castro', 'Yupanqui', 'Diego', 'M', '2010-05-21', '5', 'A', 'Aprobado', '2026-05-27', '2026-05-29', '2026-06-02', '2026-06-04', 'Calle Ayacucho 233', 'Lurigancho-Chosica', '150118', 'Combi', 35, 'Solo padre', 1, 0, 'I.E. N 1198 La Ribera', 'Ruben', 'M', 'Padre', 'Secundaria completa', 'Mecanico', '956772038'),
  @('Medina', 'Flores', 'Ariana', 'F', '2013-02-11', '2', 'A', 'Rechazado', '2026-05-27', '2026-05-29', '', '', 'Jr. Tacna 501', 'Chaclacayo', '150107', 'A pie', 20, 'Ambos padres', 1, 1, 'I.E. N 1195 Cesar Vallejo', 'Elena', 'F', 'Madre', 'Secundaria completa', 'Costurera', '940665219'),
  @('Rivas', 'Salcedo', 'Joaquin', 'M', '2011-03-08', '4', 'A', 'Rechazado', '2026-05-27', '2026-05-29', '', '', 'Av. Central 1204', 'Ate', '150103', 'Combi', 30, 'Solo madre', 0, 1, 'I.E. N 1224 El Paraiso', 'Norma', 'F', 'Madre', 'Superior tecnica', 'Tecnica en farmacia', '977530486')
)
$e4l = New-Object Collections.Generic.List[string]; $m4l = New-Object Collections.Generic.List[string]; $a4l = New-Object Collections.Generic.List[string]
$aprobados4 = New-Object Collections.Generic.List[object]; $i = 0; $apMat = 'Quispe', 'Torres', 'Navarro', 'Campos', 'Ibarra', 'Molina', 'Peralta', 'Zamora'
foreach ($x in $n8) {
  $i++; $cod = [string]($maxCod + 50 + 10 * $i); $mid = 'MAT-2026-{0:0000}' -f ($maxMat + 5 + $i); $ok = ($x[7] -eq 'Aprobado'); $sec = "SEC-2026-$($x[5])$($x[6])"
  $e4l.Add(($cod, ('7{0:0000000}' -f (2468135 + 173 * $i)), $x[0], $x[1], $x[2], $x[4], $x[3], 'Castellano', 'Catolica', 'SIS', 0, '', $x[12], $x[13], $x[14], 'Urbana', $x[15], $x[16], $x[17], $x[18], $x[19], 2026, $x[20]) -join ';')
  $m4l.Add(($mid, 2026, $cod, $sec, $x[5], $x[6], 'Traslado', 'Solicitud de vacante', 'Complementaria', $x[8], $x[9], $x[10], $x[11], $x[7], $(if ($ok) { '' } else { $sinVacante }), 'Traslado', $(if ($ok) { 'CT-2026-{0:0000}' -f ($maxMat + 5 + $i) } else { '' }), 'PER-007') -join ';')
  $apP = if ($x[22] -eq 'M') { $x[0] } else { $x[1] }
  $a4l.Add(($cod, ('4{0:0000000}' -f (3579246 + 191 * $i)), $apP, $apMat[$i - 1], $x[21], $x[22], $x[23], $x[24], $x[25], $x[26], 1, $(if ($x[17] -in 'Ambos padres', 'Abuelos' -or ($x[17] -eq 'Solo madre' -and $x[23] -eq 'Madre') -or ($x[17] -eq 'Solo padre' -and $x[23] -eq 'Padre')) { 1 } else { 0 })) -join ';')
  if ($ok) { $aprobados4.Add([pscustomobject]@{ Codigo = $cod; Seccion = $sec; Orden = $i }) }
}
Guardar "$d4\+estudiantes.csv" (@(& $cabDe 'estudiantes.csv') + $e4l)
Guardar "$d4\+matricula.csv" (@(& $cabDe 'matricula.csv') + $m4l)
Guardar "$d4\+apoderados.csv" (@(& $cabDe 'apoderados.csv') + $a4l)

# c) Notas del II bimestre de 2026 (cierre 31/07) de los seis aprobados: las mismas areas y competencias que ya
#    tiene su seccion en ese bimestre, con el docente de la carga horaria. El cuarto estudiante queda con
#    Matematica por debajo de 11 (bajo rendimiento) y el primero trae una competencia sin evidencia.
$notas = Import-Csv "$base\notas_competencias.csv" -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Anio.Trim() -eq '2026' -and $_.Bimestre.Trim() -eq '2' -and $_.FechaCierreBimestre.Trim() -eq '2026-07-31' }
$n4l = New-Object Collections.Generic.List[string]
$areaDe = @{}; Import-Csv "$base\competencias.csv" -Delimiter ';' -Encoding UTF8 | ForEach-Object { $areaDe[$_.CompetenciaID.Trim().ToUpper()] = $_.AreaID.Trim().ToUpper() }
foreach ($a in $aprobados4) {
  $comp = @($notas | Where-Object { $_.SeccionID.Trim().ToUpper() -eq $a.Seccion } | ForEach-Object { "$($_.AreaID.Trim().ToUpper())|$($_.CompetenciaID.Trim().ToUpper())" } | Where-Object { $_ -match '^AR-[A-Z]+\|CP-\d+$' -and $areaDe[$_.Split('|')[1]] -eq $_.Split('|')[0] } | Sort-Object -Unique)
  $j = 0
  foreach ($c in $comp) {
    $j++; $ar, $cp = $c.Split('|'); $doc = $carga["$ar|$($a.Seccion)"]; if (-not $doc) { continue }
    $nota = 11 + (($a.Orden * 7 + $j * 3) % 7)
    if ($a.Orden -eq 4 -and $ar -eq 'AR-MAT') { $nota = 8 + ($j % 3) }
    if ($a.Orden -eq 1 -and $j -eq 5) { $nota = 'SIN EVIDENCIA' }
    $n4l.Add((2026, 2, $a.Codigo, $a.Seccion, $ar, $cp, $doc, $nota, '2026-07-31') -join ';')
  }
}
Guardar "$d4\+notas_competencias.csv" (@(& $cabDe 'notas_competencias.csv') + $n4l)

# d) Material de Ingles: texto y cuaderno de trabajo para las diez secciones. El area no tenia dotacion registrada.
#    El 05 trata toda entrega como programada al inicio de clases del anio, asi que llevan esa fecha (16/03/2026).
$matr = @{}; $visto = @{}   # estudiantes distintos con matricula aprobada por seccion (el CSV trae algunas filas repetidas)
$mat | Where-Object { $_.Anio.Trim() -eq '2026' -and $_.EstadoMatricula.Trim() -eq 'Aprobado' } | ForEach-Object { $kk = "$($_.SeccionID.Trim().ToUpper())|$($_.CodigoEstudiante.Trim())"; if (-not $visto.ContainsKey($kk)) { $visto[$kk] = 1; $matr[$_.SeccionID.Trim().ToUpper()] = 1 + [int]$matr[$_.SeccionID.Trim().ToUpper()] } }
$maxMtl = (Import-Csv "$base\materiales.csv" -Delimiter ';' -Encoding UTF8 | ForEach-Object { if ($_.MaterialID -match '^MTL-(\d+)') { [int]$Matches[1] } } | Measure-Object -Maximum).Maximum
$maxEnt = (Import-Csv "$base\entrega_materiales.csv" -Delimiter ';' -Encoding UTF8 | ForEach-Object { if ($_.EntregaID -match '^ENT-2026-(\d+)') { [int]$Matches[1] } } | Measure-Object -Maximum).Maximum
$ml = New-Object Collections.Generic.List[string]; $el = New-Object Collections.Generic.List[string]; $idMtl = @{}; $porEntregar = 0; $tarde = 0; $q = 0
foreach ($gr in 1..5) {
  $maxMtl++; $idMtl["$gr|T"] = 'MTL-{0:000}' -f $maxMtl; $ml.Add(($idMtl["$gr|T"], 'AR-ING', $gr, 'Texto escolar', "English $gr - Student's Book", 'Retornable', 'Ministerio de Educacion del Peru') -join ';')
  $maxMtl++; $idMtl["$gr|C"] = 'MTL-{0:000}' -f $maxMtl; $ml.Add(($idMtl["$gr|C"], 'AR-ING', $gr, 'Cuaderno de trabajo', "English $gr - Workbook", 'Fungible', 'Ministerio de Educacion del Peru') -join ';')
}
foreach ($sec in $secciones) {
  $doc = $carga["AR-ING|$sec"]; if (-not $doc -or $sec -notmatch '^SEC-2026-(\d)([A-Z])$') { continue }
  $gr = $Matches[1]; $le = $Matches[2]; $cant = [int]$matr[$sec]; if ($cant -le 0) { continue }
  foreach ($t in 'T', 'C') {
    $q++; $maxEnt++
    # una de cada cinco entregas sale tarde por completo; en el resto, uno o dos ejemplares fuera de fecha
    if ($q % 5 -eq 0) { $dest = $cant; $dias = 2 + ($q % 3); $efec = ([datetime]'2026-03-16').AddDays($dias).ToString('yyyy-MM-dd'); $obs = 'Entrega tardia por el docente de area'; $tarde++ }
    else { $dest = $q % 3; $dias = 0; $efec = '2026-03-16'; $obs = '' }
    $el.Add((('ENT-2026-{0:0000}' -f $maxEnt), 2026, $sec, $gr, $le, 'AR-ING', $doc, $idMtl["$gr|$t"], $(if ($t -eq 'T') { 'Texto escolar' } else { 'Cuaderno de trabajo' }), ('2026-03-{0:00}' -f (2 + $q % 5)), '2026-03-16', $efec, $cant, $cant, ($cant - $dest), $dest, 0, $dias, $obs) -join ';')
    $porEntregar += $cant
  }
}
Guardar "$d4\+materiales.csv" (@(& $cabDe 'materiales.csv') + $ml)
Guardar "$d4\+entrega_materiales.csv" (@(& $cabDe 'entrega_materiales.csv') + $el)

$nApr = $aprobados4.Count
@{ nombre = 'Lote integral: primera semana de junio de 2026 (los tres datamarts)'
   descripcion = "Una sola carga que mueve matricula, preparacion y aprendizajes: $($s4.Count) sesiones del lunes 1 de junio, $($m4l.Count) solicitudes de traslado con su estudiante y apoderado ($nApr aprobadas, $($m4l.Count - $nApr) rechazadas por falta de vacante), $($n4l.Count) notas del II bimestre de los $nApr aprobados y la dotacion de Ingles ($($ml.Count) materiales, $($el.Count) entregas)."
   esperado = "Matriculas +$($m4l.Count) (validadas +$nApr, rechazadas +$($m4l.Count - $nApr)); estudiantes en la dimension +$($m4l.Count). Sesiones programadas +$($s4.Count) (en horario +$($c4.Dictada), con retraso +$($c4.Retraso), incidencias +$($c4.Otras)): junio de 2026 aparece como mes nuevo. Notas +$($n4l.Count), una de ellas sin evidencia; un estudiante de 4B queda con bajo rendimiento en el II bimestre. Materiales por entregar +$porEntregar; $tarde entregas completas fuera de plazo."
   acciones = @(@{ modo = 'agregar'; archivo = 'estudiantes.csv'; origen = '+estudiantes.csv' }, @{ modo = 'agregar'; archivo = 'apoderados.csv'; origen = '+apoderados.csv' }, @{ modo = 'agregar'; archivo = 'matricula.csv'; origen = '+matricula.csv' }, @{ modo = 'agregar'; archivo = 'sesiones.csv'; origen = '+sesiones.csv' }, @{ modo = 'agregar'; archivo = 'notas_competencias.csv'; origen = '+notas_competencias.csv' }, @{ modo = 'agregar'; archivo = 'materiales.csv'; origen = '+materiales.csv' }, @{ modo = 'agregar'; archivo = 'entrega_materiales.csv'; origen = '+entrega_materiales.csv' }) } | ConvertTo-Json -Depth 4 | Set-Content "$d4\lote.json" -Encoding UTF8
"04: $($s4.Count) sesiones, $($m4l.Count) matriculas, $($n4l.Count) notas, $($ml.Count) materiales y $($el.Count) entregas"

