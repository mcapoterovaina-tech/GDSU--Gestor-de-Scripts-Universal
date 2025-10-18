<#
.SYNOPSIS
  Optimización de arranque: deshabilitar startups no críticos por impacto medido, con UI simple y consola en vivo.

.DESCRIPTION
  - Enumera startup desde Registro (HKLM/HKCU Run) y carpetas Startup (usuario y sistema).
  - Mide impacto (CPU/RAM) de procesos asociados con muestreo breve y delta de CPU.
  - Presenta candidatos en UI simple (Out-GridView o consola) y deshabilita con backup seguro.
  - Genera auditoría CSV/JSON, log y resumen; ventana permanece abierta si se indica.
  - DryRun disponible para simular sin modificar.

.NOTES
  - Deshabilitar en Registro: mueve el valor a una clave "RunDisabled" paralela (rollback posible).
  - Deshabilitar en carpeta Startup: mueve el archivo/link a subcarpeta "Disabled" dentro de la misma (rollback posible).
#>

[CmdletBinding()]
param(
  [int]$CpuThresholdPercent = 10,                     # CPU ≥ X% considera impacto alto (media del muestreo)
  [int]$RamThresholdMB     = 200,                     # RAM ≥ X MB considera impacto alto
  [int]$SampleSeconds      = 3,                       # segundos para medir delta CPU y RAM

  [string[]]$WhitelistNames = @("OneDrive","Windows Security","explorer","powershell","svchost"),
  [string[]]$WhitelistPaths = @(),

  [switch]$DryRun,
  [switch]$KeepWindowOpen,

  [string]$ExecutionLogPath,
  [string]$AuditCsvPath,
  [string]$AuditJsonPath,
  [string]$SummaryReportPath
)

begin {
  # Preparación de rutas de salida
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $defaultDir = Join-Path $env:TEMP "StartupOptimizer"
  if (-not (Test-Path -LiteralPath $defaultDir)) { New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null }
  if (-not $ExecutionLogPath)  { $ExecutionLogPath  = Join-Path $defaultDir "startup_$timestamp.log" }
  if (-not $AuditCsvPath)      { $AuditCsvPath      = Join-Path $defaultDir "startup_$timestamp.csv" }
  if (-not $AuditJsonPath)     { $AuditJsonPath     = Join-Path $defaultDir "startup_$timestamp.json" }
  if (-not $SummaryReportPath) { $SummaryReportPath = Join-Path $defaultDir "summary_$timestamp.txt" }

  # Utilidades de log
  function Write-Log {
    param([string]$Message,[ConsoleColor]$Color=[ConsoleColor]::Gray)
    $ts=(Get-Date).ToString("HH:mm:ss")
    $line="[$ts] $Message"
    $orig=$Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor=$Color
    Write-Host $line
    $Host.UI.RawUI.ForegroundColor=$orig
    Add-Content -LiteralPath $ExecutionLogPath -Value $line
  }

  # Parsear comando de registro para extraer ejecutable y argumentos
  function Parse-Command {
    param([string]$Command)
    if (-not $Command) { return [pscustomobject]@{Exe=$null; Args=$null} }
    $cmd = $Command.Trim()
    # Manejar comillas y rutas con espacios
    if ($cmd.StartsWith('"')) {
      $end = $cmd.IndexOf('"',1)
      if ($end -gt 0) {
        $exe = $cmd.Substring(1,$end-1)
        $args = $cmd.Substring($end+1).Trim()
        return [pscustomobject]@{Exe=$exe; Args=$args}
      }
    }
    # Si no hay comillas, separar por primer espacio
    $parts = $cmd.Split(' ',2,[System.StringSplitOptions]::RemoveEmptyEntries)
    $exe = if ($parts.Count -gt 0) { $parts[0] } else { $null }
    $args = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    return [pscustomobject]@{Exe=$exe; Args=$args}
  }

  # Medición de impacto (CPU delta y RAM actual)
  function Measure-Impact {
    param([string]$ProcName,[string]$ExePath,[int]$DurationSec)
    $p1 = Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p1 -and $ExePath) {
      # Intentar por ruta (MainModule puede fallar por acceso)
      $cands = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.MainModule.FileName -eq $ExePath } catch { $false }
      }
      $p1 = $cands | Select-Object -First 1
    }
    if (-not $p1) {
      return [pscustomobject]@{ CPU=0; RAMMB=0; Exists=$false }
    }
    $cpu1 = $p1.TotalProcessorTime
    $ram1 = $p1.WorkingSet64
    Start-Sleep -Seconds ([math]::Max(1,$DurationSec))
    try { $p2 = Get-Process -Id $p1.Id -ErrorAction Stop } catch { $p2 = $null }
    if (-not $p2) {
      return [pscustomobject]@{ CPU=0; RAMMB=0; Exists=$false }
    }
    $cpu2 = $p2.TotalProcessorTime
    $ram2 = $p2.WorkingSet64
    $deltaMs = ($cpu2 - $cpu1).TotalMilliseconds
    $cpuPctApprox = 0
    try {
      # Aproximación: delta CPU ms / (DurationSec * 1000) * 100, en un solo core (orientativo)
      $cpuPctApprox = [math]::Round(($deltaMs / ($DurationSec * 1000)) * 100,2)
    } catch { $cpuPctApprox = 0 }
    $ramMB = [math]::Round($ram2/1MB,2)
    return [pscustomobject]@{ CPU=$cpuPctApprox; RAMMB=$ramMB; Exists=$true }
  }

  # Inventario auditoría
  $Audit = New-Object System.Collections.Generic.List[Object]

  Write-Log "Inicio optimización de arranque | DryRun=$($DryRun.IsPresent) | Sample=${SampleSeconds}s | CPU>=$CpuThresholdPercent% | RAM>=$RamThresholdMB MB" ([ConsoleColor]::Cyan)
}

process {
  try {
    # Enumerar entradas de startup
    $startupItems = @()
    $regPaths = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
      "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($rp in $regPaths) {
      if (Test-Path $rp) {
        $props = (Get-ItemProperty -Path $rp)
        foreach ($prop in $props.PSObject.Properties) {
          if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
          $cmd = [string]$prop.Value
          $parsed = Parse-Command -Command $cmd
          $startupItems += [pscustomobject]@{
            Name    = $prop.Name
            Command = $cmd
            ExePath = $parsed.Exe
            Args    = $parsed.Args
            Source  = $rp
            Type    = 'Registry'
            Enabled = $true
          }
        }
      }
    }

    $startupFolders = @(
      "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
      "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    )
    foreach ($sf in $startupFolders) {
      if (Test-Path $sf) {
        foreach ($fi in (Get-ChildItem -Path $sf -File -ErrorAction SilentlyContinue)) {
          $startupItems += [pscustomobject]@{
            Name    = $fi.BaseName
            Command = $fi.FullName
            ExePath = $fi.FullName
            Args    = ''
            Source  = $sf
            Type    = 'Folder'
            Enabled = $true
          }
        }
      }
    }

    if ($startupItems.Count -eq 0) {
      Write-Log "No se detectaron entradas de inicio." ([ConsoleColor]::Yellow)
      return
    }

    # Medir impacto en tiempo real
    Write-Log "Midiendo impacto de ${SampleSeconds}s para ${($startupItems.Count)} entradas..." ([ConsoleColor]::DarkCyan)
    foreach ($item in $startupItems) {
      # Saltar si en lista blanca por nombre o ruta
      $isWL = ($WhitelistNames -contains $item.Name) -or ($item.ExePath -and ($WhitelistPaths | Where-Object { $item.ExePath -like $_ }))
      if ($isWL) {
        $item | Add-Member -NotePropertyName CPU    -NotePropertyValue 0
        $item | Add-Member -NotePropertyName RAMMB  -NotePropertyValue 0
        $item | Add-Member -NotePropertyName Impact -NotePropertyValue 'Whitelisted'
        continue
      }
      $impact = Measure-Impact -ProcName $item.Name -ExePath $item.ExePath -DurationSec $SampleSeconds
      $item | Add-Member -NotePropertyName CPU    -NotePropertyValue $impact.CPU
      $item | Add-Member -NotePropertyName RAMMB  -NotePropertyValue $impact.RAMMB
      $impScore = if ($impact.Exists -and ($impact.CPU -ge $CpuThresholdPercent -or $impact.RAMMB -ge $RamThresholdMB)) { 'High' } elseif ($impact.Exists -and ($impact.CPU -ge ($CpuThresholdPercent/2) -or $impact.RAMMB -ge ($RamThresholdMB/2))) { 'Medium' } else { 'Low' }
      $item | Add-Member -NotePropertyName Impact -NotePropertyValue $impScore
      Write-Log ("{0,-30} CPU={1,6}% RAM={2,6}MB Impact={3}" -f $item.Name, [math]::Round($impact.CPU,2), [math]::Round($impact.RAMMB,2), $impScore) ([ConsoleColor]::Gray)
    }

    # Mostrar tabla ordenada por impacto y métricas
    Write-Log "Entradas de inicio (ordenadas por impacto):" ([ConsoleColor]::DarkCyan)
    $startupItems | Sort-Object @{Expression='Impact';Descending=$true}, @{Expression='CPU';Descending=$true}, @{Expression='RAMMB';Descending=$true} |
      Format-Table Name,CPU,RAMMB,Impact,Type,Source -AutoSize | Out-String | ForEach-Object { Write-Log $_ }

    # Candidatos (no en lista blanca y con impacto High/Medium)
    $candidates = $startupItems | Where-Object {
      $_.Impact -in @('High','Medium') -and -not ($WhitelistNames -contains $_.Name) -and -not ($item.ExePath -and ($WhitelistPaths | Where-Object { $_ -like $_ }))
    }

    if (-not $candidates -or $candidates.Count -eq 0) {
      Write-Log "No hay candidatos a deshabilitar según umbrales y lista blanca." ([ConsoleColor]::Green)
      return
    }

    # Selección por UI simple
    $selected = @()
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
      $selected = $candidates | Out-GridView -Title "Seleccione startups a deshabilitar (Ctrl para múltiple)" -PassThru
    } else {
      Write-Log "Seleccione índices a deshabilitar (coma separada). Enter para omitir:" ([ConsoleColor]::Yellow)
      $i=0
      foreach ($c in $candidates) {
        $i++
        Write-Log ("[{0}] {1} | CPU={2}% RAM={3}MB Impact={4} | {5}" -f $i,$c.Name,[math]::Round($c.CPU,2),[math]::Round($c.RAMMB,2),$c.Impact,$c.Source) ([ConsoleColor]::Gray)
      }
      $input = Read-Host
      if (-not [string]::IsNullOrWhiteSpace($input)) {
        $idx = $input.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        for ($j=0; $j -lt $candidates.Count; $j++) {
          if ($idx -contains ($j+1)) { $selected += $candidates[$j] }
        }
      }
    }

    if (-not $selected -or $selected.Count -eq 0) {
      Write-Log "No se seleccionaron entradas." ([ConsoleColor]::Yellow)
      return
    }

    # Funciones de backup y deshabilitar
    function Backup-RegistryRun {
      param([string]$RunPath,[string]$Name,[string]$Command)
      try {
        $disabledKey = $RunPath -replace '\\Run$','\RunDisabled'
        if (-not (Test-Path $disabledKey)) { New-Item -Path $disabledKey -Force | Out-Null }
        New-ItemProperty -Path $disabledKey -Name $Name -Value $Command -PropertyType String -Force | Out-Null
        return $disabledKey
      } catch { return $null }
    }

    function Disable-RegistryRun {
      param([string]$RunPath,[string]$Name)
      try {
        if (Get-ItemProperty -Path $RunPath -Name $Name -ErrorAction SilentlyContinue) {
          Remove-ItemProperty -Path $RunPath -Name $Name -Force -ErrorAction Stop
          return $true
        }
      } catch { }
      return $false
    }

    function Disable-StartupFile {
      param([string]$Folder,[string]$FullPath)
      try {
        $disabledDir = Join-Path $Folder "Disabled"
        if (-not (Test-Path $disabledDir)) { New-Item -ItemType Directory -Path $disabledDir -Force | Out-Null }
        $target = Join-Path $disabledDir (Split-Path $FullPath -Leaf)
        if (-not (Test-Path $target)) {
          Move-Item -LiteralPath $FullPath -Destination $target -Force
          return $target
        } else {
          # Ya existe en Disabled -> idempotencia
          return $target
        }
      } catch { return $null }
    }

    # Deshabilitar seleccionados con backup y auditoría
    foreach ($s in $selected) {
      try {
        if ($s.Type -eq 'Registry') {
          Write-Log "Deshabilitando (Registro): $($s.Name) en $($s.Source)" ([ConsoleColor]::Yellow)
          if (-not $DryRun) {
            $bkKey = Backup-RegistryRun -RunPath $s.Source -Name $s.Name -Command $s.Command
            $ok = Disable-RegistryRun -RunPath $s.Source -Name $s.Name
            if ($ok) {
              $Audit.Add([pscustomobject]@{
                Timestamp=(Get-Date); Action='Disable-Startup'; Source="$($s.Source)\$($s.Name)"; Target=$bkKey; SizeBytes=0; Status='OK'; Reason="Impact=$($s.Impact);CPU=$($s.CPU);RAM=$($s.RAMMB)"
              })
            } else {
              Write-Log "No se pudo deshabilitar (ya deshabilitado o inexistente): $($s.Name)" ([ConsoleColor]::Red)
              $Audit.Add([pscustomobject]@{
                Timestamp=(Get-Date); Action='Disable-Startup'; Source="$($s.Source)\$($s.Name)"; Target=$bkKey; SizeBytes=0; Status='ERROR'; Reason='NotFound/AccessDenied'
              })
            }
          } else {
            $Audit.Add([pscustomobject]@{
              Timestamp=(Get-Date); Action='Disable-Startup'; Source="$($s.Source)\$($s.Name)"; Target="$($s.Source)\RunDisabled\$($s.Name)"; SizeBytes=0; Status='DRYRUN'; Reason="Impact=$($s.Impact)"
            })
          }
        } elseif ($s.Type -eq 'Folder') {
          Write-Log "Deshabilitando (Carpeta): $($s.Command)" ([ConsoleColor]::Yellow)
          if (-not $DryRun) {
            $movedTo = Disable-StartupFile -Folder $s.Source -FullPath $s.Command
            if ($movedTo) {
              $Audit.Add([pscustomobject]@{
                Timestamp=(Get-Date); Action='Disable-Startup'; Source=$s.Command; Target=$movedTo; SizeBytes=0; Status='OK'; Reason="Impact=$($s.Impact);CPU=$($s.CPU);RAM=$($s.RAMMB)"
              })
            } else {
              Write-Log "No se pudo mover a Disabled: $($s.Command)" ([ConsoleColor]::Red)
              $Audit.Add([pscustomobject]@{
                Timestamp=(Get-Date); Action='Disable-Startup'; Source=$s.Command; Target=''; SizeBytes=0; Status='ERROR'; Reason='MoveFailed'
              })
            }
          } else {
            $Audit.Add([pscustomobject]@{
              Timestamp=(Get-Date); Action='Disable-Startup'; Source=$s.Command; Target=(Join-Path $s.Source 'Disabled'); SizeBytes=0; Status='DRYRUN'; Reason="Impact=$($s.Impact)"
            })
          }
        }
      } catch {
        Write-Log "Error al deshabilitar $($s.Name): $($_.Exception.Message)" ([ConsoleColor]::Red)
        $Audit.Add([pscustomobject]@{
          Timestamp=(Get-Date); Action='Disable-Startup'; Source=$s.Command; Target=''; SizeBytes=0; Status='ERROR'; Reason=$_.Exception.Message
        })
      }
    }

  } catch {
    Write-Log "Error durante la optimización -> $($_.Exception.Message)" ([ConsoleColor]::Red)
    $Audit.Add([pscustomobject]@{
      Timestamp=(Get-Date); Action='Optimizer-Error'; Source=''; Target=''; SizeBytes=0; Status='ERROR'; Reason=$_.Exception.Message
    })
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
  $summary = $Audit | Group-Object Action | ForEach-Object {
    [pscustomobject]@{
      Action = $_.Name
      Count  = $_.Count
    }
  } | Sort-Object Action

  $report = @()
  $report += "==== Startup Optimizer Summary ($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) ===="
  $report += "Host: $env:COMPUTERNAME"
  $report += "Sample: ${SampleSeconds}s | CPU>=$CpuThresholdPercent% | RAM>=$RamThresholdMB MB"
  $report += ""
  foreach ($row in $summary) { $report += "{0,-18} Count={1,5}" -f $row.Action, $row.Count }
  $report += ""
  $report += "Logs:"
  $report += " - Execution: $ExecutionLogPath"
  $report += " - Audit CSV: $AuditCsvPath"
  $report += " - Audit JSON: $AuditJsonPath"

  try { $report | Out-File -LiteralPath $SummaryReportPath -Encoding UTF8 } catch { Write-Log "Error guardando resumen -> $($_.Exception.Message)" ([ConsoleColor]::Red) }

  Write-Log "Optimización completada. Resumen: $SummaryReportPath" ([ConsoleColor]::Green)

  if ($KeepWindowOpen) {
    Write-Host ""
    Write-Host "Presiona Enter para cerrar..." -ForegroundColor Cyan
    [void](Read-Host)
  }
}
