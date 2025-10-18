<# 
.SYNOPSIS
  App WPF en tiempo real con tablas y gráficos incrustados para inventario de hardware.
.NOTES
  - Requiere STA para WPF. Bootstrap incluido.
  - PowerShell 5.1+ en Windows. Ejecutar como admin para cobertura total de WMI/CIM.
#>

param(
  [string]$OutputPath = "C:\HardwareInventory",
  [switch]$IncludePerDeviceCSV,
  [string]$Tag = "GSU",
  [string]$LogPath = "C:\Logs",
  [int]$RefreshSeconds = 10
)

# --- Garantizar STA ---
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  $argsList = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$PSCommandPath`"")

  if ($OutputPath)          { $argsList += "-OutputPath";         $argsList += "`"$OutputPath`"" }
  if ($IncludePerDeviceCSV) { $argsList += "-IncludePerDeviceCSV" }
  if ($Tag)                 { $argsList += "-Tag";                $argsList += "`"$Tag`"" }
  if ($LogPath)             { $argsList += "-LogPath";            $argsList += "`"$LogPath`"" }
  if ($RefreshSeconds)      { $argsList += "-RefreshSeconds";     $argsList += "$RefreshSeconds" }

  $exe = (Get-Command powershell).Source
  Start-Process -FilePath $exe -ArgumentList $argsList -WindowStyle Normal
  return
}

# --- Dependencias WPF + Charts ---
try {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
  Add-Type -AssemblyName WindowsFormsIntegration
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Windows.Forms.DataVisualization
} catch {
  Write-Host "Error cargando ensamblados WPF/Charting: $($_.Exception.Message)" -ForegroundColor Red
  exit
}

# --- Preparación de carpetas y estado ---
foreach ($p in @($OutputPath, $LogPath)) {
  if (-not (Test-Path $p)) {
    New-Item -ItemType Directory -Path $p -Force | Out-Null
  }
}

$TimeStamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$SnapshotDir = Join-Path $OutputPath "Snapshot_$TimeStamp"
New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null
$LogFile     = Join-Path $LogPath "HWInventory_$TimeStamp.log"
$SummaryJson = Join-Path $SnapshotDir "summary.json"
$SummaryCsv  = Join-Path $SnapshotDir "summary.csv"

function Write-Log {
  param([string]$Message, [string]$Level = "INFO")
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
  Add-Content -Path $LogFile -Value $line
  $color = switch ($Level) {
    "ERROR" { "Red" }
    "WARN"  { "Yellow" }
    default { "Green" }
  }
  Write-Host $line -ForegroundColor $color
}

function Try-Cim {
  param([string]$Class)
  try {
    Get-CimInstance -ClassName $Class -ErrorAction Stop
  } catch {
    Write-Log "Fallo CIM ${Class}. Probando WMI..." "WARN"
    try {
      Get-WmiObject -Class $Class -ErrorAction Stop
    } catch {
      $msg = $_.Exception.Message
      Write-Log "Fallo WMI ${Class}: $msg" "ERROR"
      @()
    }
  }
}



$State = [pscustomobject]@{
  Tag         = $Tag
  SnapshotDir = $SnapshotDir
  IncludeCSV  = $IncludePerDeviceCSV.IsPresent
  FilterText  = ''
  Paused      = $false
  IntervalSec = [math]::Max(2, $RefreshSeconds)
  Counts      = @{}
}

# --- XAML: layout con tabs y contenedores para gráficos (WindowsFormsHost) ---
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:wfi="clr-namespace:System.Windows.Forms.Integration;assembly=WindowsFormsIntegration"
        Title="Hardware Inventory (Realtime + Charts)" Height="780" Width="1200" Background="#1E1E1E" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#1E1E1E"/>
      <Setter Property="Foreground" Value="#DDDDDD"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="AlternationCount" Value="2"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="#202020"/>
      <Style.Triggers>
        <Trigger Property="ItemsControl.AlternationIndex" Value="1">
          <Setter Property="Background" Value="#242424"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#DDDDDD"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
    </Style>
  </Window.Resources>

  <DockPanel Margin="12">
    <!-- Header -->
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBox x:Name="FilterBox" Width="280" Margin="0,0,8,0" ToolTip="Filtrar por texto en la pestaña actual"/>
      <Button x:Name="ExportAllBtn" Content="Exportar todo (CSV/JSON)"/>
      <Button x:Name="OpenFolderBtn" Content="Abrir carpeta Snapshot"/>
      <Button x:Name="PauseResumeBtn" Content="Pausar"/>
      <TextBlock Text="Intervalo (s)" Margin="12,0,6,0"/>
      <Slider x:Name="IntervalSlider" Minimum="2" Maximum="60" Width="160" TickFrequency="2" IsSnapToTickEnabled="True"/>
      <TextBlock x:Name="IntervalValue" Margin="8,0,0,0"/>
      <TextBlock Text="  |  Tag:" Margin="12,0,4,0"/>
      <TextBlock x:Name="TagText"/>
      <TextBlock Text="  |  Snapshot:" Margin="12,0,4,0"/>
      <TextBlock x:Name="SnapshotPathText"/>
    </StackPanel>

    <!-- Tabs -->
    <TabControl x:Name="Tabs">
      <TabItem Header="Sistema">
        <Grid Margin="0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <TextBlock x:Name="SysBadge" />
          </StackPanel>
          <DataGrid x:Name="GridSys" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Fabricante" Binding="{Binding Manufacturer}" Width="180"/>
              <DataGridTextColumn Header="Modelo" Binding="{Binding Model}" Width="220"/>
              <DataGridTextColumn Header="RAM Total (GB)" Binding="{Binding TotalRAM_GB}" Width="120"/>
              <DataGridTextColumn Header="OS" Binding="{Binding OS}" Width="220"/>
              <DataGridTextColumn Header="Versión" Binding="{Binding OSVersion}" Width="120"/>
              <DataGridTextColumn Header="Arquitectura" Binding="{Binding Architecture}" Width="120"/>
              <DataGridTextColumn Header="Build" Binding="{Binding Build}" Width="80"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem Header="CPU">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="3*"/>
          </Grid.ColumnDefinitions>
          <DataGrid x:Name="GridCPU" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Nombre" Binding="{Binding Name}" Width="*"/>
              <DataGridTextColumn Header="Fabricante" Binding="{Binding Manufacturer}" Width="160"/>
              <DataGridTextColumn Header="Cores" Binding="{Binding NumberOfCores}" Width="80"/>
              <DataGridTextColumn Header="Threads" Binding="{Binding NumberOfLogicalProcessors}" Width="90"/>
              <DataGridTextColumn Header="Max MHz" Binding="{Binding MaxClockSpeed}" Width="90"/>
              <DataGridTextColumn Header="L2 KB" Binding="{Binding L2CacheSize}" Width="80"/>
              <DataGridTextColumn Header="L3 KB" Binding="{Binding L3CacheSize}" Width="80"/>
              <DataGridTextColumn Header="ProcessorId" Binding="{Binding ProcessorId}" Width="240"/>
            </DataGrid.Columns>
          </DataGrid>
          <WindowsFormsHost x:Name="ChartCPUHost" Grid.Column="1" Margin="8,0,0,0"/>
        </Grid>
      </TabItem>

      <TabItem Header="RAM">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="3*"/>
          </Grid.ColumnDefinitions>
          <DataGrid x:Name="GridRAM" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Bank" Binding="{Binding BankLabel}" Width="160"/>
              <DataGridTextColumn Header="Capacidad (GB)" Binding="{Binding Capacity_GB}" Width="120"/>
              <DataGridTextColumn Header="Speed (MHz)" Binding="{Binding Speed_MHz}" Width="120"/>
              <DataGridTextColumn Header="Manufacturer" Binding="{Binding Manufacturer}" Width="160"/>
              <DataGridTextColumn Header="PartNumber" Binding="{Binding PartNumber}" Width="160"/>
              <DataGridTextColumn Header="Serial" Binding="{Binding SerialNumber}" Width="160"/>
              <DataGridTextColumn Header="ConfiguredClock" Binding="{Binding ConfiguredClockSpeed}" Width="140"/>
            </DataGrid.Columns>
          </DataGrid>
          <WindowsFormsHost x:Name="ChartRAMHost" Grid.Column="1" Margin="8,0,0,0"/>
        </Grid>
      </TabItem>

      <TabItem Header="Discos">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="3*"/>
          </Grid.ColumnDefinitions>
          <DataGrid x:Name="GridDisk" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Modelo" Binding="{Binding Model}" Width="220"/>
              <DataGridTextColumn Header="Fabricante" Binding="{Binding Manufacturer}" Width="160"/>
              <DataGridTextColumn Header="Interfaz" Binding="{Binding Interface}" Width="120"/>
              <DataGridTextColumn Header="Tipo" Binding="{Binding MediaType}" Width="120"/>
              <DataGridTextColumn Header="Serial" Binding="{Binding SerialNumber}" Width="220"/>
              <DataGridTextColumn Header="Tamaño (GB)" Binding="{Binding Size_GB}" Width="120"/>
              <DataGridTextColumn Header="Firmware" Binding="{Binding Firmware}" Width="120"/>
            </DataGrid.Columns>
          </DataGrid>
          <WindowsFormsHost x:Name="ChartDiskHost" Grid.Column="1" Margin="8,0,0,0"/>
        </Grid>
      </TabItem>

      <TabItem Header="GPU">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="3*"/>
          </Grid.ColumnDefinitions>
          <DataGrid x:Name="GridGPU" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Nombre" Binding="{Binding Name}" Width="260"/>
              <DataGridTextColumn Header="Driver" Binding="{Binding DriverVersion}" Width="160"/>
              <DataGridTextColumn Header="Vendor" Binding="{Binding Vendor}" Width="160"/>
              <DataGridTextColumn Header="VRAM (GB)" Binding="{Binding VRAM_GB}" Width="120"/>
              <DataGridTextColumn Header="VideoProcessor" Binding="{Binding VideoProcessor}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
          <WindowsFormsHost x:Name="ChartGPUHost" Grid.Column="1" Margin="8,0,0,0"/>
        </Grid>
      </TabItem>

      <TabItem Header="BIOS / Board">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DataGrid x:Name="GridFW" AutoGenerateColumns="False" IsReadOnly="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="BIOS Fabricante" Binding="{Binding BIOS_Manufacturer}" Width="220"/>
              <DataGridTextColumn Header="BIOS Versión" Binding="{Binding BIOS_Version}" Width="220"/>
              <DataGridTextColumn Header="ReleaseDate" Binding="{Binding BIOS_ReleaseDate}" Width="160"/>
              <DataGridTextColumn Header="BIOS Serial" Binding="{Binding BIOS_Serial}" Width="160"/>
              <DataGridTextColumn Header="Board Fabricante" Binding="{Binding Board_Manufacturer}" Width="220"/>
              <DataGridTextColumn Header="Board Producto" Binding="{Binding Board_Product}" Width="220"/>
              <DataGridTextColumn Header="Board Serial" Binding="{Binding Board_Serial}" Width="160"/>
              <DataGridTextColumn Header="Board Version" Binding="{Binding Board_Version}" Width="160"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- Footer -->
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock x:Name="StatusText"/>
      <TextBlock Text="  |  "/>
      <TextBlock Text="Items:"/>
      <TextBlock x:Name="CountText"/>
    </StackPanel>
  </DockPanel>
</Window>
"@

# --- Cargar UI y referencias ---
$reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$FilterBox         = $window.FindName('FilterBox')
$ExportAllBtn      = $window.FindName('ExportAllBtn')
$OpenFolderBtn     = $window.FindName('OpenFolderBtn')
$PauseResumeBtn    = $window.FindName('PauseResumeBtn')
$IntervalSlider    = $window.FindName('IntervalSlider')
$IntervalValue     = $window.FindName('IntervalValue')
$TagText           = $window.FindName('TagText')
$SnapshotPathText  = $window.FindName('SnapshotPathText')
$StatusText        = $window.FindName('StatusText')
$CountText         = $window.FindName('CountText')
$Tabs              = $window.FindName('Tabs')
$SysBadge          = $window.FindName('SysBadge')

$GridSys = $window.FindName('GridSys')
$GridCPU = $window.FindName('GridCPU')
$GridRAM = $window.FindName('GridRAM')
$GridDisk= $window.FindName('GridDisk')
$GridGPU = $window.FindName('GridGPU')
$GridFW  = $window.FindName('GridFW')

$ChartCPUHost = $window.FindName('ChartCPUHost')
$ChartRAMHost = $window.FindName('ChartRAMHost')
$ChartDiskHost= $window.FindName('ChartDiskHost')
$ChartGPUHost = $window.FindName('ChartGPUHost')

$TagText.Text = $State.Tag
$SnapshotPathText.Text = $State.SnapshotDir
$IntervalSlider.Value  = [double]$State.IntervalSec
$IntervalValue.Text    = "$($State.IntervalSec)s"

# --- Crear Chart controls y asignar al host ---
function New-ChartControl([string]$title,[string]$yTitle) {
  $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
  $chart.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
  $chart.ForeColor = [System.Drawing.Color]::White
  $chart.Dock = [System.Windows.Forms.DockStyle]::Fill

  $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea "Main"
  $area.BackColor = [System.Drawing.Color]::FromArgb(34,34,34)
  $area.AxisX.Interval = 1
  $area.AxisX.LabelStyle.ForeColor = [System.Drawing.Color]::White
  $area.AxisY.LabelStyle.ForeColor = [System.Drawing.Color]::White
  $area.AxisY.Title = $yTitle
  $area.AxisY.TitleForeColor = [System.Drawing.Color]::White
  $chart.ChartAreas.Add($area)

  $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
  $legend.ForeColor = [System.Drawing.Color]::White
  $chart.Legends.Add($legend)

  $chart.Titles.Add($title) | Out-Null
  $chart.Titles[0].ForeColor = [System.Drawing.Color]::White
  return $chart
}
# Instanciar y montar charts
$cpuChart  = New-ChartControl "CPU logical processors" "Threads"
$ramChart  = New-ChartControl "RAM modules capacity (GB)" "GB"
$diskChart = New-ChartControl "Disk size (GB)" "GB"
$gpuChart  = New-ChartControl "GPU VRAM (GB)" "GB"

$ChartCPUHost.Child  = $cpuChart
$ChartRAMHost.Child  = $ramChart
$ChartDiskHost.Child = $diskChart
$ChartGPUHost.Child  = $gpuChart

# --- Datos en memoria ---
$sysSummary = $null
$cpu = $null
$ramNormalized = $null
$diskNormalized = $null
$gpuNormalized = $null
$fwSummary = $null

function Collect-Inventory {
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

  # RAM
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

  # Discos
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

  # GPU
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

  # BIOS / Board
  $biosRaw = Try-Cim -Class "Win32_BIOS"
  $bios = $biosRaw | Select-Object Manufacturer, SMBIOSBIOSVersion, BIOSVersion, ReleaseDate, SerialNumber
  $mbRaw = Try-Cim -Class "Win32_BaseBoard"
  $mb = $mbRaw | Select-Object Manufacturer, Product, SerialNumber, Version

  $fwSummary = [pscustomobject]@{
    BIOS_Manufacturer     = $bios.Manufacturer -join "; "
    BIOS_Version          = if ($bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion } else { ($bios.BIOSVersion -join "; ") }
    BIOS_ReleaseDate      = ($bios.ReleaseDate | Select-Object -First 1)
    BIOS_Serial           = ($bios.SerialNumber | Select-Object -First 1)
    Board_Manufacturer    = $mb.Manufacturer -join "; "
    Board_Product         = $mb.Product -join "; "
    Board_Serial          = $mb.SerialNumber -join "; "
    Board_Version         = $mb.Version -join "; "
  }

  $State.Counts = @{
    Sys   = 1
    CPU   = ($cpu | Measure-Object).Count
    RAM   = ($ramNormalized | Measure-Object).Count
    Disk  = ($diskNormalized | Measure-Object).Count
    GPU   = ($gpuNormalized | Measure-Object).Count
    FW    = 1
  }
}

# --- Filtro y binding ---
function Passes-Filter { param($item, [string]$text)
  if ([string]::IsNullOrWhiteSpace($text)) { return $true }
  $t = $text.ToLowerInvariant()
  foreach ($p in $item.PSObject.Properties) {
    $v = [string]$p.Value
    if ($v -and $v.ToLowerInvariant().Contains($t)) { return $true }
  }
  return $false
}

function Bind-Tables {
  $GridSys.ItemsSource  = ,$sysSummary
  $GridCPU.ItemsSource  = $cpu
  $GridRAM.ItemsSource  = $ramNormalized
  $GridDisk.ItemsSource = $diskNormalized
  $GridGPU.ItemsSource  = $gpuNormalized
  $GridFW.ItemsSource   = ,$fwSummary

  $CountText.Text = "Sys:$($State.Counts.Sys) CPU:$($State.Counts.CPU) RAM:$($State.Counts.RAM) Disk:$($State.Counts.Disk) GPU:$($State.Counts.GPU) FW:$($State.Counts.FW)"
  $StatusText.Text = "Última actualización: $(Get-Date -Format 'HH:mm:ss') | Intervalo: $($State.IntervalSec)s | Pausado: $($State.Paused)"
  $SysBadge.Text = "Equipo: $($sysSummary.Manufacturer) $($sysSummary.Model) | OS: $($sysSummary.OS) ($($sysSummary.OSVersion)) | RAM Total: $($sysSummary.TotalRAM_GB) GB"
}

function Apply-Filter {
  $tab = $Tabs.SelectedItem.Header
  switch ($tab) {
    'Sistema'      { $GridSys.ItemsSource  = (, $sysSummary | Where-Object { Passes-Filter $_ $State.FilterText }) }
    'CPU'          { $GridCPU.ItemsSource  = ($cpu | Where-Object { Passes-Filter $_ $State.FilterText }) }
    'RAM'          { $GridRAM.ItemsSource  = ($ramNormalized | Where-Object { Passes-Filter $_ $State.FilterText }) }
    'Discos'       { $GridDisk.ItemsSource = ($diskNormalized | Where-Object { Passes-Filter $_ $State.FilterText }) }
    'GPU'          { $GridGPU.ItemsSource  = ($gpuNormalized | Where-Object { Passes-Filter $_ $State.FilterText }) }
    'BIOS / Board' { $GridFW.ItemsSource   = (, $fwSummary | Where-Object { Passes-Filter $_ $State.FilterText }) }
  }
}

# --- Render de gráficos ---
function Update-BarChart($chart, [object[]]$items, [string]$labelProp, [string]$valueProp, [int]$maxHint) {
  $chart.Series.Clear()
  $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series "Data"
  $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Bar
  $series.Color = [System.Drawing.Color]::FromArgb(76,175,80) # verde
  $series.BackSecondaryColor = [System.Drawing.Color]::FromArgb(33,150,243) # azul
  $series.BorderWidth = 1

  # Eje Y escala
  $area = $chart.ChartAreas["Main"]
  $vals = @()
  foreach ($it in $items) {
    $v = $it.$valueProp
    if ($v -ne $null) { $vals += [double]$v }
  }
  $maxVal = if ($vals.Count -gt 0) { [double]([Math]::Max($vals)) } else { 0 }
  if ($maxHint -gt 0) { $maxVal = [Math]::Max($maxVal, $maxHint) }
  if ($maxVal -le 0) { $maxVal = 1 }
  $area.AxisY.Minimum = 0
  $area.AxisY.Maximum = [Math]::Ceiling($maxVal * 1.1)

  # Datos
  $i = 0
  foreach ($it in $items) {
    $label = [string]$it.$labelProp
    $value = $it.$valueProp
    if (($value -ne $null) -and ($label)) {
      $p = $series.Points.Add([double]$value)
      $series.Points[$i].AxisLabel = if ($label.Length -gt 20) { $label.Substring(0,20) + "…" } else { $label }
      $series.Points[$i].Label = [string]$value
      $i++
    }
  }
  $chart.Series.Add($series)
}

function Render-Charts {
  # CPU: threads por CPU
  Update-BarChart -chart $cpuChart -items $cpu -labelProp 'Name' -valueProp 'NumberOfLogicalProcessors' -maxHint 0
  # RAM: capacidad por módulo
  Update-BarChart -chart $ramChart -items $ramNormalized -labelProp 'BankLabel' -valueProp 'Capacity_GB' -maxHint 0
  # Discos: tamaño por disco
  Update-BarChart -chart $diskChart -items $diskNormalized -labelProp 'Model' -valueProp 'Size_GB' -maxHint 0
  # GPU: VRAM por adaptador
  Update-BarChart -chart $gpuChart -items $gpuNormalized -labelProp 'Name' -valueProp 'VRAM_GB' -maxHint 0
}

# --- Exportación ---
function Export-All {
  try {
    # CPU
    $cpu        | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "cpu.csv")
    $cpu        | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $State.SnapshotDir "cpu.json") -Encoding UTF8
    # RAM
    $ramNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "ram.csv")
    $ramNormalized | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $State.SnapshotDir "ram.json") -Encoding UTF8
    # Discos
    $diskNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "disks.csv")
    $diskNormalized | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $State.SnapshotDir "disks.json") -Encoding UTF8
    # GPU
    $gpuNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "gpu.csv")
    $gpuNormalized | ConvertTo-Json -Depth 4 | Out-File -Path (Join-Path $State.SnapshotDir "gpu.json") -Encoding UTF8
    # BIOS/Board
    (, $fwSummary) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "bios_board.csv")
    $fwSummary | ConvertTo-Json -Depth 4 | Out-File -Path (Join-Path $State.SnapshotDir "bios_board.json") -Encoding UTF8

    # Resumen consolidado
    $summary = [pscustomobject]@{
      Tag                 = $State.Tag
      Timestamp           = $TimeStamp
      System              = $sysSummary
      CPU                 = $cpu
      RAM_Modules         = $ramNormalized
      Disks               = $diskNormalized
      GPU                 = $gpuNormalized
      Firmware_And_Board  = $fwSummary
    }
    $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $SummaryJson -Encoding UTF8

    # CSV plano
    $flat = [pscustomobject]@{
      Tag              = $State.Tag
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

    if ($State.IncludeCSV) {
      $cpu | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "cpu_per_device.csv")
      $ramNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "ram_per_device.csv")
      $diskNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "disks_per_device.csv")
      $gpuNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "gpu_per_device.csv")
    }

    [System.Windows.MessageBox]::Show("Exportación completada en:`n$($State.SnapshotDir)","Exportación", 'OK','Information') | Out-Null
  } catch {
    [System.Windows.MessageBox]::Show("Error exportando:`n$($_.Exception.Message)","Error", 'OK','Error') | Out-Null
  }
}

# --- Eventos UI ---
$FilterBox.Add_TextChanged({
  $State.FilterText = $FilterBox.Text
  Apply-Filter
})

$Tabs.Add_SelectionChanged({
  Apply-Filter
})

$ExportAllBtn.Add_Click({
  Export-All
})

$OpenFolderBtn.Add_Click({
  try {
    Start-Process explorer.exe $State.SnapshotDir
  } catch {}
})

$PauseResumeBtn.Add_Click({
  $State.Paused = -not $State.Paused
  if ($State.Paused) {
    $PauseResumeBtn.Content = 'Continuar'
  } else {
    $PauseResumeBtn.Content = 'Pausar'
  }
  $StatusText.Text = "Última actualización: $(Get-Date -Format 'HH:mm:ss') | Intervalo: $($State.IntervalSec)s | Pausado: $($State.Paused)"
})

$IntervalSlider.Add_ValueChanged({
  $State.IntervalSec = [int]$IntervalSlider.Value
  $IntervalValue.Text = "$($State.IntervalSec)s"
  $timer.Interval = [TimeSpan]::FromSeconds([double]$State.IntervalSec)
})

# --- Timer de refresco continuo ---
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([double]$State.IntervalSec)
$timer.Add_Tick({
  if (-not $State.Paused) {
    Collect-Inventory
    Bind-Tables
    Apply-Filter
    Render-Charts
  }
})
$timer.Start()

# --- Primera carga y mostrar ventana ---
Collect-Inventory
Bind-Tables
Apply-Filter
Render-Charts

if (-not [System.Windows.Application]::Current) {
  $app = New-Object System.Windows.Application
  $app.Run($window) | Out-Null
} else {
  $null = $window.ShowDialog()
}
