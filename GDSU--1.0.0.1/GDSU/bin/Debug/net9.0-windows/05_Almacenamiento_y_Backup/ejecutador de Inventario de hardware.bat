@echo off
REM Ir a la carpeta donde está este .bat
cd /d "%~dp0"

REM Ejecutar el .ps1 en modo STA (necesario para WPF)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File ".\Inventario de hardware.ps1"

pause
