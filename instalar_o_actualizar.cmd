@echo off
rem Doble clic: instala o actualiza DW_IE1217 con autenticacion de Windows.
rem Opciones (desde una consola): instalar_o_actualizar.cmd -ConJob ^| -UsuarioSql sa ^| -SoloVerificar
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar_o_actualizar.ps1" %*
pause
