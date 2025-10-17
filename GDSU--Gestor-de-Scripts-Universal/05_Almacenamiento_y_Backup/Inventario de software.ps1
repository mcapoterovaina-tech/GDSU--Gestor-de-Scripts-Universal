<#
.SYNOPSIS
    Inventario de software por origen: MSI, Store (AppX) y Portable, con versiones. Exporta CSV/JSON.
.DESCRIPTION
    - MSI: Lee HKLM/HKCU (x64/x86) y normaliza DisplayName, DisplayVersion, Publisher, UninstallString.
    - Store: Enumera Get-AppxPackage (todas las cuentas locales opcionalmente) con Name, Version, Publisher.
    - Portable: Heurística por carpetas comunes (Program Files, Desktop, Downloads, Tools) detectando .exe con metadatos.
    - Exporta CSV/JSON por origen y un summary consolidado con conteos.
.NOTES
    Requiere PowerShell 5+ en Windows 10/11. Ejecutar como admin para máxima cobertura (especialmente AppX all users).
#>

param(
    [string]$OutputPath = "C:\SoftwareInventory",
    [string]$LogPath = "C:\Logs",
    [switch]$ScanPortable,                        # Activa escaneo de portables
    [string[]]$PortableRoots = @(
        "$env:ProgramFiles",
        "$env:ProgramFiles(x86)",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Downloads",
        "C:\Tools",
        "D:\Tools"
    ),
    [switch]$IncludeAllUsersAppX                  # Intenta enumerar AppX de todos los usuarios
)

# Preparación
foreach ($p in @($OutputPath, $LogPath)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
$TimeStamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapshotDir = Join-Path $OutputPath "Snapshot_$TimeStamp"
New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null

$LogFile        = Join-Path $LogPath "SWInventory_$TimeStamp.log"
$MsiCsv         = Join-Path $SnapshotDir "msi.csv"
$MsiJson        = Join-Path $SnapshotDir "msi.json"
$StoreCsv       = Join-Path $SnapshotDir "store.csv"
$StoreJson      = Join-Path $SnapshotDir "store.json"
$PortableCsv    = Join-Path $SnapshotDir "portable.csv"
$PortableJson   = Join-Path $SnapshotDir "portable.json"
$SummaryCsv     = Join-Path $SnapshotDir "summary.csv"
$SummaryJson    = Join-Path $SnapshotDir "summary.json"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
}

# --- MSI: Registro HKLM/HKCU (x64/x86) ---
function Get-MSIInstalled {
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $items = foreach ($path in $paths) {
        try {
            Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -and $_.DisplayVersion
            } | ForEach-Object {
                [pscustomobject]@{
                    Origin          = "MSI"
                    DisplayName     = $_.DisplayName
                    Version         = $_.DisplayVersion
                    Publisher       = $_.Publisher
                    InstallDate     = $_.InstallDate
                    UninstallString = $_.UninstallString
                    InstallLocation = $_.InstallLocation
                    Architecture    = if ($path -like "*WOW6432Node*") { "x86 on x64" } else { "native" }
                    RegistryPath    = $path
                }
            }
        } catch {
            Write-Log "Error leyendo $path: $($_.Exception.Message)" "WARN"
        }
    }
    $items | Sort-Object DisplayName, Version
}

# --- Store: AppX packages ---
function Get-StoreApps {
    $apps = @()
    try {
        if ($IncludeAllUsersAppX) {
            Write-Log "Enumerando AppX de todos los usuarios (requiere privilegios)."
            # Enumera SID de perfiles locales y consulta AppX por usuario
            $profiles = Get-CimInstance Win32_UserProfile | Where-Object { $_.Local -and $_.Loaded -eq $false }
            foreach ($p in $profiles) {
                try {
                    $sid = $p.SID
                    # AppX por usuario vía conmutador -AllUsers para cobertura
                    $apps += Get-AppxPackage -AllUsers | Where-Object { $_.PackageUserInformation -match $sid } 2>$null
                } catch {
                    Write-Log "Fallo enumerando AppX para SID $($p.SID): $($_.Exception.Message)" "WARN"
                }
            }
            # Complemento: agrega actuales del usuario activo
            $apps += Get-AppxPackage
        } else {
            $apps = Get-AppxPackage
        }
    } catch {
        Write-Log "Error Get-AppxPackage: $($_.Exception.Message)" "WARN"
    }

    $apps | ForEach-Object {
        [pscustomobject]@{
            Origin      = "Store"
            Name        = $_.Name
            PackageFull = $_.PackageFullName
            Version     = $_.Version.ToString()
            Publisher   = $_.Publisher
            Architecture= $_.Architecture
            InstallDir  = $_.InstallLocation
            UserInfo    = ($_.PackageUserInformation -join "; ")
        }
    } | Sort-Object Name, Version
}

# --- Portable: Heurística (EXE detectados con metadatos) ---
function Get-PortableApps {
    param([string[]]$Roots)

    $exeList = @()
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($root)
        if (!(Test-Path $expanded)) { continue }

        Write-Log "Escaneando portable en: $expanded"
        try {
            # Busca EXE hasta cierta profundidad, ignorando binarios del sistema y archivos muy pequeños
            Get-ChildItem -Path $expanded -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 500KB } |
                ForEach-Object {
                    try {
                        $vi = (Get-Item $_.FullName).VersionInfo
                        # Heurística: si no está en Program Files y no tiene entrada MSI conocida
                        $exeList += [pscustomobject]@{
                            Origin        = "Portable"
                            DisplayName   = if ($vi.ProductName) { $vi.ProductName } else { $_.BaseName }
                            Version       = $vi.ProductVersion
                            Publisher     = $vi.CompanyName
                            Path          = $_.FullName
                            Size_MB       = [Math]::Round(($_.Length/1MB),2)
                            DetectedRoot  = $expanded
                        }
                    } catch {
                        # Ignora EXE sin metadatos
                    }
                }
        } catch {
            Write-Log "Error escaneando $expanded: $($_.Exception.Message)" "WARN"
        }
    }

    # Deduplicación por DisplayName + Version + Path
    $exeList | Sort-Object DisplayName, Version, Path | Select-Object -Unique DisplayName, Version, Publisher, Path, Size_MB, Origin, DetectedRoot
}

# --- Ejecución ---
Write-Log "Iniciando inventario de software."
$msi      = Get-MSIInstalled
$store    = Get-StoreApps
$portable = if ($ScanPortable) { Get-PortableApps -Roots $PortableRoots } else { @() }

# --- Exportación ---
try {
    Write-Log "Exportando MSI..."
    $msi   | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $MsiCsv
    $msi   | ConvertTo-Json -Depth 4 | Out-File -FilePath $MsiJson -Encoding UTF8

    Write-Log "Exportando Store..."
    $store | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $StoreCsv
    $store | ConvertTo-Json -Depth 4 | Out-File -FilePath $StoreJson -Encoding UTF8

    if ($ScanPortable) {
        Write-Log "Exportando Portable..."
        $portable | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $PortableCsv
        $portable | ConvertTo-Json -Depth 4 | Out-File -FilePath $PortableJson -Encoding UTF8
    } else {
        Write-Log "Escaneo portable desactivado (use -ScanPortable)."
    }
} catch {
    Write-Log "Error exportando: $($_.Exception.Message)" "ERROR"
}

# --- Resumen consolidado ---
$summary = [pscustomobject]@{
    Timestamp        = $TimeStamp
    Counts           = [pscustomobject]@{
        MSI      = $msi.Count
        Store    = $store.Count
        Portable = $portable.Count
        Total    = ($msi.Count + $store.Count + $portable.Count)
    }
    TopPublishers    = ($msi + $store + $portable | Where-Object { $_.Publisher } |
                        Group-Object Publisher | Sort-Object Count -Descending | Select-Object -First 10 |
                        ForEach-Object { [pscustomobject]@{ Publisher=$_.Name; Count=$_.Count } })
}
$summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $SummaryJson -Encoding UTF8

# CSV plano con conteos
[pscustomobject]@{
    Timestamp = $TimeStamp
    MSI       = $msi.Count
    Store     = $store.Count
    Portable  = $portable.Count
    Total     = ($msi.Count + $store.Count + $portable.Count)
} | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $SummaryCsv

Write-Log "Inventario completado. Carpeta: $SnapshotDir"
Write-Log "Archivos: msi.*, store.*, portable.* (si aplica), summary.*"
Write-Log "✅ Listo."
