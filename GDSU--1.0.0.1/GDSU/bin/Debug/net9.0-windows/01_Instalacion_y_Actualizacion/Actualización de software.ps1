<#
.SYNOPSIS
    Actualizador universal con validación de versión, descarga, instalación y rollback.
.DESCRIPTION
    - Verifica versión instalada.
    - Descarga release desde URL.
    - Aplica actualización silenciosa.
    - Si falla, restaura versión anterior.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AppName,                  # Nombre de la app para validar
    [Parameter(Mandatory=$true)]
    [string]$CurrentExePath,           # Ruta al ejecutable actual
    [Parameter(Mandatory=$true)]
    [string]$DownloadUrl,              # URL de la nueva versión
    [Parameter(Mandatory=$true)]
    [string]$InstallerType,            # "msi" o "exe"
    [string]$TempPath = "C:\Temp",     # Carpeta temporal
    [string]$BackupPath = "C:\Backup", # Carpeta para rollback
    [string]$LogPath = "C:\Logs"       # Carpeta de logs
)

# Crear carpetas necesarias
foreach ($p in @($TempPath, $BackupPath, $LogPath)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogPath "$($AppName)_Update_$TimeStamp.log"
$InstallerFile = Join-Path $TempPath "$AppName.$InstallerType"

# 1. Verificar versión instalada
try {
    $currentVersion = (Get-Item $CurrentExePath).VersionInfo.ProductVersion
    Write-Host "Versión instalada de $AppName: $currentVersion"
} catch {
    Write-Warning "No se pudo obtener la versión actual. Continuando..."
    $currentVersion = "0.0.0"
}

# 2. Descargar nueva versión
Write-Host "Descargando nueva versión desde $DownloadUrl..."
Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerFile -UseBasicParsing

# 3. Backup de versión actual (rollback)
Write-Host "Respaldando versión actual en $BackupPath..."
Copy-Item -Path (Split-Path $CurrentExePath -Parent) -Destination $BackupPath -Recurse -Force

# 4. Instalar actualización
switch ($InstallerType) {
    "msi" {
        $Arguments = "/i `"$InstallerFile`" /qn /norestart /L*v `"$LogFile`""
        $Exe = "msiexec.exe"
    }
    "exe" {
        $Arguments = "/quiet /norestart /log `"$LogFile`""
        $Exe = $InstallerFile
    }
    default {
        Write-Error "Tipo de instalador no soportado: $InstallerType"
        exit 1
    }
}

Write-Host "Instalando actualización..."
$process = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru

# 5. Validar instalación
if ($process.ExitCode -eq 0) {
    try {
        $newVersion = (Get-Item $CurrentExePath).VersionInfo.ProductVersion
        Write-Host "Nueva versión detectada: $newVersion"
        if ($newVersion -ne $currentVersion) {
            Write-Host "✅ Actualización de $AppName completada."
        } else {
            Write-Warning "⚠ Instalación ejecutada, pero la versión no cambió."
        }
    } catch {
        Write-Warning "No se pudo validar la nueva versión."
    }
} else {
    Write-Error "❌ Error en la actualización. Código: $($process.ExitCode). Iniciando rollback..."
    # Rollback
    Remove-Item -Path (Split-Path $CurrentExePath -Parent) -Recurse -Force
    Copy-Item -Path (Join-Path $BackupPath (Split-Path $CurrentExePath -Leaf)) -Destination (Split-Path $CurrentExePath -Parent) -Recurse -Force
    Write-Host "Rollback completado. Revisa el log: $LogFile"
}
