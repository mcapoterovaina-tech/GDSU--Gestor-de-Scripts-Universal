<#
.SYNOPSIS
    Gestión de servicios con verificación y alertas.
.DESCRIPTION
    Permite iniciar, detener o reiniciar un servicio.
    Verifica el estado final y genera alertas en consola y log.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ServiceName,             # Nombre del servicio (ej: "Spooler")
    [Parameter(Mandatory=$true)]
    [ValidateSet("Start","Stop","Restart")]
    [string]$Action,                  # Acción a ejecutar
    [string]$LogPath = "C:\Logs"      # Carpeta de logs
)

# Crear carpeta de logs si no existe
if (!(Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogPath "Service_$($ServiceName)_$TimeStamp.log"

# Función para escribir en log y consola
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    if ($Level -eq "ERROR") { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq "WARN") { Write-Host $line -ForegroundColor Yellow }
    else { Write-Host $line -ForegroundColor Green }
}

try {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    Write-Log "Servicio detectado: $($service.DisplayName) (Estado: $($service.Status))"

    switch ($Action) {
        "Start" {
            if ($service.Status -ne "Running") {
                Start-Service -Name $ServiceName
                Start-Sleep -Seconds 3
            }
        }
        "Stop" {
            if ($service.Status -ne "Stopped") {
                Stop-Service -Name $ServiceName -Force
                Start-Sleep -Seconds 3
            }
        }
        "Restart" {
            Restart-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 3
        }
    }

    # Verificar estado final
    $service.Refresh()
    Write-Log "Estado final: $($service.Status)"

    if (($Action -eq "Start" -and $service.Status -ne "Running") -or
        ($Action -eq "Stop" -and $service.Status -ne "Stopped")) {
        Write-Log "La acción $Action no se completó correctamente." "ERROR"
    } else {
        Write-Log "✅ Acción $Action ejecutada con éxito en $ServiceName."
    }

} catch {
    Write-Log "❌ Error: $($_.Exception.Message)" "ERROR"
}
