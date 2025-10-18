<# 
Toolkit: Monitor de procesos (WPF en hilo STA persistente) + Limpieza de cachés con gráficos ASCII
Notas:
- Requiere PowerShell 5+ en Windows. Ejecutar como admin para máxima visibilidad (Temp sistema, Prefetch, algunos procesos).
- La ventana WPF corre en un hilo STA dedicado y permanece abierta hasta que el usuario la cierre.
#>

[CmdletBinding()]
param()

# ============================================================
# Sección A: Monitor de procesos con UI WPF persistente (STA)
# ============================================================

function Start-ProcessMonitorUI {
<#
.SYNOPSIS
  UI de procesos en tiempo real con CPU%, RAM, I/O, búsqueda y Kill con confirmación. Ventana persistente.
.PARAMETER IntervalSeconds
  Intervalo de muestreo en segundos.
.PARAMETER CpuHighPercent
  Umbral de CPU% por proceso para alertas consecutivas.
.PARAMETER RamHighMB
  Umbral de WorkingSet (MB) por proceso.
.PARAMETER IoHighBps
  Umbral de I/O total (read+write B/s) por proceso.
.PARAMETER AlertOnConsecutive
  Muestras consecutivas para marcar alerta.
.PARAMETER TopByCPU
  Ordena por CPU desc en cada tick.
#>
  param(
    [int]$IntervalSeconds = 2,
    [double]$CpuHighPercent = 50.0,
    [int]$RamHighMB = 500,
    [double]$IoHighBps = 5MB,
    [int]$AlertOnConsecutive = 3,
    [switch]$TopByCPU
  )

  # Lanzar la UI en hilo STA para garantizar el ciclo de mensajes WPF y persistencia de la ventana
  $uiThread = [System.Threading.Thread]::new({
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Estado de cálculo
    $LogicalProcs = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if (-not $LogicalProcs) { $LogicalProcs = 1 }
    $prev   = @{}
    $consec = @{}

    # XAML
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Process Monitor - Live" Height="640" Width="1000"
        WindowStartupLocation="CenterScreen" Background="#0F1115">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="Process Monitor" FontSize="18" FontWeight="Bold" Foreground="#e6e6e6" Margin="4"/>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
        <TextBlock Text="Search:" Foreground="#cfcfcf" Margin="10,0,4,0"/>
        <TextBox x:Name="SearchBox" Width="220" ToolTip="Filtra por nombre de proceso o ruta"/>
        <Button x:Name="RefreshBtn" Content="Refresh" Margin="4" Padding="6,3"/>
        <Button x:Name="KillBtn" Content="Kill Selected" Margin="4" Padding="6,3" Background="#8a2b2b" Foreground="#e6e6e6"/>
      </StackPanel>
    </DockPanel>

    <DataGrid x:Name="Grid" Grid.Row="1" AutoGenerateColumns="False" CanUserSortColumns="True"
              HeadersVisibility="Column" Background="#151821" Foreground="#e6e6e6"
              GridLinesVisibility="None" RowBackground="#1a1d24" AlternatingRowBackground="#13161d"
              SelectionMode="Extended" SelectionUnit="FullRow">
      <DataGrid.Columns>
        <DataGridTextColumn Header="PID"        Binding="{Binding PID}" Width="70"/>
        <DataGridTextColumn Header="Process"    Binding="{Binding Name}" Width="180"/>
        <DataGridTextColumn Header="CPU %"      Binding="{Binding CPUPercent, StringFormat={}{0:F1}}" Width="80"/>
        <DataGridTextColumn Header="RAM MB"     Binding="{Binding RAMMB, StringFormat={}{0:F0}}" Width="90"/>
        <DataGridTextColumn Header="Handles"    Binding="{Binding Handles}" Width="90"/>
        <DataGridTextColumn Header="IO Read/s"  Binding="{Binding ReadBpsFmt}" Width="110"/>
        <DataGridTextColumn Header="IO Write/s" Binding="{Binding WriteBpsFmt}" Width="110"/>
        <DataGridTextColumn Header="IO Total/s" Binding="{Binding TotalBpsFmt}" Width="110"/>
        <DataGridTextColumn Header="User"       Binding="{Binding User}" Width="160"/>
        <DataGridTextColumn Header="Path"       Binding="{Binding Path}" Width="*" />
      </DataGrid.Columns>
    </DataGrid>

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

    # Cargar XAML
    $xaml = $xaml -replace 'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"', 'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib"'
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Referencias
    $Grid       = $window.FindName('Grid')
    $SearchBox  = $window.FindName('SearchBox')
    $RefreshBtn = $window.FindName('RefreshBtn')
    $KillBtn    = $window.FindName('KillBtn')
    $StatusText = $window.FindName('StatusText')
    $CpuText    = $window.FindName('CpuText')
    $RamText    = $window.FindName('RamText')
    $NetText    = $window.FindName('NetText')

    # Colección
    $Items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $Grid.ItemsSource = $Items

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

    # Muestreo
    $lastSample = Get-Date
    function Sample-Processes {
      $now = Get-Date
      $dt = ($now - $lastSample).TotalSeconds
      if ($dt -lt 0.5) { return }
      $lastSample = $now

      $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -gt 0 }
      $newItems = @()

      foreach ($p in $procs) {
        $pid = $p.Id
        $name = $p.ProcessName
        $wsMB = [math]::Round($p.WorkingSet64/1MB,1)
        $handles = $p.Handles
        $path = ""
        try { $path = $p.Path } catch {}

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

        $cpuSec = $p.TotalProcessorTime.TotalSeconds
        $cpuDelta = [math]::Max(0, $cpuSec - $pr.CpuTotalSec)
        $cpuPct = [math]::Round(($cpuDelta / $dt) / $LogicalProcs * 100,1)

        $rBytes = $p.ReadTransferCount
        $wBytes = $p.WriteTransferCount
        $readBps = [math]::Max(0, ($rBytes - $pr.ReadBytes) / $dt)
        $writeBps = [math]::Max(0, ($wBytes - $pr.WriteBytes) / $dt)
        $totalBps = $readBps + $writeBps

        $pr.CpuTotalSec = $cpuSec
        $pr.ReadBytes   = $rBytes
        $pr.WriteBytes  = $wBytes
        $pr.Updated     = $now

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
          User         = ""  # relleno para top N
          Path         = $path
          HighCPU      = ($consec[$pid].CPU -ge $AlertOnConsecutive)
          HighRAM      = ($consec[$pid].RAM -ge $AlertOnConsecutive)
          HighIO       = ($consec[$pid].IO  -ge $AlertOnConsecutive)
        }
      }

      # Rellenar propietario para top N
      $topN = $newItems | Sort-Object CPUPercent -Descending | Select-Object -First 20
      foreach ($ti in $topN) {
        if ([string]::IsNullOrWhiteSpace($ti.User)) { $ti.User = Get-Owner $ti.PID }
      }

      # Filtro
      $filter = $SearchBox.Text
      if ($filter -and $filter.Trim().Length -gt 0) {
        $pattern = $filter.Trim()
        $newItems = $newItems | Where-Object { $_.Name -like "*$pattern*" -or $_.Path -like "*$pattern*" }
      }

      if ($TopByCPU) { $newItems = $newItems | Sort-Object CPUPercent -Descending }

      # Actualizar colección
      $Items.Clear()
      foreach ($ni in $newItems) { $Items.Add($ni) }

      # Barra de estado
      $sys = Get-SystemMetrics
      $CpuText.Text = "CPU: " + ([string]::Format("{0:F1}%", $sys.CpuTotal))
      $RamText.Text = "RAM: " + ([string]::Format("{0:F1}%", $sys.RamPercent))
      $NetText.Text = "Net: " + (Format-Bps $sys.NetBps)
      $StatusText.Text = ("[{0}] Items: {1} | Interval: {2}s" -f (Get-Date).ToString('HH:mm:ss'), $Items.Count, $IntervalSeconds)
    }

    # Timer WPF (DispatcherTimer garantiza ejecución en el hilo UI)
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($IntervalSeconds)
    $timer.Add_Tick({ Sample-Processes })

    # Eventos
    $RefreshBtn.Add_Click({ Sample-Processes })
    $SearchBox.Add_TextChanged({ Sample-Processes })
    $KillBtn.Add_Click({
      $sel = $Grid.SelectedItems
      if (-not $sel -or $sel.Count -eq 0) { [System.Windows.MessageBox]::Show("Selecciona uno o más procesos.", "Kill", "OK", "Warning") | Out-Null; return }
      $names = ($sel | ForEach-Object { "{0} (PID {1})" -f $_.Name, $_.PID }) -join "`n"
      $confirm = [System.Windows.MessageBox]::Show("¿Terminar estos procesos?\n\n$names", "Confirmar Kill", "YesNo", "Warning")
      if ($confirm -eq 'Yes') {
        foreach ($s in $sel) { try { Stop-Process -Id $s.PID -Force -ErrorAction Stop } catch {} }
        Sample-Processes
      }
    })

    # Iniciar UI: arranca timer y bloquea con ShowDialog hasta que el usuario cierre la ventana
    $window.Add_SourceInitialized({ $timer.Start(); Sample-Processes })
    $null = $window.ShowDialog()
  })

  # Configurar STA y arrancar hilo; Join bloquea hasta cerrar la ventana
  $uiThread.SetApartmentState([System.Threading.ApartmentState]::STA)
  $uiThread.IsBackground = $false
  $uiThread.Start()
  $uiThread.Join()
}

# ============================================================
# Sección B: Limpieza de cachés + Gráficos ASCII en consola
# ============================================================

function Invoke-CacheCleanup {
<#
.SYNOPSIS
  Limpia Temp usuario/sistema, Prefetch, y logs antiguos. Auditoría CSV/JSON y gráficos ASCII.
#>
  param(
    [int]$LogRetentionDays = 14,
    [int]$MinLogSizeMB = 5,
    [switch]$IncludePrefetch,
    [switch]$IncludeSystemTemp,
    [switch]$DryRun,
    [string]$LogPath = "C:\Logs",
    [string[]]$ExtraLogRoots = @("C:\Logs","C:\Temp"),
    [string[]]$ExcludePaths = @(
      "C:\Windows\System32",
      "C:\Program Files",
      "$env:ProgramData\Microsoft\Windows\Start Menu"
    ),
    [string[]]$ExcludePatterns = @("*.config","*.json","*.dll","*.sys"),
    [string[]]$AdditionalTempDirs = @()
  )

  # Auditoría
  if (!(Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
  $ts      = Get-Date -Format "yyyyMMdd_HHmmss"
  $session = Join-Path $LogPath "CleanCaches_$ts"
  New-Item -ItemType Directory -Path $session -Force | Out-Null
  $logFile   = Join-Path $session "actions.log"
  $reportCsv = Join-Path $session "summary.csv"
  $reportJson= Join-Path $session "summary.json"

  function Write-Log { param([string]$Message,[string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
  }

  function Is-ExcludedPath { param([string]$Path)
    foreach ($ex in $ExcludePaths) { if ($Path -like "$ex*") { return $true } }
    return $false
  }
  function Is-ExcludedPattern { param([string]$Name)
    foreach ($pat in $ExcludePatterns) { if ($Name -like $pat) { return $true } }
    return $false
  }

  function Try-DeleteItem { param([System.IO.FileSystemInfo]$Item,[int]$Retries = 2)
    if (Is-ExcludedPath -Path $Item.FullName) { return $false }
    if (Is-ExcludedPattern -Name $Item.Name) { return $false }
    for ($i=0; $i -le $Retries; $i++) {
      try {
        if ($DryRun) { Write-Log "[DryRun] Borra: $($Item.FullName)"; return $true }
        if ($Item.PSIsContainer) { Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop }
        else { Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop }
        return $true
      } catch {
        Start-Sleep -Milliseconds 250
        if ($i -eq $Retries) { Write-Log "No se pudo borrar: $($Item.FullName) :: $($_.Exception.Message)" "WARN"; return $false }
      }
    }
  }

  function Get-SizeBytes { param([string]$Path)
    try {
      $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop
      $size = 0
      foreach ($it in $items) {
        try {
          if ($it.PSIsContainer) {
            $size += (Get-ChildItem -LiteralPath $it.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
          } else { $size += $it.Length }
        } catch {}
      }
      return [long]$size
    } catch { return 0 }
  }

  $userTemp    = $env:TEMP
  $systemTemp  = "C:\Windows\Temp"
  $prefetchDir = "C:\Windows\Prefetch"

  Write-Log "Sesión de limpieza iniciada."

  function Clean-TempFolder { param([string]$Path,[string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
      Write-Log "Temp no válido: $Path" "WARN"
      return [pscustomobject]@{ Label=$Label; Path=$Path; FreedMB=0; DeletedItems=0 }
    }
    Write-Log "Limpiando $Label: $Path"
    $before = Get-SizeBytes -Path $Path
    $deleted = 0
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if (Try-DeleteItem -Item $_) { $deleted++ }
    }
    $after = Get-SizeBytes -Path $Path
    $freedMB = [Math]::Round((($before - $after)/1MB),2)
    Write-Log "Liberado en $Label: $freedMB MB (items: $deleted)"
    [pscustomobject]@{ Label=$Label; Path=$Path; FreedMB=$freedMB; DeletedItems=$deleted }
  }

  function Clean-Prefetch {
    if (-not (Test-Path $prefetchDir)) {
      Write-Log "Prefetch no existe." "WARN"
      return [pscustomobject]@{ Label="Prefetch"; Path=$prefetchDir; FreedMB=0; DeletedItems=0 }
    }
    Write-Log "Limpiando Prefetch (archivos .pf antiguos)."
    $before = Get-SizeBytes -Path $prefetchDir
    $deleted = 0
    Get-ChildItem -LiteralPath $prefetchDir -Filter *.pf -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | ForEach-Object {
        if (Try-DeleteItem -Item $_) { $deleted++ }
      }
    $after = Get-SizeBytes -Path $prefetchDir
    $freedMB = [Math]::Round((($before - $after)/1MB),2)
    Write-Log "Prefetch liberado: $freedMB MB (items: $deleted)"
    [pscustomobject]@{ Label="Prefetch"; Path=$prefetchDir; FreedMB=$freedMB; DeletedItems=$deleted }
  }

  function Clean-OldLogs { param([string[]]$Roots,[int]$RetentionDays,[int]$MinSizeMB)
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Write-Log "Buscando logs > $RetentionDays días y > $MinSizeMB MB en: $($Roots -join ', ')"
    $deleted = 0
    $bytesFreed = 0
    foreach ($root in $Roots) {
      $expanded = [Environment]::ExpandEnvironmentVariables($root)
      if (-not (Test-Path $expanded)) { continue }
      Get-ChildItem -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } |
        Where-Object {
          ($_.Extension -in ".log",".txt",".etl") -and
          ($_.LastWriteTime -lt $cutoff) -and
          (($_.Length/1MB) -ge $MinSizeMB) -and
          (-not (Is-ExcludedPath -Path $_.FullName)) -and
          (-not (Is-ExcludedPattern -Name $_.Name))
        } | ForEach-Object {
          $size = $_.Length
          if (Try-DeleteItem -Item $_) { $deleted++; $bytesFreed += $size }
        }
    }
    $freedMB = [Math]::Round(($bytesFreed/1MB),2)
    Write-Log "Logs purgados: $deleted archivos. Liberado: $freedMB MB"
    [pscustomobject]@{ Label="OldLogs"; Paths=($Roots -join "; "); FreedMB=$freedMB; DeletedItems=$deleted }
  }

  # Ejecución
  $results = @()
  $results += Clean-TempFolder -Path $userTemp -Label "UserTemp"
  if ($IncludeSystemTemp) { $results += Clean-TempFolder -Path $systemTemp -Label "SystemTemp" }
  if ($IncludePrefetch) { $results += Clean-Prefetch } else { Write-Log "Prefetch desactivado (use -IncludePrefetch)." }
  foreach ($t in $AdditionalTempDirs) { $results += Clean-TempFolder -Path $t -Label "ExtraTemp" }
  $results += Clean-OldLogs -Roots $ExtraLogRoots -RetentionDays $LogRetentionDays -MinLogSizeMB $MinLogSizeMB

  try {
    $totalFreed = [Math]::Round(($results | Measure-Object FreedMB -Sum).Sum,2)
    $totalItems = ($results | Measure-Object DeletedItems -Sum).Sum
    $summary = [pscustomobject]@{
      Timestamp    = $ts
      DryRun       = [bool]$DryRun
      TotalFreedMB = $totalFreed
      TotalItems   = $totalItems
      Details      = $results
    }
    $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $reportCsv
    $summary  | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportJson -Encoding UTF8
    Write-Log "Resumen: liberado $totalFreed MB en $totalItems items."
    Write-Log "Auditoría en: $session"
    Write-Log "Limpieza completada."
  } catch {
    Write-Log "Error exportando resumen: $($_.Exception.Message)" "ERROR"
  }

  # Gráficos ASCII en consola
  function New-SparkBlock { param([double]$Value,[double]$Max)
    if ($Max -le 0 -or $Value -le 0) { return " " }
    $levels = @("▂","▃","▄","▅","▆","▇","█")
    $idx = [math]::Min($levels.Count-1, [math]::Floor(($Value/$Max) * ($levels.Count)))
    return $levels[$idx]
  }

  function Show-ConsoleTable { param([array]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $nameW = [math]::Max(12, ($Rows | ForEach-Object { $_.Name.ToString().Length } | Measure-Object -Maximum).Maximum)
    $valW  = 12
    Write-Host ""
    Write-Host ("{0}  {1,12}  {2}" -f ("Nombre".PadRight($nameW)), "Freed (MB)", "Items") -ForegroundColor Cyan
    Write-Host ("{0}" -f ("-" * ($nameW + 2 + $valW + 8))) -ForegroundColor DarkGray
    foreach ($r in $Rows) {
      Write-Host ("{0}  {1,12:N2}  {2,5}" -f ($r.Name.PadRight($nameW)), $r.Value, $r.Items) -ForegroundColor Gray
    }
  }

  function Show-ConsoleChart { param([Parameter(Mandatory)][array]$Results,[int]$MaxBarLength = 60)
    Write-Host ""
    Write-Host "===== Impacto por categoría (MB liberados) =====" -ForegroundColor Cyan
    $maxValue = ($Results | Measure-Object FreedMB -Maximum).Maximum
    if (-not $maxValue -or $maxValue -le 0) { Write-Host "No se liberó espacio significativo." -ForegroundColor Yellow; return }
    foreach ($r in $Results) {
      $label   = if ($r.Label) { $r.Label } else { "Unknown" }
      $val     = [math]::Round([double]$r.FreedMB,2)
      $items   = [int]$r.DeletedItems
      $barLen  = [math]::Max(0, [math]::Round(($val / $maxValue) * $MaxBarLength))
      $bar     = ("█" * $barLen)
      $spark   = New-SparkBlock -Value $val -Max $maxValue
      $color = switch -Regex ($label) {
        "^UserTemp$"    { "Green" }
        "^SystemTemp$"  { "DarkGreen" }
        "^Prefetch$"    { "Magenta" }
        "^OldLogs$"     { "Yellow" }
        "^ExtraTemp$"   { "Cyan" }
        default         { "Gray" }
      }
      $left = ("{0,-12} |" -f $label)
      $right = ("| {0,8:N2} MB  ({1,4} items) {2}" -f $val, $items, $spark)
      Write-Host $left -ForegroundColor DarkGray -NoNewline
      Write-Host " $bar " -ForegroundColor $color -NoNewline
      Write-Host $right -ForegroundColor Gray
    }
    $total = [math]::Round(($Results | Measure-Object FreedMB -Sum).Sum,2)
    Write-Host ("Total liberado: {0:N2} MB" -f $total) -ForegroundColor Cyan
  }

  function Show-LogsDistributionChart { param([Parameter(Mandatory)][pscustomobject]$OldLogsResult,[int]$MaxBarLength = 60)
    if (-not $OldLogsResult -or $OldLogsResult.Label -ne "OldLogs") { return }
    if (-not $OldLogsResult.Paths -or $OldLogsResult.Paths.Trim().Length -eq 0) { return }
    $roots = $OldLogsResult.Paths.Split(";") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
    if ($roots.Count -eq 0) { return }
    $buckets = @{}
    foreach ($root in $roots) {
      $expanded = [Environment]::ExpandEnvironmentVariables($root)
      if (-not (Test-Path $expanded)) { continue }
      $sumSize = 0L; $count = 0
      Get-ChildItem -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } |
        Where-Object { ($_.Extension -in ".log",".txt",".etl") } | ForEach-Object {
          $sumSize += $_.Length; $count++
        }
      $buckets[$expanded] = [pscustomobject]@{ Root=$expanded; SizeMB=[math]::Round($sumSize/1MB,2); Count=$count }
    }
    if ($buckets.Keys.Count -eq 0) { return }
    $maxMB = ($buckets.Values | Measure-Object SizeMB -Maximum).Maximum
    Write-Host ""
    Write-Host "===== Distribución de logs por raíz (tamaño total) =====" -ForegroundColor Cyan
    foreach ($b in $buckets.Values) {
      $barLen = if ($maxMB -gt 0) { [math]::Round(($b.SizeMB/$maxMB) * $MaxBarLength) } else { 0 }
      $bar = ("█" * $barLen)
      Write-Host ("{0,-30} | {1} | {2,8:N2} MB ({3,5} files)" -f $b.Root, $bar, $b.SizeMB, $b.Count) -ForegroundColor DarkYellow
    }
  }

  # Mostrar tabla y gráficos
  try {
    $rows = $results | ForEach-Object { [pscustomobject]@{ Name=$_.Label; Value=[double]$_.FreedMB; Items=[int]$_.DeletedItems } }
    Show-ConsoleTable -Rows $rows
    Show-ConsoleChart -Results $results -MaxBarLength 60
    $logsResult = $results | Where-Object { $_.Label -eq "OldLogs" } | Select-Object -First 1
    if ($logsResult) { Show-LogsDistributionChart -OldLogsResult $logsResult -MaxBarLength 60 }
  } catch {
    Write-Host "Error mostrando gráficos: $($_.Exception.Message)" -ForegroundColor Red
  }
}

# ============================================================
# Uso rápido
# ============================================================
<#
- Iniciar UI de procesos (persistente hasta que cierres la ventana):
    Start-ProcessMonitorUI -IntervalSeconds 2 -CpuHighPercent 60 -RamHighMB 800 -IoHighBps 10MB -AlertOnConsecutive 3 -TopByCPU

- Ejecutar limpieza con gráficos en consola:
    Invoke-CacheCleanup -IncludeSystemTemp -IncludePrefetch -LogRetentionDays 21 -MinLogSizeMB 10 -ExtraLogRoots @("C:\Logs","D:\Logs") -AdditionalTempDirs @("$env:LOCALAPPDATA\Temp") -LogPath "C:\Logs"
#>
