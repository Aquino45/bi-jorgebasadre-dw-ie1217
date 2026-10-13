/* =============================================================================
   07_job_sql_agent_v5_1.sql — AUTOMATIZACION DEL ETL CON SQL SERVER AGENT
   Base: DW_IE1217 | SQL Server 2017 o posterior (no Express: no trae Agente)

   QUE HACE
     1. Crea el esquema ctl con el control de lotes:
          ctl.LoteETL       una fila por corrida (inicio, fin, estado, error)
          ctl.ConteoLote    filas de cada tabla en cada corrida
          ctl.vw_HistorialLotes  vista para revisar las corridas
     2. Crea el job ETL_IE1217_Carga, que ejecuta los scripts 01 a 06 en orden
        y se detiene en el primer error, sin tocar lo que ya estaba publicado
        si el problema aparece antes de los hechos.

   FLUJO DEL JOB
      1 Iniciar lote ........ abre una fila en ctl.LoteETL
      2 01 Staging .......... recarga los 17 CSV
      3 Validar staging ..... FRENO: si una tabla llega vacia o cae mas del 50 %
                              frente a la ultima corrida buena, el job se detiene
                              ANTES de recalcular los hechos (un lote incompleto
                              borraria historia, porque 04-06 son recarga total)
      4 02 Diagnostico ...... deja el reporte de calidad en logs\02_diagnostico.log
      5 03 Dimensiones
      6 04 Matricula
      7 05 Preparacion
      8 06 Aprendizajes
      9 Validar y cerrar .... comprueba hechos no vacios y la reconciliacion de
                              notas; marca el lote como Exitoso
     10 Registrar fallo ..... solo si algo fallo: marca el lote como Fallido con
                              el paso y el mensaje de error, y el job termina en
                              error (queda tambien en el visor de eventos)

   ANTES DE EJECUTAR ESTE SCRIPT (una sola vez)
     a) Haber corrido 01 a 06 a mano y validado los resultados.
     b) Carpetas:  C:\BI_IE1217\data     (los 17 CSV, ya existe)
                   C:\BI_IE1217\scripts  (copiar aqui 01 a 06 v5_1)
                   C:\BI_IE1217\logs     (crearla vacia)
     c) Iniciar el Agente: SQL Server Configuration Manager -> Servicios de
        SQL Server -> SQL Server Agent -> Iniciar, y Modo de inicio: Automatico.
        Con eso desaparece el aviso "Agent XPs deshabilitado".
     d) Permisos para la cuenta del Agente (CMD como administrador). En una
        instancia predeterminada la cuenta es NT SERVICE\SQLSERVERAGENT:
          icacls "C:\BI_IE1217\scripts" /grant "NT SERVICE\SQLSERVERAGENT:(OI)(CI)R"
          icacls "C:\BI_IE1217\data"    /grant "NT SERVICE\SQLSERVERAGENT:(OI)(CI)R"
          icacls "C:\BI_IE1217\logs"    /grant "NT SERVICE\SQLSERVERAGENT:(OI)(CI)M"
        La carpeta data tambien: el job se conecta con la cuenta de Windows del
        Agente, y con una cuenta de Windows el BULK INSERT lee el archivo con
        ESA cuenta, no con la del servicio de SQL Server.
     e) Comprobar que existe sqlcmd: en CMD escribir  sqlcmd -?

   PROGRAMACION
     Por defecto cada 15 minutos (para la demostracion). En operacion real,
     como 04-06 recalculan todo, basta una vez al dia: cambiar @Frecuencia a
     N'DIARIO' en la seccion 3.
   ========================================================================== */

SET NOCOUNT ON;
GO

/* =============================================================================
   1. COMPROBACIONES PREVIAS
   Si algo falta, SET NOEXEC ON hace que el resto del script no se ejecute.
   La ultima linea del archivo lo vuelve a apagar.
   ========================================================================== */
IF CAST(SERVERPROPERTY('EngineEdition') AS INT) = 4
BEGIN
    RAISERROR(N'Esta instancia es Express: no incluye SQL Server Agent. Usar Developer.', 16, 1);
    SET NOEXEC ON;
END
ELSE IF DB_ID(N'DW_IE1217') IS NULL
BEGIN
    RAISERROR(N'No existe DW_IE1217: ejecutar primero los scripts 01 a 06.', 16, 1);
    SET NOEXEC ON;
END
ELSE IF OBJECT_ID(N'DW_IE1217.dm_aprendizajes.FacLogroCompetencia', N'U') IS NULL
BEGIN
    RAISERROR(N'Faltan los hechos: ejecutar 01 a 06 a mano antes de automatizar.', 16, 1);
    SET NOEXEC ON;
END;

IF NOT EXISTS (SELECT 1 FROM sys.dm_server_services
               WHERE servicename LIKE N'SQL Server Agent%' AND status_desc = N'Running')
    PRINT N'AVISO: el Agente no esta iniciado. El job se crea igual, pero no correra
       hasta iniciar SQL Server Agent (ver paso c del encabezado).';
GO

/* =============================================================================
   2. CONTROL DE LOTES (en DW_IE1217)
   ========================================================================== */
USE DW_IE1217;
GO

IF SCHEMA_ID(N'ctl') IS NULL EXEC (N'CREATE SCHEMA ctl');
GO

IF OBJECT_ID(N'ctl.LoteETL', N'U') IS NULL
CREATE TABLE ctl.LoteETL (
    LoteID       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoteETL PRIMARY KEY,
    Origen       NVARCHAR(30)   NOT NULL,          -- 'SQL Agent' o 'Manual'
    Inicio       DATETIME2(0)   NOT NULL CONSTRAINT DF_LoteETL_Inicio DEFAULT SYSDATETIME(),
    Fin          DATETIME2(0)   NULL,
    Estado       NVARCHAR(20)   NOT NULL CONSTRAINT DF_LoteETL_Estado DEFAULT N'En curso',
    PasoFallido  NVARCHAR(128)  NULL,
    Mensaje      NVARCHAR(4000) NULL,
    DuracionSeg  AS DATEDIFF(SECOND, Inicio, Fin),
    CONSTRAINT CK_LoteETL_Estado
        CHECK (Estado IN (N'En curso', N'Exitoso', N'Fallido', N'Abandonado'))
);
GO

IF OBJECT_ID(N'ctl.ConteoLote', N'U') IS NULL
CREATE TABLE ctl.ConteoLote (
    LoteID  INT           NOT NULL CONSTRAINT FK_ConteoLote_Lote REFERENCES ctl.LoteETL (LoteID),
    Fase    NVARCHAR(20)  NOT NULL,   -- 'Staging' (tras el 01) o 'Publicado' (al cerrar)
    Objeto  NVARCHAR(128) NOT NULL,
    Filas   BIGINT        NOT NULL,
    CONSTRAINT PK_ConteoLote PRIMARY KEY (LoteID, Fase, Objeto),
    CONSTRAINT CK_ConteoLote_Fase CHECK (Fase IN (N'Staging', N'Publicado'))
);
GO

/* Lote abierto en este momento (NULL si no hay ninguno) */
CREATE OR ALTER FUNCTION ctl.fn_LoteActual ()
RETURNS INT
AS
BEGIN
    RETURN (SELECT MAX(LoteID) FROM ctl.LoteETL WHERE Estado = N'En curso');
END;
GO

/* Paso 1 del job. Un lote que quedo 'En curso' de una corrida interrumpida
   (por ejemplo, se apago la PC) se marca como Abandonado. */
CREATE OR ALTER PROCEDURE ctl.usp_IniciarLote
    @Origen NVARCHAR(30) = N'Manual'
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE ctl.LoteETL
    SET Estado = N'Abandonado', Fin = SYSDATETIME(),
        Mensaje = N'Quedo abierto: la corrida anterior se interrumpio sin cerrarse.'
    WHERE Estado = N'En curso';

    INSERT INTO ctl.LoteETL (Origen) VALUES (@Origen);

    PRINT CONCAT(N'Lote ', SCOPE_IDENTITY(), N' iniciado (', @Origen, N').');
END;
GO

/* Paso 3 del job: el freno antes de tocar los hechos.
   04, 05 y 06 son RECARGA TOTAL: si llegara un lote de CSV incompleto, borrarian
   historia. Por eso, con staging ya cargado y los hechos todavia intactos, se
   compara contra la ultima corrida exitosa. */
CREATE OR ALTER PROCEDURE ctl.usp_ValidarStaging
    @CaidaMaximaPct DECIMAL(5,2) = 50
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Lote INT = ctl.fn_LoteActual();
    IF @Lote IS NULL
        THROW 51070, N'No hay lote en curso: ejecutar ctl.usp_IniciarLote primero.', 1;

    DELETE FROM ctl.ConteoLote WHERE LoteID = @Lote AND Fase = N'Staging';

    /* Conteo exacto de cada tabla stg (menos la bitacora, que la llena el 06) */
    DECLARE @Sql NVARCHAR(MAX);
    SELECT @Sql = STRING_AGG(CAST(
               N'SELECT ' + CAST(@Lote AS NVARCHAR(10)) + N', N''Staging'', N''stg.'
             + t.name + N''', COUNT_BIG(*) FROM stg.' + QUOTENAME(t.name)
           AS NVARCHAR(MAX)), N' UNION ALL ')
    FROM sys.tables AS t
    WHERE t.schema_id = SCHEMA_ID(N'stg') AND t.name <> N'BitacoraNota';

    INSERT INTO ctl.ConteoLote (LoteID, Fase, Objeto, Filas)
    EXEC (@Sql);

    IF EXISTS (SELECT 1 FROM ctl.ConteoLote
               WHERE LoteID = @Lote AND Fase = N'Staging' AND Filas = 0)
    BEGIN
        SELECT Objeto AS TablaVacia
        FROM ctl.ConteoLote
        WHERE LoteID = @Lote AND Fase = N'Staging' AND Filas = 0;
        THROW 51071, N'Hay tablas de staging vacias: lote de CSV incompleto. Los hechos no se tocaron.', 1;
    END;

    DECLARE @Previo INT = (SELECT MAX(LoteID) FROM ctl.LoteETL
                           WHERE Estado = N'Exitoso' AND LoteID < @Lote);

    IF @Previo IS NOT NULL
    BEGIN
        SELECT a.Objeto,
               p.Filas AS FilasCorridaAnterior,
               a.Filas AS FilasCorridaActual,
               CAST(100.0 * (p.Filas - a.Filas) / p.Filas AS DECIMAL(6,2)) AS CaidaPct
        INTO #Caidas
        FROM ctl.ConteoLote AS a
        JOIN ctl.ConteoLote AS p
          ON p.LoteID = @Previo AND p.Fase = N'Staging' AND p.Objeto = a.Objeto
        WHERE a.LoteID = @Lote AND a.Fase = N'Staging'
          AND p.Filas > 0
          AND a.Filas < p.Filas * (1 - @CaidaMaximaPct / 100.0);

        IF EXISTS (SELECT 1 FROM #Caidas)
        BEGIN
            SELECT * FROM #Caidas ORDER BY CaidaPct DESC;
            THROW 51072, N'Una tabla de staging cayo mas del umbral frente a la ultima corrida exitosa. Los hechos no se tocaron.', 1;
        END;
    END;

    PRINT N'Staging validado: se puede recalcular dimensiones y hechos.';
END;
GO

/* Paso 9 del job: controles finales y cierre */
CREATE OR ALTER PROCEDURE ctl.usp_CerrarLote
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Lote INT = ctl.fn_LoteActual();
    IF @Lote IS NULL
        THROW 51073, N'No hay lote en curso para cerrar.', 1;

    DECLARE @Matricula   BIGINT = (SELECT COUNT_BIG(*) FROM dm_matricula.FacMatricula),
            @Preparacion BIGINT = (SELECT COUNT_BIG(*) FROM dm_preparacion.FacPreparacion),
            @Logro       BIGINT = (SELECT COUNT_BIG(*) FROM dm_aprendizajes.FacLogroCompetencia),
            @Bitacora    BIGINT = (SELECT COUNT_BIG(*) FROM stg.BitacoraNota),
            @NotasOrigen BIGINT = (SELECT COUNT_BIG(*) FROM stg.NotaCompetencia),
            @Msg         NVARCHAR(2048);

    IF @Matricula = 0 OR @Preparacion = 0 OR @Logro = 0
        THROW 51074, N'Un hecho quedo vacio: revisar el log de su paso.', 1;

    IF @NotasOrigen <> @Logro + @Bitacora
    BEGIN
        SET @Msg = CONCAT(N'Reconciliacion de notas no cuadra: origen ', @NotasOrigen,
                          N' <> hecho ', @Logro, N' + bitacora ', @Bitacora, N'.');
        THROW 51075, @Msg, 1;
    END;

    /* Fotografia de lo publicado: dimensiones, hechos y bitacora */
    DELETE FROM ctl.ConteoLote WHERE LoteID = @Lote AND Fase = N'Publicado';

    DECLARE @Sql NVARCHAR(MAX);
    SELECT @Sql = STRING_AGG(CAST(
               N'SELECT ' + CAST(@Lote AS NVARCHAR(10)) + N', N''Publicado'', N'''
             + s.name + N'.' + t.name + N''', COUNT_BIG(*) FROM '
             + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
           AS NVARCHAR(MAX)), N' UNION ALL ')
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE s.name IN (N'dw', N'dm_matricula', N'dm_preparacion', N'dm_aprendizajes')
       OR (s.name = N'stg' AND t.name = N'BitacoraNota');

    INSERT INTO ctl.ConteoLote (LoteID, Fase, Objeto, Filas)
    EXEC (@Sql);

    UPDATE ctl.LoteETL
    SET Estado = N'Exitoso', Fin = SYSDATETIME(),
        Mensaje = CONCAT(N'Matricula ', @Matricula, N' | Preparacion ', @Preparacion,
                         N' | Aprendizajes ', @Logro, N' + bitacora ', @Bitacora)
    WHERE LoteID = @Lote;

    SELECT LoteID, Origen, Inicio, Fin, DuracionSeg, Estado, Mensaje
    FROM ctl.LoteETL WHERE LoteID = @Lote;
END;
GO

/* Paso 10 del job: deja constancia del error. Si fallo el propio paso 1 y no
   llego a abrirse un lote, crea uno ya marcado como Fallido. */
CREATE OR ALTER PROCEDURE ctl.usp_RegistrarFallo
    @Paso    NVARCHAR(128)  = NULL,
    @Mensaje NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Lote INT = ctl.fn_LoteActual();

    IF @Lote IS NULL
        INSERT INTO ctl.LoteETL (Origen, Fin, Estado, PasoFallido, Mensaje)
        VALUES (N'SQL Agent', SYSDATETIME(), N'Fallido', @Paso, @Mensaje);
    ELSE
        UPDATE ctl.LoteETL
        SET Estado = N'Fallido', Fin = SYSDATETIME(),
            PasoFallido = @Paso, Mensaje = @Mensaje
        WHERE LoteID = @Lote;
END;
GO

/* Historial legible: una fila por corrida con los tres hechos */
CREATE OR ALTER VIEW ctl.vw_HistorialLotes
AS
SELECT l.LoteID, l.Origen, l.Inicio, l.Fin, l.DuracionSeg, l.Estado,
       l.PasoFallido,
       MAX(CASE WHEN c.Objeto = N'dm_matricula.FacMatricula'           THEN c.Filas END) AS FacMatricula,
       MAX(CASE WHEN c.Objeto = N'dm_preparacion.FacPreparacion'       THEN c.Filas END) AS FacPreparacion,
       MAX(CASE WHEN c.Objeto = N'dm_aprendizajes.FacLogroCompetencia' THEN c.Filas END) AS FacLogroCompetencia,
       MAX(CASE WHEN c.Objeto = N'stg.BitacoraNota'                    THEN c.Filas END) AS BitacoraNota,
       l.Mensaje
FROM ctl.LoteETL AS l
LEFT JOIN ctl.ConteoLote AS c
       ON c.LoteID = l.LoteID AND c.Fase = N'Publicado'
GROUP BY l.LoteID, l.Origen, l.Inicio, l.Fin, l.DuracionSeg, l.Estado,
         l.PasoFallido, l.Mensaje;
GO

/* =============================================================================
   3. EL JOB (en msdb)
   Se borra y se vuelve a crear: reejecutar este script no lo duplica.
   ========================================================================== */
USE msdb;
GO

DECLARE
    /* ---- AJUSTAR SI HACE FALTA -------------------------------------------- */
    @Job          SYSNAME       = N'ETL_IE1217_Carga',
    @RutaScripts  NVARCHAR(260) = N'C:\BI_IE1217\scripts\',
    @RutaLogs     NVARCHAR(260) = N'C:\BI_IE1217\logs\',
    @Frecuencia   NVARCHAR(10)  = N'MINUTOS',   -- N'MINUTOS' o N'DIARIO'
    @CadaMinutos  INT           = 15,           -- si MINUTOS
    @HoraDiaria   INT           = 20000,        -- si DIARIO: HHMMSS -> 02:00:00
    /* ----------------------------------------------------------------------- */
    @JobId        UNIQUEIDENTIFIER,
    @HorarioId    INT,
    @Sqlcmd       NVARCHAR(1000),
    @Cmd          NVARCHAR(1200),
    @Log          NVARCHAR(400),
    @PasoFallo    NVARCHAR(MAX);

/* sqlcmd con la cuenta de Windows del Agente:
     -E  autenticacion de Windows     -C  confiar en el certificado local
     -b  devolver error y salir al primer fallo (asi el job detecta el error)
     -I  QUOTED_IDENTIFIER ON, igual que SSMS
     -x  no interpretar $(variables)  -f 65001  leer los archivos como UTF-8 */
SET @Sqlcmd = N'sqlcmd -S "' + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + N'" -E -C -b -I -x -W -f 65001 -i "' + @RutaScripts;

/* Paso de fallo: averigua en el historial del Agente que paso fallo y por que */
SET @PasoFallo = REPLACE(N'
DECLARE @Inicio DATETIME2(0) =
    (SELECT Inicio FROM ctl.LoteETL WHERE LoteID = ctl.fn_LoteActual());
DECLARE @Paso NVARCHAR(128), @Mensaje NVARCHAR(4000);

SELECT TOP (1) @Paso = h.step_name, @Mensaje = h.message
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
WHERE j.name = N''{JOB}'' AND h.step_id > 0 AND h.run_status = 0
  AND (@Inicio IS NULL
       OR msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(SECOND, -5, @Inicio))
ORDER BY h.instance_id DESC;

EXEC ctl.usp_RegistrarFallo @Paso = @Paso, @Mensaje = @Mensaje;', N'{JOB}', @Job);

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @Job)
    EXEC msdb.dbo.sp_delete_job @job_name = @Job, @delete_unused_schedule = 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC msdb.dbo.sp_add_job
        @job_name              = @Job,
        @enabled               = 1,
        @description           = N'ETL I.E. 1217: staging, diagnostico, dimensiones y tres datamarts (scripts 01-06 v5.1) con control de lotes en DW_IE1217.ctl.',
        @owner_login_name      = N'sa',
        @notify_level_eventlog = 2,          -- escribe en el visor de eventos si falla
        @job_id                = @JobId OUTPUT;

    /* on_success_action 3 = siguiente paso | on_fail_action 4 = ir al paso 10 */
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 1,
        @step_name = N'Iniciar lote', @subsystem = N'TSQL', @database_name = N'DW_IE1217',
        @command = N'EXEC ctl.usp_IniciarLote @Origen = N''SQL Agent'';',
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    SET @Cmd = @Sqlcmd + N'01_staging_secundaria_v5_1.sql"';
    SET @Log = @RutaLogs + N'01_staging.log';
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 2,
        @step_name = N'01 Staging', @subsystem = N'CmdExec',
        @command = @Cmd,
        @output_file_name = @Log,
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 3,
        @step_name = N'Validar staging', @subsystem = N'TSQL', @database_name = N'DW_IE1217',
        @command = N'EXEC ctl.usp_ValidarStaging @CaidaMaximaPct = 50;',
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    SET @Cmd = @Sqlcmd + N'02_diagnostico_calidad_v5_1.sql"';
    SET @Log = @RutaLogs + N'02_diagnostico.log';
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 4,
        @step_name = N'02 Diagnostico', @subsystem = N'CmdExec',
        @command = @Cmd,
        @output_file_name = @Log,
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    SET @Cmd = @Sqlcmd + N'03_dimensiones_v5_1.sql"';
    SET @Log = @RutaLogs + N'03_dimensiones.log';
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 5,
        @step_name = N'03 Dimensiones', @subsystem = N'CmdExec',
        @command = @Cmd,
        @output_file_name = @Log,
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    SET @Cmd = @Sqlcmd + N'04_fac_matricula_v5_1.sql"';
    SET @Log = @RutaLogs + N'04_matricula.log';
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 6,
        @step_name = N'04 Matricula', @subsystem = N'CmdExec',
        @command = @Cmd,
        @output_file_name = @Log,
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    SET @Cmd = @Sqlcmd + N'05_fac_preparacion_v5_1.sql"';
    SET @Log = @RutaLogs + N'05_preparacion.log';
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 7,
        @step_name = N'05 Preparacion', @subsystem = N'CmdExec',
        @command = @Cmd,
        @output_file_name = @Log,
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    SET @Cmd = @Sqlcmd + N'06_fac_aprendizajes_v5_1.sql"';
    SET @Log = @RutaLogs + N'06_aprendizajes.log';
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 8,
        @step_name = N'06 Aprendizajes', @subsystem = N'CmdExec',
        @command = @Cmd,
        @output_file_name = @Log,
        @on_success_action = 3, @on_fail_action = 4, @on_fail_step_id = 10;

    /* on_success_action 1 = terminar con exito */
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 9,
        @step_name = N'Validar y cerrar lote', @subsystem = N'TSQL', @database_name = N'DW_IE1217',
        @command = N'EXEC ctl.usp_CerrarLote;',
        @on_success_action = 1, @on_fail_action = 4, @on_fail_step_id = 10;

    /* on_success_action 2 = terminar informando error: el job queda en rojo */
    EXEC msdb.dbo.sp_add_jobstep @job_id = @JobId, @step_id = 10,
        @step_name = N'Registrar fallo', @subsystem = N'TSQL', @database_name = N'DW_IE1217',
        @command = @PasoFallo,
        @on_success_action = 2, @on_fail_action = 2;

    EXEC msdb.dbo.sp_update_job @job_id = @JobId, @start_step_id = 1;

    /* Horario */
    IF @Frecuencia = N'DIARIO'
        EXEC msdb.dbo.sp_add_schedule
            @schedule_name     = N'ETL_IE1217_Diario',
            @enabled           = 1,
            @freq_type         = 4,      -- diario
            @freq_interval     = 1,      -- todos los dias
            @freq_subday_type  = 1,      -- una vez, a la hora indicada
            @active_start_time = @HoraDiaria,
            @schedule_id       = @HorarioId OUTPUT;
    ELSE
        EXEC msdb.dbo.sp_add_schedule
            @schedule_name        = N'ETL_IE1217_CadaMinutos',
            @enabled              = 1,
            @freq_type            = 4,   -- diario
            @freq_interval        = 1,
            @freq_subday_type     = 4,   -- repetir cada N minutos
            @freq_subday_interval = @CadaMinutos,
            @active_start_time    = 0,
            @active_end_time      = 235959,
            @schedule_id          = @HorarioId OUTPUT;

    EXEC msdb.dbo.sp_attach_schedule @job_id = @JobId, @schedule_id = @HorarioId;
    EXEC msdb.dbo.sp_add_jobserver   @job_id = @JobId, @server_name = N'(local)';

    COMMIT;
    PRINT N'Job ' + @Job + N' creado.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH;
GO

/* =============================================================================
   4. VERIFICACION: deben salir 10 pasos y un horario
   ========================================================================== */
SELECT s.step_id, s.step_name, s.subsystem,
       CASE s.on_success_action WHEN 1 THEN N'Terminar OK' WHEN 2 THEN N'Terminar con error'
                                WHEN 3 THEN N'Siguiente paso' ELSE N'Ir a paso' END AS SiSaleBien,
       CASE s.on_fail_action    WHEN 2 THEN N'Terminar con error'
                                WHEN 4 THEN CONCAT(N'Ir a paso ', s.on_fail_step_id) END AS SiFalla,
       s.output_file_name
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
WHERE j.name = N'ETL_IE1217_Carga'
ORDER BY s.step_id;

SELECT sc.name AS Horario,
       CASE sc.freq_subday_type WHEN 1 THEN N'Una vez al dia'
            ELSE CONCAT(N'Cada ', sc.freq_subday_interval, N' minutos') END AS Frecuencia,
       sc.active_start_time AS DesdeHHMMSS
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
WHERE j.name = N'ETL_IE1217_Carga';
GO

/* =============================================================================
   5. USO (copiar y ejecutar aparte; no se ejecuta con el script)

   -- Ejecucion inicial sin esperar al horario:
   EXEC msdb.dbo.sp_start_job @job_name = N'ETL_IE1217_Carga';

   -- Ver como va o como termino (refrescar cada tanto):
   SELECT TOP (10) * FROM DW_IE1217.ctl.vw_HistorialLotes ORDER BY LoteID DESC;

   -- Detalle paso a paso de las ultimas corridas:
   EXEC msdb.dbo.sp_help_jobhistory @job_name = N'ETL_IE1217_Carga', @mode = N'FULL';

   -- Pausar / reanudar la programacion:
   EXEC msdb.dbo.sp_update_job @job_name = N'ETL_IE1217_Carga', @enabled = 0;
   EXEC msdb.dbo.sp_update_job @job_name = N'ETL_IE1217_Carga', @enabled = 1;

   -- Eliminar el job:
   EXEC msdb.dbo.sp_delete_job @job_name = N'ETL_IE1217_Carga', @delete_unused_schedule = 1;
   ========================================================================== */

SET NOEXEC OFF;
GO
