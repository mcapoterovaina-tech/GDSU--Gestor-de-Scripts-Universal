#requires -version 5.1
# Instalador silencioso con GUI por perfiles
# Autor: Copilot (para Maikol)
# Ejecutar como Administrador

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =========================
# Configuracion y utilidades
# =========================
$Global:AppTitle   = "Instalador Silencioso por Perfiles"
$Global:LogRoot    = "C:\Logs\InstaladorApps"
$Global:TempRoot   = Join-Path $env:TEMP "InstaladorApps"
$Global:LogFile    = Join-Path $Global:LogRoot ("Install_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

foreach ($p in @($Global:LogRoot, $Global:TempRoot)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

# Parametros silenciosos comunes para EXE
$Global:ExeSilentArgs = @(
    "/S", "/silent", "/quiet", "/VERYSILENT", "/SP- /VERYSILENT /NORESTART", "/qn"
)

# Perfiles (migrable a JSON)
$Global:Profiles = @{
    "AltaProduccion" = @(
        @{ Name="VSCode";        Url="https://update.code.visualstudio.com/latest/win32-x64-user/stable"; Type="exe"; Args="/silent"; Validate="Microsoft VS Code" }
        @{ Name="LibreOffice";   Url="https://download.documentfoundation.org/libreoffice/stable/24.2.2/win/x86_64/LibreOffice_24.2.2_Win_x86-64.msi"; Type="msi"; Args=""; Validate="LibreOffice" }
        @{ Name="DefenderUpdate";Url="https://go.microsoft.com/fwlink/?LinkID=121721"; Type="exe"; Args="/quiet /norestart"; Validate="Windows Defender" }
    )
    "Oficina" = @(
        @{ Name="GoogleChrome";  Url="https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"; Type="msi"; Args=""; Validate="Google Chrome" }
        @{ Name="LibreOffice";   Url="https://download.documentfoundation.org/libreoffice/stable/24.2.2/win/x86_64/LibreOffice_24.2.2_Win_x86-64.msi"; Type="msi"; Args=""; Validate="LibreOffice" }
        @{ Name="Malwarebytes";  Url="https://downloads.malwarebytes.com/file/mb4_offline"; Type="exe"; Args="/silent"; Validate="Malwarebytes" }
    )
    "BajoRecursos" = @(
        @{ Name="GoogleChrome";  Url="https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"; Type="msi"; Args=""; Validate="Google Chrome" }
        @{ Name="LibreOffice";   Url="https://download.documentfoundation.org/libreoffice/stable/24.2.2/win/x86_64/LibreOffice_24.2.2_Win_x86-64.msi"; Type="msi"; Args=""; Validate="LibreOffice" }
        @{ Name="360TotalSecurity"; Url="https://free.360totalsecurity.com/totalsecurity/360TS_Setup.exe"; Type="exe"; Args="/S"; Validate="360 Total Security" }
    )
}

# =========================
# Logging
# =========================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpper(), $Message
    try {
        Add-Content -Path $Global:LogFile -Value $line
    } catch {
        # Si falla escribir a disco, seguimos mostrando en GUI
    }
    if ($Global:LogBox -and !$Global:LogBox.IsDisposed) {
        $Global:LogBox.AppendText("$line`r`n")
        $Global:LogBox.SelectionStart = $Global:LogBox.Text.Length
        $Global:LogBox.ScrollToCaret()
    }
}

# =========================
# Validacion de instalacion
# =========================
function Test-AppInstalled {
    param(
        [Parameter(Mandatory)][string]$ValidateKeyOrPath
    )

    if (Test-Path $ValidateKeyOrPath) { return $true }

    $uninstallPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $uninstallPaths) {
        try {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            foreach ($it in $items) {
                if ($it.DisplayName -and ($it.DisplayName -like "*$ValidateKeyOrPath*")) {
                    return $true
                }
            }
        } catch {
        }
    }
    return $false
}

# =========================
# Instalacion manual
# =========================
function Get-SilentArgsForFile {
    param([string]$FilePath)
    $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -eq ".msi") {
        return "/i `"$FilePath`" /quiet /norestart /log `"$Global:LogFile`""
    } else {
        foreach ($arg in $Global:ExeSilentArgs) {
            if ($arg -eq "/silent") { return "$arg" }
        }
        return "/quiet"
    }
}

function Install-LocalFile {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$CustomArgs = ""
    )
    try {
        if (!(Test-Path $FilePath)) { throw "Archivo no encontrado: $FilePath" }
        $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
        $silentArgs = if ($CustomArgs) { $CustomArgs } else { Get-SilentArgsForFile -FilePath $FilePath }

        if ($ext -eq ".msi") {
            Write-Log "Instalando MSI: $FilePath"
            Start-Process -FilePath "msiexec.exe" -ArgumentList $silentArgs -Wait -PassThru | Out-Null
        } else {
            Write-Log "Instalando EXE: $FilePath (args: $silentArgs)"
            Start-Process -FilePath $FilePath -ArgumentList $silentArgs -Wait -PassThru | Out-Null
        }
        Write-Log "Instalacion finalizada para $FilePath"
    } catch {
        Write-Log "Error instalando $FilePath -> $($_.Exception.Message)" "ERROR"
        throw
    } finally {
    }
}

# =========================
# Descarga + instalacion
# =========================
function Download-FileSafe {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$TargetPath
    )
    try {
        Write-Log "Descargando: $Url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $TargetPath -UseBasicParsing -ErrorAction Stop
        Write-Log "Descarga OK -> $TargetPath"
        return $true
    } catch {
        Write-Log "Error de descarga: $Url -> $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
    }
}

function Install-AppFromProfileItem {
    param(
        [Parameter(Mandatory)][hashtable]$Item
    )

    $name  = $Item.Name
    $url   = $Item.Url
    $type  = $Item.Type.ToLowerInvariant()
    $args  = $Item.Args
    $valid = $Item.Validate

    $fileName = "{0}_{1}{2}" -f $name, (Get-Date -Format "yyyyMMddHHmmss"), (if ($type -eq "msi") { ".msi" } else { ".exe" })
    $target   = Join-Path $Global:TempRoot $fileName

    if (!(Download-FileSafe -Url $url -TargetPath $target)) {
        Write-Log "Saltando $name por fallo de descarga" "WARN"
        return
    }

    try {
        if ($type -eq "msi") {
            $argsFinal = if ($args) { $args } else { "/i `"$target`" /quiet /norestart /log `"$Global:LogFile`"" }
            Write-Log "Instalando $name (MSI)"
            Start-Process -FilePath "msiexec.exe" -ArgumentList $argsFinal -Wait -PassThru | Out-Null
        } else {
            $argsFinal = if ($args) { $args } else { "/silent" }
            Write-Log "Instalando $name (EXE)"
            Start-Process -FilePath $target -ArgumentList $argsFinal -Wait -PassThru | Out-Null
        }

        Start-Sleep -Seconds 3
        $ok = Test-AppInstalled -ValidateKeyOrPath $valid
        if ($ok) {
            Write-Log "Validacion OK -> $name"
        } else {
            Write-Log "Validacion FALLO -> $name" "WARN"
        }
    } catch {
        Write-Log "Error instalando $name -> $($_.Exception.Message)" "ERROR"
    } finally {
        if (Test-Path $target) {
            try { Remove-Item -Path $target -Force } catch { }
        }
    }
}

function Install-ProfileBatch {
    param(
        [Parameter(Mandatory)][string]$ProfileKey
    )
    if (!$Global:Profiles.ContainsKey($ProfileKey)) {
        Write-Log "Perfil desconocido: $ProfileKey" "ERROR"
        return
    }

    $items = $Global:Profiles[$ProfileKey]
    Write-Log "Iniciando perfil: $ProfileKey (apps: $($items.Count))"
    foreach ($item in $items) {
        Install-AppFromProfileItem -Item $item
    }
    Write-Log "Perfil finalizado: $ProfileKey"
}

# =========================
# GUI (Windows Forms)
# =========================
$form = New-Object System.Windows.Forms.Form
$form.Text = $Global:AppTitle
$form.Size = New-Object System.Drawing.Size(980, 680)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.TopMost = $false

$labelTitle = New-Object System.Windows.Forms.Label
$labelTitle.Text = "Instalador silencioso por perfiles"
$labelTitle.ForeColor = [System.Drawing.Color]::White
$labelTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$labelTitle.AutoSize = $true
$labelTitle.Location = New-Object System.Drawing.Point(20,20)
$form.Controls.Add($labelTitle)

$gbManual = New-Object System.Windows.Forms.GroupBox
$gbManual.Text = "Instalacion manual (MSI/EXE)"
$gbManual.ForeColor = [System.Drawing.Color]::White
$gbManual.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbManual.Size = New-Object System.Drawing.Size(930, 150)
$gbManual.Location = New-Object System.Drawing.Point(20,60)
$form.Controls.Add($gbManual)

$tbFile = New-Object System.Windows.Forms.TextBox
$tbFile.Size = New-Object System.Drawing.Size(700, 25)
$tbFile.Location = New-Object System.Drawing.Point(20,40)
$tbFile.ReadOnly = $true
$gbManual.Controls.Add($tbFile)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Examinar..."
$btnBrowse.Size = New-Object System.Drawing.Size(100,30)
$btnBrowse.Location = New-Object System.Drawing.Point(730,38)
$gbManual.Controls.Add($btnBrowse)

$labelArgs = New-Object System.Windows.Forms.Label
$labelArgs.Text = "Parametros silenciosos (opcional):"
$labelArgs.ForeColor = [System.Drawing.Color]::White
$labelArgs.AutoSize = $true
$labelArgs.Location = New-Object System.Drawing.Point(20,80)
$gbManual.Controls.Add($labelArgs)

$tbArgs = New-Object System.Windows.Forms.TextBox
$tbArgs.Size = New-Object System.Drawing.Size(700, 25)
$tbArgs.Location = New-Object System.Drawing.Point(20,100)
$gbManual.Controls.Add($tbArgs)

$btnInstallManual = New-Object System.Windows.Forms.Button
$btnInstallManual.Text = "Instalar seleccionado"
$btnInstallManual.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
$btnInstallManual.ForeColor = [System.Drawing.Color]::White
$btnInstallManual.Size = New-Object System.Drawing.Size(150,35)
$btnInstallManual.Location = New-Object System.Drawing.Point(730,95)
$gbManual.Controls.Add($btnInstallManual)

$gbProfiles = New-Object System.Windows.Forms.GroupBox
$gbProfiles.Text = "Descarga e instalacion automatica por perfil"
$gbProfiles.ForeColor = [System.Drawing.Color]::White
$gbProfiles.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbProfiles.Size = New-Object System.Drawing.Size(930, 180)
$gbProfiles.Location = New-Object System.Drawing.Point(20,220)
$form.Controls.Add($gbProfiles)

$btnHigh = New-Object System.Windows.Forms.Button
$btnHigh.Text = "Alta produccion"
$btnHigh.BackColor = [System.Drawing.Color]::FromArgb(16,124,16)
$btnHigh.ForeColor = [System.Drawing.Color]::White
$btnHigh.Size = New-Object System.Drawing.Size(250,45)
$btnHigh.Location = New-Object System.Drawing.Point(30,40)
$gbProfiles.Controls.Add($btnHigh)

$btnOffice = New-Object System.Windows.Forms.Button
$btnOffice.Text = "Oficina"
$btnOffice.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
$btnOffice.ForeColor = [System.Drawing.Color]::White
$btnOffice.Size = New-Object System.Drawing.Size(250,45)
$btnOffice.Location = New-Object System.Drawing.Point(340,40)
$gbProfiles.Controls.Add($btnOffice)

$btnLow = New-Object System.Windows.Forms.Button
$btnLow.Text = "Bajo recursos"
$btnLow.BackColor = [System.Drawing.Color]::FromArgb(217,96,0)
$btnLow.ForeColor = [System.Drawing.Color]::White
$btnLow.Size = New-Object System.Drawing.Size(250,45)
$btnLow.Location = New-Object System.Drawing.Point(650,40)
$gbProfiles.Controls.Add($btnLow)

$labelHint = New-Object System.Windows.Forms.Label
$labelHint.Text = "Cada boton descargara e instalara apps con parametros silenciosos y validacion."
$labelHint.ForeColor = [System.Drawing.Color]::Gainsboro
$labelHint.AutoSize = $true
$labelHint.Location = New-Object System.Drawing.Point(30,100)
$gbProfiles.Controls.Add($labelHint)

$gbLogs = New-Object System.Windows.Forms.GroupBox
$gbLogs.Text = "Estado y logs"
$gbLogs.ForeColor = [System.Drawing.Color]::White
$gbLogs.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbLogs.Size = New-Object System.Drawing.Size(930, 200)
$gbLogs.Location = New-Object System.Drawing.Point(20,410)
$form.Controls.Add($gbLogs)

$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Multiline = $true
$Global:LogBox.ReadOnly = $true
$Global:LogBox.ScrollBars = "Vertical"
$Global:LogBox.BackColor = [System.Drawing.Color]::Black
$Global:LogBox.ForeColor = [System.Drawing.Color]::LightGreen
$Global:LogBox.Size = New-Object System.Drawing.Size(890, 150)
$Global:LogBox.Location = New-Object System.Drawing.Point(20,30)
$gbLogs.Controls.Add($Global:LogBox)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Style = "Continuous"
$progressBar.Value = 0
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Size = New-Object System.Drawing.Size(890, 20)
$progressBar.Location = New-Object System.Drawing.Point(20,185)
$gbLogs.Controls.Add($progressBar)

# =========================
# Eventos GUI
# =========================
$btnBrowse.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Instaladores|*.msi;*.exe|Todos|*.*"
    $ofd.Multiselect = $false
    if ($ofd.ShowDialog() -eq "OK") {
        $tbFile.Text = $ofd.FileName
        Write-Log "Seleccionado: $($ofd.FileName)"
    }
})

$btnInstallManual.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($tbFile.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Selecciona un archivo MSI/EXE", "Aviso", "OK", "Information") | Out-Null
            return
        }
        Install-LocalFile -FilePath $tbFile.Text -CustomArgs $tbArgs.Text
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
    } finally {
    }
})

$btnHigh.Add_Click({
    try {
        Start-Job -Name "Perfil_Alta" -ScriptBlock {
            Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
            & {
                Install-ProfileBatch -ProfileKey "AltaProduccion"
            }
        } | Out-Null
        Write-Log "Lanzado perfil Alta Produccion en segundo plano"
    } catch {
        Write-Log "Error al lanzar perfil Alta Produccion -> $($_.Exception.Message)" "ERROR"
    } finally {
    }
})

$btnOffice.Add_Click({
    try {
        Start-Job -Name "Perfil_Oficina" -ScriptBlock {
            Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
            & {
                Install-ProfileBatch -ProfileKey "Oficina"
            }
        } | Out-Null
        Write-Log "Lanzado perfil Oficina en segundo plano"
    } catch {
        Write-Log "Error al lanzar perfil Oficina -> $($_.Exception.Message)" "ERROR"
    } finally {
    }
})

$btnLow.Add_Click({
    try {
        Start-Job -Name "Perfil_Bajo" -ScriptBlock {
            Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
            & {
                Install-ProfileBatch -ProfileKey "BajoRecursos"
            }
        } | Out-Null
        Write-Log "Lanzado perfil Bajo Recursos en segundo plano"
    } catch {
        Write-Log "Error al lanzar perfil Bajo Recursos -> $($_.Exception.Message)" "ERROR"
    } finally {
    }
})

# =========================
# Inicializar
# =========================
try {
    Write-Log "Log: $Global:LogFile"
    Write-Log "Temp: $Global:TempRoot"
    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
} catch {
    Write-Log "Error critico de GUI -> $($_.Exception.Message)" "ERROR"
} finally {
}
