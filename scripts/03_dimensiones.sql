/* ============================================================================
   03_dimensiones.sql
   CAMBIOS v6.0 (20/10/2026) — dimensiones segun la matriz de metricas y
   dimensiones v2.1 del equipo (solo lo que responde las preguntas de la
   Matriz BI; el CSV completo se conserva en staging):
   - DimTiempo: Anio, AnioEscolar, Mes, Bimestre y Fecha. El bimestre sale de
     las fechas OFICIALES de cierre, ya no se aproxima por mes (resuelve P1).
     Se quitan dia de la semana, dia habil y periodo escolar aproximado.
   - DimPeriodoAcademico desaparece: el bimestre vive en DimTiempo.
   - DimEstudiante: codigo, nombre completo, sexo y fecha de nacimiento (la
     edad se calcula). DimDocente: codigo, nombre completo, sexo y condicion.
     DimSeccion: ciclo, grado y seccion. DimArea: codigo y nombre.
   - DimCompetencia une competencia y nivel de logro: una fila por cada
     competencia x nivel (S/E, C, B, A, AD). DimEscalaLogro desaparece; la
     regla nota -> nivel vive en esta dimension.
   - DimTipoMatricula: tipo, via, fase y estado.
   - DimMotivoRechazo: solo la categoria (el motivo textual queda en staging,
     en stg.MotivoRechazoCategoria, que el 04 usa para asignar la categoria).
   - Migracion: sobre una base v5.x se eliminan una sola vez los hechos y las
     dimensiones viejas; el 04, el 05 y el 06 vuelven a crear los hechos.
   ============================================================================ */
/* ============================================================================
   ARCHIVO   : 03_dimensiones.sql   [PASO 1 DEL ETL]
   CAMBIOS v5.1:
     - DimSeccion.Ciclo pasa a NVARCHAR(20): 'No definido' no cabia en 10
       (error 2628). Si la tabla ya existe, se amplia sola con ALTER.
     - DimTipoMatricula se arma con la via CORREGIDA por tipo, igual que el
       04; antes podia faltar la combinacion que el 04 busca (THROW 51004).
     - Padron duplicado: desempate determinista (la FechaCarga del BULK
       INSERT es la misma en todas las filas y no decidia nada).
     - DNI con mas de 8 digitos ya no se recorta ni se marca como valido.
     - 'Ã±' se restaura a 'ñ' (antes se convertia en 'n').
     - La prueba de espacios invisibles usa DATALENGTH.
     - Guardar este archivo como UTF-8 (ya viene con BOM).
   PROPOSITO : Crear y cargar las DIMENSIONES CONFORMADAS que comparten los
               tres datamarts.
   ORDEN     : Ejecutar DESPUES de 01_staging_secundaria.sql
               (02_diagnostico_calidad.sql es opcional pero recomendado antes)

   RECARGA   : Crea las tablas cuando faltan; si ya existen, conserva sus
               claves sustitutas y actualiza/inserta miembros por clave natural.
               Las fechas se limitan al calendario 2024-2027 y los bimestres a
               los cierres declarados en DimTiempo; extenderlos si cambia el corte.

   ============================================================================
   POR QUE LAS DIMENSIONES VAN PRIMERO
   ----------------------------------------------------------------------------
   Los hechos guardan claves sustitutas, no codigos de origen. Si se cargan los
   hechos antes que las dimensiones, todos los lookups fallan y las filas caen
   a la clave -1. Por eso el orden es: dimensiones, luego hechos, siempre.

   ============================================================================
   LA REGLA DE ORO DE ESTE SCRIPT: LIMPIAR LA CLAVE ANTES DE CRUZAR
   ----------------------------------------------------------------------------
   El diagnostico encontro claves con espacio normal, con espacio NO SEPARABLE
   (CHAR 160, que TRIM no elimina), con tabuladores y con la letra O en lugar
   del cero. SQL Server ignora el espacio normal al final al comparar, pero
   el resto rompe un JOIN en silencio, y Power BI si distingue el final.

   El patron que se repite en todo el script es este:

       LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(col, NCHAR(160), N''),
                                   CHAR(9), N''), CHAR(13), N'')))

   Se escribe inline y no como funcion escalar: una UDF escalar en SQL Server
   se evalua fila por fila y en la carga de hechos (45 mil filas) se nota.
   ============================================================================ */

USE DW_IE1217;
GO

IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
GO

/* ----------------------------------------------------------------------------
   MIGRACION v6.0 (se ejecuta una sola vez)
   Si la base todavia tiene la estructura v5.x (DimPeriodoAcademico,
   DimEscalaLogro o columnas que la matriz v2.1 ya no pide), se eliminan los
   tres hechos y las dimensiones para crearlos con la estructura nueva. Los
   hechos se recargan completos en cada ejecucion del 04, 05 y 06, asi que no
   se pierde informacion: el origen sigue en staging.
   En una base ya migrada este bloque no hace nada.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID(N'dw.DimPeriodoAcademico', N'U') IS NOT NULL
   OR OBJECT_ID(N'dw.DimEscalaLogro', N'U') IS NOT NULL
   OR COL_LENGTH(N'dw.DimTiempo', N'EsDiaHabil') IS NOT NULL
   OR COL_LENGTH(N'dw.DimEstudiante', N'DNI') IS NOT NULL
   OR COL_LENGTH(N'dw.DimMotivoRechazo', N'Motivo') IS NOT NULL
BEGIN
    PRINT 'Migracion v6.0: se recrean los hechos y las dimensiones.';
    DROP TABLE IF EXISTS dm_aprendizajes.FacLogroCompetencia;
    DROP TABLE IF EXISTS dm_preparacion.FacPreparacion;
    DROP TABLE IF EXISTS dm_matricula.FacMatricula;
    DROP TABLE IF EXISTS dw.DimEscalaLogro;
    DROP TABLE IF EXISTS dw.DimPeriodoAcademico;
    DROP TABLE IF EXISTS dw.DimCompetencia;
    DROP TABLE IF EXISTS dw.DimArea;
    DROP TABLE IF EXISTS dw.DimSeccion;
    DROP TABLE IF EXISTS dw.DimDocente;
    DROP TABLE IF EXISTS dw.DimEstudiante;
    DROP TABLE IF EXISTS dw.DimTipoMatricula;
    DROP TABLE IF EXISTS dw.DimMotivoRechazo;
    DROP TABLE IF EXISTS dw.DimTiempo;
END;
GO

/* ============================================================================
   1. DimTiempo
   ----------------------------------------------------------------------------
   Clave inteligente AAAAMMDD. Es la unica dimension donde se acepta una clave
   que no es IDENTITY, porque la fecha ya es un identificador estable.

   DOS MIEMBROS ESPECIALES, y aqui esta la decision de diseno mas importante
   del modelo:

       -1  No aplica     -> el hecho existe pero esa fecha no le corresponde.
                            Ejemplo: un continuador no presenta solicitud de
                            vacante, asi que sus fechas de solicitud, revision
                            y asignacion apuntan aqui.
       -2  No registrado -> la fecha le corresponde al hecho pero no ocurrio o
                            no se registro. Ejemplo: una matricula rechazada no
                            tiene fecha de registro en SIAGIE.

   Sin esta separacion, un NULL en la tabla de hechos significaria dos cosas
   distintas y nadie podria distinguirlas al consultar. Con ella, el analista
   filtra por "No aplica" o por "No registrado" y sabe exactamente que esta
   contando. Es la diferencia entre "no le tocaba" y "fallamos".
   ============================================================================ */
IF OBJECT_ID('dw.DimTiempo', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimTiempo (
    TiempoKey        INT          NOT NULL,
    Fecha            DATE         NULL,     -- Dia
    Anio             SMALLINT     NULL,
    AnioEscolar      SMALLINT     NULL,     -- en este colegio coincide con el anio calendario
    Mes              TINYINT      NULL,
    NombreMes        NVARCHAR(15) NULL,
    Bimestre         TINYINT      NULL,     -- 0 = fuera del periodo escolar
    NombreBimestre   NVARCHAR(40) NULL,
    EsCierreBimestre BIT          NOT NULL DEFAULT 0,  -- fecha oficial de cierre
    EsFilaEspecial   BIT          NOT NULL DEFAULT 0,
    CONSTRAINT PK_DimTiempo PRIMARY KEY CLUSTERED (TiempoKey)
);
END;
GO

/* Miembros especiales */
INSERT INTO dw.DimTiempo (TiempoKey, NombreMes, NombreBimestre, EsFilaEspecial)
SELECT v.TiempoKey, v.Nombre, v.Nombre, 1
FROM (VALUES (-1, N'No aplica'), (-2, N'No registrado')) AS v(TiempoKey, Nombre)
WHERE NOT EXISTS (SELECT 1 FROM dw.DimTiempo t WHERE t.TiempoKey = v.TiempoKey);

/* Calendario 2024-2027 */
;WITH Calendario AS (
    SELECT CAST('2024-01-01' AS DATE) AS F
    UNION ALL SELECT DATEADD(DAY, 1, F) FROM Calendario WHERE F < '2027-12-31'
)
INSERT INTO dw.DimTiempo (TiempoKey, Fecha, Anio, AnioEscolar, Mes, NombreMes,
                          Bimestre, NombreBimestre, EsCierreBimestre, EsFilaEspecial)
SELECT
    CONVERT(INT, FORMAT(F, 'yyyyMMdd')), F, YEAR(F), YEAR(F), MONTH(F),
    CASE MONTH(F) WHEN 1 THEN N'Enero' WHEN 2 THEN N'Febrero' WHEN 3 THEN N'Marzo'
                  WHEN 4 THEN N'Abril' WHEN 5 THEN N'Mayo'    WHEN 6 THEN N'Junio'
                  WHEN 7 THEN N'Julio' WHEN 8 THEN N'Agosto'  WHEN 9 THEN N'Setiembre'
                  WHEN 10 THEN N'Octubre' WHEN 11 THEN N'Noviembre' ELSE N'Diciembre' END,
    0, N'Sin calendario academico', 0, 0
FROM Calendario
WHERE NOT EXISTS (SELECT 1 FROM dw.DimTiempo t
                  WHERE t.TiempoKey = CONVERT(INT, FORMAT(F, 'yyyyMMdd')))
OPTION (MAXRECURSION 0);
GO

/* Bimestre ACADEMICO de cada dia, desde las fechas oficiales de cierre
   (notas_competencias.FechaCierreBimestre) y el inicio de clases del anio
   (primera sesion registrada en sesiones.csv). Reglas:
     - antes del inicio de clases                 -> 0 Fuera del periodo escolar
     - hasta el cierre del bimestre n (inclusive) -> n
     - despues del ultimo cierre, si el anio tiene sus 4 cierres -> 0
     - despues del ultimo cierre, si faltan cierres -> el bimestre siguiente
       («sin cierre»): 2026-III sigue abierto en el corte de los datos
     - anios sin calendario (2024, 2027)          -> 0 Sin calendario academico
   Para una recarga con nuevos bimestres, agregar su cierre en esta lista. */
DROP TABLE IF EXISTS #Cierres;
SELECT * INTO #Cierres FROM (VALUES
    (2025, 1, CAST('2025-05-23' AS DATE)), (2025, 2, CAST('2025-08-01' AS DATE)),
    (2025, 3, CAST('2025-10-24' AS DATE)), (2025, 4, CAST('2025-12-19' AS DATE)),
    (2026, 1, CAST('2026-05-22' AS DATE)), (2026, 2, CAST('2026-07-31' AS DATE))
) AS v(AnioEscolar, Bimestre, FechaCierre);

DROP TABLE IF EXISTS #InicioClases;
SELECT TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio))) AS AnioEscolar,
       MIN(COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSesion)), 23),
                    TRY_CONVERT(DATE, LTRIM(RTRIM(FechaSesion)), 103))) AS Inicio
INTO #InicioClases
FROM stg.Sesion
GROUP BY TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Anio)));

UPDATE t SET
    Bimestre = x.Bimestre,
    NombreBimestre = CASE WHEN x.Bimestre = 0 THEN x.Texto
                          ELSE CASE x.Bimestre WHEN 1 THEN N'I' WHEN 2 THEN N'II'
                                               WHEN 3 THEN N'III' ELSE N'IV' END
                               + N' Bimestre' + CASE WHEN x.SinCierre = 1 THEN N' (sin cierre)' ELSE N'' END END,
    EsCierreBimestre = CASE WHEN EXISTS (SELECT 1 FROM #Cierres c WHERE c.FechaCierre = t.Fecha)
                            THEN 1 ELSE 0 END
FROM dw.DimTiempo AS t
CROSS APPLY (
    SELECT
        CASE WHEN NOT EXISTS (SELECT 1 FROM #Cierres c WHERE c.AnioEscolar = t.Anio) THEN 0
             WHEN t.Fecha < (SELECT i.Inicio FROM #InicioClases i WHERE i.AnioEscolar = t.Anio) THEN 0
             WHEN EXISTS (SELECT 1 FROM #Cierres c WHERE c.AnioEscolar = t.Anio AND c.FechaCierre >= t.Fecha)
                  THEN (SELECT MIN(c.Bimestre) FROM #Cierres c WHERE c.AnioEscolar = t.Anio AND c.FechaCierre >= t.Fecha)
             WHEN (SELECT COUNT(*) FROM #Cierres c WHERE c.AnioEscolar = t.Anio) = 4 THEN 0
             ELSE (SELECT COUNT(*) + 1 FROM #Cierres c WHERE c.AnioEscolar = t.Anio) END AS Bimestre,
        CASE WHEN NOT EXISTS (SELECT 1 FROM #Cierres c WHERE c.AnioEscolar = t.Anio)
             THEN N'Sin calendario academico' ELSE N'Fuera del periodo escolar' END AS Texto,
        CASE WHEN EXISTS (SELECT 1 FROM #Cierres c WHERE c.AnioEscolar = t.Anio)
                  AND NOT EXISTS (SELECT 1 FROM #Cierres c WHERE c.AnioEscolar = t.Anio AND c.FechaCierre >= t.Fecha)
                  AND (SELECT COUNT(*) FROM #Cierres c WHERE c.AnioEscolar = t.Anio) < 4
             THEN 1 ELSE 0 END AS SinCierre
) AS x
WHERE t.EsFilaEspecial = 0;
GO

/* ============================================================================
   2. DimEstudiante
   ----------------------------------------------------------------------------
   SCD tipo 1: los atributos se sobrescriben. Si el estudiante se muda, se
   pierde la direccion anterior. Lo correcto seria tipo 2, pero para el alcance
   del proyecto no compensa la complejidad.

   Aqui se resuelven, en un solo SELECT, seis defectos del diagnostico:
     - clave con espacio normal, no separable o tabulador
     - padron duplicado         -> ROW_NUMBER, se conserva la fila mas completa
     - nombres en MAYUSCULAS o minusculas y con doble espacio
     - sexo escrito de seis formas
     - fechas en cinco formatos
     - distrito con mayusculas, tildes, espacios y el typo 'Chaclayo'
   ============================================================================ */
IF OBJECT_ID('dw.DimEstudiante', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimEstudiante (
    EstudianteKey      INT IDENTITY(1,1) NOT NULL,
    CodigoEstudiante   NVARCHAR(20)  NOT NULL,
    NombreCompleto     NVARCHAR(220) NULL,
    Sexo               CHAR(1)       NULL,
    FechaNacimiento    DATE          NULL,   -- la edad se calcula en Power BI
    CONSTRAINT PK_DimEstudiante PRIMARY KEY CLUSTERED (EstudianteKey),
    CONSTRAINT UQ_DimEstudiante UNIQUE (CodigoEstudiante)
);
END;
GO

SET IDENTITY_INSERT dw.DimEstudiante ON;
INSERT INTO dw.DimEstudiante (EstudianteKey, CodigoEstudiante, NombreCompleto, Sexo)
SELECT -1, N'N/D', N'No definido', 'N'
WHERE NOT EXISTS (SELECT 1 FROM dw.DimEstudiante WHERE EstudianteKey = -1);
SET IDENTITY_INSERT dw.DimEstudiante OFF;
GO

/* DNI y distrito ya no se guardan, pero se siguen limpiando aqui porque
   deciden cual fila del padron duplicado se conserva (la mas completa). */
;WITH Limpio AS (
    SELECT
        LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(CodigoEstudiante, NCHAR(160), N''),
                            CHAR(9), N''), CHAR(13), N''))) AS Cod,
        CASE WHEN NULLIF(LTRIM(RTRIM(DNI)), N'') IS NULL THEN NULL
             WHEN LEN(REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N'')) > 8
                  THEN REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N'')
             ELSE RIGHT(N'00000000' + REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N''), 8)
        END AS Dni,
        /* 'Ã±' es una ñ mal codificada: se restaura la letra real */
        REPLACE(REPLACE(LTRIM(RTRIM(ApellidoPaterno)), N'Ã±', N'ñ'), N'  ', N' ') AS ApePat,
        REPLACE(REPLACE(LTRIM(RTRIM(ApellidoMaterno)), N'Ã±', N'ñ'), N'  ', N' ') AS ApeMat,
        REPLACE(REPLACE(LTRIM(RTRIM(Nombres)), N'Ã±', N'ñ'), N'  ', N' ')         AS Noms,
        CASE WHEN UPPER(LTRIM(Sexo)) IN (N'M', N'MASCULINO', N'H', N'1') THEN 'M'
             WHEN UPPER(LTRIM(Sexo)) IN (N'F', N'FEMENINO', N'MUJER', N'2') THEN 'F'
             ELSE 'N' END AS Sx,
        /* el orden importa: 103 (dd/mm) se prueba antes que 101 (mm/dd) */
        COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 103),
                 TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 105),
                 TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaNacimiento)), 10), 23),
                 TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 101)) AS FNac,
        CASE
            WHEN UPPER(LTRIM(RTRIM(Distrito))) IN (N'CHACLACAYO', N'CHACLAYO') THEN N'Chaclacayo'
            WHEN UPPER(LTRIM(RTRIM(Distrito))) LIKE N'%CHOSICA%'
              OR UPPER(LTRIM(RTRIM(Distrito))) LIKE N'%LURIGANCHO%'           THEN N'Lurigancho-Chosica'
            WHEN UPPER(LTRIM(RTRIM(Distrito))) LIKE N'ATE%'                   THEN N'Ate'
            ELSE N'No determinado' END AS Distr,
        FechaCarga
    FROM stg.Estudiante
    WHERE NULLIF(LTRIM(RTRIM(CodigoEstudiante)), N'') IS NOT NULL
),
/* Duplicidad de padron: UNA fila por codigo, la mas completa, con un orden
   alfabetico fijo al final para que cada reejecucion elija la misma. */
Unico AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY Cod
        ORDER BY FechaCarga DESC,
                 CASE WHEN Dni LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
                      THEN 0 ELSE 1 END,
                 CASE WHEN FNac  IS NULL             THEN 1 ELSE 0 END,
                 CASE WHEN Sx    = 'N'               THEN 1 ELSE 0 END,
                 CASE WHEN Distr = N'No determinado' THEN 1 ELSE 0 END,
                 ApePat, ApeMat, Noms, Dni) AS rn
    FROM Limpio
)
MERGE dw.DimEstudiante AS d
USING (SELECT Cod, ApePat + N' ' + ApeMat + N', ' + Noms AS Nombre, Sx, FNac
       FROM Unico WHERE rn = 1) AS o
ON d.CodigoEstudiante = o.Cod
WHEN MATCHED THEN UPDATE SET
    d.NombreCompleto = o.Nombre, d.Sexo = o.Sx, d.FechaNacimiento = o.FNac
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CodigoEstudiante, NombreCompleto, Sexo, FechaNacimiento)
    VALUES (o.Cod, o.Nombre, o.Sx, o.FNac);
GO

/* ============================================================================
   3. DimDocente
   ============================================================================ */
IF OBJECT_ID('dw.DimDocente', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimDocente (
    DocenteKey         INT IDENTITY(1,1) NOT NULL,
    DocenteID          NVARCHAR(20)  NOT NULL,
    NombreCompleto     NVARCHAR(220) NULL,
    Sexo               CHAR(1)       NULL,
    CondicionLaboral   NVARCHAR(20)  NULL,
    CONSTRAINT PK_DimDocente PRIMARY KEY CLUSTERED (DocenteKey),
    CONSTRAINT UQ_DimDocente UNIQUE (DocenteID)
);
END;
GO
SET IDENTITY_INSERT dw.DimDocente ON;
INSERT INTO dw.DimDocente (DocenteKey, DocenteID, NombreCompleto, Sexo, CondicionLaboral)
SELECT -1, N'N/D', N'No definido', 'N', N'No definido'
WHERE NOT EXISTS (SELECT 1 FROM dw.DimDocente WHERE DocenteKey = -1);
SET IDENTITY_INSERT dw.DimDocente OFF;
GO

MERGE dw.DimDocente AS d
USING (
    SELECT
        /* La letra O en lugar del cero aparece en DocenteID: se normaliza */
        UPPER(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(DocenteID, NCHAR(160), N''),
                     CHAR(9), N''))), N'DOC-O', N'DOC-0')) AS Did,
        REPLACE(REPLACE(LTRIM(RTRIM(ApellidoPaterno)), N'Ã±', N'ñ'), N'  ', N' ') + N' '
          + REPLACE(REPLACE(LTRIM(RTRIM(ApellidoMaterno)), N'Ã±', N'ñ'), N'  ', N' ') + N', '
          + REPLACE(REPLACE(LTRIM(RTRIM(Nombres)), N'Ã±', N'ñ'), N'  ', N' ') AS Nombre,
        CASE WHEN UPPER(LTRIM(Sexo)) IN (N'M', N'MASCULINO', N'H', N'1') THEN 'M'
             WHEN UPPER(LTRIM(Sexo)) IN (N'F', N'FEMENINO', N'MUJER', N'2') THEN 'F'
             ELSE 'N' END AS Sx,
        /* NOMBRADO / nombrado / Nombrada / Nombrrado -> Nombrado */
        CASE WHEN UPPER(LTRIM(RTRIM(CondicionLaboral))) LIKE N'NOMBR%' THEN N'Nombrado'
             WHEN UPPER(LTRIM(RTRIM(CondicionLaboral))) LIKE N'CONT%'  THEN N'Contratado'
             ELSE N'No determinado' END AS Cond
    FROM stg.Docente
    WHERE NULLIF(LTRIM(RTRIM(DocenteID)), N'') IS NOT NULL
) AS o
ON d.DocenteID = o.Did
WHEN MATCHED THEN UPDATE SET
    d.NombreCompleto = o.Nombre, d.Sexo = o.Sx, d.CondicionLaboral = o.Cond
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DocenteID, NombreCompleto, Sexo, CondicionLaboral)
    VALUES (o.Did, o.Nombre, o.Sx, o.Cond);
GO

/* ============================================================================
   4. DimSeccion
   ----------------------------------------------------------------------------
   DECISION: la dimension NO lleva el anio. Son 10 filas (1A a 5B), no 20.
   El SeccionID del origen si lo lleva (SEC-2025-1A), asi que se parte el
   codigo y se reutiliza la seccion entre periodos. El AnioEscolar debe ir
   explicito en cada hecho: una solicitud de diciembre de 2024 puede ser
   matricula del anio escolar 2025.

   El tutor NO entra aqui: cambia todos los anios y convertiria la dimension en
   una SCD sin necesidad.
   ============================================================================ */
IF OBJECT_ID('dw.DimSeccion', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimSeccion (
    SeccionKey   INT IDENTITY(1,1) NOT NULL,
    CodigoCorto  NVARCHAR(10)  NOT NULL,     -- '1A'
    Ciclo        NVARCHAR(20)  NULL,
    Grado        TINYINT       NULL,
    Seccion      NVARCHAR(5)   NULL,
    NombreGrado  NVARCHAR(30)  NULL,
    CONSTRAINT PK_DimSeccion PRIMARY KEY CLUSTERED (SeccionKey),
    CONSTRAINT UQ_DimSeccion UNIQUE (CodigoCorto)
);
END;
GO
SET IDENTITY_INSERT dw.DimSeccion ON;
INSERT INTO dw.DimSeccion (SeccionKey, CodigoCorto, Ciclo, Grado, Seccion, NombreGrado)
SELECT -1, N'N/D', N'No definido', 0, N'X', N'No definido'
WHERE NOT EXISTS (SELECT 1 FROM dw.DimSeccion WHERE SeccionKey = -1);
SET IDENTITY_INSERT dw.DimSeccion OFF;
GO

/* El aforo NO va en la dimension: cambia por anio y el 04 lo toma de la
   seccion del anio de cada matricula. */
;WITH s AS (
    SELECT TRY_CONVERT(TINYINT, LTRIM(RTRIM(Grado))) AS Grado,
           UPPER(LTRIM(RTRIM(Seccion))) AS Seccion,
           LTRIM(RTRIM(Ciclo)) AS Ciclo,
           ROW_NUMBER() OVER (
               PARTITION BY TRY_CONVERT(TINYINT, LTRIM(RTRIM(Grado))), UPPER(LTRIM(RTRIM(Seccion)))
               ORDER BY TRY_CONVERT(SMALLINT, Anio) DESC, SeccionID DESC
           ) AS rn
    FROM stg.Seccion
)
MERGE dw.DimSeccion AS d
USING (
    SELECT CAST(Grado AS NVARCHAR(3)) + Seccion AS CodigoCorto,
           Grado, Seccion, Ciclo,
           CASE Grado WHEN 1 THEN N'Primero de secundaria' WHEN 2 THEN N'Segundo de secundaria'
                      WHEN 3 THEN N'Tercero de secundaria' WHEN 4 THEN N'Cuarto de secundaria'
                      ELSE N'Quinto de secundaria' END AS NombreGrado
    FROM s WHERE rn = 1 AND Grado BETWEEN 1 AND 5 AND Seccion IS NOT NULL AND Seccion <> N''
) AS o ON d.CodigoCorto = o.CodigoCorto
WHEN MATCHED THEN UPDATE SET
    d.Grado = o.Grado, d.Seccion = o.Seccion, d.Ciclo = o.Ciclo, d.NombreGrado = o.NombreGrado
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CodigoCorto, Grado, Seccion, Ciclo, NombreGrado)
    VALUES (o.CodigoCorto, o.Grado, o.Seccion, o.Ciclo, o.NombreGrado);
GO

/* ============================================================================
   5. DimArea y DimCompetencia
   ----------------------------------------------------------------------------
   DimArea la usa preparacion (las sesiones y entregas son por area, sin
   competencia). DimCompetencia la usan las notas y, segun la matriz v2.1,
   junta en una sola dimension el area, el tipo de competencia, la
   competencia y el NIVEL DE LOGRO: hay una fila por cada competencia x nivel
   (S/E, C, B, A, AD). Cada nota apunta a la fila de su competencia con el
   nivel que obtuvo. Ninguna dimension se relaciona con otra (estrella).

   La regla nota -> nivel vive AQUI y en ningun otro lado. La fila S/E
   («Sin evidencia») recibe las notas vacias: NULL en el hecho, nunca 0 ni C.
   ============================================================================ */
IF OBJECT_ID('dw.DimArea', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimArea (
    AreaKey        INT IDENTITY(1,1) NOT NULL,
    AreaID         NVARCHAR(20)  NOT NULL,
    NombreArea     NVARCHAR(100) NULL,
    CONSTRAINT PK_DimArea PRIMARY KEY CLUSTERED (AreaKey),
    CONSTRAINT UQ_DimArea UNIQUE (AreaID)
);
END;
GO
SET IDENTITY_INSERT dw.DimArea ON;
INSERT INTO dw.DimArea (AreaKey, AreaID, NombreArea)
SELECT -1, N'N/D', N'No definida'
WHERE NOT EXISTS (SELECT 1 FROM dw.DimArea WHERE AreaKey = -1);
SET IDENTITY_INSERT dw.DimArea OFF;

MERGE dw.DimArea AS d
USING (
    SELECT LTRIM(RTRIM(AreaID)) AS AreaID, LTRIM(RTRIM(NombreArea)) AS NombreArea
    FROM stg.AreaCurricular
    WHERE NULLIF(LTRIM(RTRIM(AreaID)), N'') IS NOT NULL
) AS o ON d.AreaID = o.AreaID
WHEN MATCHED THEN UPDATE SET d.NombreArea = o.NombreArea
WHEN NOT MATCHED BY TARGET THEN
    INSERT (AreaID, NombreArea) VALUES (o.AreaID, o.NombreArea);
GO

IF OBJECT_ID('dw.DimCompetencia', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimCompetencia (
    CompetenciaKey    INT IDENTITY(1,1) NOT NULL,
    AreaID            NVARCHAR(20)  NULL,       -- desnormalizado (sin FK a DimArea)
    NombreArea        NVARCHAR(100) NULL,
    TipoCompetencia   NVARCHAR(30)  NULL,
    CompetenciaID     NVARCHAR(20)  NOT NULL,
    NombreCompetencia NVARCHAR(200) NULL,
    NivelLogro        NVARCHAR(10)  NOT NULL,   -- S/E, C, B, A, AD
    DescripcionNivel  NVARCHAR(40)  NULL,
    NotaDesde         TINYINT       NULL,       -- regla del nivel (vacia en S/E)
    NotaHasta         TINYINT       NULL,
    OrdenNivel        TINYINT       NOT NULL,   -- 0 S/E, 1 C ... 4 AD
    EsAprobatorio     BIT           NOT NULL,
    CONSTRAINT PK_DimCompetencia PRIMARY KEY CLUSTERED (CompetenciaKey),
    CONSTRAINT UQ_DimCompetencia UNIQUE (CompetenciaID, NivelLogro)
);
END;
GO
SET IDENTITY_INSERT dw.DimCompetencia ON;
INSERT INTO dw.DimCompetencia (CompetenciaKey, AreaID, NombreArea, TipoCompetencia,
       CompetenciaID, NombreCompetencia, NivelLogro, DescripcionNivel, OrdenNivel, EsAprobatorio)
SELECT -1, N'N/D', N'No definida', N'No definida', N'N/D', N'No definida', N'N/D', N'No definido', 0, 0
WHERE NOT EXISTS (SELECT 1 FROM dw.DimCompetencia WHERE CompetenciaKey = -1);
SET IDENTITY_INSERT dw.DimCompetencia OFF;

MERGE dw.DimCompetencia AS d
USING (
    SELECT ISNULL(a.AreaID, N'N/D') AS AreaID,
           ISNULL(a.NombreArea, N'No definida') AS NombreArea,
           LTRIM(RTRIM(c.TipoCompetencia)) AS TipoCompetencia,
           LTRIM(RTRIM(c.CompetenciaID)) AS CompetenciaID,
           LTRIM(RTRIM(c.NombreCompetencia)) AS NombreCompetencia,
           n.NivelLogro, n.DescripcionNivel, n.NotaDesde, n.NotaHasta, n.OrdenNivel, n.EsAprobatorio
    FROM stg.Competencia AS c
    LEFT JOIN dw.DimArea AS a ON a.AreaID = LTRIM(RTRIM(c.AreaID))
    CROSS JOIN (VALUES
        (N'S/E', N'Sin evidencia suficiente', CAST(NULL AS TINYINT), CAST(NULL AS TINYINT), 0, 0),
        (N'C',   N'En inicio',         0, 10, 1, 0),
        (N'B',   N'En proceso',       11, 13, 2, 1),
        (N'A',   N'Logro esperado',   14, 17, 3, 1),
        (N'AD',  N'Logro destacado',  18, 20, 4, 1)
    ) AS n(NivelLogro, DescripcionNivel, NotaDesde, NotaHasta, OrdenNivel, EsAprobatorio)
    WHERE NULLIF(LTRIM(RTRIM(c.CompetenciaID)), N'') IS NOT NULL
) AS o ON d.CompetenciaID = o.CompetenciaID AND d.NivelLogro = o.NivelLogro
WHEN MATCHED THEN UPDATE SET
    d.AreaID = o.AreaID, d.NombreArea = o.NombreArea, d.TipoCompetencia = o.TipoCompetencia,
    d.NombreCompetencia = o.NombreCompetencia, d.DescripcionNivel = o.DescripcionNivel,
    d.NotaDesde = o.NotaDesde, d.NotaHasta = o.NotaHasta,
    d.OrdenNivel = o.OrdenNivel, d.EsAprobatorio = o.EsAprobatorio
WHEN NOT MATCHED BY TARGET THEN
    INSERT (AreaID, NombreArea, TipoCompetencia, CompetenciaID, NombreCompetencia,
            NivelLogro, DescripcionNivel, NotaDesde, NotaHasta, OrdenNivel, EsAprobatorio)
    VALUES (o.AreaID, o.NombreArea, o.TipoCompetencia, o.CompetenciaID, o.NombreCompetencia,
            o.NivelLogro, o.DescripcionNivel, o.NotaDesde, o.NotaHasta, o.OrdenNivel, o.EsAprobatorio);
GO

/* ============================================================================
   6. DimTipoMatricula  (dimension "junk")
   ----------------------------------------------------------------------------
   Cuatro banderas de baja cardinalidad que por si solas no merecen una tabla
   cada una: tipo, via, fase y estado. En lugar de cuatro dimensiones enanas o
   de cuatro columnas de texto repetidas 600 veces en el hecho, se combinan en
   una sola dimension chatarra. El hecho guarda una sola clave.
   ============================================================================ */
IF OBJECT_ID('dw.DimTipoMatricula', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimTipoMatricula (
    TipoMatriculaKey INT IDENTITY(1,1) NOT NULL,
    TipoMatricula    NVARCHAR(30) NOT NULL,
    ViaMatricula     NVARCHAR(40) NOT NULL,
    FaseProceso      NVARCHAR(20) NOT NULL,
    EstadoMatricula  NVARCHAR(20) NOT NULL,
    CONSTRAINT PK_DimTipoMatricula PRIMARY KEY CLUSTERED (TipoMatriculaKey),
    CONSTRAINT UQ_DimTipoMatricula UNIQUE (TipoMatricula, ViaMatricula, FaseProceso, EstadoMatricula)
);
END;
GO
SET IDENTITY_INSERT dw.DimTipoMatricula ON;
INSERT INTO dw.DimTipoMatricula (TipoMatriculaKey, TipoMatricula, ViaMatricula,
                                 FaseProceso, EstadoMatricula)
SELECT -1, N'No definido', N'No definida', N'No definida', N'No definido'
WHERE NOT EXISTS (SELECT 1 FROM dw.DimTipoMatricula WHERE TipoMatriculaKey = -1);
SET IDENTITY_INSERT dw.DimTipoMatricula OFF;

;WITH Normalizado AS (
    SELECT
        /* Ingresente / Continuadorr / Repitiente: typos del origen */
        CASE WHEN UPPER(LTRIM(RTRIM(TipoMatricula))) LIKE N'INGRES%'  THEN N'Ingresante'
             WHEN UPPER(LTRIM(RTRIM(TipoMatricula))) LIKE N'CONTIN%'  THEN N'Continuador'
             WHEN UPPER(LTRIM(RTRIM(TipoMatricula))) LIKE N'REPIT%'   THEN N'Repitente'
             WHEN UPPER(LTRIM(RTRIM(TipoMatricula))) LIKE N'TRASLAD%' THEN N'Traslado'
             ELSE N'No determinado' END AS Tipo,
        CASE WHEN UPPER(LTRIM(RTRIM(ViaMatricula))) LIKE N'SOLICITUD%' THEN N'Solicitud de vacante'
             WHEN UPPER(LTRIM(RTRIM(ViaMatricula))) LIKE N'RATIFIC%'   THEN N'Ratificacion de continuidad'
             ELSE N'No determinada' END AS Via,
        CASE WHEN UPPER(LTRIM(RTRIM(FaseProceso))) LIKE N'COMPLEMENT%' THEN N'Complementaria'
             ELSE N'Regular' END AS Fase,
        /* APROBADO / aprobado / Aprovado / Aprobada -> Aprobado */
        CASE WHEN UPPER(LTRIM(RTRIM(EstadoMatricula))) LIKE N'APRO%'    THEN N'Aprobado'
             WHEN UPPER(LTRIM(RTRIM(EstadoMatricula))) LIKE N'RECHAZ%'  THEN N'Rechazado'
             ELSE N'No determinado' END AS Estado
    FROM stg.Matricula
), Canonico AS (
    /* MISMA regla que el 04: el tipo de estudiante decide la via. Si aqui se
       guardara la via cruda, el 04 podria buscar una combinacion inexistente. */
    SELECT Tipo, Fase, Estado,
           CASE WHEN Tipo IN (N'Continuador', N'Repitente') THEN N'Ratificacion de continuidad'
                WHEN Tipo IN (N'Ingresante', N'Traslado')   THEN N'Solicitud de vacante'
                ELSE Via END AS Via
    FROM Normalizado
), Combinaciones AS (
    SELECT DISTINCT Tipo, Via, Fase, Estado
    FROM Canonico
)
MERGE dw.DimTipoMatricula AS d
USING Combinaciones AS o
ON d.TipoMatricula = o.Tipo AND d.ViaMatricula = o.Via
   AND d.FaseProceso = o.Fase AND d.EstadoMatricula = o.Estado
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TipoMatricula, ViaMatricula, FaseProceso, EstadoMatricula)
    VALUES (o.Tipo, o.Via, o.Fase, o.Estado);
GO

/* ============================================================================
   7. DimMotivoRechazo
   ----------------------------------------------------------------------------
   Segun la matriz v2.1 la dimension guarda la CATEGORIA del rechazo. El
   texto del motivo queda en staging: stg.MotivoRechazoCategoria guarda cada
   motivo de la fuente con su categoria y el 04 la usa para asignar la clave.
   Las aprobadas apuntan a -1 'No aplica'; una rechazada sin motivo, a -2.
   ============================================================================ */
DROP TABLE IF EXISTS stg.MotivoRechazoCategoria;
SELECT DISTINCT
    LTRIM(RTRIM(Observacion)) AS Motivo,
    CASE WHEN LTRIM(RTRIM(Observacion)) LIKE N'%vacante%' THEN N'Capacidad de la IE'
         WHEN LTRIM(RTRIM(Observacion)) LIKE N'%plazo%'   THEN N'Fuera de cronograma'
         WHEN LTRIM(RTRIM(Observacion)) LIKE N'%otra IE%' THEN N'Duplicidad en SIAGIE'
         WHEN LTRIM(RTRIM(Observacion)) LIKE N'%RENIEC%'  THEN N'Identidad'
         ELSE N'Documentaria' END AS Categoria
INTO stg.MotivoRechazoCategoria
FROM stg.Matricula
WHERE UPPER(LTRIM(RTRIM(EstadoMatricula))) LIKE N'RECHAZ%'
  AND NULLIF(LTRIM(RTRIM(Observacion)), N'') IS NOT NULL;
GO

IF OBJECT_ID('dw.DimMotivoRechazo', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimMotivoRechazo (
    MotivoKey    INT IDENTITY(1,1) NOT NULL,
    Categoria    NVARCHAR(40)  NOT NULL,
    CONSTRAINT PK_DimMotivoRechazo PRIMARY KEY CLUSTERED (MotivoKey),
    CONSTRAINT UQ_DimMotivoRechazo UNIQUE (Categoria)
);
END;
GO
SET IDENTITY_INSERT dw.DimMotivoRechazo ON;
INSERT INTO dw.DimMotivoRechazo (MotivoKey, Categoria)
SELECT v.MotivoKey, v.Categoria
FROM (VALUES (-1, N'No aplica'), (-2, N'No registrado')) AS v(MotivoKey, Categoria)
WHERE NOT EXISTS (SELECT 1 FROM dw.DimMotivoRechazo d WHERE d.MotivoKey = v.MotivoKey);
SET IDENTITY_INSERT dw.DimMotivoRechazo OFF;

MERGE dw.DimMotivoRechazo AS d
USING (SELECT DISTINCT Categoria FROM stg.MotivoRechazoCategoria) AS o
ON d.Categoria = o.Categoria
WHEN NOT MATCHED BY TARGET THEN INSERT (Categoria) VALUES (o.Categoria);
GO

/* ============================================================================
   VERIFICACION DEL PASO 1
   ============================================================================ */
PRINT '=== 03_dimensiones.sql ejecutado ===';

SELECT 'dw.DimTiempo' AS Dimension, COUNT(*) AS Filas,
       SUM(CASE WHEN TiempoKey < 0 THEN 1 ELSE 0 END) AS MiembrosEspeciales FROM dw.DimTiempo
UNION ALL SELECT 'dw.DimEstudiante',       COUNT(*), SUM(CASE WHEN EstudianteKey  < 0 THEN 1 ELSE 0 END) FROM dw.DimEstudiante
UNION ALL SELECT 'dw.DimDocente',          COUNT(*), SUM(CASE WHEN DocenteKey     < 0 THEN 1 ELSE 0 END) FROM dw.DimDocente
UNION ALL SELECT 'dw.DimSeccion',          COUNT(*), SUM(CASE WHEN SeccionKey     < 0 THEN 1 ELSE 0 END) FROM dw.DimSeccion
UNION ALL SELECT 'dw.DimArea',             COUNT(*), SUM(CASE WHEN AreaKey        < 0 THEN 1 ELSE 0 END) FROM dw.DimArea
UNION ALL SELECT 'dw.DimCompetencia',      COUNT(*), SUM(CASE WHEN CompetenciaKey < 0 THEN 1 ELSE 0 END) FROM dw.DimCompetencia
UNION ALL SELECT 'dw.DimTipoMatricula',    COUNT(*), SUM(CASE WHEN TipoMatriculaKey < 0 THEN 1 ELSE 0 END) FROM dw.DimTipoMatricula
UNION ALL SELECT 'dw.DimMotivoRechazo',    COUNT(*), SUM(CASE WHEN MotivoKey      < 0 THEN 1 ELSE 0 END) FROM dw.DimMotivoRechazo;

/* Conteos esperados (sin contar miembros especiales):
   DimEstudiante 373 | DimDocente 15 | DimSeccion 10 | DimArea 11
   DimCompetencia 140 (28 competencias x 5 niveles) | DimMotivoRechazo 4 categorias
   DimTipoMatricula: pocas decenas

   Si DimEstudiante trae MAS de 373, la deduplicacion no funciono.
   Si trae MENOS, se perdieron filas: revisar el filtro de codigo vacio.      */

/* Sin FK, la integridad area-competencia se verifica aqui.
   Cada competencia debe apuntar a un AreaID existente en DimArea. Esperado: 0. */
SELECT 'Competencias con AreaID inexistente en DimArea (esperado 0)' AS Prueba,
       COUNT(*) AS Filas
FROM dw.DimCompetencia AS c
WHERE c.CompetenciaKey <> -1
  AND NOT EXISTS (SELECT 1 FROM dw.DimArea AS a WHERE a.AreaID = c.AreaID);

/* Bimestre academico por anio: dias de clase y fechas de cierre. */
SELECT Anio, Bimestre, NombreBimestre, MIN(Fecha) AS Desde, MAX(Fecha) AS Hasta,
       SUM(CAST(EsCierreBimestre AS INT)) AS Cierres
FROM dw.DimTiempo WHERE EsFilaEspecial = 0 AND Anio IN (2025, 2026)
GROUP BY Anio, Bimestre, NombreBimestre ORDER BY Anio, MIN(Fecha);

/* Pruebas de integridad: las tres consultas deben devolver cero */
SELECT 'Claves que aun tienen basura invisible' AS Prueba, COUNT(*) AS Filas
FROM dw.DimEstudiante
WHERE CodigoEstudiante LIKE N'%' + NCHAR(160) + N'%'
   OR DATALENGTH(CodigoEstudiante) <> DATALENGTH(LTRIM(RTRIM(CodigoEstudiante)))
UNION ALL
SELECT 'Valores de sexo distintos de M, F o N', COUNT(*)
FROM dw.DimEstudiante WHERE Sexo NOT IN ('M', 'F', 'N')
UNION ALL
SELECT 'Condiciones laborales fuera del catalogo', COUNT(*)
FROM dw.DimDocente
WHERE CondicionLaboral NOT IN (N'Nombrado', N'Contratado', N'No definido', N'No determinado');
GO
