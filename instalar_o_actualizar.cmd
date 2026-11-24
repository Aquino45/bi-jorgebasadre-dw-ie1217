@echo off
rem Doble clic: instala o actualiza DW_IE1217 con autenticacion de Windows.
rem Busca solo el SQL Server de esta PC. Opciones (desde una consola):
rem   -Elegir ^| -Servidor localhost\SQLEXPRESS ^| -ConJob ^| -UsuarioSql sa ^| -SoloVerificar
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar_o_actualizar.ps1" %*
pause
