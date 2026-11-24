@echo off
rem Centro de control del ETL (I.E. 1217). Antes, una vez: instalar_o_actualizar.cmd en la raiz del repositorio.
rem Opciones: demo.cmd estado ^| resumen N ^| aplicar N ^| lanzar ^| directo ^| calidad ^| base ^| pausar ^| reanudar ^| -Servidor NOMBRE
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0demo.ps1" %*
if "%~1"=="" pause
