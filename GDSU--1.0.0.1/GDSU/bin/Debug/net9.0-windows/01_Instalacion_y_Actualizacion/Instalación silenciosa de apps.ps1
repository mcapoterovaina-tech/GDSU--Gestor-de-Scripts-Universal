<#
.SYNOPSIS
    Instalador universal silencioso para MSI/EXE con logging y validación.
.DESCRIPTION
    - Detecta extensión (MSI/EXE).
    - Aplica parámetros de instalación silenciosa.
    - Genera log en carpeta definida.
    - Valida instalación por nombre de producto.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$InstallerPath,          # Ruta completa al instalador
    [Parameter(Mandatory=$true)]
    [string]$AppName,                # Nombre de la app para validar instalación
    [string]$LogPath = "C:\Logs"     # Carpeta donde guardar logs
)

# Crear carpeta de logs si no existe
if (!(Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

# Nombre de log basado en fecha y app
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogPath "$($AppName)_$TimeStamp.log"

# Detectar tipo de instalador
$Extension = [System.IO.Path]::GetExtension($InstallerPath).ToLower()

switch ($Extension) {
    ".msi" {
        $Arguments = "/i `"$InstallerPath`" /qn /norestart /L*v `"$LogFile`""
        $Exe = "msiexec.exe"
    }
    ".exe" {
        # Ajusta parámetros según el instalador (ejemplo: InnoSetup, NSIS, InstallShield)
        $Arguments = "/quiet /norestart /log `"$LogFile`""
        $Exe = $InstallerPath
    }
    default {
        Write-Error "Extensión no soportada: $Extension"
        exit 1
    }
}

Write-Host "Instalando $AppName..."
$process = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru

if ($process.ExitCode -eq 0) {
    Write-Host "Instalación finalizada. Validando..."
    
    # Validación: buscar en lista de programas instalados
    $installed = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* ,
                                HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* `
                 | Where-Object { $_.DisplayName -like "*$AppName*" }

    if ($installed) {
        Write-Host "✅ $AppName instalado correctamente."
    } else {
        Write-Warning "⚠ Instalación ejecutada, pero no se encontró $AppName en programas instalados."
    }
} else {
    Write-Error "❌ Error en la instalación. Código de salida: $($process.ExitCode). Revisa el log: $LogFile"
}
