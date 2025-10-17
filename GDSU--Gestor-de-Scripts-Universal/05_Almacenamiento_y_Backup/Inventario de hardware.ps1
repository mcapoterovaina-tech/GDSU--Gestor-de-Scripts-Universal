<#
.SYNOPSIS
    Inventario de hardware: CPU, RAM, discos, GPU, BIOS/firmware y sistema. Exporta a CSV/JSON.
.DESCRIPTION
    - Recolecta datos vía CIM/WMI con fallbacks.
    - Normaliza propiedades relevantes.
    - Exporta cada categoría a CSV y JSON.
    - Genera un resumen consolidado y log de auditoría.
.NOTES
    PowerShell 5+ en Windows 10/11/Server. Ejecutar como admin para máxima cobertura.
#>

param(
    [string]$OutputPath = "C:\HardwareInventory",  # Carpeta de salida
    [switch]$IncludePerDeviceCSV,                  # CSV por categoría y por dispositivo
    [string]$Tag = "GSU",                          # Etiqueta para auditoría
    [string]$LogPath = "C:\Logs"                   # Carpeta de logs
)

# Preparación de carpetas
foreach ($p in @($OutputPath, $LogPath)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$TimeStamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapshotDir   = Join-Path $OutputPath "Snapshot_$TimeStamp"
New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null

$LogFile       = Join-Path $LogPath "HWInventory_$TimeStamp.log"
$SummaryJson   = Join-Path $SnapshotDir "summary.json"
$SummaryCsv    = Join-Path $SnapshotDir "summary.csv"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
}

function Try-Cim {
    param([string]$Class)
    try { Get-CimInstance -ClassName $Class -ErrorAction Stop }
    catch {
        Write-Log "Fallo CIM $Class. Probando WMI..." "WARN"
        try { Get-WmiObject -Class $Class -ErrorAction Stop }
        catch { Write-Log "Fallo WMI $Class: $($_.Exception.Message)" "ERROR"; @() }
    }
}

Write-Log "Iniciando inventario de hardware. Tag: $Tag"

# Sistema
$cs = Try-Cim -Class "Win32_ComputerSystem" | Select-Object Manufacturer, Model, TotalPhysicalMemory
$os = Try-Cim -Class "Win32_OperatingSystem" | Select-Object Caption, Version, OSArchitecture, BuildNumber
$sysSummary = [pscustomobject]@{
    Manufacturer        = $cs.Manufacturer
    Model               = $cs.Model
    TotalRAM_GB         = [Math]::Round(($cs.TotalPhysicalMemory/1GB),2)
    OS                  = $os.Caption
    OSVersion           = $os.Version
    Architecture        = $os.OSArchitecture
    Build               = $os.BuildNumber
}

# CPU
$cpuRaw = Try-Cim -Class "Win32_Processor"
$cpu = $cpuRaw | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, L2CacheSize, L3CacheSize, ProcessorId
$cpuFileCsv  = Join-Path $SnapshotDir "cpu.csv"
$cpuFileJson = Join-Path $SnapshotDir "cpu.json"

# RAM (módulos)
$ramRaw = Try-Cim -Class "Win32_PhysicalMemory"
$ram = $ramRaw | Select-Object BankLabel, Capacity, Speed, Manufacturer, PartNumber, SerialNumber, ConfiguredClockSpeed
$ramNormalized = $ram | ForEach-Object {
    [pscustomobject]@{
        BankLabel            = $_.BankLabel
        Capacity_GB          = [Math]::Round(($_.Capacity/1GB),2)
        Speed_MHz            = $_.Speed
        Manufacturer         = $_.Manufacturer
        PartNumber           = $_.PartNumber
        SerialNumber         = $_.SerialNumber
        ConfiguredClockSpeed = $_.ConfiguredClockSpeed
    }
}
$ramFileCsv  = Join-Path $SnapshotDir "ram.csv"
$ramFileJson = Join-Path $SnapshotDir "ram.json"

# Discos físicos
$diskRaw = Try-Cim -Class "Win32_DiskDrive"
$disk = $diskRaw | Select-Object Model, Manufacturer, InterfaceType, MediaType, SerialNumber, Size, FirmwareRevision
$diskNormalized = $disk | ForEach-Object {
    [pscustomobject]@{
        Model         = $_.Model
        Manufacturer  = $_.Manufacturer
        Interface     = $_.InterfaceType
        MediaType     = $_.MediaType
        SerialNumber  = $_.SerialNumber
        Size_GB       = if ($_.Size) { [Math]::Round(($_.Size/1GB),2) } else { $null }
        Firmware      = $_.FirmwareRevision
    }
}
$diskFileCsv  = Join-Path $SnapshotDir "disks.csv"
$diskFileJson = Join-Path $SnapshotDir "disks.json"

# GPU / Controladores de video
$gpuRaw = Try-Cim -Class "Win32_VideoController"
$gpu = $gpuRaw | Select-Object Name, DriverVersion, AdapterCompatibility, AdapterRAM, VideoProcessor
$gpuNormalized = $gpu | ForEach-Object {
    [pscustomobject]@{
        Name                 = $_.Name
        DriverVersion        = $_.DriverVersion
        Vendor               = $_.AdapterCompatibility
        VRAM_GB              = if ($_.AdapterRAM) { [Math]::Round(($_.AdapterRAM/1GB),2) } else { $null }
        VideoProcessor       = $_.VideoProcessor
    }
}
$gpuFileCsv  = Join-Path $SnapshotDir "gpu.csv"
$gpuFileJson = Join-Path $SnapshotDir "gpu.json"

# BIOS / Firmware / Placa base
$biosRaw = Try-Cim -Class "Win32_BIOS"
$bios = $biosRaw | Select-Object Manufacturer, SMBIOSBIOSVersion, BIOSVersion, ReleaseDate, SerialNumber
$mbRaw = Try-Cim -Class "Win32_BaseBoard"
$mb = $mbRaw | Select-Object Manufacturer, Product, SerialNumber, Version

$fwSummary = [pscustomobject]@{
    BIOS_Manufacturer     = $bios.Manufacturer -join "; "
    BIOS_Version          = if ($bios.SMBIOSBIOSVersion) { $bios.SMBlOSBIOSVersion } else { ($bios.BIOSVersion -join "; ") }
    BIOS_ReleaseDate      = ($bios.ReleaseDate | Select-Object -First 1)
    BIOS_Serial           = ($bios.SerialNumber | Select-Object -First 1)
    Board_Manufacturer    = $mb.Manufacturer -join "; "
    Board_Product         = $mb.Product -join "; "
    Board_Serial          = $mb.SerialNumber -join "; "
    Board_Version         = $mb.Version -join "; "
}

$biosFileCsv  = Join-Path $SnapshotDir "bios_board.csv"
$biosFileJson = Join-Path $SnapshotDir "bios_board.json"

# Exportaciones
try {
    Write-Log "Exportando CPU..."
    $cpu        | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $cpuFileCsv
    $cpu        | ConvertTo-Json -Depth 4 | Out-File -FilePath $cpuFileJson -Encoding UTF8

    Write-Log "Exportando RAM..."
    $ramNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ramFileCsv
    $ramNormalized | ConvertTo-Json -Depth 4 | Out-File -FilePath $ramFileJson -Encoding UTF8

    Write-Log "Exportando Discos..."
    $diskNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $diskFileCsv
    $diskNormalized | ConvertTo-Json -Depth 4 | Out-File -FilePath $diskFileJson -Encoding UTF8

    Write-Log "Exportando GPU..."
    $gpuNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $gpuFileCsv
    $gpuNormalized | ConvertTo-Json -Depth 4 | Out-File -Path $gpuFileJson -Encoding UTF8

    Write-Log "Exportando BIOS/Board..."
    $fwSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $biosFileCsv
    $fwSummary | ConvertTo-Json -Depth 4 | Out-File -Path $biosFileJson -Encoding UTF8
} catch {
    Write-Log "Error exportando: $($_.Exception.Message)" "ERROR"
}

# Resumen consolidado
$summary = [pscustomobject]@{
    Tag                 = $Tag
    Timestamp           = $TimeStamp
    System              = $sysSummary
    CPU                 = $cpu
    RAM_Modules         = $ramNormalized
    Disks               = $diskNormalized
    GPU                 = $gpuNormalized
    Firmware_And_Board  = $fwSummary
}
$summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $SummaryJson -Encoding UTF8

# CSV resumen plano (campos clave)
$flat = [pscustomobject]@{
    Tag              = $Tag
    Timestamp        = $TimeStamp
    Manufacturer     = $sysSummary.Manufacturer
    Model            = $sysSummary.Model
    TotalRAM_GB      = $sysSummary.TotalRAM_GB
    CPU_Name         = ($cpu | Select-Object -First 1).Name
    CPU_Cores        = ($cpu | Select-Object -First 1).NumberOfCores
    CPU_Threads      = ($cpu | Select-Object -First 1).NumberOfLogicalProcessors
    Disk_Count       = $diskNormalized.Count
    Disk_Total_GB    = [Math]::Round(($diskNormalized | Measure-Object -Property Size_GB -Sum).Sum,2)
    GPU_Primary      = ($gpuNormalized | Select-Object -First 1).Name
    BIOS_Version     = $fwSummary.BIOS_Version
}
$flat | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $SummaryCsv

Write-Log "Inventario completado. Carpeta: $SnapshotDir"
Write-Log "Archivos: cpu.*, ram.*, disks.*, gpu.*, bios_board.*, summary.json, summary.csv"
Write-Log "✅ Listo."
