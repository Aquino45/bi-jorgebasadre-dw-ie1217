/* ============================================================================
   06_fac_aprendizajes.sql
   CAMBIOS v6.0 (20/10/2026), segun la matriz de metricas y dimensiones v2.1:
   - El bimestre sale de DimTiempo (fecha oficial de cierre). Sin PeriodoKey:
     DimPeriodoAcademico ya no existe. Grano: estudiante + competencia +
     fecha de cierre del bimestre.
   - DimCompetencia une competencia y nivel de logro: el hecho guarda UNA
     clave, la de la fila «competencia x nivel» que obtuvo la nota (S/E si no
     hay evidencia). Sin EscalaKey: DimEscalaLogro ya no existe.
   - Sin AreaKey: el area se lee en la propia competencia. DimArea solo se usa
     aqui para validar que la competencia pertenezca al area de la fila.
   CAMBIOS RESPECTO A v5.1 (13/10/2026):
   - La validacion "Competencia incompatible con area" compara el AreaID de la
     competencia (DimCompetencia.AreaID) con el AreaID del area de la fila
     (DimArea), en lugar de AreaKey. DimCompetencia ya no tiene AreaKey (v5.2).
     Comparacion binaria: el mismo criterio de D15.
   - Resultado esperado: sin cambio en cifras (87 filas incompatibles); verificar
     con una re-ejecucion.
   Requiere haber ejecutado antes 03_dimensiones.sql.
   ============================================================================ */
/* ============================================================================
   06_fac_aprendizajes.sql — GESTION DE LOS APRENDIZAJES
   CAMBIOS v5.1:
     - Nota VACIA = sin evidencia. BULK INSERT guarda la celda vacia como
       NULL y la v5 solo reconocia '' : esas filas iban a la bitacora como
       'Nota inexistente' en vez de entrar al hecho con SinEvidencia = 1.
     - 'cp-05' ya no cuenta como codigo literal: la comparacion era
       insensible a mayusculas por la intercalacion de la base.
     - Borra sus tablas temporales al iniciar (reejecucion en la ventana).
     - v5.1b: SUM sobre columnas BIT (error 8117) -> CAST a INT.
   Ejecutar DESPUES de 01, 02, 03, 04 y 05 en DW_IE1217 (SQL Server 2017+).

   UN hecho de este datamart. Grano: estudiante + competencia + bimestre
   (el bimestre sale de la fecha de cierre en DimTiempo). Seccion y docente
   describen la evaluacion, pero no forman parte de su identidad.

   Origen de produccion: stg.NotaCompetencia (CSV crudo). El libro Excel es
   material de referencia; no se usa para recuperar notas alteradas en el CSV.

   Politica de calidad:
   * El cierre registrado determina el bimestre; se valida contra dw.
   * CP-O3 -> CP-03, CP 07 -> CP-07, cp-05 -> CP-05; la competencia debe
     pertenecer al area que figura en la fila. CP-99 no se inventa.
   * La letra capturada en vez del numero se traduce al punto medio de SU
     rango (regla de DimCompetencia). La conversion numero -> letra tambien
     se toma exclusivamente de esa dimension.
   * Los decimales validos se redondean al entero superior desde .5
     (ROUND de SQL Server). Nunca se redondea una nota fuera de 0..20.
   * Las competencias realmente sin evidencia SI entran: nota NULL,
     fila S/E de su competencia, EvaluadaConEvidencia=0, SinEvidencia=1.
   * Nota invalida, competencia/area incompatibles o referencias ausentes:
     no se les asigna artificialmente un nivel; quedan en stg.BitacoraNota.
   * Ante copias, se prefiere el CodigoCompetencia literal de catalogo,
     despues el bimestre correcto y despues la ultima FechaCarga. Una
     FechaCarga igual de BULK INSERT no prueba cual fila se modifico primero:
     los conflictos restantes exigen revision en vez de elegir una nota.

   Esta carga sustituye el lote completo de forma transaccional; se puede
   ejecutar de nuevo sin multiplicar hechos. Programarla corresponde al job
   de orquestacion, una vez verificados los seis scripts.
   ============================================================================ */
USE DW_IE1217;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'stg.NotaCompetencia', N'U') IS NULL
   OR OBJECT_ID(N'dw.DimCompetencia', N'U') IS NULL
   OR OBJECT_ID(N'dw.DimTiempo', N'U') IS NULL
   OR OBJECT_ID(N'dm_matricula.FacMatricula', N'U') IS NULL
    THROW 51060, N'Faltan staging, dimensiones o el hecho de matricula (scripts 01, 03 y 04).', 1;
GO

IF SCHEMA_ID(N'dm_aprendizajes') IS NULL
    EXEC(N'CREATE SCHEMA dm_aprendizajes');
GO

IF OBJECT_ID(N'dm_aprendizajes.FacLogroCompetencia', N'U') IS NULL
BEGIN
    CREATE TABLE dm_aprendizajes.FacLogroCompetencia (
        LogroKey               BIGINT IDENTITY(1,1) NOT NULL,
        AnioEscolar            SMALLINT NOT NULL,
        FechaCierreKey         INT NOT NULL,
        EstudianteKey          INT NOT NULL,
        SeccionKey             INT NOT NULL,
        DocenteKey             INT NOT NULL,
        CompetenciaKey         INT NOT NULL,   -- fila competencia x nivel de logro
        NotaVigesimal          DECIMAL(5,2) NULL,
        CompetenciasRegistradas TINYINT NOT NULL,
        EvaluadaConEvidencia   TINYINT NOT NULL,
        SinEvidencia           TINYINT NOT NULL,
        EnInicioC              TINYINT NOT NULL,
        EnProcesoB             TINYINT NOT NULL,
        LogroEsperadoA         TINYINT NOT NULL,
        LogroDestacadoAD       TINYINT NOT NULL,
        CompetenciaAprobada    TINYINT NOT NULL,
        BimestreCorregido      BIT NOT NULL,
        CompetenciaCorregida   BIT NOT NULL,
        DocenteCorregido       BIT NOT NULL,
        NotaDesdeLetra         BIT NOT NULL,
        NotaRedondeada         BIT NOT NULL,
        FechaCargaDW           DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT PK_FacLogroCompetencia PRIMARY KEY CLUSTERED (LogroKey),
        CONSTRAINT UQ_FacLogroCompetencia_Grano UNIQUE
            (FechaCierreKey, EstudianteKey, CompetenciaKey),
        CONSTRAINT FK_FacLogro_Fecha FOREIGN KEY (FechaCierreKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT FK_FacLogro_Estudiante FOREIGN KEY (EstudianteKey)
            REFERENCES dw.DimEstudiante(EstudianteKey),
        CONSTRAINT FK_FacLogro_Seccion FOREIGN KEY (SeccionKey)
            REFERENCES dw.DimSeccion(SeccionKey),
        CONSTRAINT FK_FacLogro_Docente FOREIGN KEY (DocenteKey)
            REFERENCES dw.DimDocente(DocenteKey),
        CONSTRAINT FK_FacLogro_Competencia FOREIGN KEY (CompetenciaKey)
            REFERENCES dw.DimCompetencia(CompetenciaKey),
        CONSTRAINT CK_FacLogro_Consistencia CHECK (
            CompetenciasRegistradas = 1
            AND EvaluadaConEvidencia IN (0, 1) AND SinEvidencia IN (0, 1)
            AND EvaluadaConEvidencia + SinEvidencia = 1
            AND EnInicioC IN (0, 1) AND EnProcesoB IN (0, 1)
            AND LogroEsperadoA IN (0, 1) AND LogroDestacadoAD IN (0, 1)
            AND CompetenciaAprobada IN (0, 1)
            AND EnInicioC + EnProcesoB + LogroEsperadoA + LogroDestacadoAD
                = EvaluadaConEvidencia
            AND CompetenciaAprobada = EnProcesoB + LogroEsperadoA + LogroDestacadoAD
            AND ((SinEvidencia = 1 AND NotaVigesimal IS NULL)
                 OR (EvaluadaConEvidencia = 1 AND NotaVigesimal BETWEEN 0 AND 20))
        )
    );
END;
GO

/* Registro auditable de filas que no se publican, incluidos los duplicados.
   Es una tabla STAGING de incidencias, NO una segunda tabla de hechos. */
IF OBJECT_ID(N'stg.BitacoraNota', N'U') IS NULL
BEGIN
    CREATE TABLE stg.BitacoraNota (
        IncidenciaKey BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        Motivo NVARCHAR(80) NOT NULL,
        Anio NVARCHAR(10) NULL, Bimestre NVARCHAR(10) NULL,
        CodigoEstudiante NVARCHAR(20) NULL, SeccionID NVARCHAR(30) NULL,
        AreaID NVARCHAR(20) NULL, CompetenciaID NVARCHAR(20) NULL,
        DocenteID NVARCHAR(20) NULL, NotaVigesimal NVARCHAR(120) NULL,
        FechaCierreBimestre NVARCHAR(30) NULL,
        FechaRegistroDW DATETIME2 NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

/* Las tablas #temporales viven mientras la ventana de SSMS siga abierta. */
DROP TABLE IF EXISTS #Asignacion;
DROP TABLE IF EXISTS #OrigenNormalizado;
DROP TABLE IF EXISTS #Vinculada;
DROP TABLE IF EXISTS #Transformada;
DROP TABLE IF EXISTS #Clasificada;
DROP TABLE IF EXISTS #Conflictos;
DROP TABLE IF EXISTS #Ordenadas;
DROP TABLE IF EXISTS #Escala;

/* Regla nota -> nivel: se toma de DimCompetencia (una sola regla para todas
   las competencias). Si dos competencias tuvieran rangos distintos para el
   mismo nivel, la carga se detiene. */
SELECT DISTINCT NivelLogro, NotaDesde, NotaHasta, OrdenNivel
INTO #Escala
FROM dw.DimCompetencia
WHERE CompetenciaKey > 0 AND OrdenNivel > 0;
IF EXISTS (SELECT 1 FROM #Escala GROUP BY NivelLogro HAVING COUNT(*) > 1)
    THROW 51063, N'Rangos distintos para un mismo nivel en DimCompetencia; se cancela la carga.', 1;

/* Asignacion oficial: la clave de docente del hecho se obtiene del horario
   del area y seccion, no de un identificador mal escrito en una nota. */
SELECT TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))) AS AnioEscolar,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(SeccionID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS SeccionID,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(AreaID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS AreaID,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(DocenteID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS DocenteID
INTO #Asignacion FROM stg.CargaHoraria;

IF NOT EXISTS (SELECT 1 FROM stg.NotaCompetencia)
    THROW 51061, N'No hay notas en stg.NotaCompetencia; se conserva el hecho anterior.', 1;
IF EXISTS (SELECT 1 FROM #Asignacion
           GROUP BY AnioEscolar, SeccionID, AreaID HAVING COUNT(*) > 1)
    THROW 51062, N'Hay asignaciones multiples de docente para una seccion/area/anio.', 1;

/* Transformar texto, SIN recurrir al libro de Excel. */
SELECT n.Anio, n.Bimestre, n.CodigoEstudiante, n.SeccionID,
       n.AreaID, n.CompetenciaID, n.DocenteID, n.NotaVigesimal,
       n.FechaCierreBimestre, n.FechaCarga,
       TRY_CONVERT(SMALLINT, LTRIM(RTRIM(n.Anio))) AS AnioEscolar,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(n.CodigoEstudiante,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS EstudianteIDLimpio,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(n.SeccionID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS SeccionIDLimpia,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(n.AreaID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS AreaIDLimpia,
       REPLACE(REPLACE(UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(
           n.CompetenciaID, NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))),
           N' ', N'-'), N'CP-O', N'CP-0') AS CompetenciaIDLimpia,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(n.DocenteID,
           NCHAR(160), N''), NCHAR(9), N''), NCHAR(13), N'')))) AS DocenteIDLimpio,
       UPPER(LTRIM(RTRIM(REPLACE(REPLACE(n.NotaVigesimal,
           NCHAR(160), N' '), NCHAR(9), N' ')))) AS NotaTexto,
       TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(n.FechaCierreBimestre)), N''), 23)
           AS FechaCierre
INTO #OrigenNormalizado
FROM stg.NotaCompetencia AS n;

/* La fecha de cierre y el catalogo identifican el periodo. El bimestre del
   archivo se usa para medir la correccion y decidir entre copias. */
SELECT o.*,
       t.Bimestre AS BimestreReal,
       t.TiempoKey AS FechaCierreKey,
       e.EstudianteKey, s.SeccionKey, a.AreaKey, a.AreaID AS AreaIDDeArea,
       c.CompetenciaKey, c.AreaID AS AreaIDDeCompetencia,
       d.DocenteKey, asg.DocenteID AS DocenteAsignado,
       m.MatriculaKey,
       TRY_CONVERT(DECIMAL(6,3), REPLACE(o.NotaTexto, N',', N'.')) AS NotaNumerica,
       el.OrdenNivel AS EscalaDeLetra,
       el.NotaDesde AS InicioLetra, el.NotaHasta AS FinLetra,
       CASE WHEN o.NotaTexto IS NULL OR o.NotaTexto = N''
                      OR o.NotaTexto LIKE N'NO SE %'
                      OR o.NotaTexto = N'SIN EVIDENCIA'
            THEN 1 ELSE 0 END AS EsSinEvidencia,
       /* Comparacion BINARIA: con la intercalacion normal (CI) 'cp-05' y
          'CP-05' son iguales y la minuscula pasaba como codigo literal. */
       CASE WHEN LTRIM(RTRIM(o.CompetenciaID)) COLLATE Latin1_General_BIN2
                 = o.CompetenciaIDLimpia COLLATE Latin1_General_BIN2
            THEN 1 ELSE 0 END AS PrioridadCompetencia,
       CASE WHEN TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM(o.Bimestre)), N''))
                           = t.Bimestre
            THEN 1 ELSE 0 END AS PrioridadBimestre
INTO #Vinculada
FROM #OrigenNormalizado AS o
LEFT JOIN dw.DimTiempo AS t
    ON t.Fecha = o.FechaCierre AND t.AnioEscolar = o.AnioEscolar
       AND t.EsCierreBimestre = 1
LEFT JOIN dw.DimEstudiante AS e
    ON e.CodigoEstudiante = o.EstudianteIDLimpio AND e.EstudianteKey <> -1
LEFT JOIN stg.Seccion AS sec
    ON TRY_CONVERT(SMALLINT, sec.Anio) = o.AnioEscolar
       AND UPPER(LTRIM(RTRIM(sec.SeccionID))) = o.SeccionIDLimpia
LEFT JOIN dw.DimSeccion AS s
    ON s.CodigoCorto = CONVERT(NVARCHAR(3), TRY_CONVERT(TINYINT, sec.Grado))
                     + UPPER(LTRIM(RTRIM(sec.Seccion)))
LEFT JOIN dw.DimArea AS a ON a.AreaID = o.AreaIDLimpia AND a.AreaKey <> -1
LEFT JOIN dw.DimCompetencia AS c
    ON c.CompetenciaID = o.CompetenciaIDLimpia AND c.NivelLogro = N'S/E'
       AND c.CompetenciaKey <> -1
LEFT JOIN #Asignacion AS asg
    ON asg.AnioEscolar = o.AnioEscolar AND asg.SeccionID = o.SeccionIDLimpia
       AND asg.AreaID = o.AreaIDLimpia
LEFT JOIN dw.DimDocente AS d ON d.DocenteID = asg.DocenteID
    AND d.DocenteKey <> -1
LEFT JOIN #Escala AS el
    ON el.NivelLogro = o.NotaTexto
LEFT JOIN dm_matricula.FacMatricula AS m
    ON m.AnioEscolar = o.AnioEscolar AND m.EstudianteKey = e.EstudianteKey
       AND m.SeccionKey = s.SeccionKey AND m.MatriculasAprobadas = 1;

/* Decimales -> entero por regla documentada; letra -> punto medio del
   intervalo vigente. Las notas fuera de escala siguen fuera, sin recorte. */
SELECT v.*,
       CASE WHEN v.EsSinEvidencia = 1 THEN CAST(NULL AS DECIMAL(5,2))
            WHEN v.EscalaDeLetra IS NOT NULL
                THEN CAST((CONVERT(DECIMAL(5,2), v.InicioLetra)
                           + v.FinLetra) / 2.0 AS DECIMAL(5,2))
            WHEN v.NotaNumerica BETWEEN 0 AND 20
                THEN CAST(ROUND(v.NotaNumerica, 0) AS DECIMAL(5,2))
            ELSE CAST(NULL AS DECIMAL(5,2)) END AS NotaFinal
INTO #Transformada FROM #Vinculada AS v;

/* Un codigo de competencia que pertenece a otra area NO es una evaluacion
   de esa competencia. Tampoco se imputa una nota textual irreconocible. */
SELECT x.*,
       escala.OrdenNivel AS EscalaFinalKey,
       cf.CompetenciaKey AS CompetenciaFinalKey,
       CASE WHEN x.FechaCierreKey IS NULL
                      OR x.AnioEscolar IS NULL
                      THEN N'Periodo o fecha de cierre desconocidos'
            WHEN x.EstudianteKey IS NULL THEN N'Estudiante fuera del padron'
            WHEN x.SeccionKey IS NULL THEN N'Seccion anual desconocida'
            WHEN x.AreaKey IS NULL THEN N'Area desconocida'
            WHEN x.CompetenciaKey IS NULL THEN N'Competencia desconocida'
            WHEN x.AreaIDDeCompetencia COLLATE Latin1_General_BIN
                 <> x.AreaIDDeArea COLLATE Latin1_General_BIN
                 THEN N'Competencia incompatible con area'
            WHEN x.DocenteKey IS NULL THEN N'Sin asignacion docente'
            WHEN x.MatriculaKey IS NULL THEN N'Sin matricula aprobada en seccion'
            WHEN x.EsSinEvidencia = 0 AND x.NotaFinal IS NULL
                 THEN N'Nota inexistente o fuera de rango'
            WHEN x.EsSinEvidencia = 0 AND escala.OrdenNivel IS NULL
                 THEN N'Nota sin equivalencia en la escala de logro'
            ELSE CAST(NULL AS NVARCHAR(80)) END AS MotivoRechazo
INTO #Clasificada
FROM #Transformada AS x
LEFT JOIN #Escala AS escala
    ON x.NotaFinal >= escala.NotaDesde
       AND x.NotaFinal < CONVERT(DECIMAL(5,2), escala.NotaHasta) + 1
LEFT JOIN dw.DimCompetencia AS cf
    ON cf.CompetenciaID = x.CompetenciaIDLimpia AND cf.CompetenciaKey <> -1
   AND cf.NivelLogro = CASE WHEN x.EsSinEvidencia = 1 THEN N'S/E' ELSE escala.NivelLogro END;

/* Una configuracion solapada de escala o una seccion anual repetida no debe
   multiplicar ni seleccionar evaluaciones arbitrariamente. */
IF EXISTS (SELECT 1 FROM #Escala a JOIN #Escala b
           ON a.OrdenNivel < b.OrdenNivel
           AND a.NotaDesde <= b.NotaHasta AND b.NotaDesde <= a.NotaHasta)
    THROW 51063, N'Rangos solapados en la escala de logro; se cancela la carga.', 1;
IF EXISTS (SELECT 1 FROM #Clasificada WHERE MotivoRechazo IS NULL AND CompetenciaFinalKey IS NULL)
    THROW 51067, N'Una nota valida no encontro su fila competencia x nivel en DimCompetencia.', 1;
IF (SELECT COUNT(*) FROM #Clasificada) <> (SELECT COUNT(*) FROM stg.NotaCompetencia)
    THROW 51064, N'Un JOIN multiplico las notas; revisar catalogos y secciones.', 1;

/* Si varias notas del mismo grano tienen igual prioridad y FechaCarga,
   el archivo carece de version confiable: informar y detenerse. */
;WITH r AS (
    SELECT c.*,
           DENSE_RANK() OVER (
               PARTITION BY FechaCierreKey, EstudianteKey, CompetenciaKey
               ORDER BY PrioridadCompetencia DESC, PrioridadBimestre DESC,
                        FechaCarga DESC) AS Prioridad
    FROM #Clasificada AS c WHERE MotivoRechazo IS NULL
)
SELECT FechaCierreKey, EstudianteKey, CompetenciaKey,
       COUNT(DISTINCT ISNULL(CONVERT(NVARCHAR(30), NotaFinal), N'S/E')) AS NotasDistintas
INTO #Conflictos
FROM r WHERE Prioridad = 1
GROUP BY FechaCierreKey, EstudianteKey, CompetenciaKey
HAVING COUNT(DISTINCT ISNULL(CONVERT(NVARCHAR(30), NotaFinal), N'S/E')) > 1;

IF EXISTS (SELECT 1 FROM #Conflictos)
BEGIN
    SELECT * FROM #Conflictos ORDER BY FechaCierreKey, EstudianteKey, CompetenciaKey;
    THROW 51065, N'Notas distintas con igual prioridad; revisar duplicados antes de cargar.', 1;
END;

SELECT c.*,
       ROW_NUMBER() OVER (
           PARTITION BY FechaCierreKey, EstudianteKey, CompetenciaKey
           ORDER BY PrioridadCompetencia DESC, PrioridadBimestre DESC,
                    FechaCarga DESC, NotaTexto DESC, AreaID DESC) AS rn
INTO #Ordenadas
FROM #Clasificada AS c WHERE MotivoRechazo IS NULL;

BEGIN TRY
    BEGIN TRANSACTION;
    DELETE FROM dm_aprendizajes.FacLogroCompetencia;
    DELETE FROM stg.BitacoraNota;

    INSERT INTO stg.BitacoraNota
        (Motivo, Anio, Bimestre, CodigoEstudiante, SeccionID, AreaID,
         CompetenciaID, DocenteID, NotaVigesimal, FechaCierreBimestre)
    SELECT MotivoRechazo, Anio, Bimestre, CodigoEstudiante, SeccionID, AreaID,
           CompetenciaID, DocenteID, NotaVigesimal, FechaCierreBimestre
    FROM #Clasificada WHERE MotivoRechazo IS NOT NULL;

    INSERT INTO stg.BitacoraNota
        (Motivo, Anio, Bimestre, CodigoEstudiante, SeccionID, AreaID,
         CompetenciaID, DocenteID, NotaVigesimal, FechaCierreBimestre)
    SELECT N'Duplicado en el grano', Anio, Bimestre, CodigoEstudiante,
           SeccionID, AreaID, CompetenciaID, DocenteID, NotaVigesimal,
           FechaCierreBimestre
    FROM #Ordenadas WHERE rn > 1;

    INSERT INTO dm_aprendizajes.FacLogroCompetencia
        (AnioEscolar, FechaCierreKey, EstudianteKey,
         SeccionKey, DocenteKey, CompetenciaKey,
         NotaVigesimal, CompetenciasRegistradas, EvaluadaConEvidencia,
         SinEvidencia, EnInicioC, EnProcesoB, LogroEsperadoA,
         LogroDestacadoAD, CompetenciaAprobada, BimestreCorregido,
         CompetenciaCorregida, DocenteCorregido, NotaDesdeLetra,
         NotaRedondeada)
    SELECT AnioEscolar, FechaCierreKey, EstudianteKey,
           SeccionKey, DocenteKey, CompetenciaFinalKey,
           NotaFinal, 1, 1 - EsSinEvidencia, EsSinEvidencia,
           CASE WHEN EscalaFinalKey = 1 THEN 1 ELSE 0 END,
           CASE WHEN EscalaFinalKey = 2 THEN 1 ELSE 0 END,
           CASE WHEN EscalaFinalKey = 3 THEN 1 ELSE 0 END,
           CASE WHEN EscalaFinalKey = 4 THEN 1 ELSE 0 END,
           CASE WHEN EscalaFinalKey IN (2, 3, 4) THEN 1 ELSE 0 END,
           CASE WHEN PrioridadBimestre = 0 THEN 1 ELSE 0 END,
           CASE WHEN PrioridadCompetencia = 0 THEN 1 ELSE 0 END,
           CASE WHEN DocenteAsignado <> DocenteIDLimpio THEN 1 ELSE 0 END,
           CASE WHEN EscalaDeLetra IS NOT NULL THEN 1 ELSE 0 END,
           CASE WHEN NotaNumerica BETWEEN 0 AND 20
                     AND NotaNumerica <> ROUND(NotaNumerica, 0)
                THEN 1 ELSE 0 END
    FROM #Ordenadas WHERE rn = 1;

    IF (SELECT COUNT(*) FROM stg.NotaCompetencia) <>
       (SELECT COUNT(*) FROM dm_aprendizajes.FacLogroCompetencia)
       + (SELECT COUNT(*) FROM stg.BitacoraNota)
        THROW 51066, N'No cuadran origen, hecho e incidencias; se revierte la carga.', 1;

    /* Grano: una sola nota por estudiante + competencia + bimestre, aunque la
       competencia tenga cinco filas (una por nivel) en la dimension. */
    IF EXISTS (SELECT 1 FROM dm_aprendizajes.FacLogroCompetencia f
               JOIN dw.DimCompetencia c ON c.CompetenciaKey = f.CompetenciaKey
               GROUP BY f.FechaCierreKey, f.EstudianteKey, c.CompetenciaID
               HAVING COUNT(*) > 1)
        THROW 51068, N'Dos notas para el mismo estudiante, competencia y bimestre; se revierte la carga.', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

/* Controles de salida: el lote actual contiene 45 396 filas de entrada.
   Los conteos de salida se calculan; NO se obligan a coincidir con el Excel
   limpio porque el CSV contiene valores borrados que aquel aun conserva. */
SELECT (SELECT COUNT(*) FROM stg.NotaCompetencia) AS FilasOrigen,
       (SELECT COUNT(*) FROM dm_aprendizajes.FacLogroCompetencia) AS FilasHecho,
       (SELECT COUNT(*) FROM stg.BitacoraNota) AS FilasIncidencia;

SELECT Motivo, COUNT(*) AS Filas
FROM stg.BitacoraNota GROUP BY Motivo ORDER BY Filas DESC, Motivo;

SELECT t.Anio AS AnioEscolar, t.Bimestre, COUNT(*) AS CompetenciasRegistradas,
       SUM(f.EvaluadaConEvidencia) AS Evaluadas,
       SUM(f.SinEvidencia) AS SinEvidencia,
       SUM(CAST(f.NotaDesdeLetra AS INT)) AS LetrasConvertidas,  -- BIT no se suma
       SUM(CAST(f.NotaRedondeada AS INT)) AS NotasRedondeadas,
       AVG(f.NotaVigesimal) AS PromedioCompetencias
FROM dm_aprendizajes.FacLogroCompetencia AS f
JOIN dw.DimTiempo AS t ON t.TiempoKey = f.FechaCierreKey
GROUP BY t.Anio, t.Bimestre ORDER BY t.Anio, t.Bimestre;

/* Ejemplo del KPI de personas: DISTINCTCOUNT, NO suma de filas de competencias.
   Aqui 'estudiante con bajo rendimiento' = al menos una competencia con nota
   menor a 11 en el periodo; el filtro de area/seccion puede aplicarse igual. */
SELECT t.Anio AS AnioEscolar, t.Bimestre,
       COUNT(DISTINCT CASE WHEN f.EvaluadaConEvidencia = 1
                           THEN f.EstudianteKey END) AS EstudiantesEvaluados,
       COUNT(DISTINCT CASE WHEN f.NotaVigesimal < 11
                           THEN f.EstudianteKey END) AS EstudiantesConAlMenosUnaBaja
FROM dm_aprendizajes.FacLogroCompetencia AS f
JOIN dw.DimTiempo AS t ON t.TiempoKey = f.FechaCierreKey
GROUP BY t.Anio, t.Bimestre ORDER BY t.Anio, t.Bimestre;
GO

SELECT CompetenciaID, Bimestre, NotaVigesimal
FROM stg.BitacoraNota
WHERE Motivo = N'Duplicado en el grano'
  AND CompetenciaID COLLATE Latin1_General_BIN2 NOT LIKE N'CP-[0-9][0-9]';

SELECT s.name AS Esquema, t.name AS Tabla, SUM(p.rows) AS Filas
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE s.name IN ('dw', 'dm_matricula', 'dm_preparacion', 'dm_aprendizajes')
GROUP BY s.name, t.name
ORDER BY s.name, t.name;