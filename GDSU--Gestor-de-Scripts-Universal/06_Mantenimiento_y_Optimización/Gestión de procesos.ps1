<#
.SYNOPSIS
  Gestión de procesos: terminar procesos colgados con lista blanca y razón de cierre.

.DESCRIPTION
  - Detecta procesos colgados por:
    * NotResponding: ventanas no responden (GUI).
    * ZeroCPU: sin actividad de CPU entre dos muestreos.
    * ExceededRuntime: ejecuciones más largas que el umbral.
  - UI simple para revisar/confirmar candidatos (Out-GridView; fallback consola).
  - Lista blanca por nombre, ruta y usuario.
  - Auditoría CSV/JSON y log con razón de cierre.
  - DryRun para simular sin terminar procesos.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [int]$SampleIntervalSeconds = 3,                  # intervalo entre muestras CPU
  [int]$MaxRuntimeMinutes = 240,                    # umbral de runtime excesivo
  [switch]$OnlyNotResponding,                       # limitar a procesos con MainWindow y NotResponding
  [switch]$IncludeServices,                         # incluir servicios (sin ventana)

  [string[]]$WhitelistNames = @("explorer","cmd","powershell","svchost"),  # ejemplos comunes
  [string[]]$WhitelistPaths = @(),                  # rutas completas permitidas
  [string[]]$WhitelistUsers = @(),                  # usuarios permitidos (DOMAIN\User o Machine\User)

  [string[]]$ExtraCriticalNames = @("wininit","winlogon","csrss","lsass","smss","services","System","Idle"),

  [switch]$DryRun,
  [switch]$ForceKill = $true,                       # usar Stop-Process -Force por defecto
  [switch]$KillChildren,                            # intentar finalizar procesos hijo (árbol)

  [string]$ExecutionLogPath,
  [string]$AuditCsvPath,
  [string]$AuditJsonPath,
  [string]$SummaryReportPath
)

begin {
  function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); $line = "[$ts][$Level] $Message"
    Write-Host $line; if ($ExecutionLogPath) { Add-Content -LiteralPath $ExecutionLogPath -Value $line } }

  function New-SafeFilePaths {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $defaultDir = Join-Path $env:TEMP "ProcessManager"
    if (-not (Test-Path -LiteralPath $defaultDir)) { New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null }
    if (-not $ExecutionLogPath)  { $ExecutionLogPath  = Join-Path $defaultDir "process_$timestamp.log" }
    if (-not $AuditCsvPath)      { $AuditCsvPath      = Join-Path $defaultDir "process_$timestamp.csv" }
    if (-not $AuditJsonPath)     { $AuditJsonPath     = Join-Path $defaultDir "process_$timestamp.json" }
    if (-not $SummaryReportPath) { $SummaryReportPath = Join-Path $defaultDir "summary_$timestamp.txt" }
  }

  function Is-Whitelisted {
    param(
      [string]$Name,
      [string]$Path,
      [string]$User,
      [string[]]$Names,
      [string[]]$Paths,
      [string[]]$Users,
      [string[]]$CriticalNames
    )
    if ($CriticalNames -contains $Name) { return $true }
    if ($Names -contains $Name) { return $true }
    if ($Path -and ($Paths | Where-Object { $_ -eq $Path })) { return $true }
    if ($User -and ($Users -contains $User)) { return $true }
    return $false
  }

  function Get-Owner {
    param([System.Diagnostics.Process]$Proc)
    try {
      $wmi = Get-CimInstance Win32_Process -Filter "ProcessId = $($Proc.Id)" -ErrorAction Stop
      $owner = $wmi | Invoke-CimMethod -MethodName GetOwner
      if ($owner.ReturnValue -eq 0) {
        if ($owner.Domain) { return "$($owner.Domain)\$($owner.User)" }
        else { return $owner.User }
      }
    } catch { }
    return $null
  }

  function Get-ExePath {
    param([System.Diagnostics.Process]$Proc)
    try {
      return $Proc.MainModule.FileName
    } catch { return $null }
  }

  function Sample-Processes {
    param([int]$IntervalSec, [switch]$IncludeServices, [switch]$OnlyNR)
    # Primera muestra
    $procs1 = Get-Process -ErrorAction SilentlyContinue
    $snap1 = @{}
    foreach ($p in $procs1) {
      $snap1[$p.Id] = [pscustomobject]@{
        Id       = $p.Id
        Name     = $p.Name
        CPUms    = $p.TotalProcessorTime.TotalMilliseconds
        HasUI    = ($null -ne $p.MainWindowHandle -and $p.MainWindowHandle -ne 0)
        NR       = $p.Responding -eq $false
        Start    = $p.StartTime
        Path     = $null
        User     = $null
      }
    }
    Start-Sleep -Seconds $IntervalSec
    # Segunda muestra
    $procs2 = Get-Process -ErrorAction SilentlyContinue
    $candidates = @()
    foreach ($p in $procs2) {
      if (-not $snap1.ContainsKey($p.Id)) { continue }
      $prev = $snap1[$p.Id]
      # Enriquecer con path/owner en segunda muestra
      $path = Get-ExePath -Proc $p
      $user = Get-Owner  -Proc $p
      $cpu2 = $p.TotalProcessorTime.TotalMilliseconds
      $cpuDelta = [math]::Round($cpu2 - $prev.CPUms, 2)
      $hasUI = $prev.HasUI
      $nr = ($p.Responding -eq $false)

      $runtimeMin = $null
      try { $runtimeMin = ((Get-Date) - $prev.Start).TotalMinutes } catch { $runtimeMin = $null }

      # Criterios
      $critNR    = ($hasUI -and $nr)
      $critZero  = ($cpuDelta -le 1) # ~0 ms CPU en el intervalo
      $critLong  = ($runtimeMin -ne $null -and $runtimeMin -ge $MaxRuntimeMinutes)

      if ($OnlyNR) {
        if (-not $critNR) { continue }
      } else {
        if (-not ($critNR -or $critZero -or $critLong)) { continue }
      }

      # Filtrar servicios si no se pide
      if (-not $IncludeServices) {
        # Heurística: sin UI y con SessionId 0 suelen ser servicios/sistema
        if (-not $hasUI -and $p.SessionId -eq 0) { continue }
      }

      $reason = @()
      if ($critNR)   { $reason += "NotResponding" }
      if ($critZero) { $reason += "ZeroCPU" }
      if ($critLong) { $reason += "ExceededRuntime" }

      $candidates += [pscustomobject]@{
        Id         = $p.Id
        Name       = $p.Name
        Path       = $path
        User       = $user
        CPUmsDelta = $cpuDelta
        HasUI      = $hasUI
        Responding = -not $nr
        RuntimeMin = [math]::Round($runtimeMin,2)
        Reason     = ($reason -join ",")
      }
    }
    return $candidates
  }

  function Confirm-Selection {
    param([object[]]$Candidates)
    if (-not $Candidates -or $Candidates.Count -eq 0) { return @() }

    # UI simple: Out-GridView; fallback consola
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
      $sel = $Candidates | Out-GridView -Title "Seleccione procesos a terminar (Ctrl para múltiples)" -PassThru
      return $sel
    } else {
      Write-Log "Out-GridView no disponible. Mostrando lista en consola..." "WARN"
      $i = 0
      foreach ($c in $Candidates) {
        $i++
        Write-Log ("[{0}] PID={1} Name={2} User={3} CPUΔms={4} RuntimeMin={5} Reason={6}" -f $i,$c.Id,$c.Name,($c.User ?? ''),$c.CPUmsDelta,$c.RuntimeMin,$c.Reason) "INFO"
      }
      Write-Log "Ingrese los índices a terminar separados por comas (o Enter para ninguno):" "INFO"
      $input = Read-Host
      if ([string]::IsNullOrWhiteSpace($input)) { return @() }
      $idx = $input.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
      $sel = @()
      for ($j=0; $j -lt $Candidates.Count; $j++) {
        if ($idx -contains ($j+1)) { $sel += $Candidates[$j] }
      }
      return $sel
    }
  }

  New-SafeFilePaths
  $Audit = New-Object System.Collections.Generic.List[Object]
  Write-Log "Inicio gestión de procesos | DryRun=$($DryRun.IsPresent) | Interval=$SampleIntervalSeconds s | MaxRuntime=$MaxRuntimeMinutes min | OnlyNR=$($OnlyNotResponding.IsPresent)" "INFO"
}

process {
  try {
    # Muestrear y obtener candidatos
    $cands = Sample-Processes -IntervalSec $SampleIntervalSeconds -IncludeServices:$IncludeServices -OnlyNR:$OnlyNotResponding

    # Filtrar lista blanca y críticos
    $filtered = @()
    foreach ($c in $cands) {
      $isWL = Is-Whitelisted -Name $c.Name -Path $c.Path -User $c.User -Names $WhitelistNames -Paths $WhitelistPaths -Users $WhitelistUsers -CriticalNames $ExtraCriticalNames
      if ($isWL) {
        Write-Log "En lista blanca: PID=$($c.Id) Name=$($c.Name) -> skip" "INFO"
        $Audit.Add([pscustomobject]@{
          Timestamp = (Get-Date); Action='Skip-Whitelist'; Source="$($c.Name)($($c.Id))"; Target=''; SizeBytes=0; Status='SKIP'; Reason=$c.Reason
        })
        continue
      }
      $filtered += $c
    }

    if (-not $filtered -or $filtered.Count -eq 0) {
      Write-Log "Sin candidatos tras filtros." "INFO"
      return
    }

    # Confirmación UI simple
    $selected = Confirm-Selection -Candidates $filtered
    if (-not $selected -or $selected.Count -eq 0) {
      Write-Log "No se seleccionaron procesos para terminar." "INFO"
      return
    }

    # Terminar (o simular)
    foreach ($s in $selected) {
      # Validar que siga existiendo
      $exists = Get-Process -Id $s.Id -ErrorAction SilentlyContinue
      if (-not $exists) {
        Write-Log "Proceso ya no existe: PID=$($s.Id) $($s.Name)" "WARN"
        $Audit.Add([pscustomobject]@{
          Timestamp=(Get-Date); Action='Already-Exited'; Source="$($s.Name)($($s.Id))"; Target=''; SizeBytes=0; Status='SKIP'; Reason=$s.Reason
        })
        continue
      }

      $children = @()
      if ($KillChildren) {
        try {
          # Obtener hijos por WMI (ParentProcessId)
          $ppid = $exists.Id
          $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ppid" -ErrorAction SilentlyContinue
        } catch { }
      }

      Write-Log ("Terminar PID={0} Name={1} Reason={2} Children={3}" -f $exists.Id,$exists.Name,$s.Reason,($children.Count)) "WARN"
      if (-not $DryRun) {
        try {
          Stop-Process -Id $exists.Id -Force:$ForceKill -ErrorAction Stop
          foreach ($ch in $children) {
            try { Stop-Process -Id $ch.ProcessId -Force:$ForceKill -ErrorAction Stop } catch { Write-Log "No se pudo cerrar hijo PID=$($ch.ProcessId) -> $($_.Exception.Message)" "ERROR" }
          }
          $Audit.Add([pscustomobject]@{
            Timestamp=(Get-Date); Action='Terminate'; Source="$($s.Name)($($s.Id))"; Target=''; SizeBytes=0; Status='OK'; Reason=$s.Reason
          })
        } catch {
          Write-Log "Error al terminar PID=$($exists.Id) -> $($_.Exception.Message)" "ERROR"
          $Audit.Add([pscustomobject]@{
            Timestamp=(Get-Date); Action='Terminate'; Source="$($s.Name)($($s.Id))"; Target=''; SizeBytes=0; Status='ERROR'; Reason=$s.Reason
          })
        }
      } else {
        $Audit.Add([pscustomobject]@{
          Timestamp=(Get-Date); Action='Terminate'; Source="$($s.Name)($($s.Id))"; Target=''; SizeBytes=0; Status='DRYRUN'; Reason=$s.Reason
        })
      }
    }

  } catch {
    Write-Log "Error en gestión de procesos -> $($_.Exception.Message)" "ERROR"
    $Audit.Add([pscustomobject]@{
      Timestamp=(Get-Date); Action='Process-Error'; Source=''; Target=''; SizeBytes=0; Status='ERROR'; Reason=$_.Exception.Message
    })
  }
}

end {
  try {
    $Audit | Export-Csv -LiteralPath $AuditCsvPath -NoTypeInformation -Encoding UTF8
    $Audit | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $AuditJsonPath -Encoding UTF8
  } catch {
    Write-Log "Error guardando auditoría -> $($_.Exception.Message)" "ERROR"
  }

  # Resumen final
  $summary = $Audit | Group-Object Action | ForEach-Object {
    [pscustomobject]@{
      Action = $_.Name
      Count  = $_.Count
      SizeMB = 0
    }
  } | Sort-Object Action

  $report = @()
  $report += "==== Process Management Summary ($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) ===="
  $report += "DryRun:       $($DryRun.IsPresent)"
  $report += "OnlyNR:       $($OnlyNotResponding.IsPresent)"
  $report += "IncludeSrv:   $($IncludeServices.IsPresent)"
  $report += "MaxRuntime:   $MaxRuntimeMinutes min"
  $report += ""
  foreach ($row in $summary) { $report += "{0,-18} Count={1,5}" -f $row.Action, $row.Count }
  $report += ""
  $report += "Logs:"
  $report += " - Execution: $ExecutionLogPath"
  $report += " - Audit CSV: $AuditCsvPath"
  $report += " - Audit JSON: $AuditJsonPath"

  try { $report | Out-File -LiteralPath $SummaryReportPath -Encoding UTF8 } catch { Write-Log "Error guardando resumen -> $($_.Exception.Message)" "ERROR" }
  Write-Log "Gestión de procesos completada. Resumen: $SummaryReportPath" "INFO"
}
