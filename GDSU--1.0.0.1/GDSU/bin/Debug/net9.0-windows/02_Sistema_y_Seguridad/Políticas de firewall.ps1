<#
.SYNOPSIS
    Aplica políticas de firewall por perfil y puertos, con auditoría de cambios.
.DESCRIPTION
    - Permite abrir/cerrar puertos TCP/UDP.
    - Aplica reglas por perfil (Domain, Private, Public).
    - Genera auditoría: snapshot antes/después y diff.
    - Etiqueta reglas con un Tag para identificar y gestionar fácilmente.
.NOTES
    Requiere privilegios de administrador. PowerShell 5+ (Windows 10/11 / Server).
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Open","Close")]
    [string]$Mode,                                 # Acción: Open (abrir) / Close (cerrar)
    [Parameter(Mandatory=$true)]
    [int[]]$Ports,                                 # Puertos a gestionar (ej: 80,443,3389)
    [Parameter(Mandatory=$true)]
    [ValidateSet("TCP","UDP")]
    [string]$Protocol,                             # Protocolo
    [string[]]$Profiles = @("Domain","Private","Public"), # Perfiles afectados
    [string]$RulePrefix = "ManagedByGSU",          # Prefijo/Tag para reglas gestionadas
    [string]$AppName = "GenericApp",               # Nombre lógico de la política
    [string]$LogPath = "C:\Logs"                   # Carpeta de logs
)

# --- Preparación de auditoría ---
if (!(Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$AuditFolder = Join-Path $LogPath "FirewallAudit_$TimeStamp"
New-Item -ItemType Directory -Path $AuditFolder -Force | Out-Null
$BeforeSnapshot = Join-Path $AuditFolder "before.json"
$AfterSnapshot  = Join-Path $AuditFolder "after.json"
$DiffFile       = Join-Path $AuditFolder "diff.txt"
$ActionLog      = Join-Path $AuditFolder "actions.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $ActionLog -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
}

function Snapshot-Firewall {
    param([string]$Path)
    Get-NetFirewallRule |
      Select-Object Name, DisplayName, Enabled, Direction, Profile, Action, Description, @{n="Ports";e={ (Get-NetFirewallPortFilter -AssociatedNetFirewallRule $_ | Select-Object -ExpandProperty LocalPort -ErrorAction SilentlyContinue) -join "," }},
                    @{n="Protocol";e={ (Get-NetFirewallPortFilter -AssociatedNetFirewallRule $_ | Select-Object -ExpandProperty Protocol -ErrorAction SilentlyContinue) }},
                    @{n="Program";e={ (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $_ | Select-Object -ExpandProperty Program -ErrorAction SilentlyContinue) }},
                    @{n="Service";e={ (Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $_ | Select-Object -ExpandProperty Service -ErrorAction SilentlyContinue) }},
                    @{n="Tags";e={$_.DisplayGroup}}
    | ConvertTo-Json -Depth 4 | Out-File -FilePath $Path -Encoding UTF8
}

# Snapshot inicial
Write-Log "Capturando estado de firewall (antes)."
Snapshot-Firewall -Path $BeforeSnapshot

# --- Normalización de perfiles ---
# Mapear perfiles a flags
$ProfileMap = @{
    "Domain"  = "Domain"
    "Private" = "Private"
    "Public"  = "Public"
}
$validProfiles = $Profiles | ForEach-Object { $_.Trim() } | Where-Object { $ProfileMap.ContainsKey($_) }
if ($validProfiles.Count -eq 0) {
    Write-Log "No se recibió ningún perfil válido." "ERROR"
    exit 1
}

# --- Aplicación de reglas ---
foreach ($p in $Ports) {
    $RuleName = "$RulePrefix-$AppName-$Protocol-$p"
    $display  = "$AppName $Protocol $p ($($validProfiles -join '/'))"

    try {
        $existing = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
        if ($Mode -eq "Open") {
            if (-not $existing) {
                Write-Log "Creando regla: $RuleName para puerto $p/$Protocol en perfiles: $($validProfiles -join ', ')."
                New-NetFirewallRule `
                    -Name $RuleName `
                    -DisplayName $display `
                    -Direction Inbound `
                    -Action Allow `
                    -Protocol $Protocol `
                    -LocalPort $p `
                    -Profile ($validProfiles -join ",") `
                    -Enabled True `
                    -Description "Regla gestionada por $RulePrefix para $AppName. Auditoría: $TimeStamp." | Out-Null
            } else {
                Write-Log "Regla ya existe: $RuleName. Asegurando configuración."
                Set-NetFirewallRule -Name $RuleName -Enabled True -Profile ($validProfiles -join ",") -Action Allow -Direction Inbound | Out-Null
                Set-NetFirewallRule -Name $RuleName -DisplayName $display -Description "Regla gestionada por $RulePrefix para $AppName. Auditoría: $TimeStamp." | Out-Null
                Set-NetFirewallRule -Name $RuleName -PolicyStore ActiveStore | Out-Null
                # Asegurar filtros de puerto/protocolo
                Set-NetFirewallRule -Name $RuleName -NewDisplayName $display | Out-Null
                Set-NetFirewallRule -Name $RuleName | ForEach-Object {
                    Set-NetFirewallRule -Name $RuleName -Enabled True | Out-Null
                }
                # Ajuste explícito de port filter (re-crear si hiciera falta)
                # Si el filtro de puerto no coincide, se recrea la regla.
                $pf = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $existing -ErrorAction SilentlyContinue
                $needRecreate = $false
                if ($pf) {
                    if (($pf.Protocol -ne $Protocol) -or ($pf.LocalPort -ne "$p")) { $needRecreate = $true }
                }
                if ($needRecreate) {
                    Write-Log "El filtro de puerto/protocolo no coincide. Recreando regla $RuleName." "WARN"
                    Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
                    New-NetFirewallRule -Name $RuleName -DisplayName $display -Direction Inbound -Action Allow -Protocol $Protocol -LocalPort $p -Profile ($validProfiles -join ",") -Enabled True -Description "Regla gestionada por $RulePrefix para $AppName. Auditoría: $TimeStamp." | Out-Null
                }
            }
        } else { # Close
            if ($existing) {
                Write-Log "Cerrando (eliminando) regla: $RuleName."
                Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
            } else {
                Write-Log "No existe la regla $RuleName. Nada que cerrar." "WARN"
            }
        }
    } catch {
        Write-Log "Error manejando puerto $p/$Protocol: $($_.Exception.Message)" "ERROR"
    }
}

# Snapshot final
Write-Log "Capturando estado de firewall (después)."
Snapshot-Firewall -Path $AfterSnapshot

# --- Diff de auditoría ---
try {
    $before = Get-Content -Path $BeforeSnapshot -Raw
    $after  = Get-Content -Path $AfterSnapshot -Raw

    # Diff textual simple (línea a línea); para diffs más finos, usar objetos y comparar por Name/Ports/etc.
    $tempBefore = Join-Path $AuditFolder "before.txt"
    $tempAfter  = Join-Path $AuditFolder "after.txt"
    ($before -split '\r?\n') | Sort-Object | Out-File -FilePath $tempBefore -Encoding UTF8
    ($after  -split '\r?\n') | Sort-Object | Out-File -FilePath $tempAfter  -Encoding UTF8

    $diff = Compare-Object (Get-Content $tempBefore) (Get-Content $tempAfter) -IncludeEqual:$false
    $diff | ForEach-Object {
        "{0} {1}" -f $_.SideIndicator, $_.InputObject
    } | Out-File -FilePath $DiffFile -Encoding UTF8

    Write-Log "Auditoría generada en: $AuditFolder"
    Write-Log "Archivos: before.json, after.json, diff.txt, actions.log"
} catch {
    Write-Log "No se pudo generar diff: $($_.Exception.Message)" "WARN"
}

Write-Log "✅ Política de firewall aplicada."
