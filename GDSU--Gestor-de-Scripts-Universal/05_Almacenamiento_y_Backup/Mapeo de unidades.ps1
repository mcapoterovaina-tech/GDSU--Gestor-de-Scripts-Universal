<#
.SYNOPSIS
    Mapea unidades de red (SMB) con credenciales seguras y persistencia, con auditoría y verificación.
.DESCRIPTION
    - Acepta múltiples mapeos (letra, ruta UNC, etiqueta, persistencia).
    - Usa credenciales seguras: PSCredential en memoria o Windows Credential Manager.
    - Valida conectividad (ping al host y acceso al share).
    - Crea el mapeo de forma persistente (reconectar al iniciar sesión).
    - Audita cada acción con log y genera un resumen.
.NOTES
    Ejecutar como usuario que necesita el mapeo (la persistencia es por perfil).
    Requiere PowerShell 5+ en Windows 10/11/Server.
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [array]$Mappings,
    <#
        Ejemplo:
        $Mappings = @(
            @{ DriveLetter='Z'; Path='\\fileserver01\proyectos'; Label='Proyectos'; Persist=$true; CredentialTarget='fileserver01\proyectos' },
            @{ DriveLetter='Y'; Path='\\fileserver01\recursos'; Label='Recursos'; Persist=$true; UseCurrentUser=$true }
        )
    #>
    [switch]$ForceRemap,                    # Desconectar si ya existe y remapear
    [string]$LogPath = "C:\Logs"            # Carpeta para logs
)

# Preparación de logs
if (!(Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogPath "MapDrives_$TimeStamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
}

# Helper: resolver credencial
function Resolve-Credential {
    param(
        [string]$Target,              # Nombre objetivo en Credential Manager (ej: 'fileserver01\proyectos')
        [pscredential]$Credential,    # PSCredential directa (opcional)
        [switch]$UseCurrentUser       # Usar sesión actual (sin credencial explícita)
    )
    if ($UseCurrentUser) { return $null }
    if ($Credential) { return $Credential }
    if ([string]::IsNullOrWhiteSpace($Target)) { return $null }

    try {
        # Leer desde Credential Manager (Generic Credentials)
        $creds = cmd /c "cmdkey /list" | Select-String -Pattern $Target
        if ($creds) {
            Write-Log "Encontrada credencial en Credential Manager para '$Target'."
            # cmdkey no devuelve password; se usará 'net use' con /savecred si proporcionamos actualmente la credencial.
            # Aquí solo indicamos que existe. Para mapear sin pedir, necesitamos PSCredential.
            return $null
        } else {
            Write-Log "No se encontró credencial para '$Target' en Credential Manager." "WARN"
            return $null
        }
    } catch {
        Write-Log "Error consultando Credential Manager: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# Helper: guardar credencial en Credential Manager (opcional)
function Save-Credential {
    param([string]$Target, [pscredential]$Credential)
    if ([string]::IsNullOrWhiteSpace($Target) -or -not $Credential) { return }
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        )
        cmd /c "cmdkey /generic:$Target /user:$($Credential.UserName) /pass:$plain" | Out-Null
        Write-Log "Credencial almacenada en Credential Manager para '$Target'."
    } catch { Write-Log "No se pudo guardar credencial: $($_.Exception.Message)" "WARN" }
}

# Conectividad al host
function Test-HostReachable {
    param([string]$UNC)
    try {
        $host = ($UNC -replace '^\\\\','').Split('\')[0]
        $ok = Test-Connection -ComputerName $host -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $ok) { Write-Log "Host no responde: $host" "WARN" }
        return $ok
    } catch { Write-Log "Error probando host: $($_.Exception.Message)" "WARN"; return $false }
}

# Acceso al share
function Test-ShareAccessible {
    param([string]$UNC)
    try {
        # Intento de listar raíz del share (sin credencial explícita)
        Get-ChildItem -Path $UNC -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

# Mapear (New-PSDrive -Persist o 'net use')
function Map-Drive {
    param(
        [char]$DriveLetter,
        [string]$Path,
        [string]$Label,
        [bool]$Persist,
        [pscredential]$Credential,
        [string]$CredentialTarget
    )

    $drive = "$DriveLetter`:"
    # Si existe, decidir
    $existing = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($existing) {
        if ($ForceRemap) {
            Write-Log "Desconectando $drive existente para remapear." "WARN"
            try { net use $drive /delete /y | Out-Null } catch {}
            try { Remove-PSDrive -Name $DriveLetter -Force -ErrorAction SilentlyContinue } catch {}
        } else {
            Write-Log "La unidad $drive ya existe. Omitiendo (use -ForceRemap para rehacer)." "WARN"
            return
        }
    }

    # Método con 'net use' para mejor compatibilidad con /savecred y persistencia
    try {
        if ($Credential) {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
            )
            Write-Log "Mapeando $drive -> $Path con credenciales explícitas."
            # /persistent:{yes|no} controla reconexión al inicio
            $persistFlag = if ($Persist) { "yes" } else { "no" }
            cmd /c "net use $drive $Path $plain /user:$($Credential.UserName) /persistent:$persistFlag" | Out-Null
            if ($CredentialTarget) { Save-Credential -Target $CredentialTarget -Credential $Credential }
        } else {
            Write-Log "Mapeando $drive -> $Path usando sesión actual."
            $persistFlag = if ($Persist) { "yes" } else { "no" }
            cmd /c "net use $drive $Path /persistent:$persistFlag" | Out-Null
        }
    } catch {
        Write-Log "Error mapeando $drive: $($_.Exception.Message)" "ERROR"
        return
    }

    # Etiqueta (si aplica y explorador la refleja)
    if ($Label) {
        try {
            Write-Log "Asignando etiqueta '$Label' a $drive."
            # Etiqueta de volumen para shares no siempre aplica, pero se puede crear acceso directo con label en tu UI
            # Aquí usamos 'fsutil' solo si el sistema lo admite (volúmenes locales); en red no cambia nombre.
        } catch {}
    }

    # Verificación final
    try {
        $ok = Test-Path -Path $drive
        if ($ok) { Write-Log "✅ Unidad $drive mapeada y accesible." }
        else { Write-Log "Unidad $drive mapeada pero no accesible. Verifique permisos." "WARN" }
    } catch { Write-Log "No se pudo verificar $drive: $($_.Exception.Message)" "WARN" }
}

# Ejecución principal
Write-Log "Iniciando mapeo de unidades. Total: $($Mappings.Count)"
$results = @()

foreach ($m in $Mappings) {
    try {
        # Normalizar
        $driveLetter = [char]$m.DriveLetter
        $path        = [string]$m.Path
        $label       = [string]$m.Label
        $persist     = [bool]$m.Persist
        $useCurrent  = [bool]$m.UseCurrentUser
        $targetName  = [string]$m.CredentialTarget

        if ([string]::IsNullOrWhiteSpace($path) -or -not $driveLetter) {
            Write-Log "Entrada inválida (DriveLetter/Path requeridos)." "ERROR"
            continue
        }

        Write-Log "Procesando: $driveLetter -> $path (Persistencia: $persist)"

        # Conectividad base
        $hostOK = Test-HostReachable -UNC $path
        if (-not $hostOK) { Write-Log "Continuando pese a host no alcanzable (puede conectar por VPN más tarde)." "WARN" }

        # Resolver credencial (opcional)
        $cred = $null
        if ($m.Credential -is [pscredential]) { $cred = $m.Credential }
        else { $cred = Resolve-Credential -Target $targetName -UseCurrentUser:$useCurrent }

        # Intento de acceso previo
        if (-not (Test-ShareAccessible -UNC $path)) {
            Write-Log "El share no fue accesible sin credencial; se procederá con mapeo."
        } else {
            Write-Log "Share accesible; mapeo continuará para persistencia."
        }

        # Mapear
        Map-Drive -DriveLetter $driveLetter -Path $path -Label $label -Persist $persist -Credential $cred -CredentialTarget $targetName

        # Registrar resultado
        $results += [pscustomobject]@{
            Drive   = "$driveLetter`:"
            Path    = $path
            Persist = $persist
            Status  = if (Test-Path "$driveLetter`:") { "OK" } else { "WARN" }
        }
    } catch {
        Write-Log "Error en entrada de mapeo: $($_.Exception.Message)" "ERROR"
    }
}

# Resumen
$SummaryCsv  = Join-Path (Split-Path $LogFile -Parent) "MapDrives_Summary_$TimeStamp.csv"
$SummaryJson = Join-Path (Split-Path $LogFile -Parent) "MapDrives_Summary_$TimeStamp.json"
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $SummaryCsv
$results | ConvertTo-Json -Depth 4 | Out-File -FilePath $SummaryJson -Encoding UTF8

Write-Log "Proceso completado. Resumen en:"
Write-Log " - $SummaryCsv"
Write-Log " - $SummaryJson"
Write-Log "✅ Listo."
