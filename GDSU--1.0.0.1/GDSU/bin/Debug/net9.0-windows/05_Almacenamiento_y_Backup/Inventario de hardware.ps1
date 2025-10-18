#requires -version 5.1
# Inventario de hardware con GUI: CPU, RAM, discos, GPU y firmware
# Autor: Copilot (para Maikol)
# Ejecutar como Administrador para mayor acceso a WMI/CIM

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =========================
# Configuracion y rutas
# =========================
$Global:AppTitle   = "Inventario de Hardware"
$Global:LogRoot    = "C:\Logs\InventarioHW"
$Global:ExportRoot = Join-Path $env:USERPROFILE "Documents\InventarioHW"
$Global:LogFile    = Join-Path $Global:LogRoot ("Inventario_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

foreach ($p in @($Global:LogRoot, $Global:ExportRoot)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

# =========================
# Utilidades y logging
# =========================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpper(), $Message
    try { Add-Content -Path $Global:LogFile -Value $line } catch { }
    if ($Global:LogBox -and !$Global:LogBox.IsDisposed) {
        $Global:LogBox.AppendText("$line`r`n")
        $Global:LogBox.SelectionStart = $Global:LogBox.Text.Length
        $Global:LogBox.ScrollToCaret()
    }
}

function Get-CimSafe {
    param([Parameter(Mandatory)][string]$Class, [string]$Namespace = "root\cimv2")
    try {
        return Get-CimInstance -ClassName $Class -Namespace $Namespace -ErrorAction Stop
    } catch {
        Write-Log "Fallo CIM para $Class -> $($_.Exception.Message). Intentando WMI..." "WARN"
        try {
            return Get-WmiObject -Class $Class -Namespace $Namespace -ErrorAction Stop
        } catch {
            Write-Log "Fallo WMI para $Class -> $($_.Exception.Message)" "ERROR"
            return @()
        }
    }
}

# =========================
# Coleccion de datos
# =========================
function Collect-CPU {
    $cpu = Get-CimSafe -Class Win32_Processor
    $list = foreach ($c in $cpu) {
        [PSCustomObject]@{
            Name             = $c.Name
            Manufacturer     = $c.Manufacturer
            MaxClockMHz      = $c.MaxClockSpeed
            LogicalProcessors = $c.NumberOfLogicalProcessors
            Cores            = $c.NumberOfCores
            L2CacheKB        = $c.L2CacheSize
            L3CacheKB        = $c.L3CacheSize
            Socket           = $c.SocketDesignation
            ProcessorId      = $c.ProcessorId
        }
    }
    Write-Log "CPU: $($list.Count) elemento(s)"
    return $list
}

function Collect-RAM {
    $cs  = Get-CimSafe -Class Win32_ComputerSystem
    $mem = Get-CimSafe -Class Win32_PhysicalMemory
    $totalGB = if ($cs) { [math]::Round(($cs[0].TotalPhysicalMemory / 1GB), 2) } else { $null }
    $modules = foreach ($m in $mem) {
        [PSCustomObject]@{
            CapacityGB     = [math]::Round(($m.Capacity / 1GB), 2)
            SpeedMHz       = $m.Speed
            Manufacturer   = $m.Manufacturer
            PartNumber     = $m.PartNumber
            SerialNumber   = $m.SerialNumber
            FormFactor     = $m.FormFactor
            BankLabel      = $m.BankLabel
        }
    }
    Write-Log "RAM total: $totalGB GB, modulos: $($modules.Count)"
    return @{
        TotalGB = $totalGB
        Modules = $modules
    }
}

function Collect-Disks {
    $drives = Get-CimSafe -Class Win32_DiskDrive
    $parts  = Get-CimSafe -Class Win32_DiskPartition
    $vols   = Get-CimSafe -Class Win32_LogicalDisk

    # Mapear relaciones: DiskDrive -> DiskPartition -> LogicalDisk
    $diskMap = @()
    foreach ($d in $drives) {
        $dIndex = $d.Index
        $dParts = $parts | Where-Object { $_.DiskIndex -eq $dIndex }
        $lv = @()
        foreach ($p in $dParts) {
            $links = @(Get-CimSafe -Class Win32_LogicalDiskToPartition) | Where-Object { $_.Antecedent -match "DiskPartition.*DeviceID=`"$([regex]::Escape($p.DeviceID))`"" }
            foreach ($ln in $links) {
                $id = ($ln.Dependent -replace '.*DeviceID="([^"]+)".*','$1')
                $ld = $vols | Where-Object { $_.DeviceID -eq $id }
                if ($ld) { $lv += $ld }
            }
        }
        $diskMap += [PSCustomObject]@{
            Model        = $d.Model
            SerialNumber = $d.SerialNumber
            SizeGB       = [math]::Round(($d.Size / 1GB), 2)
            Interface    = $d.InterfaceType
            MediaType    = $d.MediaType
            Partitions   = ($dParts | Select-Object DeviceID, Type, BootPartition, Size)
            Volumes      = ($lv | Select-Object DeviceID, VolumeName, FileSystem, Size, FreeSpace)
        }
    }
    Write-Log "Discos fisicos: $($diskMap.Count)"
    return $diskMap
}

function Collect-GPU {
    try {
        $gpuRaw = Get-CimSafe -Class Win32_VideoController
    } catch {
        Write-Log "Fallo al obtener Win32_VideoController -> $($_.Exception.Message)" "ERROR"
        $gpuRaw = @()
    }

    $list = @()
    foreach ($g in @($gpuRaw)) {
        if (-not $g) { continue }
        $vramMb = $null
        try {
            if ($g.AdapterRAM -and [double]$g.AdapterRAM -gt 0) {
                $vramMb = [math]::Round(($g.AdapterRAM / 1MB), 0)
            }
        } catch { }

        $list += [PSCustomObject]@{
            Name                 = $g.Name
            AdapterCompatibility = $g.AdapterCompatibility
            DriverVersion        = $g.DriverVersion
            DriverDate           = $g.DriverDate
            VideoProcessor       = $g.VideoProcessor
            VRAM_MB              = $vramMb
            PNPDeviceID          = $g.PNPDeviceID
        }
    }

    Write-Log "GPUs: $($list.Count)"
    return $list

  return $list
}

function Collect-Firmware {
    $bios = @()
    $cs   = @()
    try { $bios = Get-CimSafe -Class Win32_BIOS } catch { $bios = @() }
    try { $cs   = Get-CimSafe -Class Win32_ComputerSystem } catch { $cs = @() }

    $biosObj = $null
    if ($bios -and $bios.Count -gt 0) {
        $b = $bios[0]
        $dateReadable = $b.ReleaseDate
        try {
            if ($b.ReleaseDate) { $dateReadable = [Management.ManagementDateTimeConverter]::ToDateTime($b.ReleaseDate) }
        } catch { }

        $biosObj = [PSCustomObject]@{
            Manufacturer        = $b.Manufacturer
            SMBIOSBIOSVersion   = $b.SMBIOSBIOSVersion
            BIOSVersion         = ($b.BIOSVersion -join " ")
            ReleaseDate         = $dateReadable
            SerialNumber        = $b.SerialNumber
            EmbeddedController  = $b.EmbeddedControllerMajorVersion
            SecureBoot          = $null
        }
    }

    try {
        $sb = Get-CimInstance -Namespace root\Microsoft\Windows\HardwareManagement -ClassName MS_SecureBoot -ErrorAction Stop
        if ($sb -and $biosObj) { $biosObj.SecureBoot = $sb.SecureBootEnabled }
    } catch {
        Write-Log "Secure Boot no disponible o sin permiso." "WARN"
    }

    # Deteccion UEFI aproximada (compatible 5.1)
    $uefi = $null
    try {
        if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\EFI") {
            $uefi = "UEFI"
        } else {
            $uefi = "Legacy/BIOS"
        }
    } catch { }

    $hostObj = $null
    if ($cs -and $cs.Count -gt 0) {
        $c = $cs[0]
        $hostObj = [PSCustomObject]@{
            Manufacturer = $c.Manufacturer
            Model        = $c.Model
            SystemType   = $c.SystemType
            UEFI         = $uefi
        }
    }

    Write-Log "Firmware/BIOS recolectado"
    return @{
        BIOS = $biosObj
        Host = $hostObj
    }
}



function Collect-AllHardware {
    Write-Log "Iniciando inventario..."

    # Secciones con tolerancia a fallos
    $cpuData = @()
    try { $cpuData = Collect-CPU } catch { Write-Log "CPU fallo -> $($_.Exception.Message)" "ERROR"; $cpuData = @() }

    $ramData = $null
    try { $ramData = Collect-RAM } catch { Write-Log "RAM fallo -> $($_.Exception.Message)" "ERROR"; $ramData = @{ TotalGB = $null; Modules = @() } }

    $diskData = @()
    try { $diskData = Collect-Disks } catch { Write-Log "Discos fallo -> $($_.Exception.Message)" "ERROR"; $diskData = @() }

    $gpuData = @()
    try { $gpuData = Collect-GPU } catch { Write-Log "GPU fallo -> $($_.Exception.Message)" "ERROR"; $gpuData = @() }

    $firmData = $null
    try { $firmData = Collect-Firmware } catch { Write-Log "Firmware fallo -> $($_.Exception.Message)" "ERROR"; $firmData = @{ BIOS = $null; Host = $null } }

    $osData = @()
    try {
        $osData = Get-CimSafe -Class Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
        # Asegurar array para CSV
        $osData = @($osData)
    } catch {
        Write-Log "SO fallo -> $($_.Exception.Message)" "ERROR"
        $osData = @()
    }

    $data = [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("s")
        ComputerName = $env:COMPUTERNAME
        CPU          = $cpuData
        RAM          = $ramData
        Disks        = $diskData
        GPU          = $gpuData
        Firmware     = $firmData
        OS           = $osData
    }

    Write-Log "Inventario finalizado"
    return $data
}


# =========================
# Exportacion
# =========================
function Export-HWJson {
    param([Parameter(Mandatory)][object]$Data, [Parameter(Mandatory)][string]$Path)
    try {
        $json = $Data | ConvertTo-Json -Depth 6
        Set-Content -Path $Path -Value $json -Encoding UTF8
        Write-Log "JSON exportado -> $Path"
        return $true
    } catch {
        Write-Log "Error exportando JSON -> $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Export-HWJson {
    param([Parameter(Mandatory)][object]$Data, [Parameter(Mandatory)][string]$Path)
    try {
        if (-not $Data) { throw "Objeto Data nulo." }
        $json = $Data | ConvertTo-Json -Depth 8
        Set-Content -Path $Path -Value $json -Encoding UTF8
        Write-Log "JSON exportado -> $Path"
        return $true
    } catch {
        Write-Log "Error exportando JSON -> $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Export-HWCsv {
    param([Parameter(Mandatory)][object]$Data, [Parameter(Mandatory)][string]$Folder)

    try {
        if (-not $Data) { throw "Objeto Data nulo." }
        if (-not (Test-Path $Folder)) { throw "Carpeta destino no existe: $Folder" }

        $base = Join-Path $Folder ("HW_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        if (!(Test-Path $base)) { New-Item -ItemType Directory -Path $base | Out-Null }

        # Normalizar secciones a arrays
        $cpuArr = @($Data.CPU)
        $ramMods = @()
        $ramTotal = [PSCustomObject]@{ TotalGB = $null }
        if ($Data.RAM) {
            $ramMods = @($Data.RAM.Modules)
            $ramTotal = [PSCustomObject]@{ TotalGB = $Data.RAM.TotalGB }
        }
        $diskArr = @($Data.Disks)
        $gpuArr = @($Data.GPU)
        $osArr = @($Data.OS)

        # Exportaciones básicas
        $cpuArr       | Export-Csv -Path (Join-Path $base "CPU.csv") -NoTypeInformation -Encoding UTF8
        $ramMods      | Export-Csv -Path (Join-Path $base "RAM_Modulos.csv") -NoTypeInformation -Encoding UTF8
        $ramTotal     | Export-Csv -Path (Join-Path $base "RAM_Total.csv") -NoTypeInformation -Encoding UTF8
        $diskArr      | Export-Csv -Path (Join-Path $base "Discos.csv") -NoTypeInformation -Encoding UTF8
        $gpuArr       | Export-Csv -Path (Join-Path $base "GPU.csv") -NoTypeInformation -Encoding UTF8
        $osArr        | Export-Csv -Path (Join-Path $base "SO.csv") -NoTypeInformation -Encoding UTF8

        # Particiones y volúmenes planos (si hay discos)
        $partsFlat = @()
        $volsFlat  = @()
        foreach ($d in $diskArr) {
            foreach ($p in @($d.Partitions)) {
                if ($p) {
                    $partsFlat += [PSCustomObject]@{
                        DiskModel    = $d.Model
                        DeviceID     = $p.DeviceID
                        Type         = $p.Type
                        BootPartition= $p.BootPartition
                        Size         = $p.Size
                    }
                }
            }
            foreach ($v in @($d.Volumes)) {
                if ($v) {
                    $volsFlat += [PSCustomObject]@{
                        DiskModel  = $d.Model
                        DeviceID   = $v.DeviceID
                        VolumeName = $v.VolumeName
                        FileSystem = $v.FileSystem
                        Size       = $v.Size
                        FreeSpace  = $v.FreeSpace
                    }
                }
            }
        }
        $partsFlat | Export-Csv -Path (Join-Path $base "Particiones.csv") -NoTypeInformation -Encoding UTF8
        $volsFlat  | Export-Csv -Path (Join-Path $base "Volumenes.csv") -NoTypeInformation -Encoding UTF8

        # Firmware si existe
        if ($Data.Firmware) {
            if ($Data.Firmware.BIOS) { @($Data.Firmware.BIOS) | Export-Csv -Path (Join-Path $base "BIOS.csv") -NoTypeInformation -Encoding UTF8 }
            if ($Data.Firmware.Host) { @($Data.Firmware.Host) | Export-Csv -Path (Join-Path $base "Host.csv") -NoTypeInformation -Encoding UTF8 }
        }

        Write-Log "CSVs exportados -> $base"
        return $true
    } catch {
        Write-Log "Error exportando CSV -> $($_.Exception.Message)" "ERROR"
        return $false
    }
}


# =========================
# GUI
# =========================
$form = New-Object System.Windows.Forms.Form
$form.Text = $Global:AppTitle
$form.Size = New-Object System.Drawing.Size(920, 640)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Inventario de Hardware"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20,20)
$lblTitle.TabIndex = 0
$form.Controls.Add($lblTitle)

$gbOptions = New-Object System.Windows.Forms.GroupBox
$gbOptions.Text = "Opciones de exportacion"
$gbOptions.ForeColor = [System.Drawing.Color]::White
$gbOptions.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbOptions.Size = New-Object System.Drawing.Size(880, 140)
$gbOptions.Location = New-Object System.Drawing.Point(20,60)
$gbOptions.TabIndex = 1
$gbOptions.Anchor = "Top,Left,Right"
$form.Controls.Add($gbOptions)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = "Carpeta destino:"
$lblFolder.ForeColor = [System.Drawing.Color]::White
$lblFolder.AutoSize = $true
$lblFolder.Location = New-Object System.Drawing.Point(20,40)
$lblFolder.TabIndex = 0
$gbOptions.Controls.Add($lblFolder)

$tbFolder = New-Object System.Windows.Forms.TextBox
$tbFolder.Text = $Global:ExportRoot
$tbFolder.Size = New-Object System.Drawing.Size(630, 24)
$tbFolder.Location = New-Object System.Drawing.Point(130,36)
$tbFolder.TabIndex = 1
$tbFolder.Anchor = "Top,Left,Right"
$gbOptions.Controls.Add($tbFolder)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = "Examinar..."
$btnFolder.Size = New-Object System.Drawing.Size(100, 28)
$btnFolder.Location = New-Object System.Drawing.Point(770,34)
$btnFolder.TabIndex = 2
$btnFolder.Anchor = "Top,Right"
$gbOptions.Controls.Add($btnFolder)

$lblName = New-Object System.Windows.Forms.Label
$lblName.Text = "Nombre de archivo base:"
$lblName.ForeColor = [System.Drawing.Color]::White
$lblName.AutoSize = $true
$lblName.Location = New-Object System.Drawing.Point(20,80)
$lblName.TabIndex = 3
$gbOptions.Controls.Add($lblName)

$tbName = New-Object System.Windows.Forms.TextBox
$tbName.Text = ("Inventario_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$tbName.Size = New-Object System.Drawing.Size(260, 24)
$tbName.Location = New-Object System.Drawing.Point(200,76)
$tbName.TabIndex = 4
$gbOptions.Controls.Add($tbName)

$btnCollect = New-Object System.Windows.Forms.Button
$btnCollect.Text = "Recolectar datos"
$btnCollect.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
$btnCollect.ForeColor = [System.Drawing.Color]::White
$btnCollect.Size = New-Object System.Drawing.Size(150, 36)
$btnCollect.Location = New-Object System.Drawing.Point(480,72)
$btnCollect.TabIndex = 5
$btnCollect.Anchor = "Top"
$gbOptions.Controls.Add($btnCollect)

$btnExportJson = New-Object System.Windows.Forms.Button
$btnExportJson.Text = "Exportar JSON"
$btnExportJson.BackColor = [System.Drawing.Color]::FromArgb(16,124,16)
$btnExportJson.ForeColor = [System.Drawing.Color]::White
$btnExportJson.Size = New-Object System.Drawing.Size(140, 36)
$btnExportJson.Location = New-Object System.Drawing.Point(640,72)
$btnExportJson.TabIndex = 6
$btnExportJson.Anchor = "Top,Right"
$gbOptions.Controls.Add($btnExportJson)

$btnExportCsv = New-Object System.Windows.Forms.Button
$btnExportCsv.Text = "Exportar CSVs"
$btnExportCsv.BackColor = [System.Drawing.Color]::FromArgb(217,96,0)
$btnExportCsv.ForeColor = [System.Drawing.Color]::White
$btnExportCsv.Size = New-Object System.Drawing.Size(140, 36)
$btnExportCsv.Location = New-Object System.Drawing.Point(790,72)
$btnExportCsv.TabIndex = 7
$btnExportCsv.Anchor = "Top,Right"
$gbOptions.Controls.Add($btnExportCsv)

$gbPreview = New-Object System.Windows.Forms.GroupBox
$gbPreview.Text = "Vista previa (resumen y logs)"
$gbPreview.ForeColor = [System.Drawing.Color]::White
$gbPreview.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbPreview.Size = New-Object System.Drawing.Size(880, 380)
$gbPreview.Location = New-Object System.Drawing.Point(20,210)
$gbPreview.TabIndex = 2
$gbPreview.Anchor = "Top,Left,Right,Bottom"
$form.Controls.Add($gbPreview)

# LogBox dentro de la vista previa (parte superior)
$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Multiline = $true
$Global:LogBox.ReadOnly = $true
$Global:LogBox.ScrollBars = "Vertical"
$Global:LogBox.BackColor = [System.Drawing.Color]::Black
$Global:LogBox.ForeColor = [System.Drawing.Color]::LightGreen
$Global:LogBox.Size = New-Object System.Drawing.Size(840, 120)
$Global:LogBox.Location = New-Object System.Drawing.Point(20,30)
$Global:LogBox.TabIndex = 0
$Global:LogBox.Anchor = "Top,Left,Right"
$gbPreview.Controls.Add($Global:LogBox)

# Resumen (parte inferior)
$tbPreview = New-Object System.Windows.Forms.TextBox
$tbPreview.Multiline = $true
$tbPreview.ReadOnly = $true
$tbPreview.ScrollBars = "Vertical"
$tbPreview.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$tbPreview.ForeColor = [System.Drawing.Color]::Gainsboro
$tbPreview.Size = New-Object System.Drawing.Size(840, 220)
$tbPreview.Location = New-Object System.Drawing.Point(20,160)
$tbPreview.TabIndex = 1
$tbPreview.Anchor = "Top,Left,Right,Bottom"
$gbPreview.Controls.Add($tbPreview)

# Estado inicial de botones de exportacion (se habilitan tras recolectar)
$btnExportJson.Enabled = $false
$btnExportCsv.Enabled  = $false


# =========================
# Eventos
# =========================

# Selección de carpeta
$btnFolder.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path $tbFolder.Text) { $fbd.SelectedPath = $tbFolder.Text }
    if ($fbd.ShowDialog() -eq "OK") {
        $tbFolder.Text = $fbd.SelectedPath
        Write-Log "Carpeta destino seleccionada: $($tbFolder.Text)"
    }
})

$Global:CurrentData = $null

# Recolección de hardware
$btnCollect.Add_Click({
    try {
        Write-Log "Recolectando hardware..."
        $Global:CurrentData = Collect-AllHardware

        if (-not $Global:CurrentData) {
            Write-Log "No se pudo recolectar datos de hardware." "ERROR"
            return
        }

        # Resumen human-readable con validaciones
        $summary = @()

        if ($Global:CurrentData.CPU) {
            $cpu = $Global:CurrentData.CPU | ForEach-Object { "$($_.Name) | $($_.Cores)C/$($_.LogicalProcessors)L @ $($_.MaxClockMHz)MHz" }
            $summary += "CPU: " + ($cpu -join "; ")
        }

        if ($Global:CurrentData.GPU) {
            $gpu = $Global:CurrentData.GPU | ForEach-Object { "$($_.Name) (VRAM: $($_.VRAM_MB)MB)" }
            $summary += "GPU: " + ($gpu -join "; ")
        }

        if ($Global:CurrentData.RAM) {
            $ram = "Total: $($Global:CurrentData.RAM.TotalGB) GB | Modulos: $($Global:CurrentData.RAM.Modules.Count)"
            $summary += "RAM: " + $ram
        }

        if ($Global:CurrentData.OS) {
            $os  = $Global:CurrentData.OS | Select-Object -First 1
            $summary += "SO: $($os.Caption) $($os.Version) ($($os.OSArchitecture)) Build $($os.BuildNumber)"
        }

        if ($Global:CurrentData.Firmware -and $Global:CurrentData.Firmware.BIOS) {
            $firm = $Global:CurrentData.Firmware.BIOS
            $date = try { [Management.ManagementDateTimeConverter]::ToDateTime($firm.ReleaseDate) } catch { $firm.ReleaseDate }
            $summary += "BIOS: $($firm.Manufacturer) $($firm.SMBIOSBIOSVersion) fecha $date"
        }

        if ($Global:CurrentData.Disks) {
            $summary += "Discos: $($Global:CurrentData.Disks.Count)"
        }

        $tbPreview.Text = ($summary -join "`r`n")
        Write-Log "Hardware recolectado y resumido"

        # Habilitar exportación
        $btnExportJson.Enabled = $true
        $btnExportCsv.Enabled  = $true

    } catch {
        Write-Log "Error recolectando hardware -> $($_.Exception.Message)" "ERROR"
    }
})

# Exportar JSON
$btnExportJson.Add_Click({
    try {
        if (-not $Global:CurrentData) {
            [System.Windows.Forms.MessageBox]::Show("Primero recolecta datos.", "Aviso", "OK", "Information") | Out-Null
            return
        }
        if (-not (Test-Path $tbFolder.Text)) {
            [System.Windows.Forms.MessageBox]::Show("La carpeta destino no existe.", "Error", "OK", "Error") | Out-Null
            return
        }
        $path = Join-Path $tbFolder.Text ($tbName.Text + ".json")
        if (Export-HWJson -Data $Global:CurrentData -Path $path) {
            [System.Windows.Forms.MessageBox]::Show("JSON exportado en:`r`n$path", "Exito", "OK", "Information") | Out-Null
        }
    } catch {
        Write-Log "Error exportando JSON -> $($_.Exception.Message)" "ERROR"
    }
})

# Exportar CSV
$btnExportCsv.Add_Click({
    try {
        if (-not $Global:CurrentData) {
            [System.Windows.Forms.MessageBox]::Show("Primero recolecta datos.", "Aviso", "OK", "Information") | Out-Null
            return
        }
        if (-not (Test-Path $tbFolder.Text)) {
            [System.Windows.Forms.MessageBox]::Show("La carpeta destino no existe.", "Error", "OK", "Error") | Out-Null
            return
        }
        $folder = $tbFolder.Text
        if (Export-HWCsv -Data $Global:CurrentData -Folder $folder) {
            [System.Windows.Forms.MessageBox]::Show("CSVs exportados en subcarpeta dentro:`r`n$folder", "Exito", "OK", "Information") | Out-Null
        }
    } catch {
        Write-Log "Error exportando CSV -> $($_.Exception.Message)" "ERROR"
    }
})

# =========================
# Inicializar
# =========================
try {
    Write-Log "Log: $Global:LogFile"
    $btnExportJson.Enabled = $false
    $btnExportCsv.Enabled  = $false
    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
} catch {
    Write-Log "Error critico de GUI -> $($_.Exception.Message)" "ERROR"
}