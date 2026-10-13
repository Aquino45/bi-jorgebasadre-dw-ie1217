/* ============================================================================
   ARCHIVO   : 01_staging_secundaria_v5_1.sql
   CAMBIOS v5.1: solo comentarios del encabezado (17 CSV; escala de notas).
   PROYECTO  : DataMart de Gestion Academica - Nivel SECUNDARIA
   INSTITUCION: I.E.P. N 1217 "Jorge Basadre Grohmann" - Chaclacayo, UGEL 06

   PROPOSITO : Crear la base y la capa STAGING, y cargar los 17 archivos CSV
               de la fuente de datos.

   SUSTITUYE a los scripts anteriores 01 a 04. El modelo cambio de raiz por
   tres razones normativas:
     1. El proyecto se acota al nivel SECUNDARIA (ciclos VI y VII).
     2. En secundaria el calificativo oficial es literal (AD / A / B / C).
        El registro de origen trae la nota vigesimal 0-20 por competencia;
        el DataMart la conserva y DERIVA la letra con dw.DimEscalaLogro.
     3. El nivel de logro se registra POR COMPETENCIA, no por area. El
        calificativo del area se DERIVA de sus competencias, lo que cambia
        el grano del hecho de aprendizajes.

   ============================================================================
   PASO PREVIO
   ============================================================================
   1. Copiar la carpeta data\ completa a   C:\BI_IE1217\data
   2. Dar permiso de lectura sobre esa carpeta a  NT Service\MSSQLSERVER
      (clic derecho > Propiedades > Seguridad > Editar > Agregar).
      Si aparece "Operating system error code 5 (Access is denied)", falta
      este paso: el servicio de SQL Server no corre con su usuario de Windows.

   Formato de los archivos: delimitador ';', UTF-8, fin de linea 0x0a,
   encabezados en la primera fila. Si editan un CSV en Excel y lo vuelven a
   guardar, el fin de linea pasa a 0x0d0a y hay que cambiarlo abajo.
   ============================================================================ */

USE master;
GO
IF DB_ID('DW_IE1217') IS NULL CREATE DATABASE DW_IE1217;
GO
USE DW_IE1217;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
GO

/* ============================================================================
   CAPA STAGING
   ----------------------------------------------------------------------------
   Todo NVARCHAR: el staging debe aceptar el archivo tal como llega, incluso
   sucio. La validacion se hace en la transformacion, no aqui. Si el staging
   rechaza una fila, nadie se entera de que el origen esta mal.
   ============================================================================ */

DROP TABLE IF EXISTS stg.Institucion;
DROP TABLE IF EXISTS stg.AreaCurricular;
DROP TABLE IF EXISTS stg.Competencia;
DROP TABLE IF EXISTS stg.Docente;
DROP TABLE IF EXISTS stg.Personal;
DROP TABLE IF EXISTS stg.Seccion;
DROP TABLE IF EXISTS stg.CargaHoraria;
DROP TABLE IF EXISTS stg.Estudiante;
DROP TABLE IF EXISTS stg.Apoderado;
DROP TABLE IF EXISTS stg.Matricula;
DROP TABLE IF EXISTS stg.Asistencia;
DROP TABLE IF EXISTS stg.NotaCompetencia;
DROP TABLE IF EXISTS stg.Sesion;
DROP TABLE IF EXISTS stg.MonitoreoDocente;
DROP TABLE IF EXISTS stg.Convivencia;
DROP TABLE IF EXISTS stg.Material;
DROP TABLE IF EXISTS stg.EntregaMaterial;
GO

CREATE TABLE stg.Institucion (
    CodigoModular NVARCHAR(20), CodigoLocal NVARCHAR(20), NombreIE NVARCHAR(150),
    Nivel NVARCHAR(30), Modalidad NVARCHAR(20), Gestion NVARCHAR(60),
    DRE NVARCHAR(60), UGEL NVARCHAR(60), Departamento NVARCHAR(40),
    Provincia NVARCHAR(40), Distrito NVARCHAR(40), Ubigeo NVARCHAR(10),
    ZonaGeografica NVARCHAR(20), Direccion NVARCHAR(150), Turno NVARCHAR(30),
    JornadaEscolar NVARCHAR(50), HorasPlanEstudios NVARCHAR(10), AnioFundacion NVARCHAR(10),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.AreaCurricular (
    AreaID NVARCHAR(20), NombreArea NVARCHAR(100), Abreviatura NVARCHAR(10),
    HorasSemanales NVARCHAR(10), EsEvaluada NVARCHAR(5),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Competencia (
    CompetenciaID NVARCHAR(20), AreaID NVARCHAR(20),
    NombreCompetencia NVARCHAR(200), TipoCompetencia NVARCHAR(30),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Docente (
    DocenteID NVARCHAR(20), CodigoModular NVARCHAR(20), DNI NVARCHAR(15),
    ApellidoPaterno NVARCHAR(60), ApellidoMaterno NVARCHAR(60), Nombres NVARCHAR(80),
    FechaNacimiento NVARCHAR(30), Sexo NVARCHAR(20), CondicionLaboral NVARCHAR(30),
    EscalaMagisterial NVARCHAR(10), RegimenLaboral NVARCHAR(60),
    AreaCurricularPrincipal NVARCHAR(20), TituloProfesional NVARCHAR(150),
    GradoAcademico NVARCHAR(30), UniversidadEgreso NVARCHAR(120),
    FechaIngresoIE NVARCHAR(30), AnosServicio NVARCHAR(10),
    HorasJornadaSemanal NVARCHAR(10), Telefono NVARCHAR(20), SituacionLaboral NVARCHAR(30),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Personal (
    PersonalID NVARCHAR(20), DNI NVARCHAR(15), ApellidoPaterno NVARCHAR(60),
    ApellidoMaterno NVARCHAR(60), Nombres NVARCHAR(80), Sexo NVARCHAR(20),
    Cargo NVARCHAR(80), TipoPersonal NVARCHAR(30), CondicionLaboral NVARCHAR(30),
    FechaIngresoIE NVARCHAR(30),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Seccion (
    SeccionID NVARCHAR(30), Anio NVARCHAR(10), Grado NVARCHAR(10), Seccion NVARCHAR(10),
    Ciclo NVARCHAR(10), Turno NVARCHAR(20), Aforo NVARCHAR(10),
    DocenteTutorID NVARCHAR(20), Ambiente NVARCHAR(80),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.CargaHoraria (
    Anio NVARCHAR(10), DocenteID NVARCHAR(20), AreaID NVARCHAR(20),
    SeccionID NVARCHAR(30), HorasSemanales NVARCHAR(10),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Estudiante (
    CodigoEstudiante NVARCHAR(20), DNI NVARCHAR(15), ApellidoPaterno NVARCHAR(60),
    ApellidoMaterno NVARCHAR(60), Nombres NVARCHAR(80), FechaNacimiento NVARCHAR(30),
    Sexo NVARCHAR(20), LenguaMaterna NVARCHAR(40), Religion NVARCHAR(40),
    TipoSeguro NVARCHAR(30), TieneDiscapacidad NVARCHAR(5), TipoDiscapacidad NVARCHAR(40),
    Direccion NVARCHAR(150), Distrito NVARCHAR(50), Ubigeo NVARCHAR(10),
    ZonaResidencia NVARCHAR(20), MedioTransporte NVARCHAR(40),
    TiempoTrasladoMin NVARCHAR(10), ViveCon NVARCHAR(50), NumeroHermanos NVARCHAR(10),
    TieneInternetHogar NVARCHAR(5), AnioIngresoIE NVARCHAR(10), IEProcedencia NVARCHAR(120),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Apoderado (
    CodigoEstudiante NVARCHAR(20), DNI NVARCHAR(15), ApellidoPaterno NVARCHAR(60),
    ApellidoMaterno NVARCHAR(60), Nombres NVARCHAR(80), Sexo NVARCHAR(20),
    Parentesco NVARCHAR(40), GradoInstruccion NVARCHAR(50), Ocupacion NVARCHAR(50),
    Telefono NVARCHAR(20), EsApoderadoPrincipal NVARCHAR(5), ViveConEstudiante NVARCHAR(5),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

/* Las cuatro fechas siguen el cronograma oficial del proceso regular de
   matricula del Minedu. OJO: ViaMatricula distingue dos recorridos distintos.
     'Solicitud de vacante'        -> ingresantes y traslados. Pasan por las
         cuatro fases: solicitud, revision, asignacion y registro en SIAGIE.
     'Ratificacion de continuidad' -> continuadores y repitentes. La norma dice
         que quien sigue en el mismo colegio NO repite la inscripcion: el
         apoderado solo comunica la continuidad. Por eso sus tres primeras
         fechas vienen VACIAS, y eso no es un dato faltante. */
CREATE TABLE stg.Matricula (
    MatriculaID NVARCHAR(30), Anio NVARCHAR(10), CodigoEstudiante NVARCHAR(20),
    SeccionID NVARCHAR(30), Grado NVARCHAR(10), Seccion NVARCHAR(10),
    TipoMatricula NVARCHAR(30), ViaMatricula NVARCHAR(40), FaseProceso NVARCHAR(20),
    FechaSolicitud NVARCHAR(30), FechaRevision NVARCHAR(30),
    FechaAsignacionVacante NVARCHAR(30), FechaRegistroSiagie NVARCHAR(30),
    /* Solo dos estados: Aprobado o Rechazado. Observacion se llena UNICAMENTE
       cuando la matricula fue rechazada, y dice por que. Una matricula
       rechazada no genera asistencia, notas ni casos de convivencia: ese
       estudiante nunca curso el ano en la IE. */
    EstadoMatricula NVARCHAR(30), Observacion NVARCHAR(120),
    TipoVacante NVARCHAR(30),
    NumeroConstanciaTraslado NVARCHAR(30), ResponsableMatriculaID NVARCHAR(20),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Asistencia (
    Anio NVARCHAR(10), CodigoEstudiante NVARCHAR(20), SeccionID NVARCHAR(30),
    Fecha NVARCHAR(30), SemanaAnio NVARCHAR(10), EstadoAsistencia NVARCHAR(40),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.NotaCompetencia (
    Anio NVARCHAR(10), Bimestre NVARCHAR(10), CodigoEstudiante NVARCHAR(20),
    SeccionID NVARCHAR(30), AreaID NVARCHAR(20), CompetenciaID NVARCHAR(20),
    DocenteID NVARCHAR(20),
    /* NotaVigesimal llega como texto largo a proposito: el origen trae numeros
       ('15'), numeros con coma ('15,0'), letras ('AD') y hasta el comentario
       completo de la norma cuando no hubo evidencia. Si se declara INT, la
       carga falla y no se sabe por que. */
    NotaVigesimal NVARCHAR(120),
    FechaCierreBimestre NVARCHAR(30),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Sesion (
    SesionID NVARCHAR(30), Anio NVARCHAR(10), Bimestre NVARCHAR(10),
    FechaSesion NVARCHAR(30), DocenteID NVARCHAR(20), AreaID NVARCHAR(20),
    SeccionID NVARCHAR(30), UnidadDidactica NVARCHAR(60), TituloSesion NVARCHAR(120),
    HorasPedagogicas NVARCHAR(10), EstadoSesion NVARCHAR(40), MotivoNoDictada NVARCHAR(80),
    MinutosRetraso NVARCHAR(10), RecursosProgramados NVARCHAR(10),
    RecursosUtilizados NVARCHAR(10), UsoRecursoTIC NVARCHAR(5),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.MonitoreoDocente (
    MonitoreoID NVARCHAR(30), Anio NVARCHAR(10), Bimestre NVARCHAR(10),
    FechaVisita NVARCHAR(30), DocenteID NVARCHAR(20), AreaID NVARCHAR(20),
    SeccionID NVARCHAR(30), ObservadorID NVARCHAR(20),
    Rubrica1_Involucra NVARCHAR(10), Rubrica2_Razonamiento NVARCHAR(10),
    Rubrica3_Evalua NVARCHAR(10), Rubrica4_Respeto NVARCHAR(10),
    Rubrica5_Comportamiento NVARCHAR(10), PuntajeTotal NVARCHAR(10),
    NivelDesempeno NVARCHAR(30), RequiereAcompanamiento NVARCHAR(5),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

/* Catalogo de la dotacion oficial del Minedu: un texto escolar y un cuaderno
   de trabajo por area y grado. Titulos reales de las series que el Estado
   imprime y distribuye por UGEL. */
CREATE TABLE stg.Material (
    MaterialID NVARCHAR(20), AreaID NVARCHAR(20), Grado NVARCHAR(10),
    TipoMaterial NVARCHAR(40), TituloMaterial NVARCHAR(150),
    Condicion NVARCHAR(20), Procedencia NVARCHAR(80),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

/* Entrega del material a los estudiantes.
   GRANO: un material, una seccion, un anio.
   El colegio recibe la dotacion DOS SEMANAS antes del inicio de clases y debe
   entregarla el PRIMER DIA. De ahi salen las tres cantidades que pidio el
   negocio: cuanto debio entregarse, cuanto se entrego a tiempo y cuanto a
   destiempo, con el docente de area como responsable.
   Regla madre: ATiempo + Destiempo + NoEntregada = PorEntregar. */
CREATE TABLE stg.EntregaMaterial (
    EntregaID NVARCHAR(30), Anio NVARCHAR(10), SeccionID NVARCHAR(30),
    Grado NVARCHAR(10), Seccion NVARCHAR(10), AreaID NVARCHAR(20),
    DocenteID NVARCHAR(20), MaterialID NVARCHAR(20), TipoMaterial NVARCHAR(40),
    FechaRecepcionIE NVARCHAR(30), FechaEntregaProgramada NVARCHAR(30),
    FechaEntregaEfectiva NVARCHAR(30), CantidadRecibidaIE NVARCHAR(10),
    CantidadPorEntregar NVARCHAR(10), CantidadEntregadaATiempo NVARCHAR(10),
    CantidadEntregadaDestiempo NVARCHAR(10), CantidadNoEntregada NVARCHAR(10),
    DiasRetraso NVARCHAR(10), Observacion NVARCHAR(150),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.Convivencia (
    CasoID NVARCHAR(30), Anio NVARCHAR(10), CodigoEstudiante NVARCHAR(20),
    SeccionID NVARCHAR(30), FechaHecho NVARCHAR(30), FechaRegistro NVARCHAR(30),
    TipoCaso NVARCHAR(80), ReportadoSiseve NVARCHAR(5), DerivadoPor NVARCHAR(50),
    ResponsableAtencionID NVARCHAR(20), FechaAtencion NVARCHAR(30),
    EstadoCaso NVARCHAR(30), SesionesAtencion NVARCHAR(10),
    SeguimientoActivo NVARCHAR(5), FechaCierre NVARCHAR(30),
    FechaCarga DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO

/* ============================================================================
   VISTAS DE CARGA
   ----------------------------------------------------------------------------
   BULK INSERT exige que el archivo tenga exactamente las mismas columnas que
   el destino. Como cada tabla lleva FechaCarga con valor por defecto, se carga
   contra una vista que expone solo las columnas del archivo; SQL Server
   completa FechaCarga solo. No hace falta archivo de formato.
   ============================================================================ */
CREATE OR ALTER VIEW stg.vwc_Institucion AS SELECT CodigoModular, CodigoLocal, NombreIE, Nivel, Modalidad, Gestion, DRE, UGEL, Departamento, Provincia, Distrito, Ubigeo, ZonaGeografica, Direccion, Turno, JornadaEscolar, HorasPlanEstudios, AnioFundacion FROM stg.Institucion;
GO
CREATE OR ALTER VIEW stg.vwc_AreaCurricular AS SELECT AreaID, NombreArea, Abreviatura, HorasSemanales, EsEvaluada FROM stg.AreaCurricular;
GO
CREATE OR ALTER VIEW stg.vwc_Competencia AS SELECT CompetenciaID, AreaID, NombreCompetencia, TipoCompetencia FROM stg.Competencia;
GO
CREATE OR ALTER VIEW stg.vwc_Docente AS SELECT DocenteID, CodigoModular, DNI, ApellidoPaterno, ApellidoMaterno, Nombres, FechaNacimiento, Sexo, CondicionLaboral, EscalaMagisterial, RegimenLaboral, AreaCurricularPrincipal, TituloProfesional, GradoAcademico, UniversidadEgreso, FechaIngresoIE, AnosServicio, HorasJornadaSemanal, Telefono, SituacionLaboral FROM stg.Docente;
GO
CREATE OR ALTER VIEW stg.vwc_Personal AS SELECT PersonalID, DNI, ApellidoPaterno, ApellidoMaterno, Nombres, Sexo, Cargo, TipoPersonal, CondicionLaboral, FechaIngresoIE FROM stg.Personal;
GO
CREATE OR ALTER VIEW stg.vwc_Seccion AS SELECT SeccionID, Anio, Grado, Seccion, Ciclo, Turno, Aforo, DocenteTutorID, Ambiente FROM stg.Seccion;
GO
CREATE OR ALTER VIEW stg.vwc_CargaHoraria AS SELECT Anio, DocenteID, AreaID, SeccionID, HorasSemanales FROM stg.CargaHoraria;
GO
CREATE OR ALTER VIEW stg.vwc_Estudiante AS SELECT CodigoEstudiante, DNI, ApellidoPaterno, ApellidoMaterno, Nombres, FechaNacimiento, Sexo, LenguaMaterna, Religion, TipoSeguro, TieneDiscapacidad, TipoDiscapacidad, Direccion, Distrito, Ubigeo, ZonaResidencia, MedioTransporte, TiempoTrasladoMin, ViveCon, NumeroHermanos, TieneInternetHogar, AnioIngresoIE, IEProcedencia FROM stg.Estudiante;
GO
CREATE OR ALTER VIEW stg.vwc_Apoderado AS SELECT CodigoEstudiante, DNI, ApellidoPaterno, ApellidoMaterno, Nombres, Sexo, Parentesco, GradoInstruccion, Ocupacion, Telefono, EsApoderadoPrincipal, ViveConEstudiante FROM stg.Apoderado;
GO
CREATE OR ALTER VIEW stg.vwc_Matricula AS SELECT MatriculaID, Anio, CodigoEstudiante, SeccionID, Grado, Seccion, TipoMatricula, ViaMatricula, FaseProceso, FechaSolicitud, FechaRevision, FechaAsignacionVacante, FechaRegistroSiagie, EstadoMatricula, Observacion, TipoVacante, NumeroConstanciaTraslado, ResponsableMatriculaID FROM stg.Matricula;
GO
CREATE OR ALTER VIEW stg.vwc_Asistencia AS SELECT Anio, CodigoEstudiante, SeccionID, Fecha, SemanaAnio, EstadoAsistencia FROM stg.Asistencia;
GO
CREATE OR ALTER VIEW stg.vwc_NotaCompetencia AS SELECT Anio, Bimestre, CodigoEstudiante, SeccionID, AreaID, CompetenciaID, DocenteID, NotaVigesimal, FechaCierreBimestre FROM stg.NotaCompetencia;
GO
CREATE OR ALTER VIEW stg.vwc_Sesion AS SELECT SesionID, Anio, Bimestre, FechaSesion, DocenteID, AreaID, SeccionID, UnidadDidactica, TituloSesion, HorasPedagogicas, EstadoSesion, MotivoNoDictada, MinutosRetraso, RecursosProgramados, RecursosUtilizados, UsoRecursoTIC FROM stg.Sesion;
GO
CREATE OR ALTER VIEW stg.vwc_MonitoreoDocente AS SELECT MonitoreoID, Anio, Bimestre, FechaVisita, DocenteID, AreaID, SeccionID, ObservadorID, Rubrica1_Involucra, Rubrica2_Razonamiento, Rubrica3_Evalua, Rubrica4_Respeto, Rubrica5_Comportamiento, PuntajeTotal, NivelDesempeno, RequiereAcompanamiento FROM stg.MonitoreoDocente;
GO
CREATE OR ALTER VIEW stg.vwc_Material AS SELECT MaterialID, AreaID, Grado, TipoMaterial, TituloMaterial, Condicion, Procedencia FROM stg.Material;
GO
CREATE OR ALTER VIEW stg.vwc_EntregaMaterial AS SELECT EntregaID, Anio, SeccionID, Grado, Seccion, AreaID, DocenteID, MaterialID, TipoMaterial, FechaRecepcionIE, FechaEntregaProgramada, FechaEntregaEfectiva, CantidadRecibidaIE, CantidadPorEntregar, CantidadEntregadaATiempo, CantidadEntregadaDestiempo, CantidadNoEntregada, DiasRetraso, Observacion FROM stg.EntregaMaterial;
GO
CREATE OR ALTER VIEW stg.vwc_Convivencia AS SELECT CasoID, Anio, CodigoEstudiante, SeccionID, FechaHecho, FechaRegistro, TipoCaso, ReportadoSiseve, DerivadoPor, ResponsableAtencionID, FechaAtencion, EstadoCaso, SesionesAtencion, SeguimientoActivo, FechaCierre FROM stg.Convivencia;
GO

/* ============================================================================
   INGESTA
   ============================================================================ */
BULK INSERT stg.vwc_Institucion      FROM 'C:\BI_IE1217\data\institucion.csv'          WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_AreaCurricular   FROM 'C:\BI_IE1217\data\areas_curriculares.csv'   WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Competencia      FROM 'C:\BI_IE1217\data\competencias.csv'         WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Docente          FROM 'C:\BI_IE1217\data\docentes.csv'             WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Personal         FROM 'C:\BI_IE1217\data\personal.csv'             WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Seccion          FROM 'C:\BI_IE1217\data\secciones.csv'            WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_CargaHoraria     FROM 'C:\BI_IE1217\data\carga_horaria.csv'        WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Estudiante       FROM 'C:\BI_IE1217\data\estudiantes.csv'          WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Apoderado        FROM 'C:\BI_IE1217\data\apoderados.csv'           WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Matricula        FROM 'C:\BI_IE1217\data\matricula.csv'            WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Asistencia       FROM 'C:\BI_IE1217\data\asistencia.csv'           WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_NotaCompetencia  FROM 'C:\BI_IE1217\data\notas_competencias.csv'   WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Sesion           FROM 'C:\BI_IE1217\data\sesiones.csv'             WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_MonitoreoDocente FROM 'C:\BI_IE1217\data\monitoreo_docente.csv'    WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Material         FROM 'C:\BI_IE1217\data\materiales.csv'           WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_EntregaMaterial  FROM 'C:\BI_IE1217\data\entrega_materiales.csv'   WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
BULK INSERT stg.vwc_Convivencia      FROM 'C:\BI_IE1217\data\convivencia.csv'          WITH (FIRSTROW=2, FIELDTERMINATOR=';', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK, MAXERRORS=0);
GO

/* ============================================================================
   VERIFICACION
   ============================================================================ */
SELECT Tabla, Filas, Esperadas,
       CASE WHEN Filas = Esperadas THEN 'OK' ELSE 'REVISAR' END AS Estado
FROM (
    SELECT 'Institucion' AS Tabla, COUNT(*) AS Filas,     1 AS Esperadas FROM stg.Institucion
    UNION ALL SELECT 'AreaCurricular',    COUNT(*),      11 FROM stg.AreaCurricular
    UNION ALL SELECT 'Competencia',       COUNT(*),      28 FROM stg.Competencia
    UNION ALL SELECT 'Docente',           COUNT(*),      15 FROM stg.Docente
    UNION ALL SELECT 'Personal',          COUNT(*),       7 FROM stg.Personal
    UNION ALL SELECT 'Seccion',           COUNT(*),      20 FROM stg.Seccion
    UNION ALL SELECT 'CargaHoraria',      COUNT(*),     220 FROM stg.CargaHoraria
    UNION ALL SELECT 'Estudiante',        COUNT(*),     379 FROM stg.Estudiante
    UNION ALL SELECT 'Apoderado',         COUNT(*),     369 FROM stg.Apoderado
    UNION ALL SELECT 'Matricula',         COUNT(*),     615 FROM stg.Matricula
    UNION ALL SELECT 'Asistencia',        COUNT(*),   90745 FROM stg.Asistencia
    UNION ALL SELECT 'NotaCompetencia',   COUNT(*),   45396 FROM stg.NotaCompetencia
    UNION ALL SELECT 'Sesion',            COUNT(*),    6425 FROM stg.Sesion
    UNION ALL SELECT 'MonitoreoDocente',  COUNT(*),      88 FROM stg.MonitoreoDocente
    UNION ALL SELECT 'Material',          COUNT(*),      50 FROM stg.Material
    UNION ALL SELECT 'EntregaMaterial',   COUNT(*),     200 FROM stg.EntregaMaterial
    UNION ALL SELECT 'Convivencia',       COUNT(*),     736 FROM stg.Convivencia
) x
ORDER BY Estado DESC, Tabla;

/* Primera mirada al estado real del origen.
   OJO: en una columna que deberia tener numeros del 0 al 20 van a aparecer
   comas decimales, ceros a la izquierda, letras de la escala literal, textos
   como 'QUINCE' y el comentario completo de la norma. Eso NO es un error de
   carga: asi llega el archivo. Depurarlo es trabajo de la transformacion.
   El script 02_diagnostico_calidad.sql cuantifica todo esto. */
SELECT TOP (25) NotaVigesimal AS ValorRecibido, COUNT(*) AS Registros
FROM stg.NotaCompetencia
GROUP BY NotaVigesimal
ORDER BY Registros DESC;

/* Cuantos NO son un numero valido del 0 al 20 */
SELECT
    COUNT(*) AS Total,
    SUM(CASE WHEN TRY_CONVERT(DECIMAL(5,2), REPLACE(LTRIM(RTRIM(NotaVigesimal)), N',', N'.'))
                  BETWEEN 0 AND 20 THEN 1 ELSE 0 END) AS NotasUtilizables,
    SUM(CASE WHEN TRY_CONVERT(DECIMAL(5,2), REPLACE(LTRIM(RTRIM(NotaVigesimal)), N',', N'.'))
                  BETWEEN 0 AND 20 THEN 0 ELSE 1 END) AS RequierenTratamiento
FROM stg.NotaCompetencia;
GO
