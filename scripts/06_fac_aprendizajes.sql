/* ============================================================================
   06_fac_aprendizajes.sql
   CAMBIOS v6.5 (25/10/2026): la competencia se busca en dw.DimCurso (fila de
   la competencia, con su curso) y la seccion en dw.DimNivelAcademico.
   CompetenciaKey pasa a CursoKey. El curso de la fila se valida contra la
   fila «Todo el curso» de DimCurso.
   CAMBIOS v6.4 (25/10/2026): la matriz cambia «Competencias sin evidencia»
   por «Notas con evidencia» (base del rendimiento promedio = suma de notas /
   notas con evidencia). CompetenciasSinEvidencia pasa a NotasConEvidencia
   (1 si la competencia tiene nota). Una competencia sin evidencia sigue en
   el hecho con nota NULL y 0 en NotasConEvidencia: nunca cuenta como nota 0.
   CAMBIOS v6.2 (20/10/2026): el hecho guarda SOLO las medidas que la matriz
   v2.1 marca «Script SQL»: la nota (su suma es la «suma de notas obtenidas»)
   y CompetenciasSinEvidencia. Salen los contadores de competencias
   registradas y evaluadas (en Power BI: COUNTROWS y COUNT de la nota), las
   marcas de correccion y el anio (sale de FechaCierreKey). Las correcciones
   se siguen contando aqui y se muestran como control al final.
   CAMBIOS v6.1 (20/10/2026), matriz v2.1 corregida por el equipo:
   - DimCompetencia vuelve a una fila por competencia: el hecho guarda la
     clave de la competencia evaluada. El nivel de logro sale del modelo y
     del hecho (sin conteos C/B/A/AD ni CompetenciaAprobada): las preguntas
     de la Matriz BI usan la nota de 0 a 20 y el umbral de 11.
   - La escala C/B/A/AD queda SOLO como regla de este script, para traducir
     a numero las notas que el CSV trae escritas en letra (148 en el lote).
   - El periodo se toma de DimTiempo sin la marca EsCierreBimestre: la fecha
     informada debe caer dentro de un bimestre, y FechaCierreKey es el ultimo
     dia de ese bimestre (la fecha oficial de cierre).
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
     rango en la escala del MINEDU (#Escala, fija en este script).
   * Los decimales validos se redondean al entero superior desde .5
     (ROUND de SQL Server). Nunca se redondea una nota fuera de 0..20.
   * Las competencias realmente sin evidencia SI entran: nota NULL,
     NotasConEvidencia = 0 (nunca nota 0).
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
   OR OBJECT_ID(N'dw.DimCurso', N'U') IS NULL
   OR OBJECT_ID(N'dw.DimTiempo', N'U') IS NULL
   OR OBJECT_ID(N'dm_matricula.FacMatricula', N'U') IS NULL
    THROW 51060, N'Faltan staging, dimensiones o el hecho de matricula (scripts 01, 03 y 04).', 1;
GO

IF SCHEMA_ID(N'dm_aprendizajes') IS NULL
    EXEC(N'CREATE SCHEMA dm_aprendizajes');
GO

/* v6.2: si el hecho tiene la estructura anterior, se elimina y se crea de
   nuevo; se recarga completo mas abajo. */
IF COL_LENGTH(N'dm_aprendizajes.FacLogroCompetencia', N'EvaluadaConEvidencia') IS NOT NULL
   OR COL_LENGTH(N'dm_aprendizajes.FacLogroCompetencia', N'CompetenciaKey') IS NOT NULL
   OR COL_LENGTH(N'dm_aprendizajes.FacLogroCompetencia', N'CompetenciasSinEvidencia') IS NOT NULL
    DROP TABLE dm_aprendizajes.FacLogroCompetencia;

IF OBJECT_ID(N'dm_aprendizajes.FacLogroCompetencia', N'U') IS NULL
BEGIN
    CREATE TABLE dm_aprendizajes.FacLogroCompetencia (
        LogroKey                 BIGINT IDENTITY(1,1) NOT NULL,
        FechaCierreKey           INT NOT NULL,   -- cierre oficial del bimestre
        EstudianteKey            INT NOT NULL,
        NivelAcademicoKey               INT NOT NULL,
        DocenteKey               INT NOT NULL,
        CursoKey                 INT NOT NULL,   -- fila de la competencia evaluada en DimCurso
        /* Medidas de la matriz v2.1 marcadas «Script SQL». */
        NotaVigesimal            DECIMAL(5,2) NULL,  -- 0 a 20; NULL = sin evidencia, nunca 0
        NotasConEvidencia        TINYINT NOT NULL,   -- 1 si la competencia tiene nota (0 = sin evidencia)
        CONSTRAINT PK_FacLogroCompetencia PRIMARY KEY CLUSTERED (LogroKey),
        CONSTRAINT UQ_FacLogroCompetencia_Grano UNIQUE
            (FechaCierreKey, EstudianteKey, CursoKey),
        CONSTRAINT FK_FacLogro_Fecha FOREIGN KEY (FechaCierreKey)
            REFERENCES dw.DimTiempo(TiempoKey),
        CONSTRAINT FK_FacLogro_Estudiante FOREIGN KEY (EstudianteKey)
            REFERENCES dw.DimEstudiante(EstudianteKey),
        CONSTRAINT FK_FacLogro_Nivel FOREIGN KEY (NivelAcademicoKey)
            REFERENCES dw.DimNivelAcademico(NivelAcademicoKey),
        CONSTRAINT FK_FacLogro_Docente FOREIGN KEY (DocenteKey)
            REFERENCES dw.DimDocente(DocenteKey),
        CONSTRAINT FK_FacLogro_Curso FOREIGN KEY (CursoKey)
            REFERENCES dw.DimCurso(CursoKey),
        CONSTRAINT CK_FacLogro_Consistencia CHECK (
            (NotasConEvidencia = 0 AND NotaVigesimal IS NULL)
            OR (NotasConEvidencia = 1 AND NotaVigesimal BETWEEN 0 AND 20)
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
DROP TABLE IF EXISTS #FinBimestre;

/* Escala oficial del MINEDU (secundaria). NO es una dimension: solo sirve
   para traducir a numero la letra que algunas filas del CSV traen en lugar
   de la nota (C -> 5, B -> 12, A -> 15.5, AD -> 19: punto medio del rango). */
SELECT * INTO #Escala FROM (VALUES
    (N'C', 0, 10), (N'B', 11, 13), (N'A', 14, 17), (N'AD', 18, 20)
) AS v(NivelLogro, NotaDesde, NotaHasta);

/* Ultimo dia de cada bimestre academico = su fecha oficial de cierre
   (en un bimestre aun abierto, el ultimo dia del calendario cargado). */
SELECT Anio, Bimestre, MAX(TiempoKey) AS FechaCierreKey
INTO #FinBimestre
FROM dw.DimTiempo
WHERE TiempoKey > 0 AND Bimestre > 0
GROUP BY Anio, Bimestre;

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
       fb.FechaCierreKey,
       t.TiempoKey AS FechaInformadaKey,
       e.EstudianteKey, s.NivelAcademicoKey, a.CursoKey AS AreaKey, a.CursoID AS AreaIDDeArea,
       c.CursoKey, c.CursoID AS AreaIDDeCompetencia,
       d.DocenteKey, asg.DocenteID AS DocenteAsignado,
       m.MatriculaKey,
       TRY_CONVERT(DECIMAL(6,3), REPLACE(o.NotaTexto, N',', N'.')) AS NotaNumerica,
       el.NivelLogro AS LetraCapturada,
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
    ON t.Fecha = o.FechaCierre AND t.Anio = o.AnioEscolar AND t.Bimestre > 0
LEFT JOIN #FinBimestre AS fb
    ON fb.Anio = t.Anio AND fb.Bimestre = t.Bimestre
LEFT JOIN dw.DimEstudiante AS e
    ON e.CodigoEstudiante = o.EstudianteIDLimpio AND e.EstudianteKey <> -1
LEFT JOIN stg.Seccion AS sec
    ON TRY_CONVERT(SMALLINT, sec.Anio) = o.AnioEscolar
       AND UPPER(LTRIM(RTRIM(sec.SeccionID))) = o.SeccionIDLimpia
LEFT JOIN dw.DimNivelAcademico AS s
    ON s.CodigoCorto = CONVERT(NVARCHAR(3), TRY_CONVERT(TINYINT, sec.Grado))
                     + UPPER(LTRIM(RTRIM(sec.Seccion)))
LEFT JOIN dw.DimCurso AS a
    ON a.CursoID = o.AreaIDLimpia AND a.CompetenciaID = N'N/A' AND a.CursoKey <> -1
LEFT JOIN dw.DimCurso AS c
    ON c.CompetenciaID = o.CompetenciaIDLimpia AND c.CompetenciaID <> N'N/A'
   AND c.CursoKey <> -1
LEFT JOIN #Asignacion AS asg
    ON asg.AnioEscolar = o.AnioEscolar AND asg.SeccionID = o.SeccionIDLimpia
       AND asg.AreaID = o.AreaIDLimpia
LEFT JOIN dw.DimDocente AS d ON d.DocenteID = asg.DocenteID
    AND d.DocenteKey <> -1
LEFT JOIN #Escala AS el
    ON el.NivelLogro = o.NotaTexto
LEFT JOIN dm_matricula.FacMatricula AS m
    ON m.AnioEscolar = o.AnioEscolar AND m.EstudianteKey = e.EstudianteKey
       AND m.NivelAcademicoKey = s.NivelAcademicoKey AND m.MatriculasValidadas = 1;

/* Decimales -> entero por regla documentada; letra -> punto medio del
   intervalo vigente. Las notas fuera de escala siguen fuera, sin recorte. */
SELECT v.*,
       CASE WHEN v.EsSinEvidencia = 1 THEN CAST(NULL AS DECIMAL(5,2))
            WHEN v.LetraCapturada IS NOT NULL
                THEN CAST((CONVERT(DECIMAL(5,2), v.InicioLetra)
                           + v.FinLetra) / 2.0 AS DECIMAL(5,2))
            WHEN v.NotaNumerica BETWEEN 0 AND 20
                THEN CAST(ROUND(v.NotaNumerica, 0) AS DECIMAL(5,2))
            ELSE CAST(NULL AS DECIMAL(5,2)) END AS NotaFinal
INTO #Transformada FROM #Vinculada AS v;

/* Un codigo de competencia que pertenece a otra area NO es una evaluacion
   de esa competencia. Tampoco se imputa una nota textual irreconocible. */
SELECT x.*,
       CASE WHEN x.FechaCierreKey IS NULL
                      OR x.AnioEscolar IS NULL
                      THEN N'Periodo o fecha de cierre desconocidos'
            WHEN x.EstudianteKey IS NULL THEN N'Estudiante fuera del padron'
            WHEN x.NivelAcademicoKey IS NULL THEN N'Seccion anual desconocida'
            WHEN x.AreaKey IS NULL THEN N'Area desconocida'
            WHEN x.CursoKey IS NULL THEN N'Competencia desconocida'
            WHEN x.AreaIDDeCompetencia COLLATE Latin1_General_BIN
                 <> x.AreaIDDeArea COLLATE Latin1_General_BIN
                 THEN N'Competencia incompatible con area'
            WHEN x.DocenteKey IS NULL THEN N'Sin asignacion docente'
            WHEN x.MatriculaKey IS NULL THEN N'Sin matricula aprobada en seccion'
            WHEN x.EsSinEvidencia = 0 AND x.NotaFinal IS NULL
                 THEN N'Nota inexistente o fuera de rango'
            ELSE CAST(NULL AS NVARCHAR(80)) END AS MotivoRechazo
INTO #Clasificada
FROM #Transformada AS x;

/* Una seccion anual repetida no debe multiplicar evaluaciones. */
IF (SELECT COUNT(*) FROM #Clasificada) <> (SELECT COUNT(*) FROM stg.NotaCompetencia)
    THROW 51064, N'Un JOIN multiplico las notas; revisar catalogos y secciones.', 1;

/* Si varias notas del mismo grano tienen igual prioridad y FechaCarga,
   el archivo carece de version confiable: informar y detenerse. */
;WITH r AS (
    SELECT c.*,
           DENSE_RANK() OVER (
               PARTITION BY FechaCierreKey, EstudianteKey, CursoKey
               ORDER BY PrioridadCompetencia DESC, PrioridadBimestre DESC,
                        FechaCarga DESC) AS Prioridad
    FROM #Clasificada AS c WHERE MotivoRechazo IS NULL
)
SELECT FechaCierreKey, EstudianteKey, CursoKey,
       COUNT(DISTINCT ISNULL(CONVERT(NVARCHAR(30), NotaFinal), N'S/E')) AS NotasDistintas
INTO #Conflictos
FROM r WHERE Prioridad = 1
GROUP BY FechaCierreKey, EstudianteKey, CursoKey
HAVING COUNT(DISTINCT ISNULL(CONVERT(NVARCHAR(30), NotaFinal), N'S/E')) > 1;

IF EXISTS (SELECT 1 FROM #Conflictos)
BEGIN
    SELECT * FROM #Conflictos ORDER BY FechaCierreKey, EstudianteKey, CursoKey;
    THROW 51065, N'Notas distintas con igual prioridad; revisar duplicados antes de cargar.', 1;
END;

SELECT c.*,
       ROW_NUMBER() OVER (
           PARTITION BY FechaCierreKey, EstudianteKey, CursoKey
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
        (FechaCierreKey, EstudianteKey, NivelAcademicoKey, DocenteKey, CursoKey,
         NotaVigesimal, NotasConEvidencia)
    SELECT FechaCierreKey, EstudianteKey, NivelAcademicoKey, DocenteKey, CursoKey,
           NotaFinal, 1 - EsSinEvidencia
    FROM #Ordenadas WHERE rn = 1;

    IF (SELECT COUNT(*) FROM stg.NotaCompetencia) <>
       (SELECT COUNT(*) FROM dm_aprendizajes.FacLogroCompetencia)
       + (SELECT COUNT(*) FROM stg.BitacoraNota)
        THROW 51066, N'No cuadran origen, hecho e incidencias; se revierte la carga.', 1;

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

/* Fechas de cierre del CSV que no son el cierre oficial de su bimestre
   (se cargan con el cierre oficial; esperado 0 en este lote). */
SELECT COUNT(*) AS NotasConFechaDistintaAlCierre
FROM #Clasificada
WHERE MotivoRechazo IS NULL AND FechaInformadaKey <> FechaCierreKey;

SELECT t.Anio AS AnioEscolar, t.Bimestre, COUNT(*) AS CompetenciasRegistradas,
       COUNT(f.NotaVigesimal) AS ConNota,               -- COUNT ignora NULL
       SUM(f.NotasConEvidencia) AS NotasConEvidencia,
       COUNT(*) - SUM(f.NotasConEvidencia) AS SinEvidencia,
       SUM(f.NotaVigesimal) AS SumaNotas,
       AVG(f.NotaVigesimal) AS RendimientoPromedio      -- AVG ignora NULL
FROM dm_aprendizajes.FacLogroCompetencia AS f
JOIN dw.DimTiempo AS t ON t.TiempoKey = f.FechaCierreKey
GROUP BY t.Anio, t.Bimestre ORDER BY t.Anio, t.Bimestre;

/* Controles de calidad del lote (ya no se guardan en el hecho). */
SELECT SUM(CASE WHEN LetraCapturada IS NOT NULL THEN 1 ELSE 0 END) AS LetrasConvertidas,
       SUM(CASE WHEN NotaNumerica BETWEEN 0 AND 20
                     AND NotaNumerica <> ROUND(NotaNumerica, 0) THEN 1 ELSE 0 END) AS NotasRedondeadas,
       SUM(CASE WHEN PrioridadBimestre = 0 THEN 1 ELSE 0 END) AS BimestresCorregidos,
       SUM(CASE WHEN PrioridadCompetencia = 0 THEN 1 ELSE 0 END) AS CompetenciasCorregidas,
       SUM(CASE WHEN DocenteAsignado <> DocenteIDLimpio THEN 1 ELSE 0 END) AS DocentesCorregidos
FROM #Ordenadas WHERE rn = 1;

/* Ejemplo del KPI de personas: DISTINCTCOUNT, NO suma de filas de competencias.
   Aqui 'estudiante con bajo rendimiento' = al menos una competencia con nota
   menor a 11 en el periodo; el filtro de area/seccion puede aplicarse igual. */
SELECT t.Anio AS AnioEscolar, t.Bimestre,
       COUNT(DISTINCT CASE WHEN f.NotaVigesimal IS NOT NULL
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