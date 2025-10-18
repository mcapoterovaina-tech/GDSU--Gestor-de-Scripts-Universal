#requires -version 5.1
# Creacion de usuarios locales con GUI
# Autor: Copilot (para Maikol)
# Ejecutar como Administrador

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =========================
# Configuracion
# =========================
$Global:AppTitle   = "Creacion de usuarios locales"
$Global:LogRoot    = "C:\Logs\UsuariosLocales"
$Global:LogFile    = Join-Path $Global:LogRoot ("Usuarios_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Global:GroupsMap  = @{
    "Administradores" = "Administrators"
    "Usuarios"        = "Users"
    "Power Users"     = "Power Users" # presente en ediciones antiguas; si no existe, se ignora
    "Remote Desktop Users" = "Remote Desktop Users"
}

foreach ($p in @($Global:LogRoot)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

# =========================
# Utilidades
# =========================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpper(), $Message
    try { Add-Content -Path $Global:LogFile -Value $line } catch { }
    if ($Global:LogBox -and !$Global:LogBox.IsDisposed) {
        $Global:LogBox.AppendText("$line`r`n")
        $Global:LogBox.SelectionStart = $Global:LogBox.Text.Length
        $Global:LogBox.ScrollToCaret()
    }
}

function Test-LocalUserExists {
    param([Parameter(Mandatory)][string]$UserName)
    try {
        $u = Get-LocalUser -Name $UserName -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Ensure-LocalUserModule {
    # Carga el módulo de cuentas locales si está disponible
    try { Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction SilentlyContinue } catch { }
}

function Validate-PasswordStrong {
    param(
        [Parameter(Mandatory)][string]$Password,
        [int]$MinLength = 12
    )
    $hasUpper = ($Password -match "[A-Z]")
    $hasLower = ($Password -match "[a-z]")
    $hasDigit = ($Password -match "\d")
    $hasSym   = ($Password -match "[^a-zA-Z0-9]")

    $lenOK    = ($Password.Length -ge $MinLength)

    $score = 0
    $score += [int]$hasUpper + [int]$hasLower + [int]$hasDigit + [int]$hasSym + ([int]$lenOK)
    return [PSCustomObject]@{
        IsValid = ($hasUpper -and $hasLower -and $hasDigit -and $hasSym -and $lenOK)
        Score   = $score
        Detail  = "Len:$($Password.Length),U:$hasUpper,L:$hasLower,D:$hasDigit,S:$hasSym"
    }
}

function Add-UserToGroupSafe {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$GroupName
    )
    try {
        # Si el grupo no existe, se ignora con advertencia
        $g = Get-LocalGroup -Name $GroupName -ErrorAction Stop
        # Evitar duplicado
        $members = Get-LocalGroupMember -Group $GroupName -ErrorAction SilentlyContinue
        $already = $members | Where-Object { $_.Name -like "*\$UserName" -or $_.Name -eq $UserName }
        if ($already) {
            Write-Log "Usuario $UserName ya es miembro de $GroupName" "WARN"
        } else {
            Add-LocalGroupMember -Group $GroupName -Member $UserName -ErrorAction Stop
            Write-Log "Agregado $UserName a grupo $GroupName"
        }
    } catch {
        Write-Log "No fue posible agregar $UserName a $GroupName -> $($_.Exception.Message)" "ERROR"
    }
}

function CreateOrUpdate-LocalUser {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$SecurePassword,
        [string]$FullName = "",
        [string]$Description = "",
        [string[]]$Groups = @()
    )

    Ensure-LocalUserModule

    if (Test-LocalUserExists -UserName $UserName) {
        try {
            Write-Log "Usuario existe: $UserName. Actualizando propiedades y restableciendo contraseña"
            Set-LocalUser -Name $UserName -FullName $FullName -Description $Description -Password $SecurePassword -ErrorAction Stop
            Write-Log "Actualizacion de usuario completada: $UserName"
        } catch {
            Write-Log "Error actualizando usuario $UserName -> $($_.Exception.Message)" "ERROR"
            throw
        }
    } else {
        try {
            Write-Log "Creando usuario: $UserName"
            New-LocalUser -Name $UserName -FullName $FullName -Description $Description -Password $SecurePassword -PasswordNeverExpires:$false -UserMayNotChangePassword:$false -ErrorAction Stop
            Write-Log "Usuario creado: $UserName"
        } catch {
            Write-Log "Error creando usuario $UserName -> $($_.Exception.Message)" "ERROR"
            throw
        }
    }

    # Asignar grupos
    foreach ($gLabel in $Groups) {
        if ($Global:GroupsMap.ContainsKey($gLabel)) {
            $gName = $Global:GroupsMap[$gLabel]
            Add-UserToGroupSafe -UserName $UserName -GroupName $gName
        } else {
            Write-Log "Grupo desconocido (label): $gLabel" "WARN"
        }
    }
}

# =========================
# GUI
# =========================
$form = New-Object System.Windows.Forms.Form
$form.Text = $Global:AppTitle
$form.Size = New-Object System.Drawing.Size(840, 640)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Titulo
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Creacion de usuarios locales"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20,20)
$form.Controls.Add($lblTitle)

# Group datos usuario
$gbUser = New-Object System.Windows.Forms.GroupBox
$gbUser.Text = "Datos del usuario"
$gbUser.ForeColor = [System.Drawing.Color]::White
$gbUser.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbUser.Size = New-Object System.Drawing.Size(780, 220)
$gbUser.Location = New-Object System.Drawing.Point(20,60)
$form.Controls.Add($gbUser)

# Campos
$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Text = "Nombre de usuario:"
$lblUser.ForeColor = [System.Drawing.Color]::White
$lblUser.AutoSize = $true
$lblUser.Location = New-Object System.Drawing.Point(20,40)
$gbUser.Controls.Add($lblUser)

$tbUser = New-Object System.Windows.Forms.TextBox
$tbUser.Size = New-Object System.Drawing.Size(240, 24)
$tbUser.Location = New-Object System.Drawing.Point(160,36)
$gbUser.Controls.Add($tbUser)

$lblFull = New-Object System.Windows.Forms.Label
$lblFull.Text = "Nombre completo:"
$lblFull.ForeColor = [System.Drawing.Color]::White
$lblFull.AutoSize = $true
$lblFull.Location = New-Object System.Drawing.Point(420,40)
$gbUser.Controls.Add($lblFull)

$tbFull = New-Object System.Windows.Forms.TextBox
$tbFull.Size = New-Object System.Drawing.Size(320, 24)
$tbFull.Location = New-Object System.Drawing.Point(540,36)
$gbUser.Controls.Add($tbFull)

$lblDesc = New-Object System.Windows.Forms.Label
$lblDesc.Text = "Descripcion:"
$lblDesc.ForeColor = [System.Drawing.Color]::White
$lblDesc.AutoSize = $true
$lblDesc.Location = New-Object System.Drawing.Point(20,80)
$gbUser.Controls.Add($lblDesc)

$tbDesc = New-Object System.Windows.Forms.TextBox
$tbDesc.Size = New-Object System.Drawing.Size(740, 24)
$tbDesc.Location = New-Object System.Drawing.Point(160,76)
$gbUser.Controls.Add($tbDesc)

$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Text = "Contraseña:"
$lblPass.ForeColor = [System.Drawing.Color]::White
$lblPass.AutoSize = $true
$lblPass.Location = New-Object System.Drawing.Point(20,120)
$gbUser.Controls.Add($lblPass)

$tbPass = New-Object System.Windows.Forms.TextBox
$tbPass.Size = New-Object System.Drawing.Size(240, 24)
$tbPass.Location = New-Object System.Drawing.Point(160,116)
$tbPass.UseSystemPasswordChar = $true
$gbUser.Controls.Add($tbPass)

$lblPass2 = New-Object System.Windows.Forms.Label
$lblPass2.Text = "Confirmar contraseña:"
$lblPass2.ForeColor = [System.Drawing.Color]::White
$lblPass2.AutoSize = $true
$lblPass2.Location = New-Object System.Drawing.Point(420,120)
$gbUser.Controls.Add($lblPass2)

$tbPass2 = New-Object System.Windows.Forms.TextBox
$tbPass2.Size = New-Object System.Drawing.Size(240, 24)
$tbPass2.Location = New-Object System.Drawing.Point(580,116)
$tbPass2.UseSystemPasswordChar = $true
$gbUser.Controls.Add($tbPass2)

$lblStrength = New-Object System.Windows.Forms.Label
$lblStrength.Text = "Fortaleza: -"
$lblStrength.ForeColor = [System.Drawing.Color]::Gainsboro
$lblStrength.AutoSize = $true
$lblStrength.Location = New-Object System.Drawing.Point(20,160)
$gbUser.Controls.Add($lblStrength)

# Group grupos
$gbGroups = New-Object System.Windows.Forms.GroupBox
$gbGroups.Text = "Pertenencia a grupos"
$gbGroups.ForeColor = [System.Drawing.Color]::White
$gbGroups.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbGroups.Size = New-Object System.Drawing.Size(780, 140)
$gbGroups.Location = New-Object System.Drawing.Point(20,290)
$form.Controls.Add($gbGroups)

$clbGroups = New-Object System.Windows.Forms.CheckedListBox
$clbGroups.Size = New-Object System.Drawing.Size(740, 90)
$clbGroups.Location = New-Object System.Drawing.Point(20,30)
$clbGroups.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$clbGroups.ForeColor = [System.Drawing.Color]::White
$clbGroups.BorderStyle = "FixedSingle"
$gbGroups.Controls.Add($clbGroups)

# Llenar grupos
foreach ($k in $Global:GroupsMap.Keys) { [void]$clbGroups.Items.Add($k, $false) }

# Group acciones y logs
$gbActions = New-Object System.Windows.Forms.GroupBox
$gbActions.Text = "Acciones y estado"
$gbActions.ForeColor = [System.Drawing.Color]::White
$gbActions.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbActions.Size = New-Object System.Drawing.Size(780, 160)
$gbActions.Location = New-Object System.Drawing.Point(20,440)
$form.Controls.Add($gbActions)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = "Crear / Actualizar usuario"
$btnCreate.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
$btnCreate.ForeColor = [System.Drawing.Color]::White
$btnCreate.Size = New-Object System.Drawing.Size(220, 40)
$btnCreate.Location = New-Object System.Drawing.Point(20,30)
$gbActions.Controls.Add($btnCreate)

$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Multiline = $true
$Global:LogBox.ReadOnly = $true
$Global:LogBox.ScrollBars = "Vertical"
$Global:LogBox.BackColor = [System.Drawing.Color]::Black
$Global:LogBox.ForeColor = [System.Drawing.Color]::LightGreen
$Global:LogBox.Size = New-Object System.Drawing.Size(520, 90)
$Global:LogBox.Location = New-Object System.Drawing.Point(250,25)
$gbActions.Controls.Add($Global:LogBox)

# =========================
# Eventos
# =========================
$updateStrength = {
    $pwd = $tbPass.Text
    $res = Validate-PasswordStrong -Password $pwd
    $state = if ($res.IsValid) { "Fuerte" } else { "Debil" }
    $lblStrength.Text = "Fortaleza: $state ($($res.Detail))"
    $lblStrength.ForeColor = if ($res.IsValid) { [System.Drawing.Color]::LightGreen } else { [System.Drawing.Color]::OrangeRed }
}
$tbPass.Add_TextChanged($updateStrength)

$btnCreate.Add_Click({
    try {
        Ensure-LocalUserModule

        $user = $tbUser.Text.Trim()
        $full = $tbFull.Text.Trim()
        $desc = $tbDesc.Text.Trim()
        $p1   = $tbPass.Text
        $p2   = $tbPass2.Text

        if ([string]::IsNullOrWhiteSpace($user)) { 
            [System.Windows.Forms.MessageBox]::Show("Ingresa un nombre de usuario.", "Validacion", "OK", "Information") | Out-Null
            return
        }

        if ($p1 -ne $p2) {
            [System.Windows.Forms.MessageBox]::Show("Las contraseñas no coinciden.", "Validacion", "OK", "Warning") | Out-Null
            return
        }

        $res = Validate-PasswordStrong -Password $p1
        if (-not $res.IsValid) {
            [System.Windows.Forms.MessageBox]::Show("Contraseña debil. Requiere mayusculas, minusculas, digitos, simbolos y longitud >= 12.", "Validacion", "OK", "Warning") | Out-Null
            return
        }

        # Convertir a SecureString sin guardar en disco
        $sec = ConvertTo-SecureString -String $p1 -AsPlainText -Force

        # Capturar grupos seleccionados
        $selected = @()
        foreach ($idx in 0..($clbGroups.Items.Count - 1)) {
            if ($clbGroups.GetItemChecked($idx)) { $selected += $clbGroups.Items[$idx] }
        }

        Write-Log "Procesando usuario: $user"
        CreateOrUpdate-LocalUser -UserName $user -SecurePassword $sec -FullName $full -Description $desc -Groups $selected
        Write-Log "Operacion completada para: $user"
        [System.Windows.Forms.MessageBox]::Show("Usuario procesado correctamente.", "Exito", "OK", "Information") | Out-Null
    } catch {
        Write-Log "Error al procesar usuario -> $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
    } finally {
        # Limpieza de memoria sensible (opcional): no almacenamos contraseñas en variables globales
    }
})

# =========================
# Inicializar
# =========================
try {
    Write-Log "Log: $Global:LogFile"
    Ensure-LocalUserModule
    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
} catch {
    Write-Log "Error critico de GUI -> $($_.Exception.Message)" "ERROR"
} finally {
}
