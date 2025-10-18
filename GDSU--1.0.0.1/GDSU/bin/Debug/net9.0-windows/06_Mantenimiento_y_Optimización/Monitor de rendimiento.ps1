<# 
.SYNOPSIS
  UI de procesos en tiempo real: CPU%, RAM, I/O y acciones seguras (Kill), con búsqueda y resaltado por umbral.

.DESCRIPTION
  - Mide periódicamente CPU% por proceso (delta de TotalProcessorTime) y RAM (WorkingSet).
  - Calcula I/O Read/Write bytes/sec por proceso usando deltas.
  - Muestra DataGrid WPF con orden, filtro, y color por umbrales.
  - Incluye acciones: Refresh inmediato y Kill con confirmación.
  - Diseñado para integrarse con tu monitor existente (intervalo y umbrales compartidos).

.NOTES
  - Red por proceso es limitada en PowerShell sin ETW; se expone "I/O Total Bps" como proxy de actividad.
  - Requiere PowerShell 5+ y .NET WPF disponible (Windows).
#>

[CmdletBinding()]
param(
  [int]$IntervalSeconds = 2,
  [double]$CpuHighPercent = 50.0,
  [int]$RamHighMB = 500,              # WorkingSet alto, en MB
  [double]$IoHighBps = 5MB,           # umbral alto para Read+Write bytes/sec
  [int]$AlertOnConsecutive = 3,       # consecutivos para resaltar fuerte
  [switch]$TopByCPU,                  # si se activa, ordena por CPU desc en cada tick
  [switch]$VerboseConsole
)

begin {
  # Cargar WPF
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase

  # Núcleos lógicos para CPU%
  $LogicalProcs = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
  if (-not $LogicalProcs) { $LogicalProcs = 1 }

  # Estado previo para deltas
  $prev = @{}
  $consec = @{}  # consecutive highs per PID

  # XAML UI
  $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Process Monitor - Live" Height="640" Width="1000" WindowStartupLocation="CenterScreen" Background="#0F1115">
  <Window.Resources>
    <Style TargetType="DataGridRow">
      <Style.Triggers>
        <!-- Soft highlight on CPU -->
        <DataTrigger Binding="{Binding CPUPercent}" Value="{x:Static sys:Double.NaN}">
          <Setter Property="Background" Value="#22262e"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding CPUPercent}" Value="0">
          <Setter Property="Background" Value="#1a1d24"/>
        </DataTrigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="Foreground" Value="#e6e6e6"/>
      <Setter Property="Background" Value="#2b3038"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Foreground" Value="#e6e6e6"/>
      <Setter Property="Background" Value="#1c2026"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Foreground" Value="#e6e6e6"/>
      <Setter Property="Background" Value="#1c2026"/>
    </Style>
  </Window.Resources>
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="Process Monitor" FontSize="18" FontWeight="Bold" Foreground="#e6e6e6" Margin="4"/>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
        <TextBlock Text="Search:" Foreground="#cfcfcf" Margin="10,0,4,0"/>
        <TextBox x:Name="SearchBox" Width="220" ToolTip="Filtra por nombre de proceso"/>
        <Button x:Name="RefreshBtn" Content="Refresh"/>
        <Button x:Name="KillBtn" Content="Kill Selected" Background="#8a2b2b"/>
      </StackPanel>
    </DockPanel>

    <!-- DataGrid -->
    <DataGrid x:Name="Grid" Grid.Row="1" AutoGenerateColumns="False" CanUserSortColumns="True"
              HeadersVisibility="Column" Background="#151821" Foreground="#e6e6e6"
              GridLinesVisibility="None" RowBackground="#1a1d24" AlternatingRowBackground="#13161d"
              SelectionMode="Extended" SelectionUnit="FullRow">
      <DataGrid.Columns>
        <DataGridTextColumn Header="PID" Binding="{Binding PID}" Width="70"/>
        <DataGridTextColumn Header="Process" Binding="{Binding Name}" Width="180"/>
        <DataGridTextColumn Header="CPU %" Binding="{Binding CPUPercent, StringFormat={}{0:F1}}" Width="80"/>
        <DataGridTextColumn Header="RAM MB" Binding="{Binding RAMMB, StringFormat={}{0:F0}}" Width="90"/>
        <DataGridTextColumn Header="Handles" Binding="{Binding Handles}" Width="90"/>
        <DataGridTextColumn Header="IO Read/s" Binding="{Binding ReadBpsFmt}" Width="110"/>
        <DataGridTextColumn Header="IO Write/s" Binding="{Binding WriteBpsFmt}" Width="110"/>
        <DataGridTextColumn Header="IO Total/s" Binding="{Binding TotalBpsFmt}" Width="110"/>
        <DataGridTextColumn Header="User" Binding="{Binding User}" Width="160"/>
        <DataGridTextColumn Header="Path" Binding="{Binding Path}" Width="*" />
      </DataGrid.Columns>
    </DataGrid>

    <!-- Status bar -->
    <DockPanel Grid.Row="2" Margin="0,10,0,0">
      <TextBlock x:Name="StatusText" Foreground="#cfcfcf" />
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
        <TextBlock x:Name="CpuText" Foreground="#cfcfcf" Margin="10,0,10,0"/>
        <TextBlock x:Name="RamText" Foreground="#cfcfcf" Margin="10,0,10,0"/>
        <TextBlock x:Name="NetText" Foreground="#cfcfcf" Margin="10,0,10,0"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
"@

  # Inject sys namespace
  $xaml = $xaml -replace 'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"', 'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib"'
  $reader = (New-Object System.Xml.XmlNodeReader ([xml]$xaml))
  $window = [Windows.Markup.XamlReader]::Load($reader)

  # Element refs
  $Grid       = $window.FindName('Grid')
  $SearchBox  = $window.FindName('SearchBox')
  $RefreshBtn = $window.FindName('RefreshBtn')
  $KillBtn    = $window.FindName('KillBtn')
  $StatusText = $window.FindName('StatusText')
  $CpuText    = $window.FindName('CpuText')
  $RamText    = $window.FindName('RamText')
  $NetText    = $window.FindName('NetText')

  # Observable collection
  $obsType = [System.Collections.ObjectModel.ObservableCollection[object]]
  $Items = New-Object $obsType
  $Grid.ItemsSource = $Items

  # Helpers
  function Format-Bps([double]$v) {
    if ($v -lt 1KB) { "{0:F0} B/s" -f $v }
    elseif ($v -lt 1MB) { "{0:F1} KB/s" -f ($v/1KB) }
    elseif ($v -lt 1GB) { "{0:F2} MB/s" -f ($v/1MB) }
    else { "{0:F2} GB/s" -f ($v/1GB) }
  }

  function Get-Owner($pid) {
    try {
      $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pid"
      $res = $p.GetOwner()
      if ($res.ReturnValue -eq 0) { return "$($res.Domain)\$($res.User)" }
    } catch {}
    return ""
  }

  # System-level metrics
  function Get-SystemMetrics {
    try {
      $cpuTotal = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue
    } catch { $cpuTotal = [double]::NaN }
    try {
      $memAvailMB = (Get-Counter '\Memory\Available MBytes' -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue
      $totalRAM = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1MB
      $ramPct = if ($totalRAM -gt 0) { [math]::Round((1 - ($memAvailMB/$totalRAM))*100,1) } else { [double]::NaN }
    } catch { $ramPct = [double]::NaN }
    try {
      $netBps = (Get-Counter '\Network Interface(*)\Bytes Total/sec' -SampleInterval 1 -MaxSamples 1).CounterSamples |
        Measure-Object -Property CookedValue -Sum | Select-Object -ExpandProperty Sum
    } catch { $netBps = [double]::NaN }
    [pscustomobject]@{ CpuTotal=$cpuTotal; RamPercent=$ramPct; NetBps=$netBps }
  }

  # Sampling loop
  $lastSample = Get-Date
  function Sample-Processes {
    $now = Get-Date
    $dt = ($now - $lastSample).TotalSeconds
    if ($dt -lt 0.5) { return } # avoid too frequent
    $lastSample = $now

    # Collect processes
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -gt 0 }
    $newItems = @()

    foreach ($p in $procs) {
      $pid = $p.Id
      $name = $p.ProcessName
      $wsMB = [math]::Round($p.WorkingSet64/1MB,1)
      $handles = $p.Handles
      $path = ""
      try { $path = $p.Path } catch {}
      $owner = ""
      if (-not $prev.ContainsKey($pid)) {
        $prev[$pid] = [pscustomobject]@{
          CpuTotalSec = $p.TotalProcessorTime.TotalSeconds
          ReadBytes   = $p.ReadTransferCount
          WriteBytes  = $p.WriteTransferCount
          Updated     = $now
        }
        $consec[$pid] = [pscustomobject]@{ CPU=0; RAM=0; IO=0 }
      }

      $pr = $prev[$pid]

      # CPU delta
      $cpuSec = $p.TotalProcessorTime.TotalSeconds
      $cpuDelta = [math]::Max(0, $cpuSec - $pr.CpuTotalSec)
      $cpuPct = [math]::Round(($cpuDelta / $dt) / $LogicalProcs * 100,1)

      # IO deltas
      $rBytes = $p.ReadTransferCount
      $wBytes = $p.WriteTransferCount
      $readBps = [math]::Max(0, ($rBytes - $pr.ReadBytes) / $dt)
      $writeBps = [math]::Max(0, ($wBytes - $pr.WriteBytes) / $dt)
      $totalBps = $readBps + $writeBps

      # Update prev
      $pr.CpuTotalSec = $cpuSec
      $pr.ReadBytes   = $rBytes
      $pr.WriteBytes  = $wBytes
      $pr.Updated     = $now

      # Consecutive high counters
      if ($cpuPct -ge $CpuHighPercent) { $consec[$pid].CPU++ } else { $consec[$pid].CPU = 0 }
      if ($wsMB -ge $RamHighMB)       { $consec[$pid].RAM++ } else { $consec[$pid].RAM = 0 }
      if ($totalBps -ge $IoHighBps)   { $consec[$pid].IO++ }  else { $consec[$pid].IO  = 0 }

      $newItems += [pscustomobject]@{
        PID          = $pid
        Name         = $name
        CPUPercent   = $cpuPct
        RAMMB        = $wsMB
        Handles      = $handles
        ReadBps      = $readBps
        WriteBps     = $writeBps
        TotalBps     = $totalBps
        ReadBpsFmt   = (Format-Bps $readBps)
        WriteBpsFmt  = (Format-Bps $writeBps)
        TotalBpsFmt  = (Format-Bps $totalBps)
        User         = $owner  # Lazy-fill owner below to avoid slow CIM per process
        Path         = $path
        HighCPU      = ($consec[$pid].CPU -ge $AlertOnConsecutive)
        HighRAM      = ($consec[$pid].RAM -ge $AlertOnConsecutive)
        HighIO       = ($consec[$pid].IO  -ge $AlertOnConsecutive)
      }
    }

    # Fill owner for top N only (performance)
    $topN = $newItems | Sort-Object CPUPercent -Descending | Select-Object -First 20
    foreach ($ti in $topN) {
      if ([string]::IsNullOrWhiteSpace($ti.User)) { $ti.User = Get-Owner $ti.PID }
    }

    # Apply filter
    $filter = $SearchBox.Text
    if ($filter -and $filter.Trim().Length -gt 0) {
      $pattern = $filter.Trim()
      $newItems = $newItems | Where-Object { $_.Name -like "*$pattern*" -or $_.Path -like "*$pattern*" }
    }

    if ($TopByCPU) { $newItems = $newItems | Sort-Object CPUPercent -Descending }

    # Update observable collection (diff-based to reduce churn)
    $Items.Clear()
    foreach ($ni in $newItems) { $Items.Add($ni) }

    # System bar
    $sys = Get-SystemMetrics
    $CpuText.Text = "CPU: " + ([string]::Format("{0:F1}%", $sys.CpuTotal))
    $RamText.Text = "RAM: " + ([string]::Format("{0:F1}%", $sys.RamPercent))
    $NetText.Text = "Net: " + (Format-Bps $sys.NetBps)
    $StatusText.Text = ("[{0}] Items: {1} | Interval: {2}s" -f (Get-Date).ToString('HH:mm:ss'), $Items.Count, $IntervalSeconds)
  }

  # Timer
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromSeconds($IntervalSeconds)
  $timer.Add_Tick({ Sample-Processes })

  # Events
  $RefreshBtn.Add_Click({ Sample-Processes })
  $SearchBox.Add_TextChanged({ Sample-Processes })
  $KillBtn.Add_Click({
    $sel = $Grid.SelectedItems
    if (-not $sel -or $sel.Count -eq 0) { [System.Windows.MessageBox]::Show("Selecciona uno o más procesos.", "Kill", "OK", "Warning") | Out-Null; return }
    $names = ($sel | ForEach-Object { "{0} (PID {1})" -f $_.Name, $_.PID }) -join "`n"
    $confirm = [System.Windows.MessageBox]::Show("¿Terminar estos procesos?\n\n$names", "Confirmar Kill", "YesNo", "Warning")
    if ($confirm -eq 'Yes') {
      foreach ($s in $sel) {
        try { Stop-Process -Id $s.PID -Force -ErrorAction Stop } catch {}
      }
      Sample-Processes
    }
  })

  # Start
  $window.Add_SourceInitialized({ $timer.Start(); Sample-Processes })
  $null = $window.ShowDialog()
}
