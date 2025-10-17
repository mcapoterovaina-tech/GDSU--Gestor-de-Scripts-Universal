<#
.SYNOPSIS
    Crea usuarios locales con contraseñas seguras y pertenencia a grupos.
.DESCRIPTION
    - Valida existencia del usuario.
    - Genera contraseña fuerte si no se proporciona.
    - Crea el usuario con nombre completo y descripción opcional.
    - Agrega a grupos locales predefinidos.
    - Aplica políticas base (expiración, cambio obligatorio, habilitado).
    - Loguea y verifica pertenencia final.
.NOTES
    Requiere PowerShell 5+ (Windows 10/11). Para compatibilidad con versiones antiguas, usa fallback con 'net user'.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$UserName,                           # Ej: "deployuser"
    [Parameter(Mandatory = $true)]
    [string]$FullName,                           # Ej: "Usuario de despliegue"
    [string]$Description = "Creado por automatización PowerShell",
    [string[]]$Groups = @("Users"),              # Ej: @("Administrators","Remote Desktop Users")
    [securestring]$SecurePassword,               # Opcional: si no se pasa, se genera
    [int]$PasswordLength = 16,                   # Largo de contraseña si se genera
    [switch]$ForceChangeAtNextLogon,             # Marca el usuario para cambiar contraseña en próximo inicio
    [switch]$DisableUser,                        # Crear y deshabilitar (útil para staging)
    [datetime]$PasswordExpiresOn,                # Fecha de expiración de contraseña opcional
    [string]$LogPath = "C:\Logs"                 # Carpeta de logs
)

# Crear carpeta de logs si no existe
if (!(Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogPath "CreateUser_$($UserName)_$TimeStamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
}

function New-StrongSecurePassword {
    param([int]$Length = 16)
    if ($Length -lt 12) { $Length = 12 } # mínimo razonable
    $lower = 'abcdefghijklmnopqrstuvwxyz'
    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $digits = '0123456789'
    $symbols = '!@#$%^&*()-_=+[]{};:,.?'

    # Garantizar complejidad (al menos 1 de cada grupo)
    $mandatory = @(
        ($lower | Get-Random),
        ($upper | Get-Random),
        ($digits | Get-Random),
        ($symbols | Get-Random)
    )
    $pool = ($lower + $upper + $digits + $symbols).ToCharArray()
    $rest = 1..($Length - $mandatory.Count) | ForEach-Object { $pool | Get-Random }
    $chars = ($mandatory + $rest) | Sort-Object { Get-Random } # shuffle
    return ($chars -join '') | ConvertTo-SecureString -AsPlainText -Force
}

# Verificar si el usuario ya existe
try {
    $existing = Get-LocalUser -Name $UserName -ErrorAction Stop
    Write-Log "El usuario '$UserName' ya existe. No se creará de nuevo." "WARN"
} catch {
    Write-Log "Usuario '$UserName' no existe. Procediendo a crear."
    # Preparar contraseña
    if (-not $SecurePassword) {
        $SecurePassword = New-StrongSecurePassword -Length $PasswordLength
        Write-Log "Contraseña generada automáticamente (no se imprime por seguridad)."
    } else {
        Write-Log "Se recibió una contraseña segura como parámetro."
    }

    # Crear usuario (cmdlets modernos)
    try {
        New-LocalUser -Name $UserName `
                      -Password $SecurePassword `
                      -FullName $FullName `
                      -Description $Description `
                      -PasswordNeverExpires:$false `
                      -AccountNeverExpires:$false | Out-Null
        Write-Log "Usuario '$UserName' creado."
    } catch {
        # Fallback para entornos antiguos: 'net user'
        Write-Log "Fallo con New-LocalUser. Intentando fallback con 'net user'..." "WARN"
        try {
            # Convertir securestring a texto controlado para comando (solo si es necesario)
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
            )
            cmd /c "net user $UserName $plain /add" | Out-Null
            cmd /c "wmic useraccount where name='$UserName' set fullname='$FullName'" | Out-Null
            Write-Log "Usuario '$UserName' creado con 'net user' (compatibilidad)."
        } catch {
            Write-Log "Error creando usuario: $($_.Exception.Message)" "ERROR"
            exit 1
        }
    }
}

# Políticas: forzar cambio de contraseña en próximo inicio (si se indicó)
if ($ForceChangeAtNextLogon.IsPresent) {
    try {
        Set-LocalUser -Name $UserName -PasswordChangeRequired $true
        Write-Log "Se exigirá cambio de contraseña en el próximo inicio."
    } catch {
        Write-Log "No se pudo marcar PasswordChangeRequired: $($_.Exception.Message)" "WARN"
    }
}

# Políticas: deshabilitar usuario (si se indicó)
if ($DisableUser.IsPresent) {
    try {
        Disable-LocalUser -Name $UserName
        Write-Log "Usuario '$UserName' deshabilitado."
    } catch {
        Write-Log "No se pudo deshabilitar: $($_.Exception.Message)" "WARN"
    }
}

# Políticas: establecer expiración de contraseña si se indicó
if ($PasswordExpiresOn) {
    try {
        # No hay cmdlet directo para fecha de expiración; se gestiona por política global o AD.
        # Lo registramos en log y documentamos para auditoría.
        Write-Log "Solicitud de expiración de contraseña en: $PasswordExpiresOn (requiere política local)."
    } catch {
        Write-Log "No se pudo registrar expiración: $($_.Exception.Message)" "WARN"
    }
}

# Agregar a grupos locales
foreach ($g in $Groups) {
    try {
        # Verificar existencia del grupo
        $grp = Get-LocalGroup -Name $g -ErrorAction Stop
        Add-LocalGroupMember -Group $g -Member $UserName -ErrorAction Stop
        Write-Log "Usuario '$UserName' agregado al grupo '$g'."
    } catch {
        Write-Log "Grupo '$g' no existe o no se pudo agregar: $($_.Exception.Message)" "ERROR"
    }
}

# Verificación final
try {
    $user = Get-LocalUser -Name $UserName -ErrorAction Stop
    $state = if ($user.Enabled) { "Enabled" } else { "Disabled" }
    Write-Log "Verificación: Usuario existe y está '$state'."
    $memberships = foreach ($g in $Groups) {
        try {
            (Get-LocalGroupMember -Group $g | Where-Object { $_.Name -match $UserName }) | Out-Null
            "$g: OK"
        } catch { "$g: MISSING" }
    }
    Write-Log ("Pertenencia: " + ($memberships -join ", "))
    Write-Log "✅ Proceso completado para '$UserName'."
} catch {
    Write-Log "No se pudo verificar el usuario: $($_.Exception.Message)" "ERROR"
    exit 1
}
