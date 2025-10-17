<#
.SYNOPSIS
  Monitor de rendimiento: captura métricas (CPU, RAM, disco, red) y alerta por umbrales, con consola en vivo.

.DESCRIPTION
  - Mide periódicamente CPU %, RAM %, Disco (% Disk Time y Avg. Queue Length) y Red (Mbps por adaptador).
  - Muestra progreso en tiempo real en consola y mantiene la ventana abierta al finalizar.
  - Genera auditoría CSV/JSON con cada muestra y un resumen final TXT.
  - Umbrales configurables con alertas después de N consecutivos para evitar ruido.
#>

[CmdletBinding()]
param(
  [int]$IntervalSeconds = 3,                           # intervalo de muestreo
  [int]$Samples = 0,                                   # cantidad de muestras; si 0, usa DurationMinutes
  [int]$DurationMinutes = 5,                           # duración total si Samples=0

  [int]$CpuHighPercent = 85,                           # umbral alto CPU %
  [int]$RamHighPercent = 85,                           # umbral alto RAM %
  [int]$DiskBusyHighPercent = 80,                      # umbral alto % Disk Time
  [double]$DiskQueueHigh = 2.0,                        # umbral alto cola promedio
  [double]$NetHighMbps = 100.0,                        # umbral por adaptador (Mbps)

  [int]$AlertOnConsecutive = 3,                        # n muestras consecutivas antes de alertar

  [string[]]$IncludeAdapters = @(),                    # nombres exactos de adaptadores a incluir; vacío = todos
  [string[]]$ExcludeAdapters = @("isatap*","Teredo*"), # excluir pseudo-interfaces comunes
  [string[]]$IncludeDisks = @(),                       # instancias disco (ej. "0 C:", "1 D:"); vacío = _Total

  [string]$ExecutionLogPath,                           # log de consola
  [string]$AuditCsvPath,                               # CSV con muestras
  [string]$AuditJsonPath,                              # JSON con muestras
  [string]$SummaryReportPath,                          # TXT resumen

  [switch]$KeepWindowOpen,                             # mantener ventana abierta al finalizar
  [switch]$VerboseConsole = $true                      # mostrar en consola siempre (por defecto)
)

begin {
  # Preparación de rutas
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $defaultDir = Join-Path $env:TEMP "PerfMonitor"
  if (-not (Test-Path -LiteralPath $defaultDir)) { New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null }
  if (-not $ExecutionLogPath)  { $ExecutionLogPath  = Join-Path $defaultDir "perf_$timestamp.log" }
  if (-not $AuditCsvPath)      { $AuditCsvPath      = Join-Path $defaultDir "perf_$timestamp.csv" }
  if (-not $AuditJsonPath)     { $AuditJsonPath     = Join-Path $defaultDir "perf_$timestamp.json" }
  if (-not $SummaryReportPath) { $SummaryReportPath = Join-Path $defaultDir "summary_$timestamp.txt" }

  # Utilidades
  function Write-Log {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $line = "[$ts] $Message"
    if ($VerboseConsole) {
      $orig = $Host.UI.RawUI.ForegroundColor
      $Host.UI.RawUI.ForegroundColor = $Color
      Write-Host $line
      $Host.UI.RawUI.ForegroundColor = $orig
    }
    Add-Content -LiteralPath $ExecutionLogPath -Value $line
  }

  function Get-TotalRAM {
    try {
      $cs = Get-CimInstance Win32_ComputerSystem
      return [int64]$cs.TotalPhysicalMemory
    } catch {
      return $null
    }
  }

  function Get-Adapters {
    # Nombres que Get-Counter expone como instancias en \Network Interface(*)
    try {
      $raw = (Get-Counter -ListSet 'Network Interface' -ErrorAction Stop).CounterSetName
      $inst = (Get-Counter -Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction Stop).CounterSamples |
        Select-Object -ExpandProperty InstanceName | Sort-Object -Unique
      # Filtrar
      $list = @()
      foreach ($a in $inst) {
        if ($ExcludeAdapters | Where-Object { $a -like $_ }) { continue }
        if ($IncludeAdapters.Count -gt 0 -and -not ($IncludeAdapters | Where-Object { $a -like $_ })) { continue }
        $list += $a
      }
      return $list
    } catch { return @() }
  }

  # Auditoría
  $Audit = New-Object System.Collections.Generic.List[Object]

  # Mapeo de consecutivos para alertas
  $Consec = @{
    CPU  = 0
    RAM  = 0
    Disk = 0
    Queue= 0
  }
  $ConsecNet = @{}  # por adaptador

  # Plan de muestreo
  if ($Samples -le 0) {
    $totalSeconds = [int]([math]::Max(1, $DurationMinutes)) * 60
    $Samples = [int][math]::Ceiling($totalSeconds / [math]::Max(1, $IntervalSeconds))
  }

  # Info inicial
  $hostName = $env:COMPUTERNAME
  $totalRAM = Get-TotalRAM
  Write-Log "Inicio monitor: Host=$hostName | Interval=$IntervalSeconds s | Samples=$Samples | Logs: $ExecutionLogPath" ([ConsoleColor]::Cyan)
  if ($totalRAM) { Write-Log ("RAM total: {0:N0} MB" -f ($totalRAM/1MB)) ([ConsoleColor]::DarkCyan) }

  # Precompilar contadores
  $cpuCounter   = '\Processor(_Total)\% Processor Time'
  $ramCounter   = '\Memory\Available MBytes'
  $diskBusyC    = '\PhysicalDisk(_Total)\% Disk Time'
  $diskQueueC   = '\PhysicalDisk(_Total)\Avg. Disk Queue Length'
  $netCounter   = '\Network Interface(*)\Bytes Total/sec'

  $Adapters = Get-Adapters
  foreach ($a in $Adapters) { if (-not $ConsecNet.ContainsKey($a)) { $ConsecNet[$a] = 0 } }

  # Disco por instancia (opcional)
  $DiskInstances = @()
  if ($IncludeDisks.Count -gt 0) {
    foreach ($di in $IncludeDisks) {
      $DiskInstances += @{
        Busy = "\\PhysicalDisk($di)\\% Disk Time"
        Queue= "\\PhysicalDisk($di)\\Avg. Disk Queue Length"
        Name = $di
      }
    }
  }

  # CSV header (se creará al final por Export-Csv; mantenemos datos en memoria)
}

process {
  try {
    for ($i = 1; $i -le $Samples; $i++) {
      $t0 = Get-Date

      # CPU
      $cpu = $null
      try { $cpu = (Get-Counter -Counter $cpuCounter -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue } catch { $cpu = $null }

      # RAM %
      $ramPct = $null
      try {
        $availMB = (Get-Counter -Counter $ramCounter -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue
        if ($totalRAM) {
          $ramPct = [math]::Round((1 - (($availMB*1MB)/$totalRAM)) * 100, 2)
        }
      } catch { $ramPct = $null }

      # Disco (_Total o instancias)
      $diskBusy = $null; $diskQueue = $null
      try { $diskBusy = (Get-Counter -Counter $diskBusyC -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue } catch { $diskBusy = $null }
      try { $diskQueue = (Get-Counter -Counter $diskQueueC -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue } catch { $diskQueue = $null }

      $diskInstMetrics = @()
      foreach ($di in $DiskInstances) {
        $busyI = $null; $queueI = $null
        try { $busyI  = (Get-Counter -Counter $di.Busy -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue } catch { }
        try { $queueI = (Get-Counter -Counter $di.Queue -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue } catch { }
        $diskInstMetrics += [pscustomobject]@{ Name=$di.Name; Busy=$busyI; Queue=$queueI }
      }

      # Red por adaptador
      $netPerAdapter = @()
      foreach ($a in $Adapters) {
        $bps = $null
        try {
          $val = (Get-Counter -Counter "\\Network Interface($a)\\Bytes Total/sec" -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue
          $bps = [double]$val
        } catch { }
        $mbps = if ($bps -ne $null) { [math]::Round(($bps * 8) / 1MB, 2) } else { $null }
        $netPerAdapter += [pscustomobject]@{ Adapter=$a; Mbps=$mbps }
      }

      # Alertas (consecutivos)
      # CPU
      if ($cpu -ne $null -and $cpu -ge $CpuHighPercent) { $Consec.CPU++ } else { $Consec.CPU = 0 }
      # RAM
      if ($ramPct -ne $null -and $ramPct -ge $RamHighPercent) { $Consec.RAM++ } else { $Consec.RAM = 0 }
      # Disco
      if ($diskBusy -ne $null -and $diskBusy -ge $DiskBusyHighPercent) { $Consec.Disk++ } else { $Consec.Disk = 0 }
      if ($diskQueue -ne $null -and $diskQueue -ge $DiskQueueHigh) { $Consec.Queue++ } else { $Consec.Queue = 0 }
      # Red
      foreach ($np in $netPerAdapter) {
        if (-not $ConsecNet.ContainsKey($np.Adapter)) { $ConsecNet[$np.Adapter] = 0 }
        if ($np.Mbps -ne $null -and $np.Mbps -ge $NetHighMbps) { $ConsecNet[$np.Adapter]++ } else { $ConsecNet[$np.Adapter] = 0 }
      }

      # Consola en vivo
      $line = ("[{0}/{1}] CPU={2}% | RAM={3}% | DiskBusy={4}% | Queue={5} | " -f $i, $Samples,
        [math]::Round($cpu,2), [math]::Round($ramPct,2), [math]::Round($diskBusy,2), [math]::Round($diskQueue,2))
      $netStr = ($netPerAdapter | ForEach-Object { if ($_.Mbps -ne $null) { "{0}:{1}Mbps" -f $_.Adapter, $_.Mbps } else { "{0}:n/a" -f $_.Adapter } }) -join " | "
      Write-Log ($line + "Net: " + $netStr) ([ConsoleColor]::Gray)

      # Alertas visibles
      $alerts = @()
      if ($Consec.CPU   -ge $AlertOnConsecutive -and $cpu   -ne $null) { $alerts += "CPU>{0}% ({1} cons.)"   -f $CpuHighPercent, $Consec.CPU }
      if ($Consec.RAM   -ge $AlertOnConsecutive -and $ramPct- ne $null){ $alerts += "RAM>{0}% ({1} cons.)"   -f $RamHighPercent, $Consec.RAM }
      if ($Consec.Disk  -ge $AlertOnConsecutive -and $diskBusy -ne $null) { $alerts += "DiskBusy>{0}% ({1} cons.)" -f $DiskBusyHighPercent, $Consec.Disk }
      if ($Consec.Queue -ge $AlertOnConsecutive -and $diskQueue -ne $null){ $alerts += "Queue>{0} ({1} cons.)"     -f $DiskQueueHigh, $Consec.Queue }
      foreach ($a in $Adapters) {
        if ($ConsecNet[$a] -ge $AlertOnConsecutive) { $alerts += "Net({0})>{1}Mbps ({2} cons.)" -f $a, $NetHighMbps, $ConsecNet[$a] }
      }
      if ($alerts.Count -gt 0) {
        Write-Log ("ALERTA: " + ($alerts -join " | ")) ([ConsoleColor]::Yellow)
      }

      # Auditoría de muestra
      $Audit.Add([pscustomobject]@{
        Timestamp   = $t0
        CPUPercent  = if ($cpu -ne $null) { [math]::Round($cpu,2) } else { $null }
        RAMPercent  = if ($ramPct -ne $null) { [math]::Round($ramPct,2) } else { $null }
        DiskBusyPct = if ($diskBusy -ne $null) { [math]::Round($diskBusy,2) } else { $null }
        DiskQueue   = if ($diskQueue -ne $null) { [math]::Round($diskQueue,2) } else { $null }
        NetSummary  = $netStr
        Alerts      = ($alerts -join "; ")
      })

      # Respetar intervalo
      $elapsed = ((Get-Date) - $t0).TotalSeconds
      $sleepLeft = [int][math]::Max(0, $IntervalSeconds - $elapsed)
      Start-Sleep -Seconds $sleepLeft
    }
  } catch {
    Write-Log "Error durante el monitoreo -> $($_.Exception.Message)" ([ConsoleColor]::Red)
  }
}

end {
  # Persistir auditoría
  try {
    $Audit | Export-Csv -LiteralPath $AuditCsvPath -NoTypeInformation -Encoding UTF8
    $Audit | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $AuditJsonPath -Encoding UTF8
  } catch {
    Write-Log "Error guardando auditoría -> $($_.Exception.Message)" ([ConsoleColor]::Red)
  }

  # Resumen
  $cpuMax   = ($Audit | Where-Object { $_.CPUPercent -ne $null } | Measure-Object CPUPercent -Maximum).Maximum
  $ramMax   = ($Audit | Where-Object { $_.RAMPercent -ne $null } | Measure-Object RAMPercent -Maximum).Maximum
  $diskMax  = ($Audit | Where-Object { $_.DiskBusyPct -ne $null } | Measure-Object DiskBusyPct -Maximum).Maximum
  $queueMax = ($Audit | Where-Object { $_.DiskQueue -ne $null } | Measure-Object DiskQueue -Maximum).Maximum

  $report = @()
  $report += "==== Performance Monitor Summary ($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) ===="
  $report += "Host: $env:COMPUTERNAME"
  $report += "Interval: $IntervalSeconds s | Samples: $Samples"
  $report += "Max CPU:  {0}%" -f ([math]::Round($cpuMax,2))
  $report += "Max RAM:  {0}%" -f ([math]::Round($ramMax,2))
  $report += "Max Disk: {0}%" -f ([math]::Round($diskMax,2))
  $report += "Max Queue:{0}"   -f ([math]::Round($queueMax,2))
  $report += ""
  $report += "Logs:"
  $report += " - Execution: $ExecutionLogPath"
  $report += " - Audit CSV: $AuditCsvPath"
  $report += " - Audit JSON: $AuditJsonPath"

  try { $report | Out-File -LiteralPath $SummaryReportPath -Encoding UTF8 } catch { Write-Log "Error guardando resumen -> $($_.Exception.Message)" ([ConsoleColor]::Red) }

  Write-Log "Monitoreo completado. Resumen: $SummaryReportPath" ([ConsoleColor]::Green)

  if ($KeepWindowOpen) {
    Write-Host ""
    Write-Host "Presiona Enter para cerrar..." -ForegroundColor Cyan
    [void] (Read-Host)
  }
}
