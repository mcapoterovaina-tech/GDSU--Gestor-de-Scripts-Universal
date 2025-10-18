#requires -version 5.1
<#
.SYNOPSIS
Descarga automáticamente el instalador oficial de LibreOffice (MSI) desde los servidores de The Document Foundation,
con interfaz gráfica, barra de progreso y auditoría básica.
#>

param(
    [ValidateSet('Fresh','Still')]
    [string]$Channel = 'Fresh',
    [string]$OutputDir = "$env:USERPROFILE\Downloads\LibreOffice",
    [switch]$DryRun
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =========================
# Configuración y rutas
# =========================
$Global:AppTitle   = "Descarga de LibreOffice (GDSU)"
$Global:LogRoot    = "C:\Logs\LibreOfficeGDSU"
$Global:LogFile    = Join-Path $Global:LogRoot ("LibreOffice_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

if (!(Test-Path $Global:LogRoot)) { New-Item -ItemType Directory -Path $Global:LogRoot | Out-Null }

# =========================
# Utilidades y logging
# =========================
function Write-Log {
    param([string]$Message, [string]$Level="INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpper(), $Message
    try { Add-Content -Path $Global:LogFile -Value $line } catch { }
    if ($Global:LogBox -and !$Global:LogBox.IsDisposed) {
        $Global:LogBox.AppendText("$line`r`n")
        $Global:LogBox.SelectionStart = $Global:LogBox.Text.Length
        $Global:LogBox.ScrollToCaret()
    }
}

function Get-OsArch {
    if ([Environment]::Is64BitOperatingSystem) {
        return @{ ArchFolder = 'x86_64'; ArchLabel = 'x86-64' }
    } else {
        return @{ ArchFolder = 'x86'; ArchLabel = 'x86' }
    }
}

function Get-LibreOfficeLatestVersion {
    param([ValidateSet('Fresh','Still')][string]$Channel)

    $indexUrl = 'https://download.documentfoundation.org/libreoffice/stable/'
    try {
        $resp = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -TimeoutSec 30
    } catch {
        throw "No se pudo acceder a $indexUrl. Detalle: $($_.Exception.Message)"
    }

    $versions = @()
    foreach ($link in $resp.Links) {
        if ($link.href -match '^\d+\.\d+(\.\d+)?/$') {
            $candidate = $link.href.TrimEnd('/')
            try { [void][Version]$candidate; $versions += $candidate } catch { }
        }
    }

    if (-not $versions) { throw "No se encontraron versiones válidas en el índice oficial." }

    $sorted = $versions | Sort-Object { [Version]$_ } -Descending
    if ($Channel -eq 'Fresh') { return $sorted[0] }
    else { return if ($sorted.Count -gt 1) { $sorted[1] } else { $sorted[0] } }
}

function Build-DownloadUrl {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ArchFolder,
        [Parameter(Mandatory)][string]$ArchLabel
    )
    return "https://download.documentfoundation.org/libreoffice/stable/$Version/win/$ArchFolder/LibreOffice_${Version}_Win_${ArchLabel}.msi"
}

function Download-WithProgress {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)]$ProgressBar,
        [Parameter(Mandatory)]$LogBox
    )

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = 30000
        $resp = $req.GetResponse()
    } catch {
        $LogBox.AppendText("Error al conectar con el servidor: $($_.Exception.Message)`r`n")
        Write-Log "Error al conectar: $($_.Exception.Message)" "ERROR"
        return $false
    }

    if (-not $resp) {
        $LogBox.AppendText("No se obtuvo respuesta del servidor.`r`n")
        Write-Log "Respuesta nula del servidor" "ERROR"
        return $false
    }

    $total = $resp.ContentLength
    $stream = $resp.GetResponseStream()
    try { $fs = New-Object IO.FileStream($Destination, [IO.FileMode]::Create) }
    catch {
        $LogBox.AppendText("No se pudo crear el archivo destino: $Destination`r`n")
        Write-Log "No se pudo crear archivo: $Destination" "ERROR"
        return $false
    }

    $buffer = New-Object byte[] 8192
    $totalRead = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fs.Write($buffer, 0, $read)
            $totalRead += $read
            if ($total -gt 0) {
                $percent = [math]::Round(($totalRead / $total) * 100, 0)
                $ProgressBar.Value = [math]::Min($percent, 100)
            }
        }
    } catch {
        $LogBox.AppendText("Fallo durante la descarga: $($_.Exception.Message)`r`n")
        Write-Log "Fallo descarga: $($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        try { $fs.Close() } catch { }
        if ($stream) { try { $stream.Close() } catch { } }
        if ($resp)   { try { $resp.Close() } catch { } }
    }

    $sw.Stop()
    $LogBox.AppendText("Descarga finalizada en $([math]::Round($sw.Elapsed.TotalSeconds,2)) segundos.`r`n")
    Write-Log "Descarga finalizada en $([math]::Round($sw.Elapsed.TotalSeconds,2)) s"
    return $true
}

# =========================
# GUI
# =========================
$form = New-Object System.Windows.Forms.Form
$form.Text = $Global:AppTitle
$form.Size = New-Object System.Drawing.Size(720, 480)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

# Canal
$lblChannel = New-Object System.Windows.Forms.Label
$lblChannel.Text = "Canal:"
$lblChannel.ForeColor = [System.Drawing.Color]::White
$lblChannel.AutoSize = $true
$lblChannel.Location = New-Object System.Drawing.Point(20,20)
$form.Controls.Add($lblChannel)

$cbChannel = New-Object System.Windows.Forms.ComboBox
$cbChannel.Items.AddRange(@("Fresh","Still"))
$cbChannel.SelectedItem = $Channel
$cbChannel.Location = New-Object System.Drawing.Point(80,18)
$cbChannel.DropDownStyle = "DropDownList"
$cbChannel.Width = 120
$cbChannel.TabIndex = 0
$form.Controls.Add($cbChannel)

# Carpeta destino
$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = "Carpeta destino:"
$lblFolder.ForeColor = [System.Drawing.Color]::White
$lblFolder.AutoSize = $true
$lblFolder.Location = New-Object System.Drawing.Point(20,60)
$form.Controls.Add($lblFolder)

$tbFolder = New-Object System.Windows.Forms.TextBox
$tbFolder.Text = $OutputDir
$tbFolder.Size = New-Object System.Drawing.Size(540,24)
$tbFolder.Location = New-Object System.Drawing.Point(130,58)
$tbFolder.TabIndex = 1
$tbFolder.Anchor = "Top,Left,Right"
$form.Controls.Add($tbFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Examinar..."
$btnBrowse.Location = New-Object System.Drawing.Point(680,56)
$btnBrowse.Size = New-Object System.Drawing.Size(100,28)
$btnBrowse.TabIndex = 2
$btnBrowse.Anchor = "Top,Right"
$form.Controls.Add($btnBrowse)

$btnBrowse.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path $tbFolder.Text) { $fbd.SelectedPath = $tbFolder.Text }
    if ($fbd.ShowDialog() -eq "OK") { $tbFolder.Text = $fbd.SelectedPath }
})

# Botones de acción
$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = "Descargar"
$btnDownload.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
$btnDownload.ForeColor = [System.Drawing.Color]::White
$btnDownload.Size = New-Object System.Drawing.Size(120,34)
$btnDownload.Location = New-Object System.Drawing.Point(20,100)
$btnDownload.TabIndex = 3
$form.Controls.Add($btnDownload)

$btnDryRun = New-Object System.Windows.Forms.Button
$btnDryRun.Text = "DryRun"
$btnDryRun.BackColor = [System.Drawing.Color]::FromArgb(100,100,100)
$btnDryRun.ForeColor = [System.Drawing.Color]::White
$btnDryRun.Size = New-Object System.Drawing.Size(120,34)
$btnDryRun.Location = New-Object System.Drawing.Point(150,100)
$btnDryRun.TabIndex = 4
$form.Controls.Add($btnDryRun)

# Barra de progreso
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20,150)
$progressBar.Size = New-Object System.Drawing.Size(760,20)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Style = "Continuous"
$progressBar.TabIndex = 5
$progressBar.Anchor = "Top,Left,Right"
$form.Controls.Add($progressBar)

# Cuadro de logs
$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Multiline = $true
$Global:LogBox.ReadOnly = $true
$Global:LogBox.ScrollBars = "Vertical"
$Global:LogBox.BackColor = [System.Drawing.Color]::Black
$Global:LogBox.ForeColor = [System.Drawing.Color]::LightGreen
$Global:LogBox.Size = New-Object System.Drawing.Size(760, 250)
$Global:LogBox.Location = New-Object System.Drawing.Point(20,190)
$Global:LogBox.Anchor = "Top,Left,Right,Bottom"
$Global:LogBox.TabIndex = 6
$form.Controls.Add($Global:LogBox)

# =========================
# Eventos
# =========================
$btnDryRun.Add_Click({
    try {
        Write-Log "DryRun: iniciando resolución de versión y URL"
        $arch = Get-OsArch
        $version = Get-LibreOfficeLatestVersion -Channel $cbChannel.SelectedItem
        $url = Build-DownloadUrl -Version $version -ArchFolder $arch.ArchFolder -ArchLabel $arch.ArchLabel
        $filename = Split-Path -Leaf $url
        $destPath = Join-Path $tbFolder.Text $filename

        Write-Log "Canal: $($cbChannel.SelectedItem)"
        Write-Log "Versión: $version"
        Write-Log "Arquitectura: $($arch.ArchLabel)"
        Write-Log "URL: $url"
        Write-Log "Destino: $destPath"
        Write-Log "DryRun completado. No se descarga el archivo."
        [System.Windows.Forms.MessageBox]::Show("DryRun completado.`r`n`r`n$destPath", "DryRun", "OK", "Information") | Out-Null
    } catch {
        Write-Log "Error en DryRun -> $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
    }
})

$btnDownload.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($tbFolder.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Seleccione una carpeta de destino.", "Validación", "OK", "Information") | Out-Null
            return
        }

        if (!(Test-Path $tbFolder.Text)) {
            try { New-Item -ItemType Directory -Force -Path $tbFolder.Text | Out-Null }
            catch {
                [System.Windows.Forms.MessageBox]::Show("No se puede crear la carpeta destino.", "Error", "OK", "Error") | Out-Null
                return
            }
        }

        $arch = Get-OsArch
        $version = Get-LibreOfficeLatestVersion -Channel $cbChannel.SelectedItem
        $url = Build-DownloadUrl -Version $version -ArchFolder $arch.ArchFolder -ArchLabel $arch.ArchLabel
        $filename = Split-Path -Leaf $url
        $destPath = Join-Path $tbFolder.Text $filename

        Write-Log "Iniciando descarga"
        Write-Log "Versión: $version | Arquitectura: $($arch.ArchLabel)"
        Write-Log "URL: $url"
        Write-Log "Destino: $destPath"

        $progressBar.Value = 0
        $ok = Download-WithProgress -Url $url -Destination $destPath -ProgressBar $progressBar -LogBox $Global:LogBox
        if ($ok -and (Test-Path $destPath)) {
            Write-Log "Archivo guardado: $destPath"
            [System.Windows.Forms.MessageBox]::Show("Descarga completada:`r`n$destPath", "Éxito", "OK", "Information") | Out-Null
        } else {
            Write-Log "Descarga fallida o archivo no encontrado" "ERROR"
            [System.Windows.Forms.MessageBox]::Show("La descarga falló o el archivo no se guardó.", "Error", "OK", "Error") | Out-Null
        }
    } catch {
        Write-Log "Error en descarga -> $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
    }
})

# =========================
# Inicializar
# =========================
try {
    Write-Log "Log: $Global:LogFile"
    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
} catch {
    Write-Log "Error crítico de GUI -> $($_.Exception.Message)" "ERROR"
}
