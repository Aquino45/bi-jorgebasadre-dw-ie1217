/* ============================================================================
   ARCHIVO   : 02_diagnostico.sql
   CAMBIOS v5.1: el conteo de espacios al final usa DATALENGTH (con <> SQL
                 Server ignora el espacio final y el conteo salia en cero);
                 se corrige la nota del bloque 4 sobre espacios y JOIN.
   PROPOSITO : Detectar y cuantificar los defectos del origen ANTES de
               transformar. Es el perfilado de datos de la capa de calidad.
   ORDEN     : Ejecutar DESPUES de 01_staging_secundaria.sql

   COMO USARLO EN LA SUSTENTACION
   ----------------------------------------------------------------------------
   Este script perfila reglas seleccionadas del catalogo de defectos. Sus
   bloques no equivalen uno a uno a las 94 filas de Control_Calidad: algunas
   reglas se agrupan y otras requieren revision manual. Los conteos se leen
   sobre el ORIGEN CRUDO; ningun resultado de este script es un KPI final.

   El criterio de fondo: un dato que no pasa una regla NO se borra en silencio.
   Se cuantifica, se reporta y se decide que hacer con el. Un ETL que descarta
   sin avisar es la forma mas rapida de que nadie confie en el tablero.
   ============================================================================ */

USE DW_IE1217;
GO

/* ============================================================================
   1. PERFILADO GENERAL - completitud por campo critico
   ============================================================================ */
SELECT 'stg.Estudiante' AS Tabla, 'DNI' AS Campo,
       COUNT(*) AS Total,
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(DNI)), N'') IS NULL THEN 1 ELSE 0 END) AS Vacios,
       SUM(CASE WHEN LEN(REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N'')) <> 8
                 AND NULLIF(LTRIM(RTRIM(DNI)), N'') IS NOT NULL THEN 1 ELSE 0 END) AS LongitudInvalida
FROM stg.Estudiante
UNION ALL
SELECT 'stg.Estudiante', 'FechaNacimiento', COUNT(*),
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(FechaNacimiento)), N'') IS NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(FechaNacimiento)), N'') IS NOT NULL
                 AND COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 103),
                              TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 105),
                              TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 101),
                              TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaNacimiento)), 10), 23)) IS NULL
                THEN 1 ELSE 0 END)
FROM stg.Estudiante;
GO

/* ============================================================================
   2. ESTANDARIZACION - cuantos valores distintos tiene un campo que deberia
      tener pocos. Si "Sexo" tiene 13 valores, hay trabajo que hacer.
   ============================================================================ */
SELECT 'Sexo (estudiantes)' AS Campo, COUNT(DISTINCT LTRIM(RTRIM(Sexo))) AS ValoresDistintos FROM stg.Estudiante
UNION ALL SELECT 'Distrito (estudiantes)',        COUNT(DISTINCT LTRIM(RTRIM(Distrito)))          FROM stg.Estudiante
UNION ALL SELECT 'CondicionLaboral (docentes)',   COUNT(DISTINCT LTRIM(RTRIM(CondicionLaboral)))  FROM stg.Docente
UNION ALL SELECT 'EstadoMatricula (deberian ser 2)', COUNT(DISTINCT LTRIM(RTRIM(EstadoMatricula))) FROM stg.Matricula
UNION ALL SELECT 'EstadoAsistencia',              COUNT(DISTINCT LTRIM(RTRIM(EstadoAsistencia)))  FROM stg.Asistencia
UNION ALL SELECT 'NotaVigesimal',                 COUNT(DISTINCT LTRIM(RTRIM(NotaVigesimal)))     FROM stg.NotaCompetencia
UNION ALL SELECT 'EstadoSesion',                  COUNT(DISTINCT LTRIM(RTRIM(EstadoSesion)))      FROM stg.Sesion
ORDER BY ValoresDistintos DESC;

/* El detalle de uno de ellos, para mostrarlo en la exposicion */
SELECT LTRIM(RTRIM(Sexo)) AS ValorRecibido, COUNT(*) AS Registros
FROM stg.Estudiante GROUP BY LTRIM(RTRIM(Sexo)) ORDER BY Registros DESC;
GO

/* ---------------------------------------------------------------------------
   EL ESPACIO NO SEPARABLE (CHAR 160)
   ---------------------------------------------------------------------------
   Es el defecto mas peligroso del lote porque TRIM() NO lo elimina: el codigo
   se ve identico en pantalla, pasa cualquier inspeccion visual, y el JOIN
   simplemente devuelve menos filas sin dar un solo error.
   Hay que quitarlo explicitamente antes de cruzar.
   --------------------------------------------------------------------------- */
SELECT 'stg.Estudiante.CodigoEstudiante' AS Campo,
       SUM(CASE WHEN CodigoEstudiante LIKE N'%' + NCHAR(160) + N'%' THEN 1 ELSE 0 END) AS ConNBSP,
       SUM(CASE WHEN DATALENGTH(CodigoEstudiante) <> DATALENGTH(LTRIM(RTRIM(CodigoEstudiante))) THEN 1 ELSE 0 END) AS ConEspacioNormal
FROM stg.Estudiante
UNION ALL
SELECT 'stg.Matricula.CodigoEstudiante',
       SUM(CASE WHEN CodigoEstudiante LIKE N'%' + NCHAR(160) + N'%' THEN 1 ELSE 0 END),
       SUM(CASE WHEN DATALENGTH(CodigoEstudiante) <> DATALENGTH(LTRIM(RTRIM(CodigoEstudiante))) THEN 1 ELSE 0 END)
FROM stg.Matricula
UNION ALL
SELECT 'stg.NotaCompetencia.CodigoEstudiante',
       SUM(CASE WHEN CodigoEstudiante LIKE N'%' + NCHAR(160) + N'%' THEN 1 ELSE 0 END),
       SUM(CASE WHEN DATALENGTH(CodigoEstudiante) <> DATALENGTH(LTRIM(RTRIM(CodigoEstudiante))) THEN 1 ELSE 0 END)
FROM stg.NotaCompetencia;

/* La limpieza correcta de una clave, para reutilizar en el ETL:
   LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(col, NCHAR(160), N''), CHAR(9), N''), CHAR(13), N''))) */
GO

/* ============================================================================
   3. DUPLICADOS
   ============================================================================ */
SELECT 'Estudiantes duplicados en el padron' AS Problema, COUNT(*) AS Casos FROM (
    SELECT LTRIM(RTRIM(CodigoEstudiante)) AS k FROM stg.Estudiante
    GROUP BY LTRIM(RTRIM(CodigoEstudiante)) HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'DNI compartido por estudiantes distintos', COUNT(*) FROM (
    SELECT LTRIM(RTRIM(DNI)) AS k FROM stg.Estudiante
    WHERE NULLIF(LTRIM(RTRIM(DNI)), N'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(DNI)) HAVING COUNT(DISTINCT LTRIM(RTRIM(CodigoEstudiante))) > 1) x
UNION ALL
SELECT 'Doble matricula del mismo estudiante en el mismo anio', COUNT(*) FROM (
    SELECT LTRIM(RTRIM(CodigoEstudiante)) AS e, Anio FROM stg.Matricula
    GROUP BY LTRIM(RTRIM(CodigoEstudiante)), Anio HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'Asistencia duplicada (mismo alumno y fecha)', COUNT(*) FROM (
    SELECT LTRIM(RTRIM(CodigoEstudiante)) AS e, LEFT(LTRIM(RTRIM(Fecha)), 10) AS f
    FROM stg.Asistencia
    GROUP BY LTRIM(RTRIM(CodigoEstudiante)), LEFT(LTRIM(RTRIM(Fecha)), 10) HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'Competencia calificada dos veces en el mismo bimestre', COUNT(*) FROM (
    SELECT LTRIM(RTRIM(CodigoEstudiante)) AS e, CompetenciaID, Anio, Bimestre
    FROM stg.NotaCompetencia
    GROUP BY LTRIM(RTRIM(CodigoEstudiante)), CompetenciaID, Anio, Bimestre HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'Sesion duplicada (mismo docente, fecha, seccion y area)', COUNT(*) FROM (
    SELECT DocenteID, FechaSesion, SeccionID, AreaID FROM stg.Sesion
    GROUP BY DocenteID, FechaSesion, SeccionID, AreaID HAVING COUNT(*) > 1) x;
GO

/* ============================================================================
   4. INTEGRIDAD REFERENCIAL - huerfanos
      Nota: SQL Server ignora el espacio normal AL FINAL cuando compara con
      '=' o '<>', pero NO ignora el espacio inicial, el tabulador ni el
      espacio no separable (CHAR 160): esos convierten un codigo valido en
      huerfano sin dar error. Power BI y Excel si distinguen el espacio final,
      asi que la clave se limpia completa antes de publicarla.
   ============================================================================ */
SELECT 'Matriculas sin estudiante en el padron' AS Problema, COUNT(*) AS Registros
FROM stg.Matricula m
WHERE NOT EXISTS (SELECT 1 FROM stg.Estudiante e
                  WHERE LTRIM(RTRIM(e.CodigoEstudiante)) = LTRIM(RTRIM(m.CodigoEstudiante)))
UNION ALL
SELECT 'Notas con competencia inexistente', COUNT(*)
FROM stg.NotaCompetencia n
WHERE NOT EXISTS (SELECT 1 FROM stg.Competencia c
                  WHERE LTRIM(RTRIM(c.CompetenciaID)) = LTRIM(RTRIM(n.CompetenciaID)))
UNION ALL
SELECT 'Sesiones con seccion inexistente', COUNT(*)
FROM stg.Sesion s
WHERE NOT EXISTS (SELECT 1 FROM stg.Seccion x
                  WHERE LTRIM(RTRIM(x.SeccionID)) = LTRIM(RTRIM(s.SeccionID)))
UNION ALL
SELECT 'Monitoreo con docente inexistente', COUNT(*)
FROM stg.MonitoreoDocente mo
WHERE NOT EXISTS (SELECT 1 FROM stg.Docente d
                  WHERE LTRIM(RTRIM(d.DocenteID)) = LTRIM(RTRIM(mo.DocenteID)))
UNION ALL
SELECT 'Estudiantes sin apoderado registrado', COUNT(*)
FROM stg.Estudiante e
WHERE NOT EXISTS (SELECT 1 FROM stg.Apoderado a
                  WHERE LTRIM(RTRIM(a.CodigoEstudiante)) = LTRIM(RTRIM(e.CodigoEstudiante)))
UNION ALL
SELECT 'Claves con espacios que romperian el cruce', COUNT(*)
FROM stg.Estudiante WHERE DATALENGTH(CodigoEstudiante) <> DATALENGTH(LTRIM(RTRIM(CodigoEstudiante)));
GO

/* ============================================================================
   5. COHERENCIA ENTRE COLUMNAS
   ============================================================================ */
SELECT 'Registro en SIAGIE anterior a la solicitud' AS Problema, COUNT(*) AS Registros
FROM stg.Matricula
WHERE COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRegistroSiagie)), 103),
               TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRegistroSiagie)), 105),
               TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaRegistroSiagie)), 10), 23))
    < COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSolicitud)), 103),
               TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSolicitud)), 105),
               TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaSolicitud)), 10), 23))
UNION ALL
SELECT 'Continuador con solicitud de vacante (no le corresponde)', COUNT(*)
FROM stg.Matricula
WHERE LTRIM(RTRIM(ViaMatricula)) = N'Ratificacion de continuidad'
  AND NULLIF(LTRIM(RTRIM(FechaSolicitud)), N'') IS NOT NULL
UNION ALL
SELECT 'Discapacidad marcada sin tipo especificado', COUNT(*)
FROM stg.Estudiante
WHERE LTRIM(RTRIM(TieneDiscapacidad)) = N'1' AND NULLIF(LTRIM(RTRIM(TipoDiscapacidad)), N'') IS NULL
UNION ALL
SELECT 'Docente nombrado sin escala magisterial', COUNT(*)
FROM stg.Docente
WHERE UPPER(LTRIM(RTRIM(CondicionLaboral))) LIKE N'NOMBRAD%'
  AND NULLIF(LTRIM(RTRIM(EscalaMagisterial)), N'') IS NULL
UNION ALL
SELECT 'Recursos de sesion utilizados > programados', COUNT(*)
FROM stg.Sesion
WHERE TRY_CONVERT(INT, RecursosUtilizados) > TRY_CONVERT(INT, RecursosProgramados)
UNION ALL
SELECT 'Minutos de retraso negativos', COUNT(*)
FROM stg.Sesion WHERE TRY_CONVERT(INT, MinutosRetraso) < 0
UNION ALL
SELECT 'Sesion no dictada sin motivo', COUNT(*)
FROM stg.Sesion
WHERE UPPER(LTRIM(RTRIM(EstadoSesion))) LIKE N'NO DICTADA%'
  AND NULLIF(LTRIM(RTRIM(MotivoNoDictada)), N'') IS NULL
UNION ALL
SELECT 'PuntajeTotal distinto de la suma de rubricas', COUNT(*)
FROM stg.MonitoreoDocente
WHERE TRY_CONVERT(INT, PuntajeTotal) <> (TRY_CONVERT(INT, Rubrica1_Involucra)
     + TRY_CONVERT(INT, Rubrica2_Razonamiento) + TRY_CONVERT(INT, Rubrica3_Evalua)
     + TRY_CONVERT(INT, Rubrica4_Respeto)      + TRY_CONVERT(INT, Rubrica5_Comportamiento))
UNION ALL
SELECT 'Rubrica fuera de la escala I a IV', COUNT(*)
FROM stg.MonitoreoDocente
WHERE TRY_CONVERT(INT, Rubrica1_Involucra)      NOT BETWEEN 1 AND 4
   OR TRY_CONVERT(INT, Rubrica2_Razonamiento)   NOT BETWEEN 1 AND 4
   OR TRY_CONVERT(INT, Rubrica3_Evalua)         NOT BETWEEN 1 AND 4
   OR TRY_CONVERT(INT, Rubrica4_Respeto)        NOT BETWEEN 1 AND 4
   OR TRY_CONVERT(INT, Rubrica5_Comportamiento) NOT BETWEEN 1 AND 4
UNION ALL
SELECT 'Caso atendido sin fecha de atencion', COUNT(*)
FROM stg.Convivencia
WHERE LTRIM(RTRIM(EstadoCaso)) = N'Atendido' AND NULLIF(LTRIM(RTRIM(FechaAtencion)), N'') IS NULL
UNION ALL
SELECT 'Matricula rechazada SIN motivo en Observacion', COUNT(*)
FROM stg.Matricula
WHERE UPPER(LTRIM(RTRIM(EstadoMatricula))) LIKE N'RECHAZAD%'
  AND NULLIF(LTRIM(RTRIM(Observacion)), N'') IS NULL
UNION ALL
SELECT 'Matricula aprobada CON texto en Observacion', COUNT(*)
FROM stg.Matricula
WHERE UPPER(LTRIM(RTRIM(EstadoMatricula))) LIKE N'APROB%'
  AND NULLIF(LTRIM(RTRIM(Observacion)), N'') IS NOT NULL
UNION ALL
SELECT 'Aforo excedido: seccion con mas de 30 aprobados', COUNT(*) FROM (
    SELECT SeccionID FROM stg.Matricula
    WHERE UPPER(LTRIM(RTRIM(EstadoMatricula))) LIKE N'APROB%'
    GROUP BY SeccionID HAVING COUNT(*) > 30) x
UNION ALL
SELECT 'Estudiante con matricula RECHAZADA que igual tiene notas', COUNT(DISTINCT n.CodigoEstudiante)
FROM stg.NotaCompetencia n
INNER JOIN stg.Matricula m
        ON LTRIM(RTRIM(m.CodigoEstudiante)) = LTRIM(RTRIM(n.CodigoEstudiante))
       AND m.Anio = n.Anio
WHERE UPPER(LTRIM(RTRIM(m.EstadoMatricula))) LIKE N'RECHAZAD%';
GO

/* ============================================================================
   5b. CUMPLIMIENTO DEL CRONOGRAMA OFICIAL DE MATRICULA
   ----------------------------------------------------------------------------
   Cada fecha del proceso tiene una ventana publicada por el Minedu. Una fecha
   fuera de su ventana significa carga manual tardia, error de tipeo, o que la
   IE no siguio el cronograma: las tres cosas valen la pena reportar.

   Ano escolar 2025: solicitudes 16/12/2024-03/01/2025 | revision 06-17/01 |
                     asignacion 20-28/01 | registro SIAGIE 29/01-12/02
   Ano escolar 2026: solicitudes 02-11/01 | revision 12-18/01 |
                     asignacion 19-30/01 | registro SIAGIE 31/01-04/02
   ============================================================================ */
;WITH Ventanas AS (
    SELECT * FROM (VALUES
        (2025, 'Solicitud',  CAST('2024-12-16' AS DATE), CAST('2025-01-03' AS DATE)),
        (2025, 'Revision',   '2025-01-06', '2025-01-17'),
        (2025, 'Asignacion', '2025-01-20', '2025-01-28'),
        (2025, 'SIAGIE',     '2025-01-29', '2025-02-12'),
        (2026, 'Solicitud',  '2026-01-02', '2026-01-11'),
        (2026, 'Revision',   '2026-01-12', '2026-01-18'),
        (2026, 'Asignacion', '2026-01-19', '2026-01-30'),
        (2026, 'SIAGIE',     '2026-01-31', '2026-02-04')
    ) v(Anio, Fase, Desde, Hasta)
),
Fechas AS (
    SELECT TRY_CONVERT(INT, Anio) AS Anio, 'Solicitud' AS Fase,
           COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSolicitud)), 103),
                    TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSolicitud)), 105),
                    TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaSolicitud)), 10), 23)) AS F
    FROM stg.Matricula WHERE FaseProceso = N'Regular'
    UNION ALL
    SELECT TRY_CONVERT(INT, Anio), 'Revision',
           COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRevision)), 103),
                    TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaRevision)), 10), 23))
    FROM stg.Matricula WHERE FaseProceso = N'Regular'
    UNION ALL
    SELECT TRY_CONVERT(INT, Anio), 'Asignacion',
           COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaAsignacionVacante)), 103),
                    TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaAsignacionVacante)), 10), 23))
    FROM stg.Matricula WHERE FaseProceso = N'Regular'
    UNION ALL
    SELECT TRY_CONVERT(INT, Anio), 'SIAGIE',
           COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRegistroSiagie)), 103),
                    TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaRegistroSiagie)), 10), 23))
    FROM stg.Matricula WHERE FaseProceso = N'Regular'
)
SELECT v.Anio, v.Fase, v.Desde, v.Hasta,
       COUNT(f.F) AS FechasRegistradas,
       SUM(CASE WHEN f.F BETWEEN v.Desde AND v.Hasta THEN 1 ELSE 0 END) AS DentroDeVentana,
       SUM(CASE WHEN f.F NOT BETWEEN v.Desde AND v.Hasta THEN 1 ELSE 0 END) AS FueraDeVentana
FROM Ventanas v
LEFT JOIN Fechas f ON f.Anio = v.Anio AND f.Fase = v.Fase AND f.F IS NOT NULL
GROUP BY v.Anio, v.Fase, v.Desde, v.Hasta
ORDER BY v.Anio, v.Desde;
GO

/* ============================================================================
   5c. ENTREGA DEL MATERIAL EDUCATIVO
   ----------------------------------------------------------------------------
   El material llega a la IE dos semanas antes del inicio de clases y debe
   entregarse a los estudiantes el primer dia. La regla madre de esta tabla:
       ATiempo + Destiempo + NoEntregada = PorEntregar
   Si no cuadra, cualquier porcentaje de cobertura que se calcule sera falso.
   ============================================================================ */
SELECT 'Las cantidades no cuadran con el total por entregar' AS Problema, COUNT(*) AS Registros
FROM stg.EntregaMaterial
WHERE TRY_CONVERT(INT, CantidadEntregadaATiempo) + TRY_CONVERT(INT, CantidadEntregadaDestiempo)
    + TRY_CONVERT(INT, CantidadNoEntregada) <> TRY_CONVERT(INT, CantidadPorEntregar)
UNION ALL
SELECT 'Cantidad entregada negativa', COUNT(*)
FROM stg.EntregaMaterial
WHERE TRY_CONVERT(INT, CantidadEntregadaATiempo)   < 0
   OR TRY_CONVERT(INT, CantidadEntregadaDestiempo) < 0
   OR TRY_CONVERT(INT, CantidadNoEntregada)        < 0
UNION ALL
SELECT 'Entrega anterior a la recepcion del material en la IE', COUNT(*)
FROM stg.EntregaMaterial
WHERE COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaEntregaEfectiva)), 103),
               TRY_CONVERT(DATE, LTRIM(RTRIM(FechaEntregaEfectiva)), 105),
               TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaEntregaEfectiva)), 10), 23))
    < COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRecepcionIE)), 103),
               TRY_CONVERT(DATE, LTRIM(RTRIM(FechaRecepcionIE)), 105),
               TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaRecepcionIE)), 10), 23))
UNION ALL
SELECT 'DiasRetraso no coincide con la diferencia de fechas', COUNT(*)
FROM stg.EntregaMaterial
WHERE TRY_CONVERT(INT, DiasRetraso) <> DATEDIFF(DAY,
        COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaEntregaProgramada)), 103),
                 TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaEntregaProgramada)), 10), 23)),
        COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaEntregaEfectiva)), 103),
                 TRY_CONVERT(DATE, LTRIM(RTRIM(FechaEntregaEfectiva)), 105),
                 TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaEntregaEfectiva)), 10), 23)))
UNION ALL
SELECT 'Material no entregado sin justificacion', COUNT(*)
FROM stg.EntregaMaterial
WHERE TRY_CONVERT(INT, CantidadNoEntregada) > 0
  AND NULLIF(LTRIM(RTRIM(Observacion)), N'') IS NULL
UNION ALL
SELECT 'TipoMaterial fuera del catalogo', COUNT(*)
FROM stg.EntregaMaterial
WHERE UPPER(LTRIM(RTRIM(TipoMaterial))) NOT IN (N'TEXTO ESCOLAR', N'CUADERNO DE TRABAJO');

/* El requisito de recibir la dotacion 14 dias antes del inicio se comprueba
   por fecha de entrega PROGRAMADA. El resultado es un hallazgo de calidad:
   no se inventan fechas de recepcion para que la fuente parezca cumplir. */
SELECT COUNT(*) AS EntregasOrigen,
       SUM(CASE WHEN f.Recepcion IS NULL OR f.Programada IS NULL THEN 1 ELSE 0 END)
           AS FechasNoInterpretables,
       SUM(CASE WHEN f.Recepcion IS NOT NULL AND f.Programada IS NOT NULL
                     AND DATEDIFF(DAY, f.Recepcion, f.Programada) < 14
                THEN 1 ELSE 0 END) AS RecibidasConMenosDe14Dias,
       SUM(CASE WHEN f.Recepcion IS NOT NULL AND f.Programada IS NOT NULL
                     AND DATEDIFF(DAY, f.Recepcion, f.Programada) >= 14
                THEN 1 ELSE 0 END) AS RecibidasCon14DiasOMas
FROM stg.EntregaMaterial e
CROSS APPLY (VALUES (
    COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(e.FechaRecepcionIE)), 103),
             TRY_CONVERT(DATE, LTRIM(RTRIM(e.FechaRecepcionIE)), 105),
             TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(e.FechaRecepcionIE)), 10), 23)),
    COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(e.FechaEntregaProgramada)), 103),
             TRY_CONVERT(DATE, LTRIM(RTRIM(e.FechaEntregaProgramada)), 105),
             TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(e.FechaEntregaProgramada)), 10), 23))
)) AS f(Recepcion, Programada);

/* EJEMPLO DEL EFECTO DE LA SUCIEDAD. Este ranking usa cantidades y DocenteID
   sin depurar: puede atribuir entregas al docente equivocado y sumar valores
   negativos o cantidades que no cuadran. NO es el ranking final del tablero. */
SELECT d.ApellidoPaterno + N' ' + d.ApellidoMaterno + N', ' + d.Nombres AS Docente,
       N'ORIGEN CRUDO: NO USAR COMO KPI' AS EstadoDato,
       e.AreaID,
       SUM(TRY_CONVERT(INT, e.CantidadPorEntregar))        AS DebioEntregar,
       SUM(TRY_CONVERT(INT, e.CantidadEntregadaATiempo))   AS ATiempo,
       SUM(TRY_CONVERT(INT, e.CantidadEntregadaDestiempo)) AS Destiempo,
       SUM(TRY_CONVERT(INT, e.CantidadNoEntregada))        AS NoEntregado,
       MAX(TRY_CONVERT(INT, e.DiasRetraso))                AS PeorRetrasoDias,
       CAST(100.0 * SUM(TRY_CONVERT(INT, e.CantidadEntregadaATiempo))
            / NULLIF(SUM(TRY_CONVERT(INT, e.CantidadPorEntregar)), 0) AS DECIMAL(5,2)) AS PctOportuna
FROM stg.EntregaMaterial e
INNER JOIN stg.Docente d ON LTRIM(RTRIM(d.DocenteID)) = LTRIM(RTRIM(e.DocenteID))
GROUP BY d.ApellidoPaterno, d.ApellidoMaterno, d.Nombres, e.AreaID
ORDER BY PctOportuna ASC;
GO

/* ============================================================================
   6. RANGO Y CATALOGO
   ============================================================================ */
SELECT 'Nota no convertible a numero' AS Problema, COUNT(*) AS Registros
FROM stg.NotaCompetencia
WHERE TRY_CONVERT(DECIMAL(5,2), REPLACE(LTRIM(RTRIM(NotaVigesimal)), N',', N'.')) IS NULL
  AND NULLIF(LTRIM(RTRIM(NotaVigesimal)), N'') IS NOT NULL
UNION ALL
SELECT 'Nota fuera del rango 0 a 20', COUNT(*)
FROM stg.NotaCompetencia
WHERE TRY_CONVERT(DECIMAL(5,2), REPLACE(LTRIM(RTRIM(NotaVigesimal)), N',', N'.'))
      NOT BETWEEN 0 AND 20
UNION ALL
SELECT 'Nota con decimales (la escala es entera)', COUNT(*)
FROM stg.NotaCompetencia
WHERE TRY_CONVERT(DECIMAL(5,2), REPLACE(LTRIM(RTRIM(NotaVigesimal)), N',', N'.'))
      <> TRY_CONVERT(INT, TRY_CONVERT(DECIMAL(5,2), REPLACE(LTRIM(RTRIM(NotaVigesimal)), N',', N'.')))
UNION ALL
SELECT 'El docente escribio la LETRA en la columna de la nota', COUNT(*)
FROM stg.NotaCompetencia
WHERE UPPER(LTRIM(RTRIM(NotaVigesimal))) IN (N'AD', N'A', N'B', N'C')
UNION ALL
SELECT 'Competencia sin nota (caso valido de la norma)', COUNT(*)
FROM stg.NotaCompetencia
WHERE LTRIM(RTRIM(NotaVigesimal)) LIKE N'No se%'
   OR UPPER(LTRIM(RTRIM(NotaVigesimal))) = N'SIN EVIDENCIA'
   OR NULLIF(LTRIM(RTRIM(NotaVigesimal)), N'') IS NULL
UNION ALL
SELECT 'Bimestre fuera del rango 1 a 4', COUNT(*)
FROM stg.NotaCompetencia
WHERE TRY_CONVERT(INT, Bimestre) NOT BETWEEN 1 AND 4 OR TRY_CONVERT(INT, Bimestre) IS NULL
UNION ALL
SELECT 'EstadoAsistencia fuera de catalogo', COUNT(*)
FROM stg.Asistencia
WHERE UPPER(LTRIM(RTRIM(EstadoAsistencia))) NOT IN
      (N'ASISTIO', N'TARDANZA', N'FALTA JUSTIFICADA', N'FALTA INJUSTIFICADA',
       N'A', N'T', N'FJ', N'FI')
UNION ALL
SELECT 'TiempoTrasladoMin no numerico o > 180', COUNT(*)
FROM stg.Estudiante
WHERE TRY_CONVERT(INT, TiempoTrasladoMin) IS NULL
   OR TRY_CONVERT(INT, TiempoTrasladoMin) > 180
UNION ALL
SELECT 'SesionesAtencion fuera del rango 0 a 20', COUNT(*)
FROM stg.Convivencia
WHERE TRY_CONVERT(INT, SesionesAtencion) IS NULL
   OR TRY_CONVERT(INT, SesionesAtencion) NOT BETWEEN 0 AND 20;
GO

/* ============================================================================
   7. COHERENCIA CONTRA EL CALENDARIO
      Requiere DimTiempo. Si aun no existe, omitir este bloque.
      EsDiaHabil solo distingue lunes-viernes y EsPeriodoEscolar es una
      aproximacion mensual; no validan feriados ni los extremos reales de
      cada anio lectivo. Los resultados son alertas exploratorias.
   ============================================================================ */
IF OBJECT_ID('dw.DimTiempo') IS NOT NULL
BEGIN
    SELECT 'Asistencia registrada en dia no habil' AS Problema, COUNT(*) AS Registros
    FROM stg.Asistencia a
    INNER JOIN dw.DimTiempo t
            ON t.Fecha = TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(a.Fecha)), 10), 23)
    WHERE t.EsDiaHabil = 0
    UNION ALL
    SELECT 'Asistencia fuera del periodo escolar', COUNT(*)
    FROM stg.Asistencia a
    INNER JOIN dw.DimTiempo t
            ON t.Fecha = TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(a.Fecha)), 10), 23)
    WHERE t.EsPeriodoEscolar = 0;
END
GO

/* ============================================================================
   8. EL IMPACTO: por que esto importa
   ----------------------------------------------------------------------------
   Compara el calculo literal contra una normalizacion PARCIAL. Este segundo
   calculo solo normaliza espacios y mayusculas y deduplica por columnas de
   negocio; aun deja fuera typos como Dictda/Dictadda y claves sucias.
   Ninguna de las dos filas es el KPI final del datamart.
   ============================================================================ */
SELECT
    'Sin limpiar (compara texto literal)' AS Metodo,
    SUM(CASE WHEN EstadoSesion = N'Dictada' THEN 1 ELSE 0 END) AS SesionesEnHorario,
    COUNT(*) AS SesionesProgramadas,
    CAST(100.0 * SUM(CASE WHEN EstadoSesion = N'Dictada' THEN 1 ELSE 0 END)
         / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS PctCumplimiento
FROM stg.Sesion
UNION ALL
SELECT
    'Normalizacion parcial y deduplicacion (diagnostico)',
    SUM(CASE WHEN UPPER(LTRIM(RTRIM(EstadoSesion))) = N'DICTADA' THEN 1 ELSE 0 END),
    COUNT(*),
    CAST(100.0 * SUM(CASE WHEN UPPER(LTRIM(RTRIM(EstadoSesion))) = N'DICTADA' THEN 1 ELSE 0 END)
         / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY DocenteID, FechaSesion, SeccionID, AreaID
                                   ORDER BY SesionID) AS rn
      FROM stg.Sesion) s
WHERE rn = 1;
GO
