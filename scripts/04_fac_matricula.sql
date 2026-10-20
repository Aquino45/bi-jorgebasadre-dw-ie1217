/* ============================================================================
   04_fac_matricula.sql — DATAMART: MATRICULAS Y VACANTES
   CAMBIOS v5.1: borra sus tablas temporales al iniciar (antes, reejecutar en
   la misma ventana fallaba con 'There is already an object named #...'), y
   el detalle del THROW 51004 muestra tambien las fechas fuera de DimTiempo.
   Requiere el 03 v5.1 (DimTipoMatricula con via corregida).
   v5.1b: SUM sobre la columna BIT ViaCorregida (error 8117) -> CAST a INT.
   v6.0: el motivo del rechazo se clasifica con stg.MotivoRechazoCategoria
   (creada por el 03) y el hecho guarda la clave de su CATEGORIA.
   Ejecutar DESPUES de 01_staging, 02_diagnostico y 03_dimensiones.
   Base: DW_IE1217 | SQL Server 2017 o posterior.

   GRANO: una matricula de un estudiante por anio escolar.
   La solicitud puede ocurrir en diciembre del anio anterior: el anio escolar
   se guarda explicito y NO se deduce de ninguna de las cuatro fechas.

   DimTipoMatricula contiene la via CORREGIDA por el tipo de estudiante:
     Ingresante/Traslado -> Solicitud de vacante.
     Continuador/Repitente -> Ratificacion de continuidad.
   El origen se conserva en stg.Matricula; los conflictos se muestran abajo.

   -1 No aplica: fechas solicitud/revision/asignacion para ratificaciones.
   -2 No registrado: fecha requerida sin dato valido o SIAGIE de rechazadas.
   Nunca se excluye una matricula valida por faltar una fecha.

   Reejecucion: reemplaza el contenido del HECHO en una transaccion; no cambia
   claves sustitutas de las dimensiones. 01 recarga stg, 03 sincroniza dims.
   ============================================================================ */
USE DW_IE1217;
GO

IF SCHEMA_ID(N'dm_matricula') IS NULL EXEC(N'CREATE SCHEMA dm_matricula');
GO

IF OBJECT_ID(N'dm_matricula.FacMatricula', N'U') IS NULL
BEGIN
    CREATE TABLE dm_matricula.FacMatricula (
        MatriculaKey               INT IDENTITY(1,1) NOT NULL,
        MatriculaID                NVARCHAR(30) NOT NULL, -- identificador del origen
        AnioEscolar                SMALLINT NOT NULL,
        EstudianteKey              INT NOT NULL,
        SeccionKey                 INT NOT NULL,
        TipoMatriculaKey           INT NOT NULL,
        MotivoKey                  INT NOT NULL,
        FechaSolicitudKey          INT NOT NULL,
        FechaRevisionKey           INT NOT NULL,
        FechaAsignacionKey         INT NOT NULL,
        FechaSiagieKey             INT NOT NULL,
        AforoSeccionSnapshot       SMALLINT NOT NULL,
        MatriculasRegistradas      TINYINT NOT NULL,
        SolicitudesVacante         TINYINT NOT NULL,
        MatriculasAprobadas        TINYINT NOT NULL,
        MatriculasRechazadas       TINYINT NOT NULL,
        VacantesOcupadas           TINYINT NOT NULL,
        DiasValidacion             SMALLINT NULL,
        CasosConValidacion         TINYINT NOT NULL,
        DiasHastaSiagie           SMALLINT NULL,
        CasosConDiasHastaSiagie    TINYINT NOT NULL,
        ViaCorregida               BIT NOT NULL,
        FechaCargaDW               DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT PK_FacMatricula PRIMARY KEY CLUSTERED (MatriculaKey),
        CONSTRAINT UQ_FacMatricula_EstudianteAnio UNIQUE (AnioEscolar, EstudianteKey),
        CONSTRAINT UQ_FacMatricula_ID UNIQUE (MatriculaID),
        CONSTRAINT FK_FacMatricula_Estudiante FOREIGN KEY (EstudianteKey)
            REFERENCES dw.DimEstudiante(EstudianteKey),
        CONSTRAINT FK_FacMatricula_Seccion FOREIGN KEY (SeccionKey)
            REFERENCES dw.DimSeccion(SeccionKey),
        CONSTRAINT FK_FacMatricula_Tipo FOREIGN KEY (TipoMatriculaKey)
            REFERENCES dw.DimTipoMatricula(TipoMatriculaKey),
        CONSTRAINT FK_FacMatricula_Motivo FOREIGN KEY (MotivoKey)
            REFERENCES dw.DimMotivoRechazo(MotivoKey),
        CONSTRAINT FK_FacMatricula_Solicitud FOREIGN KEY (FechaSolicitudKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT FK_FacMatricula_Revision FOREIGN KEY (FechaRevisionKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT FK_FacMatricula_Asignacion FOREIGN KEY (FechaAsignacionKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT FK_FacMatricula_Siagie FOREIGN KEY (FechaSiagieKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT CK_FacMatricula_Medidas CHECK (
            MatriculasRegistradas = 1
            AND SolicitudesVacante IN (0, 1)
            AND MatriculasAprobadas IN (0, 1)
            AND MatriculasRechazadas IN (0, 1)
            AND MatriculasAprobadas + MatriculasRechazadas = 1
            AND VacantesOcupadas = MatriculasAprobadas
            AND CasosConValidacion IN (0, 1)
            AND CasosConDiasHastaSiagie IN (0, 1)
            AND (DiasValidacion IS NULL AND CasosConValidacion = 0
                 OR DiasValidacion >= 0 AND CasosConValidacion = 1)
            AND (DiasHastaSiagie IS NULL AND CasosConDiasHastaSiagie = 0
                 OR DiasHastaSiagie >= 0 AND CasosConDiasHastaSiagie = 1)
            AND AforoSeccionSnapshot > 0
        )
    );
END;
GO

/* 0. Las tablas #temporales viven mientras la ventana de SSMS siga abierta.
      Sin esto, la segunda ejecucion falla antes de hacer nada. */
DROP TABLE IF EXISTS #MatriculaNormalizada;
DROP TABLE IF EXISTS #SeccionAnual;
DROP TABLE IF EXISTS #MatriculaPreparada;

/* 1. Normalizar y ordenar duplicados SIN alterar staging.
   La fila -BIS del lote sintetico copia otra matricula; se prefiere el ID
   original. Ante nuevos duplicados hay que revisar la consulta de descartes. */
;WITH Limpio AS (
    SELECT
        LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(m.MatriculaID,
            NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N''))) AS MatriculaID,
        TRY_CONVERT(SMALLINT, LTRIM(RTRIM(m.Anio))) AS AnioEscolar,
        LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(m.CodigoEstudiante,
            NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N''))) AS CodigoEstudiante,
        LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(m.SeccionID,
            NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N''))) AS SeccionID,
        LTRIM(RTRIM(m.TipoMatricula)) AS TipoRaw,
        LTRIM(RTRIM(m.ViaMatricula)) AS ViaRaw,
        LTRIM(RTRIM(m.FaseProceso)) AS FaseRaw,
        LTRIM(RTRIM(m.EstadoMatricula)) AS EstadoRaw,
        NULLIF(LTRIM(RTRIM(m.Observacion)), N'') AS Observacion,
        NULLIF(LTRIM(RTRIM(m.FechaSolicitud)), N'') AS FechaSolicitudRaw,
        NULLIF(LTRIM(RTRIM(m.FechaRevision)), N'') AS FechaRevisionRaw,
        NULLIF(LTRIM(RTRIM(m.FechaAsignacionVacante)), N'') AS FechaAsignacionRaw,
        NULLIF(LTRIM(RTRIM(m.FechaRegistroSiagie)), N'') AS FechaSiagieRaw
    FROM stg.Matricula AS m
), Catalogos AS (
    SELECT l.*,
        CASE WHEN UPPER(TipoRaw) LIKE N'INGRES%' THEN N'Ingresante'
             WHEN UPPER(TipoRaw) LIKE N'CONTIN%' THEN N'Continuador'
             WHEN UPPER(TipoRaw) LIKE N'REPIT%' THEN N'Repitente'
             WHEN UPPER(TipoRaw) LIKE N'TRASLAD%' THEN N'Traslado'
             ELSE N'No determinado' END AS Tipo,
        CASE WHEN UPPER(ViaRaw) LIKE N'SOLICITUD%' THEN N'Solicitud de vacante'
             WHEN UPPER(ViaRaw) LIKE N'RATIFIC%' THEN N'Ratificacion de continuidad'
             ELSE N'No determinada' END AS ViaOriginal,
        CASE WHEN UPPER(FaseRaw) LIKE N'COMPLEMENT%' THEN N'Complementaria'
             ELSE N'Regular' END AS Fase,
        CASE WHEN UPPER(EstadoRaw) LIKE N'APRO%' THEN N'Aprobado'
             WHEN UPPER(EstadoRaw) LIKE N'RECHAZ%' THEN N'Rechazado'
             ELSE N'No determinado' END AS Estado,
        CASE WHEN LEN(FechaSolicitudRaw) = 8
                  AND FechaSolicitudRaw LIKE N'[0-9][0-9]/[0-9][0-9]/[0-9][0-9]'
                 THEN TRY_CONVERT(DATE, STUFF(FechaSolicitudRaw, 7, 0, N'20'), 103)
             WHEN FechaSolicitudRaw LIKE N'[0-9][0-9]/%' THEN TRY_CONVERT(DATE, FechaSolicitudRaw, 103)
             WHEN FechaSolicitudRaw LIKE N'[0-9][0-9]-%' THEN TRY_CONVERT(DATE, FechaSolicitudRaw, 105)
             ELSE TRY_CONVERT(DATE, FechaSolicitudRaw, 23) END AS FechaSolicitud,
        CASE WHEN LEN(FechaRevisionRaw) = 8
                  AND FechaRevisionRaw LIKE N'[0-9][0-9]/[0-9][0-9]/[0-9][0-9]'
                 THEN TRY_CONVERT(DATE, STUFF(FechaRevisionRaw, 7, 0, N'20'), 103)
             WHEN FechaRevisionRaw LIKE N'[0-9][0-9]/%' THEN TRY_CONVERT(DATE, FechaRevisionRaw, 103)
             WHEN FechaRevisionRaw LIKE N'[0-9][0-9]-%' THEN TRY_CONVERT(DATE, FechaRevisionRaw, 105)
             ELSE TRY_CONVERT(DATE, FechaRevisionRaw, 23) END AS FechaRevision,
        CASE WHEN LEN(FechaAsignacionRaw) = 8
                  AND FechaAsignacionRaw LIKE N'[0-9][0-9]/[0-9][0-9]/[0-9][0-9]'
                 THEN TRY_CONVERT(DATE, STUFF(FechaAsignacionRaw, 7, 0, N'20'), 103)
             WHEN FechaAsignacionRaw LIKE N'[0-9][0-9]/%' THEN TRY_CONVERT(DATE, FechaAsignacionRaw, 103)
             WHEN FechaAsignacionRaw LIKE N'[0-9][0-9]-%' THEN TRY_CONVERT(DATE, FechaAsignacionRaw, 105)
             ELSE TRY_CONVERT(DATE, FechaAsignacionRaw, 23) END AS FechaAsignacion,
        CASE WHEN LEN(FechaSiagieRaw) = 8
                  AND FechaSiagieRaw LIKE N'[0-9][0-9]/[0-9][0-9]/[0-9][0-9]'
                 THEN TRY_CONVERT(DATE, STUFF(FechaSiagieRaw, 7, 0, N'20'), 103)
             WHEN FechaSiagieRaw LIKE N'[0-9][0-9]/%' THEN TRY_CONVERT(DATE, FechaSiagieRaw, 103)
             WHEN FechaSiagieRaw LIKE N'[0-9][0-9]-%' THEN TRY_CONVERT(DATE, FechaSiagieRaw, 105)
             ELSE TRY_CONVERT(DATE, FechaSiagieRaw, 23) END AS FechaSiagie
    FROM Limpio AS l
), Clasificado AS (
    SELECT c.*,
        CASE WHEN c.Tipo IN (N'Continuador', N'Repitente')
                 THEN N'Ratificacion de continuidad'
             WHEN c.Tipo IN (N'Ingresante', N'Traslado')
                 THEN N'Solicitud de vacante'
             ELSE c.ViaOriginal END AS ViaCanonica,
        ROW_NUMBER() OVER (
            PARTITION BY c.AnioEscolar,
                         COALESCE(NULLIF(c.CodigoEstudiante, N''), c.MatriculaID)
            ORDER BY CASE WHEN RIGHT(UPPER(c.MatriculaID), 4) = N'-BIS' THEN 1 ELSE 0 END,
                     c.MatriculaID
        ) AS rn
    FROM Catalogos AS c
)
SELECT * INTO #MatriculaNormalizada FROM Clasificado;

IF NOT EXISTS (SELECT 1 FROM #MatriculaNormalizada)
    THROW 51003, N'Staging de matricula esta vacio: se cancela la recarga.', 1;

/* Auditoria visible: duplicados y estudiantes ausentes del padron.
   Se excluyen del hecho para no inflar vacantes, pero siguen en stg.Matricula. */
SELECT N'Duplicada estudiante-anio' AS Incidencia,
       MatriculaID, AnioEscolar, CodigoEstudiante, SeccionID
FROM #MatriculaNormalizada WHERE rn > 1
UNION ALL
SELECT N'CodigoEstudiante sin padron', b.MatriculaID, b.AnioEscolar,
       b.CodigoEstudiante, b.SeccionID
FROM #MatriculaNormalizada AS b
LEFT JOIN dw.DimEstudiante AS e ON e.CodigoEstudiante = b.CodigoEstudiante
WHERE b.rn = 1 AND e.EstudianteKey IS NULL
ORDER BY Incidencia, MatriculaID;

/* Seccion del anio de origen: conserva su AFORO historico (la dimension
   DimSeccion, al ser de tipo 1, muestra el aforo mas reciente). */
;WITH s AS (
    SELECT
        LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
            NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N''))) AS SeccionID,
        TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))) AS AnioEscolar,
        TRY_CONVERT(TINYINT, LTRIM(RTRIM(Grado))) AS Grado,
        UPPER(LTRIM(RTRIM(Seccion))) AS Seccion,
        TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Aforo))) AS Aforo,
        ROW_NUMBER() OVER (
            PARTITION BY TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))),
                         LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
                             NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))
            ORDER BY FechaCarga DESC
        ) AS rn
    FROM stg.Seccion
)
SELECT SeccionID, AnioEscolar, Grado, Seccion, Aforo
INTO #SeccionAnual FROM s WHERE rn = 1;

/* 2. Resolver todas las dimensiones con LEFT JOIN: si falta una clave,
   detectarla antes de abrir la transaccion de recarga. */
SELECT
    b.MatriculaID, b.AnioEscolar, b.CodigoEstudiante, b.SeccionID,
    b.Tipo, b.ViaOriginal, b.ViaCanonica, b.Estado, b.Observacion,
    b.FechaSolicitudRaw, b.FechaRevisionRaw, b.FechaAsignacionRaw,
    b.FechaSiagieRaw, b.FechaSolicitud, b.FechaRevision,
    b.FechaAsignacion, b.FechaSiagie,
    e.EstudianteKey, ds.SeccionKey, dtm.TipoMatriculaKey, ss.Aforo,
    CASE WHEN b.Estado = N'Aprobado' THEN -1
         WHEN b.Observacion IS NULL THEN -2
         ELSE dm.MotivoKey END AS MotivoKey,
    CASE WHEN b.ViaCanonica = N'Ratificacion de continuidad' THEN -1
         WHEN b.FechaSolicitud IS NULL THEN -2
         ELSE CONVERT(INT, CONVERT(CHAR(8), b.FechaSolicitud, 112))
         END AS FechaSolicitudKey,
    CASE WHEN b.ViaCanonica = N'Ratificacion de continuidad' THEN -1
         WHEN b.FechaRevision IS NULL THEN -2
         ELSE CONVERT(INT, CONVERT(CHAR(8), b.FechaRevision, 112))
         END AS FechaRevisionKey,
    CASE WHEN b.ViaCanonica = N'Ratificacion de continuidad' THEN -1
         WHEN b.FechaAsignacion IS NULL THEN -2
         ELSE CONVERT(INT, CONVERT(CHAR(8), b.FechaAsignacion, 112))
         END AS FechaAsignacionKey,
    CASE WHEN b.Estado = N'Rechazado' OR b.FechaSiagie IS NULL THEN -2
         ELSE CONVERT(INT, CONVERT(CHAR(8), b.FechaSiagie, 112))
         END AS FechaSiagieKey,
    CASE WHEN b.Estado = N'Aprobado'
                   AND b.ViaCanonica = N'Solicitud de vacante'
                   AND b.FechaSolicitud IS NOT NULL
                   AND b.FechaRevision >= b.FechaSolicitud
         THEN DATEDIFF(DAY, b.FechaSolicitud, b.FechaRevision)
         END AS DiasValidacion,
    CASE WHEN b.Estado = N'Aprobado'
                   AND b.ViaCanonica = N'Solicitud de vacante'
                   AND b.FechaSolicitud IS NOT NULL
                   AND b.FechaSiagie >= b.FechaSolicitud
         THEN DATEDIFF(DAY, b.FechaSolicitud, b.FechaSiagie)
         END AS DiasHastaSiagie
INTO #MatriculaPreparada
FROM #MatriculaNormalizada AS b
JOIN dw.DimEstudiante AS e ON e.CodigoEstudiante = b.CodigoEstudiante
LEFT JOIN #SeccionAnual AS ss
    ON ss.SeccionID = b.SeccionID AND ss.AnioEscolar = b.AnioEscolar
LEFT JOIN dw.DimSeccion AS ds
    ON ds.CodigoCorto = CONVERT(NVARCHAR(3), ss.Grado) + ss.Seccion
LEFT JOIN dw.DimTipoMatricula AS dtm
    ON dtm.TipoMatricula = b.Tipo AND dtm.ViaMatricula = b.ViaCanonica
   AND dtm.FaseProceso = b.Fase AND dtm.EstadoMatricula = b.Estado
LEFT JOIN stg.MotivoRechazoCategoria AS mc
    ON mc.Motivo = b.Observacion AND b.Estado = N'Rechazado'
LEFT JOIN dw.DimMotivoRechazo AS dm
    ON dm.Categoria = mc.Categoria
WHERE b.rn = 1;

IF NOT EXISTS (SELECT 1 FROM #MatriculaPreparada)
    THROW 51007, N'Ninguna matricula coincide con DimEstudiante: se cancela la recarga.', 1;

/* Fuente inconsistente: no borrar observaciones, mostrar que se corrigio
   y las duraciones imposibles que quedaron sin medida. */
SELECT MatriculaID, AnioEscolar, CodigoEstudiante, Tipo,
       ViaOriginal, ViaCanonica,
       FechaSolicitudRaw, FechaRevisionRaw, FechaSiagieRaw,
       CASE WHEN ViaOriginal <> ViaCanonica THEN N'Via corregida por tipo'
            WHEN ViaCanonica = N'Ratificacion de continuidad'
                 AND (FechaSolicitudRaw IS NOT NULL OR FechaRevisionRaw IS NOT NULL
                      OR FechaAsignacionRaw IS NOT NULL)
                 THEN N'Fecha informada en tramite no aplicable'
            WHEN FechaSolicitud IS NOT NULL AND FechaSiagie < FechaSolicitud
                 THEN N'SIAGIE anterior a solicitud'
            ELSE N'Fecha requerida ausente o no valida' END AS Incidencia
FROM #MatriculaPreparada
WHERE ViaOriginal <> ViaCanonica
   OR (ViaCanonica = N'Ratificacion de continuidad'
       AND (FechaSolicitudRaw IS NOT NULL OR FechaRevisionRaw IS NOT NULL
            OR FechaAsignacionRaw IS NOT NULL))
   OR (Estado = N'Aprobado' AND FechaSiagieKey = -2)
   OR (ViaCanonica = N'Solicitud de vacante' AND Estado = N'Aprobado'
       AND (FechaSolicitudKey = -2 OR FechaRevisionKey = -2
            OR FechaAsignacionKey = -2
            OR (FechaSolicitud IS NOT NULL AND FechaSiagie < FechaSolicitud)))
ORDER BY MatriculaID;

/* Impedir truncamientos silenciosos y perdida de filas por joins.
   Una fecha -2 es admisible; una fecha fuera de DimTiempo no lo es. */
IF EXISTS (
    SELECT 1 FROM #MatriculaPreparada AS p
    LEFT JOIN dw.DimTiempo AS t1 ON t1.TiempoKey = p.FechaSolicitudKey
    LEFT JOIN dw.DimTiempo AS t2 ON t2.TiempoKey = p.FechaRevisionKey
    LEFT JOIN dw.DimTiempo AS t3 ON t3.TiempoKey = p.FechaAsignacionKey
    LEFT JOIN dw.DimTiempo AS t4 ON t4.TiempoKey = p.FechaSiagieKey
    WHERE p.AnioEscolar IS NULL OR p.MatriculaID IS NULL OR p.MatriculaID = N''
       OR p.SeccionKey IS NULL OR p.TipoMatriculaKey IS NULL
       OR p.MotivoKey IS NULL OR p.Aforo IS NULL OR p.Aforo <= 0
       OR t1.TiempoKey IS NULL OR t2.TiempoKey IS NULL
       OR t3.TiempoKey IS NULL OR t4.TiempoKey IS NULL
       OR p.Estado NOT IN (N'Aprobado', N'Rechazado')
)
BEGIN
    SELECT p.MatriculaID, p.AnioEscolar, p.SeccionID, p.Tipo,
           p.ViaCanonica, p.Estado, p.SeccionKey, p.TipoMatriculaKey,
           p.MotivoKey, p.Aforo, p.FechaSolicitudKey,
           p.FechaRevisionKey, p.FechaAsignacionKey, p.FechaSiagieKey
    FROM #MatriculaPreparada AS p
    LEFT JOIN dw.DimTiempo AS t1 ON t1.TiempoKey = p.FechaSolicitudKey
    LEFT JOIN dw.DimTiempo AS t2 ON t2.TiempoKey = p.FechaRevisionKey
    LEFT JOIN dw.DimTiempo AS t3 ON t3.TiempoKey = p.FechaAsignacionKey
    LEFT JOIN dw.DimTiempo AS t4 ON t4.TiempoKey = p.FechaSiagieKey
    WHERE p.AnioEscolar IS NULL OR p.MatriculaID IS NULL OR p.MatriculaID = N''
       OR p.SeccionKey IS NULL OR p.TipoMatriculaKey IS NULL
       OR p.MotivoKey IS NULL OR p.Aforo IS NULL OR p.Aforo <= 0
       OR t1.TiempoKey IS NULL OR t2.TiempoKey IS NULL
       OR t3.TiempoKey IS NULL OR t4.TiempoKey IS NULL
       OR p.Estado NOT IN (N'Aprobado', N'Rechazado');
    THROW 51004, N'Faltan dimensiones, aforo o fechas en DimTiempo. Revisar staging y volver a ejecutar 03.', 1;
END;

IF EXISTS (SELECT 1 FROM #MatriculaPreparada
           GROUP BY AnioEscolar, EstudianteKey HAVING COUNT(*) > 1)
    THROW 51005, N'El grano estudiante-anio quedo duplicado.', 1;

IF EXISTS (SELECT 1 FROM #MatriculaPreparada
           GROUP BY MatriculaID HAVING COUNT(*) > 1)
    THROW 51006, N'MatriculaID no es unico tras limpieza.', 1;

/* 3. Recarga atomica del unico hecho del datamart. */
BEGIN TRY
    BEGIN TRANSACTION;
    DELETE FROM dm_matricula.FacMatricula;

    INSERT INTO dm_matricula.FacMatricula (
        MatriculaID, AnioEscolar, EstudianteKey, SeccionKey,
        TipoMatriculaKey, MotivoKey, FechaSolicitudKey, FechaRevisionKey,
        FechaAsignacionKey, FechaSiagieKey, AforoSeccionSnapshot,
        MatriculasRegistradas, SolicitudesVacante, MatriculasAprobadas,
        MatriculasRechazadas, VacantesOcupadas, DiasValidacion,
        CasosConValidacion, DiasHastaSiagie, CasosConDiasHastaSiagie,
        ViaCorregida
    )
    SELECT
        p.MatriculaID, p.AnioEscolar, p.EstudianteKey, p.SeccionKey,
        p.TipoMatriculaKey, p.MotivoKey, p.FechaSolicitudKey,
        p.FechaRevisionKey, p.FechaAsignacionKey, p.FechaSiagieKey,
        p.Aforo, 1,
        CASE WHEN p.ViaCanonica = N'Solicitud de vacante' THEN 1 ELSE 0 END,
        CASE WHEN p.Estado = N'Aprobado' THEN 1 ELSE 0 END,
        CASE WHEN p.Estado = N'Rechazado' THEN 1 ELSE 0 END,
        CASE WHEN p.Estado = N'Aprobado' THEN 1 ELSE 0 END,
        p.DiasValidacion,
        CASE WHEN p.DiasValidacion IS NOT NULL THEN 1 ELSE 0 END,
        p.DiasHastaSiagie,
        CASE WHEN p.DiasHastaSiagie IS NOT NULL THEN 1 ELSE 0 END,
        CASE WHEN p.ViaOriginal <> p.ViaCanonica THEN 1 ELSE 0 END
    FROM #MatriculaPreparada AS p;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

/* 4. Controlar totales y aforo. En este lote: 615 en origen; 9 duplicadas,
   6 sin estudiante; 600 en hecho (300 cada anio), 579 aprobadas, 21 rechazadas.
   Las cifras son referencias de ESTE lote, no limites codificados en el ETL. */
SELECT COUNT(*) AS Origen,
       SUM(CASE WHEN rn > 1 THEN 1 ELSE 0 END) AS DuplicadasDescartadas
FROM #MatriculaNormalizada;

SELECT COUNT(*) AS MatriculasSinEstudiante
FROM #MatriculaNormalizada AS b
LEFT JOIN dw.DimEstudiante AS e ON e.CodigoEstudiante = b.CodigoEstudiante
WHERE b.rn = 1 AND e.EstudianteKey IS NULL;

SELECT f.AnioEscolar,
       SUM(f.MatriculasRegistradas) AS Matriculas,
       SUM(f.SolicitudesVacante) AS SolicitudesDeVacante,
       SUM(f.MatriculasAprobadas) AS Aprobadas,
       SUM(f.MatriculasRechazadas) AS Rechazadas,
       SUM(f.VacantesOcupadas) AS VacantesOcupadas,
       SUM(CAST(f.ViaCorregida AS INT)) AS ViasCorregidas,  -- BIT no se puede sumar
       SUM(f.CasosConValidacion) AS CasosConValidacion,
       CAST(SUM(CAST(f.DiasValidacion AS DECIMAL(14,2))) /
            NULLIF(SUM(f.CasosConValidacion), 0) AS DECIMAL(10,2))
           AS PromedioDiasValidacion
FROM dm_matricula.FacMatricula AS f
GROUP BY f.AnioEscolar ORDER BY f.AnioEscolar;

/* El aforo esta repetido en cada matricula del aula: JAMAS SUMAR la columna
   directamente. Agrupar por anio+seccion y tomar MAX antes de sumar. */
;WITH Aulas AS (
    SELECT AnioEscolar, SeccionKey,
           MAX(AforoSeccionSnapshot) AS Aforo,
           SUM(VacantesOcupadas) AS Ocupadas
    FROM dm_matricula.FacMatricula
    GROUP BY AnioEscolar, SeccionKey
)
SELECT AnioEscolar, SUM(Aforo) AS VacantesTotales,
       SUM(Ocupadas) AS VacantesOcupadas,
       SUM(Aforo) - SUM(Ocupadas) AS VacantesLibres,
       CAST(100.0 * SUM(Ocupadas) / NULLIF(SUM(Aforo), 0)
            AS DECIMAL(6,2)) AS PorcentajeOcupacion
FROM Aulas GROUP BY AnioEscolar ORDER BY AnioEscolar;

/* Control de los 4 roles: cada matricula conserva una clave en cada uno. */
SELECT AnioEscolar,
       SUM(CASE WHEN FechaSolicitudKey = -1 THEN 1 ELSE 0 END) AS SolicitudNoAplica,
       SUM(CASE WHEN FechaSolicitudKey = -2 THEN 1 ELSE 0 END) AS SolicitudSinRegistro,
       SUM(CASE WHEN FechaSiagieKey = -2 THEN 1 ELSE 0 END) AS SiagieSinRegistro,
       SUM(CASE WHEN FechaSiagieKey = -2 AND MatriculasAprobadas = 1
                THEN 1 ELSE 0 END) AS SiagieAprobadasConFechaInvalida
FROM dm_matricula.FacMatricula
GROUP BY AnioEscolar ORDER BY AnioEscolar;
GO


SELECT f.AnioEscolar, f.MatriculaID, m.FechaSolicitud AS FechaCruda,
       f.MatriculasRechazadas
FROM dm_matricula.FacMatricula AS f
JOIN stg.Matricula AS m
  ON LTRIM(RTRIM(REPLACE(m.MatriculaID, NCHAR(160), N''))) = f.MatriculaID
WHERE f.FechaSolicitudKey = -2
ORDER BY f.AnioEscolar, f.MatriculaID;