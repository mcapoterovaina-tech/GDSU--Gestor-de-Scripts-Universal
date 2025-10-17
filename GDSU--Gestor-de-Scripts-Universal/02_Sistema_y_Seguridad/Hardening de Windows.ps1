<#
.SYNOPSIS
    Hardening de Windows: deshabilita servicios inseguros, SMBv1, macros de Office y Autorun con auditoría.
.DESCRIPTION
    - Snapshot de estado inicial (servicios, SMBv1, claves relevantes).
    - Deshabilita servicios conocidos de alto riesgo (si existen).
    - Desactiva SMBv1 (feature y regkeys legado).
    - Forza políticas de macros (Office 2016+/365) en HKLM.
    - Deshabilita Autorun/AutoPlay por política y registro.
    - Snapshot final y log con diff.
.NOTES
    Requiere ejecución como Administrador. PowerShell 5+.
    Algunas claves de Office varían por versión; se aplican rutas comunes ClickToRun/16.0.
#>

param(
    [string]$LogPath = "C:\Logs",
    [string]$AuditPath = "C:\HardeningAudit",
    [switch]$DryRun,                            # Simula sin aplicar cambios
    [switch]$EnableRollback                     # Intento de rollback usando snapshot previo (servicios y claves principales)
)

# --- Preparación ---
foreach ($p in @($LogPath, $AuditPath)) { if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$sessionFolder = Join-Path $AuditPath "Session_$ts"
New-Item -ItemType Directory -Path $sessionFolder -Force | Out-Null
$logFile = Join-Path $sessionFolder "hardening.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
}

function Snapshot-State {
    param([string]$PathPrefix)
    Write-Log "Capturando snapshot: $PathPrefix"
    # Servicios (estado y tipo de inicio)
    Get-Service | Select-Object Name, DisplayName, Status, StartType | Export-Csv -NoTypeInformation -Encoding UTF8 -Path "$PathPrefix-services.csv"
    # SMBv1
    $smbFeature = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
    [pscustomobject]@{
        FeatureName    = "SMB1Protocol"
        State          = $smbFeature.State
    } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path "$PathPrefix-smb.csv"
    # Autorun & AutoPlay
    $autorunKeys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"
    )
    $autorunDump = foreach ($k in $autorunKeys) {
        try { Get-ItemProperty -Path $k | Select-Object PSPath, NoDriveTypeAutoRun, "DisableAutoplay", "ExplorerAutoplayHandle" }
        catch {}
    }
    $autorunDump | ConvertTo-Json -Depth 4 | Out-File -FilePath "$PathPrefix-autorun.json" -Encoding UTF8
    # Office Macros (HKLM, por versión 16.0)
    $officeMacroKeys = @(
        "HKLM:\Software\Policies\Microsoft\Office\16.0\Word\Security",
        "HKLM:\Software\Policies\Microsoft\Office\16.0\Excel\Security",
        "HKLM:\Software\Policies\Microsoft\Office\16.0\PowerPoint\Security"
    )
    $macroDump = foreach ($k in $officeMacroKeys) {
        try { Get-ItemProperty -Path $k | Select-Object PSPath, VBAWarnings, "BlockContentExecutionFromInternet", "EnableProtectedView" }
        catch {}
    }
    $macroDump | ConvertTo-Json -Depth 4 | Out-File -FilePath "$PathPrefix-macros.json" -Encoding UTF8
}

function Set-RegistryValue {
    param([string]$Path, [string]$Name, [object]$Value, [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::DWord)
    try {
        if (!(Test-Path $Path)) { if ($DryRun) { Write-Log "[DryRun] Crear clave: $Path" "WARN" } else { New-Item -Path $Path -Force | Out-Null } }
        if ($DryRun) { Write-Log "[DryRun] Set $Path\$Name = $Value ($Type)" }
        else { New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null }
    } catch { Write-Log "Error set $Path\$Name: $($_.Exception.Message)" "ERROR" }
}

# --- 1) Snapshot inicial ---
Snapshot-State -PathPrefix (Join-Path $sessionFolder "before")

# --- 2) Deshabilitar servicios inseguros ---
# Lista prudente; solo deshabilita si existe. Puedes añadir más según políticas internas.
$servicesToDisable = @(
    "SNMP",                 # Servicio SNMP (si no es imprescindible)
    "Telnet",               # Cliente/Servidor Telnet (si existiera)
    "RemoteRegistry",       # Registro remoto (riesgo si no se usa)
    "ssdpsrv",              # SSDP Discovery
    "upnphost",             # UPnP Device Host
    "LMHosts",              # Soporte de NetBIOS (si tu red no lo requiere)
    "Browser"               # Computer Browser (obsoleto)
)

foreach ($svcName in $servicesToDisable) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        Write-Log "Deshabilitando servicio: $svcName (Estado actual: $($svc.Status), Inicio: $($svc.StartType))"
        if ($DryRun) { Write-Log "[DryRun] Set-Service $svcName -StartupType Disabled" "WARN" }
        else {
            try {
                Set-Service -Name $svcName -StartupType Disabled
                if ($svc.Status -ne "Stopped") {
                    try { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue } catch {}
                }
            } catch { Write-Log "Error deshabilitando $svcName: $($_.Exception.Message)" "ERROR" }
        }
    } else {
        Write-Log "Servicio no presente: $svcName" "WARN"
    }
}

# --- 3) Desactivar SMBv1 ---
try {
    Write-Log "Desactivando SMBv1 (feature del sistema)."
    if ($DryRun) { Write-Log "[DryRun] Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart" "WARN" }
    else { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null }
} catch { Write-Log "Error desactivando SMBv1: $($_.Exception.Message)" "ERROR" }

# Refuerzo en registro para stacks antiguos (Server/legacy):
Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -Value 0
Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "AllowInsecureGuestAuth" -Value 0

# --- 4) Desactivar Autorun / AutoPlay ---
# NoDriveTypeAutoRun = 255 deshabilita AutoRun en todos los tipos de unidad
Set-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255
Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255
# DisableAutoplay = 1/No AutoPlay
Set-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoAutoRun" -Value 1
Set-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255
Set-RegistryValue -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" -Name "DisableAutoplay" -Value 1

# --- 5) Políticas de Macros (Office) ---
# Nota: requiere Office instalado; aplica política a nivel máquina (16.0). Ajusta si usas 15.0/14.0.
# VBAWarnings: 4 = Deshabilitar toda macro, 3 = Notificar y deshabilitar (más permisivo).
# BlockContentExecutionFromInternet: 1 = bloquear archivos de internet marcados con Mark-of-the-Web (MOTW).
# EnableProtectedView: 1 habilita vista protegida.
$officeApps = @("Word","Excel","PowerPoint")
foreach ($app in $officeApps) {
    $base = "HKLM:\Software\Policies\Microsoft\Office\16.0\$app\Security"
    Set-RegistryValue -Path $base -Name "VBAWarnings" -Value 4
    Set-RegistryValue -Path $base -Name "BlockContentExecutionFromInternet" -Value 1
    Set-RegistryValue -Path $base -Name "EnableUnsafeLocationsInPV" -Value 0
    # Protected View (ubicaciones de internet/archivos adjuntos)
    Set-RegistryValue -Path "HKLM:\Software\Policies\Microsoft\Office\16.0\$app\ProtectedView" -Name "DisableInternetFilesInPV" -Value 0
    Set-RegistryValue -Path "HKLM:\Software\Policies\Microsoft\Office\16.0\$app\ProtectedView" -Name "DisableAttachmentsInPV" -Value 0
}

# --- 6) Snapshot final y diff ---
Snapshot-State -PathPrefix (Join-Path $sessionFolder "after")

try {
    $beforeSvc = Import-Csv (Join-Path $sessionFolder "before-services.csv")
    $afterSvc  = Import-Csv (Join-Path $sessionFolder "after-services.csv")
    $diffSvc   = Compare-Object $beforeSvc $afterSvc -Property Name, StartType, Status -PassThru | Select-Object Name, StartType, Status
    $diffSvc | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sessionFolder "diff-services.csv")
    Write-Log "Auditoría generada. Carpeta: $sessionFolder"
} catch { Write-Log "No se pudo generar diff de servicios: $($_.Exception.Message)" "WARN" }

Write-Log "✅ Hardening aplicado."

# --- 7) Rollback opcional (servicios y claves principales) ---
if ($EnableRollback) {
    Write-Log "Rollback habilitado: se pueden restaurar estados desde 'before-*'. Requiere script adicional de restauración."
}
