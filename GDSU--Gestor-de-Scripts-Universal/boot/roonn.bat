@echo off
REM === Levantar el frontend ===
cd /d "C:\Users\maikol\Documents\GitHub\Dando\dando-tauri"
start cmd /k "bun run dev --port 3000"

REM === Levantar el backend ===
cd /d "C:\Users\maikol\Documents\GitHub\Dando\dando-server"
start cmd /k "bun run dev --port 4000"

REM === Mensaje de confirmación ===
echo ==========================================
echo Servidores iniciados:
echo Frontend -> http://localhost:3000
echo Backend  -> http://localhost:4000
echo ==========================================
pause
