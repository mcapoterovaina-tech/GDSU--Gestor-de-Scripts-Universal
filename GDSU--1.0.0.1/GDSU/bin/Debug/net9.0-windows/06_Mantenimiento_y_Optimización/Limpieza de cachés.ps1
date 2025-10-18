<#
.SYNOPSIS
    Limpieza de cachés: Temp, Prefetch y logs antiguos con exclusiones inteligentes y auditoría.
.DESCRIPTION
    - Limpia %TEMP% del usuario, Temp del sistema y Prefetch (seguro).
    - Purga logs por antigüedad y tamaño, con exclusiones por ruta/patrón.
    - Modo DryRun para simular, reporte de espacio liberado y errores.
    - Evita borrar archivos en uso; maneja reintentos y marca de auditoría.
.NOTES
    Ejecutar como admin para abarcar Temp del sistema y Prefetch. PowerShell 5+.
#>

param(
    [int]$LogRetentionDays = 14,                         # Antigüedad mínima de logs a purgar
    [int]$MinLogSizeMB = 5,                              # Tamaño mínimo de logs a considerar
    [switch]$IncludePrefetch,                            # Limpiar Prefetch (seguro)
    [switch]$IncludeSystemTemp,                          # Incluir Temp del sistema
    [switch]$DryRun,                                     # Simula sin borrar
    [string]$LogPath = "C:\Logs",                        # Carpeta de auditoría
    [string[]]$ExtraLogRoots = @("C:\Logs","C:\Temp"),   # Raíces adicionales donde buscar logs
    [string[]]$ExcludePaths = @(                         # Exclusiones por ruta
        "C:\Windows\System32",
        "C:\Program Files",
        "$env:ProgramData\Microsoft\Windows\Start Menu"
    ),
    [string[]]$ExcludePatterns = @("*.config","*.json","*.dll","*.sys"),  # Patrones a NO eliminar
    [string[]]$AdditionalTempDirs = @()                 # Temp extra (ej. appdata de herramientas)
)

# --- Preparación de auditoría ---
if (!(Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
$ts      = Get-Date -Format "yyyyMMdd_HHmmss"
$session = Join-Path $LogPath "CleanCaches_$ts"
New-Item -ItemType Directory -Path $session -Force | Out-Null
$logFile   = Join-Path $session "actions.log"
$reportCsv = Join-Path $session "summary.csv"
$reportJson= Join-Path $session "summary.json"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
}

# Helper: comprobar si un path está excluido
function Is-ExcludedPath {
    param([string]$Path)
    foreach ($ex in $ExcludePaths) {
        if ($Path -like "$ex*") { return $true }
    }
    return $false
}

# Helper: comprobar patrón excluido
function Is-ExcludedPattern {
    param([string]$Name)
    foreach ($pat in $ExcludePatterns) {
        if ($Name -like $pat) { return $true }
    }
    return $false
}

# Helper: intentar eliminar con reintentos
function Try-DeleteItem {
    param(
        [System.IO.FileSystemInfo]$Item,
        [int]$Retries = 2
    )
    if (Is-ExcludedPath -Path $Item.FullName) { return $false }
    if (Is-ExcludedPattern -Name $Item.Name) { return $false }

    for ($i=0; $i -le $Retries; $i++) {
        try {
            if ($DryRun) {
                Write-Log "[DryRun] Borra: $($Item.FullName)"
                return $true
            }
            if ($Item.PSIsContainer) {
                Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
            }
            return $true
        } catch {
            Start-Sleep -Milliseconds 250
            if ($i -eq $Retries) {
                Write-Log "No se pudo borrar: $($Item.FullName) :: $($_.Exception.Message)" "WARN"
                return $false
            }
        }
    }
}

# Helper: calcular tamaño (bytes)
function Get-SizeBytes {
    param([string]$Path)
    try {
        $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop
        $size = 0
        foreach ($it in $items) {
            try {
                if ($it.PSIsContainer) {
                    $size += (Get-ChildItem -LiteralPath $it.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                } else { $size += $it.Length }
            } catch {}
        }
        return [long]$size
    } catch { return 0 }
}

# --- Objetivos de limpieza ---
$userTemp    = $env:TEMP
$systemTemp  = "C:\Windows\Temp"
$prefetchDir = "C:\Windows\Prefetch"

Write-Log "Sesión de limpieza iniciada."

# 1) Limpiar Temp del usuario
function Clean-TempFolder {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        Write-Log "Temp no válido: $Path" "WARN"; return [pscustomobject]@{ Label=$Label; Path=$Path; FreedMB=0; DeletedItems=0 }
    }

    Write-Log "Limpiando $Label: $Path"
    $before = Get-SizeBytes -Path $Path
    $deleted = 0

    # Borra contenido pero no la carpeta raíz
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (Try-DeleteItem -Item $_) { $deleted++ }
    }

    $after = Get-SizeBytes -Path $Path
    $freedMB = [Math]::Round((($before - $after)/1MB),2)
    Write-Log "Liberado en $Label: $freedMB MB (items: $deleted)"
    return [pscustomobject]@{ Label=$Label; Path=$Path; FreedMB=$freedMB; DeletedItems=$deleted }
}

# 2) Limpiar Prefetch (solo archivos .pf viejos)
function Clean-Prefetch {
    if (-not (Test-Path $prefetchDir)) { Write-Log "Prefetch no existe." "WARN"; return [pscustomobject]@{ Label="Prefetch"; Path=$prefetchDir; FreedMB=0; DeletedItems=0 } }
    Write-Log "Limpiando Prefetch (archivos .pf antiguos)."
    $before = Get-SizeBytes -Path $prefetchDir
    $deleted = 0

    Get-ChildItem -LiteralPath $prefetchDir -Filter *.pf -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | ForEach-Object {
            if (Try-DeleteItem -Item $_) { $deleted++ }
        }

    $after = Get-SizeBytes -Path $prefetchDir
    $freedMB = [Math]::Round((($before - $after)/1MB),2)
    Write-Log "Prefetch liberado: $freedMB MB (items: $deleted)"
    return [pscustomobject]@{ Label="Prefetch"; Path=$prefetchDir; FreedMB=$freedMB; DeletedItems=$deleted }
}

# 3) Purga de logs antiguos (en raíces configuradas)
function Clean-OldLogs {
    param([string[]]$Roots, [int]$RetentionDays, [int]$MinSizeMB)
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Write-Log "Buscando logs > $RetentionDays días y > $MinSizeMB MB en: $($Roots -join ', ')"
    $deleted = 0
    $bytesFreed = 0

    foreach ($root in $Roots) {
        $expanded = [Environment]::ExpandEnvironmentVariables($root)
        if (-not (Test-Path $expanded)) { continue }
        Get-ChildItem -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Where-Object {
                ($_.Extension -in ".log",".txt",".etl") -and
                ($_.LastWriteTime -lt $cutoff) -and
                (($_.Length/1MB) -ge $MinSizeMB) -and
                (-not (Is-ExcludedPath -Path $_.FullName)) -and
                (-not (Is-ExcludedPattern -Name $_.Name))
            } | ForEach-Object {
                $size = $_.Length
                if (Try-DeleteItem -Item $_) {
                    $deleted++
                    $bytesFreed += $size
                }
            }
    }

    $freedMB = [Math]::Round(($bytesFreed/1MB),2)
    Write-Log "Logs purgados: $deleted archivos. Liberado: $freedMB MB"
    return [pscustomobject]@{ Label="OldLogs"; Paths=($Roots -join "; "); FreedMB=$freedMB; DeletedItems=$deleted }
}

# --- Ejecución ---
$results = @()
$results += Clean-TempFolder -Path $userTemp -Label "UserTemp"

if ($IncludeSystemTemp) {
    $results += Clean-TempFolder -Path $systemTemp -Label "SystemTemp"
}

if ($IncludePrefetch) {
    $results += Clean-Prefetch
} else {
    Write-Log "Prefetch desactivado (use -IncludePrefetch)."
}

# Temp adicionales
foreach ($t in $AdditionalTempDirs) {
    $results += Clean-TempFolder -Path $t -Label "ExtraTemp"
}

# Logs antiguos
$results += Clean-OldLogs -Roots $ExtraLogRoots -RetentionDays $LogRetentionDays -MinSizeMB $MinLogSizeMB

# --- Resumen y exportación ---
try {
    $totalFreed = [Math]::Round(($results | Measure-Object FreedMB -Sum).Sum,2)
    $totalItems = ($results | Measure-Object DeletedItems -Sum).Sum
    $summary = [pscustomobject]@{
        Timestamp   = $ts
        DryRun      = [bool]$DryRun
        TotalFreedMB= $totalFreed
        TotalItems  = $totalItems
        Details     = $results
    }
    $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $reportCsv
    $summary  | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportJson -Encoding UTF8
    Write-Log "Resumen: liberado $totalFreed MB en $totalItems items."
    Write-Log "Auditoría en: $session"
    Write-Log "✅ Limpieza completada."
} catch {
    Write-Log "Error exportando resumen: $($_.Exception.Message)" "ERROR"
}
