/* ============================================================================
   05_fac_preparacion.sql — PREPARACION CURRICULAR
   CAMBIOS v5.1: borra sus tablas temporales al iniciar (reejecucion en la
   misma ventana) y renumera dos THROW que chocaban con el 06:
   51060 -> 51049 (mes fuera de DimTiempo), 51061 -> 51050 (colision).
   Codigos de este script: 51049 a 51059.
   Ejecutar despues de 04_fac_matricula.sql (base DW_IE1217, SQL Server 2017+).

   CAMBIOS v6.1: el grano suma el BIMESTRE academico. Cada sesion toma el
   bimestre de su fecha en DimTiempo (cierres oficiales), asi que un mes que
   cruza dos bimestres (mayo, agosto y octubre de 2025; mayo de 2026) se
   parte en dos filas. MesTiempoKey se reemplaza por TramoTiempoKey: el primer
   dia del mes DENTRO de su bimestre. Con eso Preparacion y Aprendizajes se
   cruzan por bimestre sin descuadre (resuelve la decision pendiente 1).

   CAMBIOS v6.2: el hecho guarda SOLO las medidas que la matriz v2.1 marca
   «Script SQL», con sus nombres: sesiones programadas, dictadas en horario,
   minutos de retraso, incidencias de programacion (= reprogramadas, como
   dice la matriz), materiales programados y entregados a tiempo. Los demas
   conteos (horas, recursos, TIC, textos/cuadernos, contadores de calidad)
   se siguen calculando aqui como CONTROL y se muestran al final, pero no se
   guardan. Anio y mes salen de DimTiempo por TramoTiempoKey.
   Grano propio (Kimball: no mezclar granos): los materiales son ANUALES
   (se programan para el inicio de clases), asi que pasan a un segundo hecho,
   dm_preparacion.FacEntregaMaterial: docente + area + seccion + anio, con la
   fecha programada (inicio de clases) como clave de tiempo. FacPreparacion
   queda solo con sesiones, por mes y bimestre.

   UNA tabla de hechos: docente + area + seccion + anio escolar + mes + bimestre.
   Las sesiones se cuentan por mes de clase; la dotacion de material pertenece
   al mes en que debio entregarse (marzo para el lote 2025-2026), aunque
   alguna entrega efectiva se haya producido despues.

   MaterialesProgramados = ejemplares POR ENTREGAR a estudiantes, no unidades
   didacticas ni recursos usados en una clase. Un mismo ejemplar no se suma
   otra vez en abril al consultar tendencias mensuales.

   El material individual (titulo, fechas y observaciones) permanece completo
   en stg.EntregaMaterial. Este hecho guarda solo los ejemplares programados
   y entregados a tiempo; su grano mensual no admite el detalle individual.

   Se usan las asignaciones de stg.CargaHoraria para identificar al docente
   responsable tanto de sesiones como de entregas. Las discrepancias del CSV
   y las correcciones se muestran en controles antes de cargar.
   ============================================================================ */
USE DW_IE1217;
GO

IF SCHEMA_ID(N'dm_preparacion') IS NULL EXEC(N'CREATE SCHEMA dm_preparacion');
GO

/* v6.2: si el hecho tiene la estructura anterior, se elimina y se crea de
   nuevo; se recarga completo mas abajo. */
IF COL_LENGTH(N'dm_preparacion.FacPreparacion', N'HorasPedagogicasProgramadas') IS NOT NULL
   OR COL_LENGTH(N'dm_preparacion.FacPreparacion', N'MaterialesProgramados') IS NOT NULL
    DROP TABLE dm_preparacion.FacPreparacion;

IF OBJECT_ID(N'dm_preparacion.FacPreparacion', N'U') IS NULL
BEGIN
    CREATE TABLE dm_preparacion.FacPreparacion (
        PreparacionKey              INT IDENTITY(1,1) NOT NULL,
        TramoTiempoKey              INT NOT NULL, -- primer dia del mes dentro de su bimestre
        DocenteKey                  INT NOT NULL,
        AreaKey                     INT NOT NULL,
        SeccionKey                  INT NOT NULL,
        /* Medidas de la matriz v2.1 marcadas «Script SQL». */
        SesionesProgramadas         INT NOT NULL,
        SesionesDictadasHorario     INT NOT NULL, -- dictadas sin retraso
        MinutosRetraso              INT NOT NULL, -- suma de minutos de retraso
        IncidenciasProgramacion     INT NOT NULL, -- aproximacion: sesiones reprogramadas
        CONSTRAINT PK_FacPreparacion PRIMARY KEY CLUSTERED (PreparacionKey),
        CONSTRAINT UQ_FacPreparacion_Grano UNIQUE
            (TramoTiempoKey, DocenteKey, AreaKey, SeccionKey),
        CONSTRAINT FK_FacPreparacion_Tiempo FOREIGN KEY (TramoTiempoKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT FK_FacPreparacion_Docente FOREIGN KEY (DocenteKey)
            REFERENCES dw.DimDocente(DocenteKey),
        CONSTRAINT FK_FacPreparacion_Area FOREIGN KEY (AreaKey)
            REFERENCES dw.DimArea(AreaKey),
        CONSTRAINT FK_FacPreparacion_Seccion FOREIGN KEY (SeccionKey)
            REFERENCES dw.DimSeccion(SeccionKey),
        CONSTRAINT CK_FacPreparacion_Cantidades CHECK (
            SesionesProgramadas >= 0 AND SesionesDictadasHorario >= 0
            AND IncidenciasProgramacion >= 0 AND MinutosRetraso >= 0
            AND SesionesDictadasHorario + IncidenciasProgramacion <= SesionesProgramadas
        )
    );
END;
GO

/* Segundo hecho del datamart: dotacion anual de material por asignacion.
   Grano: docente + area + seccion + anio escolar. */
IF OBJECT_ID(N'dm_preparacion.FacEntregaMaterial', N'U') IS NULL
BEGIN
    CREATE TABLE dm_preparacion.FacEntregaMaterial (
        EntregaKey                  INT IDENTITY(1,1) NOT NULL,
        FechaProgramadaKey          INT NOT NULL, -- inicio de clases del anio
        DocenteKey                  INT NOT NULL,
        AreaKey                     INT NOT NULL,
        SeccionKey                  INT NOT NULL,
        MaterialesProgramados       INT NOT NULL, -- ejemplares por entregar
        MaterialesEntregadosATiempo INT NOT NULL,
        CONSTRAINT PK_FacEntregaMaterial PRIMARY KEY CLUSTERED (EntregaKey),
        CONSTRAINT UQ_FacEntregaMaterial_Grano UNIQUE
            (FechaProgramadaKey, DocenteKey, AreaKey, SeccionKey),
        CONSTRAINT FK_FacEntrega_Tiempo FOREIGN KEY (FechaProgramadaKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT FK_FacEntrega_Docente FOREIGN KEY (DocenteKey)
            REFERENCES dw.DimDocente(DocenteKey),
        CONSTRAINT FK_FacEntrega_Area FOREIGN KEY (AreaKey)
            REFERENCES dw.DimArea(AreaKey),
        CONSTRAINT FK_FacEntrega_Seccion FOREIGN KEY (SeccionKey)
            REFERENCES dw.DimSeccion(SeccionKey),
        CONSTRAINT CK_FacEntrega CHECK (
            MaterialesProgramados >= 0
            AND MaterialesEntregadosATiempo BETWEEN 0 AND MaterialesProgramados)
    );
END;
GO

/* 0. Las tablas #temporales viven mientras la ventana de SSMS siga abierta. */
DROP TABLE IF EXISTS #CargaLimpia;
DROP TABLE IF EXISTS #SeccionAnual;
DROP TABLE IF EXISTS #Asignacion;
DROP TABLE IF EXISTS #SesionNormalizada;
DROP TABLE IF EXISTS #SesionesMes;
DROP TABLE IF EXISTS #MaterialFechas;
DROP TABLE IF EXISTS #InicioClases;
DROP TABLE IF EXISTS #MaterialPreparado;
DROP TABLE IF EXISTS #MaterialesMes;
DROP TABLE IF EXISTS #Tramo;
DROP TABLE IF EXISTS #GranoPreparacion;

/* Tramos mes x bimestre del calendario academico: la clave de cada tramo es
   su primer dia en DimTiempo (p. ej. mayo 2025 -> 01/05 en el I Bimestre y
   24/05 en el II). El bimestre lo decide DimTiempo, no este script. */
SELECT Anio, Mes, Bimestre, MIN(TiempoKey) AS TramoKey
INTO #Tramo
FROM dw.DimTiempo
WHERE TiempoKey > 0
GROUP BY Anio, Mes, Bimestre;

/* 1. Limpiar claves de la asignacion docente y exigir una sola persona
   responsable por area/seccion/anio. No atribuir material al docente errado. */
SELECT TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))) AS AnioEscolar,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(DocenteID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS DocenteID,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(AreaID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS AreaID,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS SeccionID
INTO #CargaLimpia FROM stg.CargaHoraria;

IF NOT EXISTS (SELECT 1 FROM #CargaLimpia)
    THROW 51051, N'CargaHoraria esta vacia: se cancela la recarga.', 1;

IF EXISTS (SELECT 1 FROM #CargaLimpia
           WHERE AnioEscolar IS NULL OR DocenteID = N''
              OR AreaID = N'' OR SeccionID = N'')
    THROW 51052, N'CargaHoraria tiene claves incompletas.', 1;

IF EXISTS (SELECT 1 FROM #CargaLimpia
           GROUP BY AnioEscolar, AreaID, SeccionID HAVING COUNT(*) > 1)
    THROW 51053, N'Hay varias asignaciones para la misma area, seccion y anio.', 1;

;WITH s AS (
    SELECT TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))) AS AnioEscolar,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS SeccionID,
           TRY_CONVERT(TINYINT, LTRIM(RTRIM(Grado))) AS Grado,
           UPPER(LTRIM(RTRIM(Seccion))) AS Seccion,
           ROW_NUMBER() OVER (
               PARTITION BY LTRIM(RTRIM(Anio)),
                    UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
                        NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N''))))
               ORDER BY FechaCarga DESC
           ) AS rn
    FROM stg.Seccion
)
SELECT AnioEscolar, SeccionID, Grado, Seccion INTO #SeccionAnual
FROM s WHERE rn = 1;

SELECT a.AnioEscolar, a.DocenteID, a.AreaID, a.SeccionID,
       d.DocenteKey, ar.AreaKey, sc.SeccionKey, sa.Grado
INTO #Asignacion
FROM #CargaLimpia AS a
LEFT JOIN #SeccionAnual AS sa
    ON sa.AnioEscolar = a.AnioEscolar AND sa.SeccionID = a.SeccionID
LEFT JOIN dw.DimDocente AS d ON d.DocenteID = a.DocenteID
LEFT JOIN dw.DimArea AS ar ON ar.AreaID = a.AreaID
LEFT JOIN dw.DimSeccion AS sc
    ON sc.CodigoCorto = CONVERT(NVARCHAR(3), sa.Grado) + sa.Seccion;

IF EXISTS (SELECT 1 FROM #Asignacion
           WHERE DocenteKey IS NULL OR AreaKey IS NULL OR SeccionKey IS NULL)
BEGIN
    SELECT * FROM #Asignacion
    WHERE DocenteKey IS NULL OR AreaKey IS NULL OR SeccionKey IS NULL;
    THROW 51054, N'Asignacion sin docente, area o seccion en 03_dimensiones.', 1;
END;

/* 2. Sesiones: normalizar estados, localizar -DUP y cruzar con la asignacion.
   Un estado desconocido conserva la sesion programada, pero no se convierte
   arbitrariamente en una sesion dictada. */
;WITH l AS (
    SELECT LTRIM(RTRIM(SesionID)) AS SesionID,
           TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))) AS AnioEscolar,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(DocenteID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS DocenteOrigen,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(AreaID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS AreaID,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS SeccionID,
           TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(FechaSesion)), N''), 23)
               AS FechaSesion,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(EstadoSesion,
               NCHAR(160), N''), NCHAR(9), N'')))) AS EstadoRaw,
           TRY_CONVERT(INT, HorasPedagogicas) AS Horas,
           TRY_CONVERT(INT, MinutosRetraso) AS Retraso,
           TRY_CONVERT(INT, RecursosProgramados) AS RecursosP,
           TRY_CONVERT(INT, RecursosUtilizados) AS RecursosU,
           TRY_CONVERT(TINYINT, UsoRecursoTIC) AS TIC
    FROM stg.Sesion
), n AS (
    SELECT l.*, a.DocenteID AS DocenteAsignado,
           a.DocenteKey, a.AreaKey, a.SeccionKey,
           CASE WHEN EstadoRaw LIKE N'NO%DICT%' THEN N'No dictada'
                WHEN EstadoRaw LIKE N'REPRO%' THEN N'Reprogramada'
                WHEN EstadoRaw LIKE N'DICT%RETRAS%' THEN N'Dictada con retraso'
                WHEN EstadoRaw LIKE N'DICT%' THEN N'Dictada'
                ELSE N'Desconocida' END AS Estado,
           ROW_NUMBER() OVER (
               PARTITION BY CASE WHEN RIGHT(UPPER(l.SesionID), 4) = N'-DUP'
                                 THEN LEFT(l.SesionID, LEN(l.SesionID) - 4)
                                 ELSE l.SesionID END
               ORDER BY CASE WHEN RIGHT(UPPER(l.SesionID), 4) = N'-DUP'
                             THEN 1 ELSE 0 END, l.SesionID
           ) AS rn
    FROM l LEFT JOIN #Asignacion AS a
      ON a.AnioEscolar = l.AnioEscolar AND a.AreaID = l.AreaID
     AND a.SeccionID = l.SeccionID
)
SELECT * INTO #SesionNormalizada FROM n;

SELECT N'Duplicada' AS Incidencia, SesionID, AnioEscolar, SeccionID,
       DocenteOrigen, FechaSesion
FROM #SesionNormalizada WHERE rn > 1
UNION ALL
SELECT N'Sin asignacion/seccion', SesionID, AnioEscolar, SeccionID,
       DocenteOrigen, FechaSesion
FROM #SesionNormalizada WHERE rn = 1 AND DocenteKey IS NULL
UNION ALL
SELECT N'Fecha de sesion no valida', SesionID, AnioEscolar, SeccionID,
       DocenteOrigen, FechaSesion
FROM #SesionNormalizada
WHERE rn = 1 AND DocenteKey IS NOT NULL
  AND (FechaSesion IS NULL OR YEAR(FechaSesion) <> AnioEscolar)
ORDER BY Incidencia, SesionID;

IF NOT EXISTS (SELECT 1 FROM #SesionNormalizada WHERE rn = 1
               AND DocenteKey IS NOT NULL AND FechaSesion IS NOT NULL
               AND YEAR(FechaSesion) = AnioEscolar)
    THROW 51055, N'Ninguna sesion valida para cargar: se cancela la recarga.', 1;

/* Una colision real de clase en una seccion valida requiere investigacion.
   Las dos sesiones con mismo dia/docente/area y seccion 9Z quedan fuera por
   no existir esa seccion; no se clasifican como copias -DUP. */
IF EXISTS (
    SELECT 1 FROM #SesionNormalizada
    WHERE rn = 1 AND DocenteKey IS NOT NULL AND FechaSesion IS NOT NULL
      AND YEAR(FechaSesion) = AnioEscolar
    GROUP BY AnioEscolar, FechaSesion, DocenteKey, AreaKey, SeccionKey
    HAVING COUNT(*) > 1
)
    THROW 51050, N'Dos sesiones validas comparten docente, fecha, area y seccion.', 1;

SELECT AnioEscolar, MONTH(FechaSesion) AS MesEscolar, TramoKey,
       DocenteKey, AreaKey, SeccionKey,
       COUNT(*) AS SesionesProgramadas,
       SUM(CASE WHEN Estado IN (N'Dictada', N'Dictada con retraso')
                THEN 1 ELSE 0 END) AS SesionesDictadas,
       SUM(CASE WHEN Estado = N'Dictada' AND Retraso = 0
                THEN 1 ELSE 0 END) AS SesionesDictadasHorario,
       SUM(CASE WHEN Estado = N'Dictada con retraso' OR
                          (Estado = N'Dictada' AND Retraso > 0)
                THEN 1 ELSE 0 END) AS SesionesDictadasRetraso,
       SUM(CASE WHEN Estado = N'No dictada' THEN 1 ELSE 0 END) AS SesionesNoDictadas,
       SUM(CASE WHEN Estado = N'Reprogramada' THEN 1 ELSE 0 END)
           AS SesionesReprogramadas,
       SUM(CASE WHEN Estado = N'Desconocida' THEN 1 ELSE 0 END)
           AS SesionesEstadoDesconocido,
       SUM(CASE WHEN Horas >= 0 THEN Horas ELSE 0 END)
           AS HorasPedagogicasProgramadas,
       SUM(CASE WHEN Estado IN (N'Dictada', N'Dictada con retraso')
                          AND Horas >= 0 THEN Horas ELSE 0 END)
           AS HorasPedagogicasDictadas,
       SUM(CASE WHEN Estado IN (N'Dictada', N'Dictada con retraso')
                          AND Retraso > 0 THEN Retraso ELSE 0 END) AS MinutosRetraso,
       SUM(CASE WHEN Retraso IS NULL OR Retraso < 0 THEN 1 ELSE 0 END)
           AS SesionesRetrasoInvalido,
       SUM(CASE WHEN RecursosP >= 0 THEN RecursosP ELSE 0 END)
           AS RecursosProgramadosSesion,
       SUM(CASE WHEN RecursosP >= 0 AND RecursosU BETWEEN 0 AND RecursosP
                THEN RecursosU ELSE 0 END) AS RecursosUtilizadosSesion,
       SUM(CASE WHEN RecursosP IS NULL OR RecursosP < 0
                     OR RecursosU IS NULL OR RecursosU < 0
                     OR RecursosU > RecursosP THEN 1 ELSE 0 END)
           AS SesionesRecursosInvalidos,
       SUM(CASE WHEN Estado IN (N'Dictada', N'Dictada con retraso') AND TIC = 1
                THEN 1 ELSE 0 END) AS SesionesConTIC
INTO #SesionesMes
FROM (SELECT sn.*, tr.TramoKey
      FROM #SesionNormalizada AS sn
      LEFT JOIN dw.DimTiempo AS t ON t.Fecha = sn.FechaSesion
      LEFT JOIN #Tramo AS tr
        ON tr.Anio = t.Anio AND tr.Mes = t.Mes AND tr.Bimestre = t.Bimestre) AS x
WHERE rn = 1 AND DocenteKey IS NOT NULL AND FechaSesion IS NOT NULL
  AND YEAR(FechaSesion) = AnioEscolar
GROUP BY AnioEscolar, MONTH(FechaSesion), TramoKey, DocenteKey, AreaKey, SeccionKey;

/* 3. Entregas: el catalogo MaterialID decide si es texto o cuaderno; no
   confiar en TipoMaterial escrito libremente. La cantidad 'a tiempo' se
   reconstruye del balance, pues SOLO esa columna fue adulterada en 21 filas
   del CSV: PorEntregar - Destiempo - NoEntregada. Si el balance no es viable,
   detener la carga en vez de fabricar una cantidad. */
IF EXISTS (
    SELECT 1 FROM stg.Material
    GROUP BY LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(MaterialID,
        NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))
    HAVING COUNT(*) > 1
)
    THROW 51056, N'MaterialID duplicado en el catalogo de materiales.', 1;

;WITH l AS (
    SELECT LTRIM(RTRIM(EntregaID)) AS EntregaID,
           TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))) AS AnioEscolar,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS SeccionID,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(AreaID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS AreaID,
           UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(DocenteID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS DocenteOrigen,
           LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(MaterialID,
               NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N''))) AS MaterialID,
           NULLIF(LTRIM(RTRIM(FechaRecepcionIE)), N'') AS FechaRecepcionRaw,
           NULLIF(LTRIM(RTRIM(FechaEntregaProgramada)), N'') AS FechaProgramadaRaw,
           TRY_CONVERT(INT, CantidadRecibidaIE) AS Recibidos,
           TRY_CONVERT(INT, CantidadPorEntregar) AS PorEntregar,
           TRY_CONVERT(INT, CantidadEntregadaATiempo) AS ATiempoOriginal,
           TRY_CONVERT(INT, CantidadEntregadaDestiempo) AS Destiempo,
           TRY_CONVERT(INT, CantidadNoEntregada) AS NoEntregados
    FROM stg.EntregaMaterial
), f AS (
    SELECT l.*,
           CASE WHEN FechaRecepcionRaw LIKE N'[0-9][0-9]/%'
                     THEN TRY_CONVERT(DATE, FechaRecepcionRaw, 103)
                WHEN FechaRecepcionRaw LIKE N'[0-9][0-9]-%'
                     THEN TRY_CONVERT(DATE, FechaRecepcionRaw, 105)
                ELSE TRY_CONVERT(DATE, FechaRecepcionRaw, 23) END AS Recepcion,
           CASE WHEN FechaProgramadaRaw LIKE N'[0-9][0-9]/%'
                     THEN TRY_CONVERT(DATE, FechaProgramadaRaw, 103)
                WHEN FechaProgramadaRaw LIKE N'[0-9][0-9]-%'
                     THEN TRY_CONVERT(DATE, FechaProgramadaRaw, 105)
                ELSE TRY_CONVERT(DATE, FechaProgramadaRaw, 23)
                END AS ProgramadaOriginal
    FROM l
)
SELECT * INTO #MaterialFechas FROM f;

IF NOT EXISTS (SELECT 1 FROM #MaterialFechas)
    THROW 51057, N'Staging de entregas de material esta vacio.', 1;

/* La fecha comun de entrega programada define el inicio escolar de cada anio.
   2025 -> 17/03, 2026 -> 16/03. Se infiere de las fechas validas del lote:
   al recibir un anio nuevo no hay que editar un CASE de fechas en este ETL.
   Las fechas ilegibles se asignan al inicio mayoritario y quedan marcadas. */
;WITH frecuencia AS (
    SELECT AnioEscolar, ProgramadaOriginal, COUNT(*) AS Registros
    FROM #MaterialFechas WHERE ProgramadaOriginal IS NOT NULL
    GROUP BY AnioEscolar, ProgramadaOriginal
), priorizada AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY AnioEscolar
        ORDER BY Registros DESC, ProgramadaOriginal
    ) AS rn FROM frecuencia
)
SELECT AnioEscolar, ProgramadaOriginal AS InicioClases
INTO #InicioClases FROM priorizada WHERE rn = 1;

SELECT f.*, a.DocenteID AS DocenteAsignado, a.DocenteKey, a.AreaKey,
       a.SeccionKey, a.Grado, i.InicioClases,
       m.MaterialID AS MaterialCatalogo,
       CASE WHEN UPPER(LTRIM(RTRIM(m.TipoMaterial))) LIKE N'TEXTO%'
                 THEN N'Texto escolar'
            WHEN UPPER(LTRIM(RTRIM(m.TipoMaterial))) LIKE N'CUADERNO%'
                 THEN N'Cuaderno de trabajo' END AS TipoCatalogo,
       TRY_CONVERT(TINYINT, LTRIM(RTRIM(m.Grado))) AS GradoMaterial,
       UPPER(LTRIM(RTRIM(m.AreaID))) AS AreaMaterial,
       f.PorEntregar - f.Destiempo - f.NoEntregados AS ATiempoCorregido
INTO #MaterialPreparado
FROM #MaterialFechas AS f LEFT JOIN #InicioClases AS i
    ON i.AnioEscolar = f.AnioEscolar
LEFT JOIN #Asignacion AS a
    ON a.AnioEscolar = f.AnioEscolar AND a.AreaID = f.AreaID
   AND a.SeccionID = f.SeccionID
LEFT JOIN stg.Material AS m ON LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(m.MaterialID,
    NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N''))) = f.MaterialID;

SELECT EntregaID, AnioEscolar, AreaID, SeccionID, MaterialID,
       DocenteOrigen, DocenteAsignado, ATiempoOriginal, ATiempoCorregido,
       FechaProgramadaRaw, ProgramadaOriginal, InicioClases, Recepcion
FROM #MaterialPreparado
WHERE DocenteOrigen <> DocenteAsignado
   OR ATiempoOriginal <> ATiempoCorregido
   OR ProgramadaOriginal IS NULL OR Recepcion IS NULL
   OR ProgramadaOriginal <> InicioClases
   OR (Recepcion IS NOT NULL AND Recepcion > InicioClases)
ORDER BY EntregaID;

IF EXISTS (
    SELECT 1 FROM #MaterialPreparado
    WHERE DocenteKey IS NULL OR MaterialCatalogo IS NULL OR TipoCatalogo IS NULL
       OR AreaMaterial <> AreaID OR GradoMaterial <> Grado
       OR InicioClases IS NULL OR YEAR(InicioClases) <> AnioEscolar
       OR PorEntregar IS NULL OR PorEntregar < 0
       OR Recibidos IS NULL OR Recibidos < 0
       OR Recibidos <> PorEntregar - NoEntregados
       OR ATiempoOriginal IS NULL OR Destiempo IS NULL OR NoEntregados IS NULL
       OR Destiempo < 0 OR NoEntregados < 0 OR ATiempoCorregido < 0
)
BEGIN
    SELECT EntregaID, AnioEscolar, AreaID, SeccionID, MaterialID,
           PorEntregar, Recibidos, ATiempoOriginal, Destiempo,
           NoEntregados, ATiempoCorregido, DocenteKey, MaterialCatalogo,
           InicioClases
    FROM #MaterialPreparado
    WHERE DocenteKey IS NULL OR MaterialCatalogo IS NULL OR TipoCatalogo IS NULL
       OR AreaMaterial <> AreaID OR GradoMaterial <> Grado
       OR InicioClases IS NULL OR YEAR(InicioClases) <> AnioEscolar
       OR PorEntregar IS NULL OR PorEntregar < 0
       OR Recibidos IS NULL OR Recibidos < 0
       OR Recibidos <> PorEntregar - NoEntregados
       OR ATiempoOriginal IS NULL OR Destiempo IS NULL OR NoEntregados IS NULL
       OR Destiempo < 0 OR NoEntregados < 0 OR ATiempoCorregido < 0;
    THROW 51058, N'Entrega sin asignacion/categoria o balance recuperable: revisar staging.', 1;
END;

IF EXISTS (SELECT 1 FROM #MaterialPreparado
           GROUP BY AnioEscolar, SeccionID, MaterialID HAVING COUNT(*) > 1)
    THROW 51059, N'Entrega duplicada del mismo material a una seccion y anio.', 1;

SELECT AnioEscolar, MONTH(InicioClases) AS MesEscolar, TramoKey,
       MIN(CONVERT(INT, CONVERT(CHAR(8), InicioClases, 112))) AS FechaProgramadaKey,
       DocenteKey, AreaKey, SeccionKey,
       COUNT(*) AS RegistrosMaterial,
       SUM(Recibidos) AS MaterialesRecibidosIE,
       SUM(PorEntregar) AS MaterialesPorEntregar,
       SUM(ATiempoCorregido) AS MaterialesEntregadosATiempo,
       SUM(Destiempo) AS MaterialesEntregadosTarde,
       SUM(NoEntregados) AS MaterialesNoEntregados,
       SUM(CASE WHEN TipoCatalogo = N'Texto escolar' THEN PorEntregar ELSE 0 END)
           AS TextosPorEntregar,
       SUM(CASE WHEN TipoCatalogo = N'Texto escolar' THEN ATiempoCorregido ELSE 0 END)
           AS TextosEntregadosATiempo,
       SUM(CASE WHEN TipoCatalogo = N'Texto escolar' THEN Destiempo ELSE 0 END)
           AS TextosEntregadosTarde,
       SUM(CASE WHEN TipoCatalogo = N'Texto escolar' THEN NoEntregados ELSE 0 END)
           AS TextosNoEntregados,
       SUM(CASE WHEN TipoCatalogo = N'Cuaderno de trabajo' THEN PorEntregar ELSE 0 END)
           AS CuadernosPorEntregar,
       SUM(CASE WHEN TipoCatalogo = N'Cuaderno de trabajo' THEN ATiempoCorregido ELSE 0 END)
           AS CuadernosEntregadosATiempo,
       SUM(CASE WHEN TipoCatalogo = N'Cuaderno de trabajo' THEN Destiempo ELSE 0 END)
           AS CuadernosEntregadosTarde,
       SUM(CASE WHEN TipoCatalogo = N'Cuaderno de trabajo' THEN NoEntregados ELSE 0 END)
           AS CuadernosNoEntregados,
       SUM(CASE WHEN DATEDIFF(DAY, Recepcion, InicioClases) >= 14
                THEN 1 ELSE 0 END) AS RegistrosRecibidos14Dias,
       SUM(CASE WHEN Recepcion IS NULL THEN 1 ELSE 0 END)
           AS RegistrosRecepcionSinFecha,
       SUM(CASE WHEN ProgramadaOriginal IS NULL THEN 1 ELSE 0 END)
           AS RegistrosProgramacionSinFecha,
       SUM(CASE WHEN ATiempoOriginal <> ATiempoCorregido THEN 1 ELSE 0 END)
           AS RegistrosCantidadCorregida,
       SUM(CASE WHEN DocenteOrigen <> DocenteAsignado THEN 1 ELSE 0 END)
           AS RegistrosDocenteCorregido
INTO #MaterialesMes
FROM (SELECT mp.*, tr.TramoKey
      FROM #MaterialPreparado AS mp
      LEFT JOIN dw.DimTiempo AS t ON t.Fecha = mp.InicioClases
      LEFT JOIN #Tramo AS tr
        ON tr.Anio = t.Anio AND tr.Mes = t.Mes AND tr.Bimestre = t.Bimestre) AS x
GROUP BY AnioEscolar, MONTH(InicioClases), TramoKey, DocenteKey, AreaKey, SeccionKey;

/* 4. Cada hecho con su propio grano: sesiones por mes + bimestre en
   FacPreparacion; material por anio en FacEntregaMaterial. Nunca se unen
   sesiones con entregas (1:N), porque multiplicaria los ejemplares. */
SELECT AnioEscolar, MesEscolar, TramoKey, DocenteKey, AreaKey, SeccionKey
INTO #GranoPreparacion
FROM #SesionesMes;

/* Toda fila necesita su tramo en DimTiempo, y el material debe caer dentro
   del periodo escolar (bimestre > 0): se programa al inicio de clases. */
IF EXISTS (SELECT 1 FROM #GranoPreparacion WHERE TramoKey IS NULL)
   OR EXISTS (SELECT 1 FROM #MaterialesMes AS m
              LEFT JOIN dw.DimTiempo AS t ON t.TiempoKey = m.FechaProgramadaKey
              WHERE t.TiempoKey IS NULL OR t.Bimestre = 0)
    THROW 51049, N'Fecha fuera de DimTiempo o material fuera del periodo escolar: revisar el calendario del 03.', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    DELETE FROM dm_preparacion.FacPreparacion;

    INSERT INTO dm_preparacion.FacPreparacion (
        TramoTiempoKey, DocenteKey, AreaKey, SeccionKey,
        SesionesProgramadas, SesionesDictadasHorario, MinutosRetraso,
        IncidenciasProgramacion
    )
    SELECT g.TramoKey, g.DocenteKey, g.AreaKey, g.SeccionKey,
           ISNULL(s.SesionesProgramadas, 0),
           ISNULL(s.SesionesDictadasHorario, 0),
           ISNULL(s.MinutosRetraso, 0),
           ISNULL(s.SesionesReprogramadas, 0)
    FROM #GranoPreparacion AS g
    LEFT JOIN #SesionesMes AS s ON s.TramoKey = g.TramoKey
        AND s.DocenteKey = g.DocenteKey
        AND s.AreaKey = g.AreaKey AND s.SeccionKey = g.SeccionKey;

    DELETE FROM dm_preparacion.FacEntregaMaterial;
    INSERT INTO dm_preparacion.FacEntregaMaterial
        (FechaProgramadaKey, DocenteKey, AreaKey, SeccionKey,
         MaterialesProgramados, MaterialesEntregadosATiempo)
    SELECT FechaProgramadaKey, DocenteKey, AreaKey, SeccionKey,
           MaterialesPorEntregar, MaterialesEntregadosATiempo
    FROM #MaterialesMes;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

/* 5. Reconciliacion del lote. Esperado: 6425 sesiones de origen, 45 copias,
   28 sin seccion, 6352 sesiones validas, 200 entregas, 21 cantidades
   recuperadas, 6 docentes corregidos. Hasta v6.0 eran 769 filas mensuales
   (439+330); en v6.1 los meses partidos por un cierre suman filas.
   Son referencias del lote actual, no cifras fijas del proceso. */
SELECT COUNT(*) AS SesionesOrigen,
       SUM(CASE WHEN rn > 1 THEN 1 ELSE 0 END) AS Duplicadas,
       SUM(CASE WHEN rn = 1 AND DocenteKey IS NULL THEN 1 ELSE 0 END)
           AS SinAsignacion
FROM #SesionNormalizada;

SELECT t.Anio AS AnioEscolar, COUNT(*) AS Filas,
       SUM(f.SesionesProgramadas) AS SesionesProgramadas,
       SUM(f.SesionesDictadasHorario) AS DictadasEnHorario,
       CAST(100.0 * SUM(f.SesionesDictadasHorario)
            / NULLIF(SUM(f.SesionesProgramadas), 0) AS DECIMAL(6,2))
           AS PctCumplimientoHorario,
       SUM(f.MinutosRetraso) AS MinutosRetraso,
       SUM(f.IncidenciasProgramacion) AS IncidenciasProgramacion
FROM dm_preparacion.FacPreparacion AS f
JOIN dw.DimTiempo AS t ON t.TiempoKey = f.TramoTiempoKey
GROUP BY t.Anio ORDER BY t.Anio;

SELECT t.Anio AS AnioEscolar, MIN(t.Fecha) AS FechaProgramada, COUNT(*) AS Asignaciones,
       SUM(e.MaterialesProgramados) AS MaterialesProgramados,
       SUM(e.MaterialesEntregadosATiempo) AS MaterialesATiempo,
       CAST(100.0 * SUM(e.MaterialesEntregadosATiempo)
            / NULLIF(SUM(e.MaterialesProgramados), 0) AS DECIMAL(6,2))
           AS PctEntregaOportuna
FROM dm_preparacion.FacEntregaMaterial AS e
JOIN dw.DimTiempo AS t ON t.TiempoKey = e.FechaProgramadaKey
GROUP BY t.Anio ORDER BY t.Anio;

/* Controles de calidad del lote (calculados aqui, no guardados en el hecho). */
SELECT s.AnioEscolar,
       SUM(s.SesionesNoDictadas) AS NoDictadas,
       SUM(s.SesionesEstadoDesconocido) AS EstadoDesconocido,
       SUM(s.SesionesRetrasoInvalido) AS RetrasoInvalido,
       SUM(s.SesionesRecursosInvalidos) AS RecursosInvalidos
FROM #SesionesMes AS s GROUP BY s.AnioEscolar ORDER BY s.AnioEscolar;

SELECT m.AnioEscolar,
       SUM(m.RegistrosMaterial) AS RegistrosMaterial,
       SUM(m.MaterialesEntregadosTarde) AS MaterialesTarde,
       SUM(m.MaterialesNoEntregados) AS MaterialesNoEntregados,
       SUM(m.RegistrosRecibidos14Dias) AS EntregasRecibidas14Dias,
       SUM(m.RegistrosCantidadCorregida) AS CantidadesRecuperadas,
       SUM(m.RegistrosDocenteCorregido) AS DocentesCorregidos
FROM #MaterialesMes AS m GROUP BY m.AnioEscolar ORDER BY m.AnioEscolar;

SELECT t.Anio AS AnioEscolar, t.Mes, t.Bimestre, t.NombreBimestre,
       COUNT(*) AS Filas,
       SUM(f.SesionesProgramadas) AS Sesiones
FROM dm_preparacion.FacPreparacion AS f
JOIN dw.DimTiempo AS t ON t.TiempoKey = f.TramoTiempoKey
GROUP BY t.Anio, t.Mes, t.Bimestre, t.NombreBimestre
ORDER BY t.Anio, t.Mes, t.Bimestre;

/* Metrica 'incidencias de programacion': el origen no ofrece cruces de horario
   ni historial de cambios. SesionesReprogramadas es un dato disponible,
   pero NO representa todos los cruces o incidencias de la matriz BI. */
GO
