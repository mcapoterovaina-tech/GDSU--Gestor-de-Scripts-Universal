@echo off
setlocal enabledelayedexpansion

REM Carpeta de origen (tu Escritorio)
set "SRC=%USERPROFILE%\Desktop"

REM Carpeta de destino
set "DST=C:\Users\maikol\Desktop\ecritorio"

REM Crear subcarpetas si no existen
mkdir "%DST%\documentos" 2>nul
mkdir "%DST%\videos"     2>nul
mkdir "%DST%\img"        2>nul
mkdir "%DST%\app"        2>nul
mkdir "%DST%\otros"      2>nul

echo ================================
echo  Organizando archivos del Escritorio
echo ================================
echo.

for %%F in ("%SRC%\*") do (
    if exist "%%F" (
        set "ext=%%~xF"
        set "ext=!ext:~1!"
        set "name=%%~nxF"

        REM Clasificación por extensión
        if /I "!ext!"=="txt"  (move "%%F" "%DST%\documentos\" >nul) else (
        if /I "!ext!"=="doc"  (move "%%F" "%DST%\documentos\" >nul) else (
        if /I "!ext!"=="docx" (move "%%F" "%DST%\documentos\" >nul) else (
        if /I "!ext!"=="pdf"  (move "%%F" "%DST%\documentos\" >nul) else (
        if /I "!ext!"=="xls"  (move "%%F" "%DST%\documentos\" >nul) else (
        if /I "!ext!"=="xlsx" (move "%%F" "%DST%\documentos\" >nul) else (
        if /I "!ext!"=="ppt"  (move "%%F" "%DST%\documentos\" >nul) else (
        if /I "!ext!"=="pptx" (move "%%F" "%DST%\documentos\" >nul) else (

        if /I "!ext!"=="mp4"  (move "%%F" "%DST%\videos\" >nul) else (
        if /I "!ext!"=="avi"  (move "%%F" "%DST%\videos\" >nul) else (
        if /I "!ext!"=="mkv"  (move "%%F" "%DST%\videos\" >nul) else (

        if /I "!ext!"=="jpg"  (move "%%F" "%DST%\img\" >nul) else (
        if /I "!ext!"=="jpeg" (move "%%F" "%DST%\img\" >nul) else (
        if /I "!ext!"=="png"  (move "%%F" "%DST%\img\" >nul) else (
        if /I "!ext!"=="gif"  (move "%%F" "%DST%\img\" >nul) else (

        if /I "!ext!"=="exe"  (move "%%F" "%DST%\app\" >nul) else (
        if /I "!ext!"=="msi"  (move "%%F" "%DST%\app\" >nul) else (

        REM Si no coincide con nada, va a "otros"
        move "%%F" "%DST%\otros\" >nul
        )))))))))))))))))))
    )
)

echo.
echo Organización completada.
pause
