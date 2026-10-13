/* ============================================================================
   03_dimensiones.sql
   CAMBIOS RESPECTO A v5.1 (13/10/2026):
   - dw.DimCompetencia ya NO tiene AreaKey ni la FK FK_DimComp_Area hacia
     dw.DimArea. Motivo: modelo en estrella; las dimensiones no se relacionan
     entre si. Se conservan AreaID y NombreArea (desnormalizados).
   - Sobre una base ya cargada con v5.1, el bloque v5.2 elimina la FK y la
     columna. El resto de dimensiones no cambia.
   - El script 06 v5.2 compara el area de la competencia por AreaID.
   Orden: 03 v5.2 y luego 06 v5.2. No se cambian 01, 02, 04 ni 05.
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
               Las fechas y periodos se limitan al calendario 2024-2027 y a
               los bimestres declarados abajo; extenderlos si cambia el corte.

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
   No eliminar dimensiones: los hechos existentes hacen referencia a sus
   claves sustitutas. Los miembros que ya no lleguen en staging se conservan
   por si aun los usan hechos historicos.
   ---------------------------------------------------------------------------- */

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
    Fecha            DATE         NULL,
    Anio             SMALLINT     NULL,
    Mes              TINYINT      NULL,
    NombreMes        NVARCHAR(15) NULL,
    Dia              TINYINT      NULL,
    NumeroDiaSemana  TINYINT      NULL,
    NombreDiaSemana  NVARCHAR(15) NULL,
    EsDiaHabil       BIT          NULL,
    EsPeriodoEscolar BIT          NULL,  -- indicador aproximado por mes; no reemplaza el calendario lectivo
    Bimestre         TINYINT      NULL,
    NombreBimestre   NVARCHAR(20) NULL,
    EsFilaEspecial   BIT          NOT NULL DEFAULT 0,
    CONSTRAINT PK_DimTiempo PRIMARY KEY CLUSTERED (TiempoKey)
);
END;
GO

/* Compatibilidad con DimTiempo creada por una version anterior del proyecto.
   Agregar la columna no modifica TiempoKey ni rompe las FK de los hechos.
   GO separa el ALTER del INSERT que usa EsFilaEspecial: SQL Server debe
   compilar ese INSERT despues de reconocer la columna nueva. */
IF OBJECT_ID('dw.DimTiempo', 'U') IS NOT NULL
   AND COL_LENGTH('dw.DimTiempo', 'EsFilaEspecial') IS NULL
BEGIN
    ALTER TABLE dw.DimTiempo
    ADD EsFilaEspecial BIT NOT NULL
        CONSTRAINT DF_DimTiempo_EsFilaEspecial DEFAULT (0) WITH VALUES;
END;
GO

/* Miembros especiales */
INSERT INTO dw.DimTiempo (TiempoKey, NombreMes, NombreBimestre, NombreDiaSemana, EsFilaEspecial)
SELECT v.TiempoKey, v.Nombre, v.Nombre, v.Nombre, 1
FROM (VALUES (-1, N'No aplica'), (-2, N'No registrado')) AS v(TiempoKey, Nombre)
WHERE NOT EXISTS (SELECT 1 FROM dw.DimTiempo t WHERE t.TiempoKey = v.TiempoKey);

/* Si los miembros especiales ya existian, tambien deben quedar marcados. */
UPDATE dw.DimTiempo SET EsFilaEspecial = 1
WHERE TiempoKey IN (-1, -2) AND EsFilaEspecial <> 1;

/* Calendario 2024-2027.
   El dia de la semana se calcula con DATEDIFF desde 1900-01-01 (que fue lunes)
   en lugar de DATEPART(WEEKDAY), porque este ultimo depende del SET DATEFIRST
   de la sesion y daria un resultado distinto en otra maquina. */
;WITH Calendario AS (
    SELECT CAST('2024-01-01' AS DATE) AS F
    UNION ALL SELECT DATEADD(DAY, 1, F) FROM Calendario WHERE F < '2027-12-31'
)
INSERT INTO dw.DimTiempo
    (TiempoKey, Fecha, Anio, Mes, NombreMes, Dia, NumeroDiaSemana, NombreDiaSemana,
     EsDiaHabil, EsPeriodoEscolar, Bimestre, NombreBimestre, EsFilaEspecial)
SELECT
    CONVERT(INT, FORMAT(F, 'yyyyMMdd')), F, YEAR(F), MONTH(F),
    CASE MONTH(F) WHEN 1 THEN N'Enero' WHEN 2 THEN N'Febrero' WHEN 3 THEN N'Marzo'
                  WHEN 4 THEN N'Abril' WHEN 5 THEN N'Mayo'    WHEN 6 THEN N'Junio'
                  WHEN 7 THEN N'Julio' WHEN 8 THEN N'Agosto'  WHEN 9 THEN N'Setiembre'
                  WHEN 10 THEN N'Octubre' WHEN 11 THEN N'Noviembre' ELSE N'Diciembre' END,
    DAY(F),
    (DATEDIFF(DAY, '19000101', F) % 7) + 1,
    CASE (DATEDIFF(DAY, '19000101', F) % 7)
        WHEN 0 THEN N'Lunes'  WHEN 1 THEN N'Martes' WHEN 2 THEN N'Miercoles'
        WHEN 3 THEN N'Jueves' WHEN 4 THEN N'Viernes' WHEN 5 THEN N'Sabado'
        ELSE N'Domingo' END,
    CASE WHEN (DATEDIFF(DAY, '19000101', F) % 7) <= 4 THEN 1 ELSE 0 END,
    CASE WHEN MONTH(F) BETWEEN 3 AND 12 THEN 1 ELSE 0 END,
    CASE WHEN MONTH(F) BETWEEN 3 AND 5  THEN 1
         WHEN MONTH(F) BETWEEN 6 AND 7  THEN 2
         WHEN MONTH(F) BETWEEN 8 AND 9  THEN 3
         WHEN MONTH(F) BETWEEN 10 AND 12 THEN 4 ELSE 0 END,
    CASE WHEN MONTH(F) BETWEEN 3 AND 5  THEN N'I Bimestre'
         WHEN MONTH(F) BETWEEN 6 AND 7  THEN N'II Bimestre'
         WHEN MONTH(F) BETWEEN 8 AND 9  THEN N'III Bimestre'
         WHEN MONTH(F) BETWEEN 10 AND 12 THEN N'IV Bimestre' ELSE N'Vacaciones' END,
    0
FROM Calendario
WHERE NOT EXISTS (SELECT 1 FROM dw.DimTiempo t
                  WHERE t.TiempoKey = CONVERT(INT, FORMAT(F, 'yyyyMMdd')))
OPTION (MAXRECURSION 0);
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
    DNI                NVARCHAR(15)  NULL,
    ApellidoPaterno    NVARCHAR(60)  NULL,
    ApellidoMaterno    NVARCHAR(60)  NULL,
    Nombres            NVARCHAR(80)  NULL,
    NombreCompleto     AS (ApellidoPaterno + N' ' + ApellidoMaterno + N', ' + Nombres),
    Sexo               CHAR(1)       NULL,
    FechaNacimiento    DATE          NULL,
    LenguaMaterna      NVARCHAR(40)  NULL,
    Religion           NVARCHAR(40)  NULL,
    TipoSeguro         NVARCHAR(30)  NULL,
    TieneDiscapacidad  BIT           NULL,
    TipoDiscapacidad   NVARCHAR(40)  NULL,
    Distrito           NVARCHAR(50)  NULL,
    ZonaResidencia     NVARCHAR(20)  NULL,
    MedioTransporte    NVARCHAR(40)  NULL,
    TiempoTrasladoMin  SMALLINT      NULL,
    ViveCon            NVARCHAR(50)  NULL,
    NumeroHermanos     TINYINT       NULL,
    TieneInternetHogar BIT           NULL,
    DniValido          BIT           NOT NULL,   -- bandera de calidad
    FechaActualizacion DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_DimEstudiante PRIMARY KEY CLUSTERED (EstudianteKey),
    CONSTRAINT UQ_DimEstudiante UNIQUE (CodigoEstudiante)
);
END;
GO

SET IDENTITY_INSERT dw.DimEstudiante ON;
INSERT INTO dw.DimEstudiante (EstudianteKey, CodigoEstudiante, ApellidoPaterno,
                              ApellidoMaterno, Nombres, Sexo, DniValido)
SELECT -1, N'N/D', N'No', N'Definido', N'No definido', 'N', 0
WHERE NOT EXISTS (SELECT 1 FROM dw.DimEstudiante WHERE EstudianteKey = -1);
SET IDENTITY_INSERT dw.DimEstudiante OFF;
GO

;WITH Limpio AS (
    SELECT
        LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(CodigoEstudiante, NCHAR(160), N''),
                            CHAR(9), N''), CHAR(13), N''))) AS Cod,
        /* El DNI puede venir con puntos, con guiones o sin el cero inicial */
        /* Mas de 8 digitos NO se recorta: se guarda tal cual y DniValido = 0 */
        CASE WHEN NULLIF(LTRIM(RTRIM(DNI)), N'') IS NULL THEN NULL
             WHEN LEN(REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N'')) > 8
                  THEN REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N'')
             ELSE RIGHT(N'00000000' + REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N''), 8)
        END AS Dni,
        /* 'Ã±' es una ñ mal codificada: se restaura la letra real */
        REPLACE(REPLACE(LTRIM(RTRIM(ApellidoPaterno)), N'Ã±', N'ñ'), N'  ', N' ') AS ApePat,
        REPLACE(REPLACE(LTRIM(RTRIM(ApellidoMaterno)), N'Ã±', N'ñ'), N'  ', N' ') AS ApeMat,
        REPLACE(REPLACE(LTRIM(RTRIM(Nombres)), N'Ã±', N'ñ'), N'  ', N' ')         AS Noms,
        /* Seis escrituras distintas de sexo -> M / F / N */
        CASE WHEN UPPER(LTRIM(Sexo)) IN (N'M', N'MASCULINO', N'H', N'1') THEN 'M'
             WHEN UPPER(LTRIM(Sexo)) IN (N'F', N'FEMENINO', N'MUJER', N'2') THEN 'F'
             ELSE 'N' END AS Sx,
        /* Cinco formatos de fecha; el orden importa porque 103 (dd/mm) y 101
           (mm/dd) son ambiguos entre si: se prueba primero el peruano */
        COALESCE(TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 103),
                 TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 105),
                 TRY_CONVERT(DATE, LEFT(LTRIM(RTRIM(FechaNacimiento)), 10), 23),
                 TRY_CONVERT(DATE, LTRIM(RTRIM(FechaNacimiento)), 101)) AS FNac,
        LTRIM(RTRIM(LenguaMaterna)) AS Lengua,
        LTRIM(RTRIM(Religion))      AS Relig,
        LTRIM(RTRIM(TipoSeguro))    AS Seguro,
        TRY_CONVERT(BIT, LTRIM(RTRIM(TieneDiscapacidad))) AS Discap,
        NULLIF(LTRIM(RTRIM(TipoDiscapacidad)), N'')       AS TipoDiscap,
        /* Catalogo cerrado de distritos, con el typo incluido */
        CASE
            WHEN UPPER(LTRIM(RTRIM(Distrito))) IN (N'CHACLACAYO', N'CHACLAYO') THEN N'Chaclacayo'
            WHEN UPPER(LTRIM(RTRIM(Distrito))) LIKE N'%CHOSICA%'
              OR UPPER(LTRIM(RTRIM(Distrito))) LIKE N'%LURIGANCHO%'           THEN N'Lurigancho-Chosica'
            WHEN UPPER(LTRIM(RTRIM(Distrito))) LIKE N'ATE%'                   THEN N'Ate'
            ELSE N'No determinado' END AS Distr,
        LTRIM(RTRIM(ZonaResidencia))  AS Zona,
        LTRIM(RTRIM(MedioTransporte)) AS Transp,
        CASE WHEN TRY_CONVERT(SMALLINT, TiempoTrasladoMin) BETWEEN 0 AND 180
             THEN TRY_CONVERT(SMALLINT, TiempoTrasladoMin) END AS Traslado,
        LTRIM(RTRIM(ViveCon)) AS Vive,
        CASE WHEN TRY_CONVERT(TINYINT, NumeroHermanos) BETWEEN 0 AND 15
             THEN TRY_CONVERT(TINYINT, NumeroHermanos) END AS Herm,
        TRY_CONVERT(BIT, LTRIM(RTRIM(TieneInternetHogar))) AS Internet,
        FechaCarga
    FROM stg.Estudiante
    WHERE NULLIF(LTRIM(RTRIM(CodigoEstudiante)), N'') IS NOT NULL
),
/* Duplicidad de padron: se conserva UNA fila por codigo.
   Todas las filas de un BULK INSERT reciben la misma FechaCarga, asi que
   ordenar solo por ella deja la eleccion al azar y cada reejecucion podria
   guardar otra version. Se prefiere la fila MAS COMPLETA y, al final, un
   orden alfabetico fijo para que el resultado sea siempre el mismo. */
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
USING (SELECT * FROM Unico WHERE rn = 1) AS o
ON d.CodigoEstudiante = o.Cod
WHEN MATCHED THEN UPDATE SET
    d.DNI = o.Dni, d.ApellidoPaterno = o.ApePat, d.ApellidoMaterno = o.ApeMat,
    d.Nombres = o.Noms, d.Sexo = o.Sx, d.FechaNacimiento = o.FNac,
    d.LenguaMaterna = o.Lengua, d.Religion = o.Relig, d.TipoSeguro = o.Seguro,
    d.TieneDiscapacidad = o.Discap, d.TipoDiscapacidad = o.TipoDiscap,
    d.Distrito = o.Distr, d.ZonaResidencia = o.Zona, d.MedioTransporte = o.Transp,
    d.TiempoTrasladoMin = o.Traslado, d.ViveCon = o.Vive, d.NumeroHermanos = o.Herm,
    d.TieneInternetHogar = o.Internet,
    d.DniValido = CASE WHEN o.Dni IS NOT NULL AND
        o.Dni LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN 1 ELSE 0 END,
    d.FechaActualizacion = SYSDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CodigoEstudiante, DNI, ApellidoPaterno, ApellidoMaterno, Nombres, Sexo,
            FechaNacimiento, LenguaMaterna, Religion, TipoSeguro, TieneDiscapacidad,
            TipoDiscapacidad, Distrito, ZonaResidencia, MedioTransporte,
            TiempoTrasladoMin, ViveCon, NumeroHermanos, TieneInternetHogar, DniValido)
    VALUES (o.Cod, o.Dni, o.ApePat, o.ApeMat, o.Noms, o.Sx, o.FNac, o.Lengua, o.Relig,
            o.Seguro, o.Discap, o.TipoDiscap, o.Distr, o.Zona, o.Transp, o.Traslado,
            o.Vive, o.Herm, o.Internet,
            CASE WHEN o.Dni IS NOT NULL AND
                o.Dni LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN 1 ELSE 0 END);
GO

/* ============================================================================
   3. DimDocente
   ============================================================================ */
IF OBJECT_ID('dw.DimDocente', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimDocente (
    DocenteKey         INT IDENTITY(1,1) NOT NULL,
    DocenteID          NVARCHAR(20)  NOT NULL,
    CodigoModular      NVARCHAR(20)  NULL,
    DNI                NVARCHAR(15)  NULL,
    ApellidoPaterno    NVARCHAR(60)  NULL,
    ApellidoMaterno    NVARCHAR(60)  NULL,
    Nombres            NVARCHAR(80)  NULL,
    NombreCompleto     AS (ApellidoPaterno + N' ' + ApellidoMaterno + N', ' + Nombres),
    Sexo               CHAR(1)       NULL,
    CondicionLaboral   NVARCHAR(20)  NULL,
    EscalaMagisterial  NVARCHAR(10)  NULL,
    AreaPrincipal      NVARCHAR(20)  NULL,
    GradoAcademico     NVARCHAR(30)  NULL,
    AnosServicio       SMALLINT      NULL,
    SituacionLaboral   NVARCHAR(30)  NULL,
    FechaActualizacion DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_DimDocente PRIMARY KEY CLUSTERED (DocenteKey),
    CONSTRAINT UQ_DimDocente UNIQUE (DocenteID)
);
END;
GO
SET IDENTITY_INSERT dw.DimDocente ON;
INSERT INTO dw.DimDocente (DocenteKey, DocenteID, ApellidoPaterno, ApellidoMaterno,
                           Nombres, Sexo, CondicionLaboral)
SELECT -1, N'N/D', N'No', N'Definido', N'No definido', 'N', N'No definido'
WHERE NOT EXISTS (SELECT 1 FROM dw.DimDocente WHERE DocenteKey = -1);
SET IDENTITY_INSERT dw.DimDocente OFF;
GO

MERGE dw.DimDocente AS d
USING (
    SELECT
        /* La letra O en lugar del cero aparece en DocenteID: se normaliza */
        UPPER(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(DocenteID, NCHAR(160), N''),
                     CHAR(9), N''))), N'DOC-O', N'DOC-0')) AS Did,
        LTRIM(RTRIM(CodigoModular)) AS CodMod,
        CASE WHEN LEN(REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N'')) > 8
                  THEN REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N'')
             ELSE RIGHT(N'00000000' + REPLACE(REPLACE(LTRIM(RTRIM(DNI)), N'.', N''), N'-', N''), 8)
        END AS Dni,
        REPLACE(REPLACE(LTRIM(RTRIM(ApellidoPaterno)), N'Ã±', N'ñ'), N'  ', N' ') AS ApePat,
        REPLACE(REPLACE(LTRIM(RTRIM(ApellidoMaterno)), N'Ã±', N'ñ'), N'  ', N' ') AS ApeMat,
        REPLACE(REPLACE(LTRIM(RTRIM(Nombres)), N'Ã±', N'ñ'), N'  ', N' ')         AS Noms,
        CASE WHEN UPPER(LTRIM(Sexo)) IN (N'M', N'MASCULINO', N'H', N'1') THEN 'M'
             WHEN UPPER(LTRIM(Sexo)) IN (N'F', N'FEMENINO', N'MUJER', N'2') THEN 'F'
             ELSE 'N' END AS Sx,
        /* NOMBRADO / nombrado / Nombrada / Nombrrado -> Nombrado */
        CASE WHEN UPPER(LTRIM(RTRIM(CondicionLaboral))) LIKE N'NOMBR%' THEN N'Nombrado'
             WHEN UPPER(LTRIM(RTRIM(CondicionLaboral))) LIKE N'CONT%'  THEN N'Contratado'
             ELSE N'No determinado' END AS Cond,
        NULLIF(LTRIM(RTRIM(EscalaMagisterial)), N'') AS Escala,
        LTRIM(RTRIM(AreaCurricularPrincipal))        AS Area,
        LTRIM(RTRIM(GradoAcademico))                 AS Grado,
        CASE WHEN TRY_CONVERT(SMALLINT, AnosServicio) BETWEEN 0 AND 45
             THEN TRY_CONVERT(SMALLINT, AnosServicio) END AS Anios,
        LTRIM(RTRIM(SituacionLaboral)) AS Situacion
    FROM stg.Docente
    WHERE NULLIF(LTRIM(RTRIM(DocenteID)), N'') IS NOT NULL
) AS o
ON d.DocenteID = o.Did
WHEN MATCHED THEN UPDATE SET
    d.CodigoModular = o.CodMod, d.DNI = o.Dni, d.ApellidoPaterno = o.ApePat,
    d.ApellidoMaterno = o.ApeMat, d.Nombres = o.Noms, d.Sexo = o.Sx,
    d.CondicionLaboral = o.Cond, d.EscalaMagisterial = o.Escala,
    d.AreaPrincipal = o.Area, d.GradoAcademico = o.Grado, d.AnosServicio = o.Anios,
    d.SituacionLaboral = o.Situacion, d.FechaActualizacion = SYSDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DocenteID, CodigoModular, DNI, ApellidoPaterno, ApellidoMaterno, Nombres,
            Sexo, CondicionLaboral, EscalaMagisterial, AreaPrincipal, GradoAcademico,
            AnosServicio, SituacionLaboral)
    VALUES (o.Did, o.CodMod, o.Dni, o.ApePat, o.ApeMat, o.Noms, o.Sx, o.Cond, o.Escala,
            o.Area, o.Grado, o.Anios, o.Situacion);
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
    Grado        TINYINT       NULL,
    Seccion      NVARCHAR(5)   NULL,
    Ciclo        NVARCHAR(20)  NULL,
    NombreGrado  NVARCHAR(30)  NULL,
    Turno        NVARCHAR(20)  NULL,
    Aforo        SMALLINT      NULL,
    CONSTRAINT PK_DimSeccion PRIMARY KEY CLUSTERED (SeccionKey),
    CONSTRAINT UQ_DimSeccion UNIQUE (CodigoCorto)
);
END;
GO
/* Base creada con la v5: la columna medía 10 y el miembro -1 no entraba.
   COL_LENGTH devuelve bytes: NVARCHAR(20) = 40. */
IF COL_LENGTH('dw.DimSeccion', 'Ciclo') < 40
    ALTER TABLE dw.DimSeccion ALTER COLUMN Ciclo NVARCHAR(20) NULL;
GO
SET IDENTITY_INSERT dw.DimSeccion ON;
INSERT INTO dw.DimSeccion (SeccionKey, CodigoCorto, Grado, Seccion, Ciclo, NombreGrado, Aforo)
SELECT -1, N'N/D', 0, N'X', N'No definido', N'No definido', 0
WHERE NOT EXISTS (SELECT 1 FROM dw.DimSeccion WHERE SeccionKey = -1);
SET IDENTITY_INSERT dw.DimSeccion OFF;
GO

/* Si una seccion aparece en varios anios se toma su descripcion mas reciente
   (SCD tipo 1). El aforo historico, si cambia, corresponde al hecho anual. */
;WITH s AS (
    SELECT TRY_CONVERT(TINYINT, LTRIM(RTRIM(Grado))) AS Grado,
           UPPER(LTRIM(RTRIM(Seccion))) AS Seccion,
           LTRIM(RTRIM(Ciclo)) AS Ciclo,
           LTRIM(RTRIM(Turno)) AS Turno,
           TRY_CONVERT(SMALLINT, LTRIM(RTRIM(Aforo))) AS Aforo,
           ROW_NUMBER() OVER (
               PARTITION BY TRY_CONVERT(TINYINT, LTRIM(RTRIM(Grado))), UPPER(LTRIM(RTRIM(Seccion)))
               ORDER BY TRY_CONVERT(SMALLINT, Anio) DESC, SeccionID DESC
           ) AS rn
    FROM stg.Seccion
)
MERGE dw.DimSeccion AS d
USING (
    SELECT CAST(Grado AS NVARCHAR(3)) + Seccion AS CodigoCorto,
           Grado, Seccion, Ciclo, Turno, Aforo,
           CASE Grado WHEN 1 THEN N'Primero de secundaria' WHEN 2 THEN N'Segundo de secundaria'
                      WHEN 3 THEN N'Tercero de secundaria' WHEN 4 THEN N'Cuarto de secundaria'
                      ELSE N'Quinto de secundaria' END AS NombreGrado
    FROM s WHERE rn = 1 AND Grado BETWEEN 1 AND 5 AND Seccion IS NOT NULL AND Seccion <> N''
) AS o ON d.CodigoCorto = o.CodigoCorto
WHEN MATCHED THEN UPDATE SET
    d.Grado = o.Grado, d.Seccion = o.Seccion, d.Ciclo = o.Ciclo,
    d.NombreGrado = o.NombreGrado, d.Turno = o.Turno, d.Aforo = o.Aforo
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CodigoCorto, Grado, Seccion, Ciclo, NombreGrado, Turno, Aforo)
    VALUES (o.CodigoCorto, o.Grado, o.Seccion, o.Ciclo, o.NombreGrado, o.Turno, o.Aforo);
GO

/* ============================================================================
   5. DimArea y DimCompetencia
   ----------------------------------------------------------------------------
   DimCompetencia guarda el area DESNORMALIZADA (AreaID y NombreArea como
   columnas propias). NO tiene clave a DimArea: en un modelo estrella las
   dimensiones no se relacionan entre si (v5.2). El area se consulta por texto
   dentro de la propia dimension; la relacion area-hecho vive en
   FacLogroCompetencia.AreaKey.
   ============================================================================ */
IF OBJECT_ID('dw.DimArea', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimArea (
    AreaKey        INT IDENTITY(1,1) NOT NULL,
    AreaID         NVARCHAR(20)  NOT NULL,
    NombreArea     NVARCHAR(100) NULL,
    Abreviatura    NVARCHAR(10)  NULL,
    HorasSemanales TINYINT       NULL,
    EsEvaluada     BIT           NULL,
    CONSTRAINT PK_DimArea PRIMARY KEY CLUSTERED (AreaKey),
    CONSTRAINT UQ_DimArea UNIQUE (AreaID)
);
END;
GO
SET IDENTITY_INSERT dw.DimArea ON;
INSERT INTO dw.DimArea (AreaKey, AreaID, NombreArea, Abreviatura, EsEvaluada)
SELECT -1, N'N/D', N'No definida', N'N/D', 0
WHERE NOT EXISTS (SELECT 1 FROM dw.DimArea WHERE AreaKey = -1);
SET IDENTITY_INSERT dw.DimArea OFF;

MERGE dw.DimArea AS d
USING (
    SELECT LTRIM(RTRIM(AreaID)) AS AreaID, LTRIM(RTRIM(NombreArea)) AS NombreArea,
           LTRIM(RTRIM(Abreviatura)) AS Abreviatura,
           TRY_CONVERT(TINYINT, HorasSemanales) AS HorasSemanales,
           TRY_CONVERT(BIT, EsEvaluada) AS EsEvaluada
    FROM stg.AreaCurricular
    WHERE NULLIF(LTRIM(RTRIM(AreaID)), N'') IS NOT NULL
) AS o ON d.AreaID = o.AreaID
WHEN MATCHED THEN UPDATE SET d.NombreArea = o.NombreArea, d.Abreviatura = o.Abreviatura,
                             d.HorasSemanales = o.HorasSemanales, d.EsEvaluada = o.EsEvaluada
WHEN NOT MATCHED BY TARGET THEN
    INSERT (AreaID, NombreArea, Abreviatura, HorasSemanales, EsEvaluada)
    VALUES (o.AreaID, o.NombreArea, o.Abreviatura, o.HorasSemanales, o.EsEvaluada);
GO

IF OBJECT_ID('dw.DimCompetencia', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimCompetencia (
    CompetenciaKey    INT IDENTITY(1,1) NOT NULL,
    CompetenciaID     NVARCHAR(20)  NOT NULL,
    NombreCompetencia NVARCHAR(200) NULL,
    TipoCompetencia   NVARCHAR(30)  NULL,
    AreaID            NVARCHAR(20)  NULL,       -- desnormalizado (sin FK a DimArea)
    NombreArea        NVARCHAR(100) NULL,       -- desnormalizado
    CONSTRAINT PK_DimCompetencia PRIMARY KEY CLUSTERED (CompetenciaKey),
    CONSTRAINT UQ_DimCompetencia UNIQUE (CompetenciaID)
);
END;
GO
/* v5.2: correccion sobre una base ya cargada con v5.1. Si la tabla aun tiene
   AreaKey y su FK, se eliminan. En una base nueva no hace nada (idempotente). */
IF EXISTS (SELECT 1 FROM sys.foreign_keys
           WHERE name = N'FK_DimComp_Area'
             AND parent_object_id = OBJECT_ID(N'dw.DimCompetencia'))
    ALTER TABLE dw.DimCompetencia DROP CONSTRAINT FK_DimComp_Area;
GO
IF COL_LENGTH(N'dw.DimCompetencia', N'AreaKey') IS NOT NULL
    ALTER TABLE dw.DimCompetencia DROP COLUMN AreaKey;
GO
SET IDENTITY_INSERT dw.DimCompetencia ON;
INSERT INTO dw.DimCompetencia (CompetenciaKey, CompetenciaID, NombreCompetencia,
                               TipoCompetencia, AreaID, NombreArea)
SELECT -1, N'N/D', N'No definida', N'No definida', N'N/D', N'No definida'
WHERE NOT EXISTS (SELECT 1 FROM dw.DimCompetencia WHERE CompetenciaKey = -1);
SET IDENTITY_INSERT dw.DimCompetencia OFF;

MERGE dw.DimCompetencia AS d
USING (
    SELECT LTRIM(RTRIM(c.CompetenciaID)) AS CompetenciaID,
           LTRIM(RTRIM(c.NombreCompetencia)) AS NombreCompetencia,
           LTRIM(RTRIM(c.TipoCompetencia)) AS TipoCompetencia,
           ISNULL(a.AreaID, N'N/D') AS AreaID,
           ISNULL(a.NombreArea, N'No definida') AS NombreArea
    FROM stg.Competencia c
    LEFT JOIN dw.DimArea a ON a.AreaID = LTRIM(RTRIM(c.AreaID))
    WHERE NULLIF(LTRIM(RTRIM(c.CompetenciaID)), N'') IS NOT NULL
) AS o ON d.CompetenciaID = o.CompetenciaID
WHEN MATCHED THEN UPDATE SET
    d.NombreCompetencia = o.NombreCompetencia, d.TipoCompetencia = o.TipoCompetencia,
    d.AreaID = o.AreaID, d.NombreArea = o.NombreArea
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CompetenciaID, NombreCompetencia, TipoCompetencia, AreaID, NombreArea)
    VALUES (o.CompetenciaID, o.NombreCompetencia, o.TipoCompetencia,
            o.AreaID, o.NombreArea);
GO

/* ============================================================================
   6. DimPeriodoAcademico
   ----------------------------------------------------------------------------
   Anio + bimestre. Existe aparte de DimTiempo porque el bimestre es una unidad
   de negocio con la que se compara y se filtra, y porque su fecha de cierre no
   coincide con el corte de mes calendario.
   ============================================================================ */
IF OBJECT_ID('dw.DimPeriodoAcademico', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimPeriodoAcademico (
    PeriodoKey     INT IDENTITY(1,1) NOT NULL,
    AnioEscolar    SMALLINT     NOT NULL,
    Bimestre       TINYINT      NOT NULL,
    NombreBimestre NVARCHAR(20) NULL,
    EtiquetaCorta  AS (CAST(AnioEscolar AS NVARCHAR(4)) + N'-B' + CAST(Bimestre AS NVARCHAR(2))),
    FechaCierre    DATE         NULL,
    EstaCerrado    BIT          NOT NULL,
    CONSTRAINT PK_DimPeriodo PRIMARY KEY CLUSTERED (PeriodoKey),
    CONSTRAINT UQ_DimPeriodo UNIQUE (AnioEscolar, Bimestre)
);
END;
GO
SET IDENTITY_INSERT dw.DimPeriodoAcademico ON;
INSERT INTO dw.DimPeriodoAcademico (PeriodoKey, AnioEscolar, Bimestre, NombreBimestre, EstaCerrado)
SELECT -1, 0, 0, N'No definido', 0
WHERE NOT EXISTS (SELECT 1 FROM dw.DimPeriodoAcademico WHERE PeriodoKey = -1);
SET IDENTITY_INSERT dw.DimPeriodoAcademico OFF;

/* Corte academico del conjunto de datos: 2026 hasta el 15/09. Para una
   recarga con nuevos bimestres, ampliar estas filas y DimTiempo si hace falta. */
MERGE dw.DimPeriodoAcademico AS d
USING (VALUES
    (2025, 1, N'I Bimestre',   CAST('2025-05-23' AS DATE), 1),
    (2025, 2, N'II Bimestre',  CAST('2025-08-01' AS DATE), 1),
    (2025, 3, N'III Bimestre', CAST('2025-10-24' AS DATE), 1),
    (2025, 4, N'IV Bimestre',  CAST('2025-12-19' AS DATE), 1),
    (2026, 1, N'I Bimestre',   CAST('2026-05-22' AS DATE), 1),
    (2026, 2, N'II Bimestre',  CAST('2026-07-31' AS DATE), 1),
    (2026, 3, N'III Bimestre', CAST(NULL AS DATE),         0)
) AS o(AnioEscolar, Bimestre, NombreBimestre, FechaCierre, EstaCerrado)
ON d.AnioEscolar = o.AnioEscolar AND d.Bimestre = o.Bimestre
WHEN MATCHED THEN UPDATE SET
    d.NombreBimestre = o.NombreBimestre, d.FechaCierre = o.FechaCierre,
    d.EstaCerrado = o.EstaCerrado
WHEN NOT MATCHED BY TARGET THEN
    INSERT (AnioEscolar, Bimestre, NombreBimestre, FechaCierre, EstaCerrado)
    VALUES (o.AnioEscolar, o.Bimestre, o.NombreBimestre, o.FechaCierre, o.EstaCerrado);
GO

/* ============================================================================
   7. DimEscalaLogro
   ----------------------------------------------------------------------------
   La conversion vigesimal -> literal vive AQUI y en ningun otro lado. Si
   manana la IE cambia un umbral, se corrige esta tabla y se recarga el hecho:
   no hay que buscar el CASE WHEN repartido por cinco consultas.

   El miembro -1 'Sin evidencia' es la fila donde caen las competencias que la
   norma permite dejar sin nivel. NO son desaprobados y por eso tienen su
   propio miembro en vez de un NULL.
   ============================================================================ */
IF OBJECT_ID('dw.DimEscalaLogro', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimEscalaLogro (
    EscalaKey       INT          NOT NULL,
    NivelLogro      NVARCHAR(10) NOT NULL,
    Descripcion     NVARCHAR(40) NULL,
    NotaDesde       TINYINT      NULL,
    NotaHasta       TINYINT      NULL,
    OrdenJerarquico TINYINT      NULL,
    EsAprobatorio   BIT          NOT NULL,
    CONSTRAINT PK_DimEscalaLogro PRIMARY KEY CLUSTERED (EscalaKey)
);
END;
GO
MERGE dw.DimEscalaLogro AS d
USING (VALUES
    (-1, N'S/E', N'Sin evidencia suficiente', CAST(NULL AS TINYINT), CAST(NULL AS TINYINT), 0, 0),
    ( 1, N'C',   N'En inicio',                    0,   10, 1, 0),
    ( 2, N'B',   N'En proceso',                  11,   13, 2, 1),
    ( 3, N'A',   N'Logro esperado',              14,   17, 3, 1),
    ( 4, N'AD',  N'Logro destacado',             18,   20, 4, 1)
) AS o(EscalaKey, NivelLogro, Descripcion, NotaDesde, NotaHasta, OrdenJerarquico, EsAprobatorio)
ON d.EscalaKey = o.EscalaKey
WHEN MATCHED THEN UPDATE SET
    d.NivelLogro = o.NivelLogro, d.Descripcion = o.Descripcion,
    d.NotaDesde = o.NotaDesde, d.NotaHasta = o.NotaHasta,
    d.OrdenJerarquico = o.OrdenJerarquico, d.EsAprobatorio = o.EsAprobatorio
WHEN NOT MATCHED BY TARGET THEN
    INSERT (EscalaKey, NivelLogro, Descripcion, NotaDesde, NotaHasta, OrdenJerarquico, EsAprobatorio)
    VALUES (o.EscalaKey, o.NivelLogro, o.Descripcion, o.NotaDesde, o.NotaHasta,
            o.OrdenJerarquico, o.EsAprobatorio);
GO

/* ============================================================================
   8. DimTipoMatricula  (dimension "junk")
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
    EsAprobada       BIT          NOT NULL,
    PideVacante      BIT          NOT NULL,
    CONSTRAINT PK_DimTipoMatricula PRIMARY KEY CLUSTERED (TipoMatriculaKey),
    CONSTRAINT UQ_DimTipoMatricula UNIQUE (TipoMatricula, ViaMatricula, FaseProceso, EstadoMatricula)
);
END;
GO
SET IDENTITY_INSERT dw.DimTipoMatricula ON;
INSERT INTO dw.DimTipoMatricula (TipoMatriculaKey, TipoMatricula, ViaMatricula,
                                 FaseProceso, EstadoMatricula, EsAprobada, PideVacante)
SELECT -1, N'No definido', N'No definida', N'No definida', N'No definido', 0, 0
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
    SELECT DISTINCT Tipo, Via, Fase, Estado,
           CASE WHEN Estado = N'Aprobado' THEN 1 ELSE 0 END AS EsAprobada,
           CASE WHEN Via = N'Solicitud de vacante' THEN 1 ELSE 0 END AS PideVacante
    FROM Canonico
)
MERGE dw.DimTipoMatricula AS d
USING Combinaciones AS o
ON d.TipoMatricula = o.Tipo AND d.ViaMatricula = o.Via
   AND d.FaseProceso = o.Fase AND d.EstadoMatricula = o.Estado
WHEN MATCHED THEN UPDATE SET d.EsAprobada = o.EsAprobada, d.PideVacante = o.PideVacante
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TipoMatricula, ViaMatricula, FaseProceso, EstadoMatricula, EsAprobada, PideVacante)
    VALUES (o.Tipo, o.Via, o.Fase, o.Estado, o.EsAprobada, o.PideVacante);
GO

/* ============================================================================
   9. DimMotivoRechazo
   ----------------------------------------------------------------------------
   Solo aplica a las matriculas rechazadas. Las aprobadas apuntan al miembro
   -1 'No aplica', no a NULL: misma logica que los miembros especiales de
   DimTiempo.
   ============================================================================ */
IF OBJECT_ID('dw.DimMotivoRechazo', 'U') IS NULL
BEGIN
CREATE TABLE dw.DimMotivoRechazo (
    MotivoKey    INT IDENTITY(1,1) NOT NULL,
    Motivo       NVARCHAR(150) NOT NULL,
    Categoria    NVARCHAR(40)  NULL,
    EsSubsanable BIT           NULL,
    CONSTRAINT PK_DimMotivoRechazo PRIMARY KEY CLUSTERED (MotivoKey),
    CONSTRAINT UQ_DimMotivoRechazo UNIQUE (Motivo)
);
END;
GO
SET IDENTITY_INSERT dw.DimMotivoRechazo ON;
INSERT INTO dw.DimMotivoRechazo (MotivoKey, Motivo, Categoria, EsSubsanable)
SELECT v.MotivoKey, v.Motivo, v.Categoria, CAST(NULL AS BIT)
FROM (VALUES (-1, N'No aplica', N'No aplica'),
             (-2, N'No registrado', N'Sin dato')) AS v(MotivoKey, Motivo, Categoria)
WHERE NOT EXISTS (SELECT 1 FROM dw.DimMotivoRechazo d WHERE d.MotivoKey = v.MotivoKey);
SET IDENTITY_INSERT dw.DimMotivoRechazo OFF;

/* La categoria permite agrupar en el tablero: lo documentario se subsana, la
   falta de vacante no depende de la familia. */
MERGE dw.DimMotivoRechazo AS d
USING (
    SELECT DISTINCT
        LTRIM(RTRIM(Observacion)) AS Motivo,
        CASE WHEN LTRIM(RTRIM(Observacion)) LIKE N'%vacante%' THEN N'Capacidad de la IE'
             WHEN LTRIM(RTRIM(Observacion)) LIKE N'%plazo%' THEN N'Fuera de cronograma'
             WHEN LTRIM(RTRIM(Observacion)) LIKE N'%otra IE%' THEN N'Duplicidad en SIAGIE'
             WHEN LTRIM(RTRIM(Observacion)) LIKE N'%RENIEC%' THEN N'Identidad'
             ELSE N'Documentaria' END AS Categoria,
        CASE WHEN LTRIM(RTRIM(Observacion)) LIKE N'%vacante%' THEN 0 ELSE 1 END AS EsSubsanable
    FROM stg.Matricula
    WHERE UPPER(LTRIM(RTRIM(EstadoMatricula))) LIKE N'RECHAZ%'
      AND NULLIF(LTRIM(RTRIM(Observacion)), N'') IS NOT NULL
) AS o ON d.Motivo = o.Motivo
WHEN MATCHED THEN UPDATE SET d.Categoria = o.Categoria, d.EsSubsanable = o.EsSubsanable
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Motivo, Categoria, EsSubsanable)
    VALUES (o.Motivo, o.Categoria, o.EsSubsanable);
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
UNION ALL SELECT 'dw.DimPeriodoAcademico', COUNT(*), SUM(CASE WHEN PeriodoKey     < 0 THEN 1 ELSE 0 END) FROM dw.DimPeriodoAcademico
UNION ALL SELECT 'dw.DimEscalaLogro',      COUNT(*), SUM(CASE WHEN EscalaKey      < 0 THEN 1 ELSE 0 END) FROM dw.DimEscalaLogro
UNION ALL SELECT 'dw.DimTipoMatricula',    COUNT(*), SUM(CASE WHEN TipoMatriculaKey < 0 THEN 1 ELSE 0 END) FROM dw.DimTipoMatricula
UNION ALL SELECT 'dw.DimMotivoRechazo',    COUNT(*), SUM(CASE WHEN MotivoKey      < 0 THEN 1 ELSE 0 END) FROM dw.DimMotivoRechazo;

/* Conteos esperados (sin contar miembros especiales):
   DimEstudiante 373 | DimDocente 15 | DimSeccion 10 | DimArea 11
   DimCompetencia 28 | DimPeriodoAcademico 7 | DimEscalaLogro 4
   DimTipoMatricula: pocas decenas | DimMotivoRechazo: 8 o 9 motivos

   Si DimEstudiante trae MAS de 373, la deduplicacion no funciono.
   Si trae MENOS, se perdieron filas: revisar el filtro de codigo vacio.      */

/* v5.2: sin FK, la integridad area-competencia se verifica aqui.
   Cada competencia debe apuntar a un AreaID existente en DimArea. Esperado: 0. */
SELECT 'Competencias con AreaID inexistente en DimArea (esperado 0)' AS Prueba,
       COUNT(*) AS Filas
FROM dw.DimCompetencia AS c
WHERE c.CompetenciaKey <> -1
  AND NOT EXISTS (SELECT 1 FROM dw.DimArea AS a WHERE a.AreaID = c.AreaID);

/* Pruebas de integridad: las cuatro consultas deben devolver cero */
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
WHERE CondicionLaboral NOT IN (N'Nombrado', N'Contratado', N'No definido', N'No determinado')
UNION ALL
SELECT 'DNI vacio marcado como valido', COUNT(*)
FROM dw.DimEstudiante WHERE DNI IS NULL AND DniValido = 1;

/* Cuantos estudiantes traian el DNI mal formado. No se descartan: se marcan,
   para que la secretaria sepa a quien llamar. */
SELECT DniValido, COUNT(*) AS Estudiantes
FROM dw.DimEstudiante WHERE EstudianteKey > 0
GROUP BY DniValido;
GO
