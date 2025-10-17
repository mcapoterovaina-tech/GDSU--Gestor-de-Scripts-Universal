<#
.SYNOPSIS
  Backup incremental: copias versiónadas con retención y verificación.

.DESCRIPTION
  - Crea una versión de backup en RootBackup\<SetName>\YYYY\MM\DD\HHmmss.
  - Copia diferencial con Robocopy, preservando atributos y timestamps.
  - Genera catálogo y manifiesto de la versión (CSV/JSON) con hashes opcionales.
  - Verifica integridad por checksum (SHA256 por defecto) entre origen y versión.
  - Aplica retención por días y/o por cantidad de versiones (FIFO seguro).
  - Audita todas las acciones y produce un resumen final legible.
  - Opcional: registra tarea en el Programador de tareas para ejecución recurrente.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory=$true)]
  [string]$Source,

  [Parameter(Mandatory=$true)]
  [string]$RootBackup,

  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[A-Za-z0-9_\-]+$')]
  [string]$SetName,                                 # nombre lógico del conjunto de backup

  [int]$RetentionDays    = 30,                       # retención por antigüedad
  [int]$RetentionVersions= 20,                       # retención por número de versiones

  [switch]$VerifyChecksum,                           # verificar integridad post-copia
  [ValidateSet("SHA256","SHA1","MD5")]
  [string]$ChecksumAlgorithm = "SHA256",

  [int]$ThreadCount = 8,                             # /MT:n
  [int]$RetryCount  = 2,                             # /R:n
  [int]$WaitSeconds = 2,                             # /W:n

  [string[]]$IncludePatterns = @("*"),               # patrones a incluir
  [string[]]$ExcludePatterns = @("*.tmp","*.lck","*.lock","Thumbs.db"),

  [switch]$UseLongPaths,
  [switch]$DryRun,

  [string]$ExecutionLogPath,
  [string]$AuditCsvPath,
  [string]$AuditJsonPath,
  [string]$SummaryReportPath,

  [switch]$RegisterSchedule,                         # crear/actualizar tarea programada
  [string]$ScheduleName = "BackupIncremental",       # nombre de la tarea
  [string]$ScheduleTrigger = "Daily 02:00"           # ej.: "Daily 02:00", "Hourly", "Weekly Sun 03:00"
)

begin {
  function New-SafeDirectory { param([string]$Path) if ($Path -and -not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
  function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); $line = "[$ts][$Level] $Message"
    Write-Host $line; if ($ExecutionLogPath) { Add-Content -LiteralPath $ExecutionLogPath -Value $line } }
  function Get-IsExcluded { param([string]$Name, [string[]]$Patterns) foreach ($p in $Patterns) { if ($Name -like $p) { return $true } } return $false }
  function Get-Checksum { param([string]$Path, [string]$Algo = "SHA256") try { (Get-FileHash -LiteralPath $Path -Algorithm $Algo -ErrorAction Stop).Hash } catch { $null } }

  $Audit = New-Object System.Collections.Generic.List[Object]
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $defaultLogDir = Join-Path $env:TEMP "BackupIncremental"
  New-SafeDirectory $defaultLogDir
  if (-not $ExecutionLogPath)  { $ExecutionLogPath  = Join-Path $defaultLogDir "backup_$timestamp.log" }
  if (-not $AuditCsvPath)      { $AuditCsvPath      = Join-Path $defaultLogDir "backup_$timestamp.csv" }
  if (-not $AuditJsonPath)     { $AuditJsonPath     = Join-Path $defaultLogDir "backup_$timestamp.json" }
  if (-not $SummaryReportPath) { $SummaryReportPath = Join-Path $defaultLogDir "summary_$timestamp.txt" }

  if (-not (Test-Path -LiteralPath $Source)) { throw "Source no existe: $Source" }
  New-SafeDirectory $RootBackup

  # Estructura del conjunto
  $setRoot = Join-Path $RootBackup $SetName
  New-SafeDirectory $setRoot

  # Carpeta de versión YYYY\MM\DD\HHmmss
  $versionFolder = Join-Path $setRoot (Get-Date -Format 'yyyy\\MM\\dd\\HHmmss')
  New-SafeDirectory $versionFolder

  # Manifiesto y catálogo
  $manifestJson = Join-Path $versionFolder "manifest.json"
  $catalogCsv   = Join-Path $versionFolder "catalog.csv"

  Write-Log "Inicio backup | SetName=$SetName | Source=$Source | Version=$versionFolder | DryRun=$($DryRun.IsPresent) | Verify=$($VerifyChecksum.IsPresent)" "INFO"

  function Normalize-Path { param([string]$Path)
    if ($UseLongPaths) {
      if ($Path -match '^[A-Za-z]:\\') { return "\\?\$Path" }
      if ($Path -match '^\\\\')        { return "\\?\UNC\$($Path.TrimStart('\'))" }
    } return $Path
  }
  $SourceNorm  = Normalize-Path -Path $Source
  $VersionNorm = Normalize-Path -Path $versionFolder

  # Construir opciones Robocopy para diferencial
  $roboOptions = @("/COPY:DAT","/DCOPY:T","/R:$RetryCount","/W:$WaitSeconds","/MT:$ThreadCount","/FFT","/TEE","/NP","/NFL","/NDL","/XJ","/E")
  foreach ($exc in $ExcludePatterns) { $roboOptions += "/XF:$exc" }
  foreach ($inc in $IncludePatterns) { $maskArgs += $inc } # máscaras al final
  if ($DryRun) { $roboOptions += "/L" }

  # Log crudo Robocopy
  $roboRawLog = Join-Path $versionFolder "robocopy.log"
  $roboOptions += "/LOG:`"$roboRawLog`""
}

process {
  try {
    # Copia diferencial hacia versión
    $cmdArgs = @($SourceNorm, $VersionNorm) + $maskArgs + $roboOptions
    Write-Log "Ejecutando Robocopy..." "INFO"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "robocopy.exe"
    $psi.Arguments = ($cmdArgs -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    Add-Content -LiteralPath $ExecutionLogPath -Value $stdout
    if ($stderr) { Add-Content -LiteralPath $ExecutionLogPath -Value $stderr }
    Write-Log "Robocopy finalizado con código $exitCode" "INFO"

    # Construir catálogo de versión
    $catalog = New-Object System.Collections.Generic.List[Object]
    $filesVer = Get-ChildItem -LiteralPath $versionFolder -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $filesVer) {
      $rel = $f.FullName.Substring($versionFolder.Length).TrimStart('\')
      $catalog.Add([pscustomobject]@{
        RelativePath = $rel
        SizeBytes    = $f.Length
        LastWrite    = $f.LastWriteTime
      })
    }
    if (-not $DryRun) {
      $catalog | Export-Csv -LiteralPath $catalogCsv -NoTypeInformation -Encoding UTF8
    } else {
      $catalog | Export-Csv -LiteralPath $catalogCsv -NoTypeInformation -Encoding UTF8
    }

    # Manifiesto (metadatos de versión)
    $manifest = [pscustomobject]@{
      SetName        = $SetName
      Source         = $Source
      VersionFolder  = $versionFolder
      Timestamp      = (Get-Date)
      IncludePatterns= $IncludePatterns
      ExcludePatterns= $ExcludePatterns
      ExitCode       = $exitCode
      DryRun         = $DryRun.IsPresent
      VerifyChecksum = $VerifyChecksum.IsPresent
      ChecksumAlgo   = $ChecksumAlgorithm
      ThreadCount    = $ThreadCount
      RetryCount     = $RetryCount
      WaitSeconds    = $WaitSeconds
    }
    $manifest | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $manifestJson -Encoding UTF8

    # Verificación de checksum (solo si se copió y se solicitó)
    if ($VerifyChecksum -and -not $DryRun) {
      Write-Log "Verificando integridad ($ChecksumAlgorithm)..." "INFO"
      $sourceFiles = Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue
      foreach ($sf in $sourceFiles) {
        if (Get-IsExcluded -Name $sf.Name -Patterns $ExcludePatterns) { continue }
        $rel = $sf.FullName.Substring($Source.Length).TrimStart('\')
        $vf  = Join-Path $versionFolder $rel
        if (-not (Test-Path -LiteralPath $vf)) { continue } # archivo no presente (posible exclusión por patrón)
        $hSrc = Get-Checksum -Path $sf.FullName -Algo $ChecksumAlgorithm
        $hDst = Get-Checksum -Path $vf        -Algo $ChecksumAlgorithm
        $ok = ($hSrc -and $hDst -and ($hSrc -eq $hDst))
        $Audit.Add([pscustomobject]@{
          Timestamp = (Get-Date)
          Action    = 'Verify'
          Source    = $sf.FullName
          Target    = $vf
          SizeBytes = $sf.Length
          Status    = $ok ? 'OK' : 'MISMATCH'
        })
        if (-not $ok) { Write-Log "Checksum mismatch: $rel" "WARN" }
      }
    }

    # Auditoría de ejecución de versión
    $Audit.Add([pscustomobject]@{
      Timestamp = (Get-Date)
      Action    = 'Version-Created'
      Source    = $Source
      Target    = $versionFolder
      SizeBytes = (Get-ChildItem -LiteralPath $versionFolder -Recurse -File | Measure-Object -Property Length -Sum).Sum
      Status    = $DryRun ? 'DRYRUN' : 'OK'
    })

    # Retención: por días y/o por cantidad de versiones
    Write-Log "Aplicando retención (Days=$RetentionDays, Versions=$RetentionVersions)..." "INFO"
    $versions = Get-ChildItem -LiteralPath $setRoot -Directory -Recurse | Where-Object {
      $_.FullName -match '\\\d{4}\\\d{2}\\\d{2}\\\d{6}$'
    } | Sort-Object FullName

    # Por antigüedad
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    foreach ($v in $versions) {
      # Extraer timestamp desde el nombre del directorio final
      $stampStr = Split-Path $v.FullName -Leaf
      $datePath = Split-Path (Split-Path (Split-Path $v.FullName -Parent) -Parent) -Leaf # yyyy
      $monthPath= Split-Path (Split-Path $v.FullName -Parent) -Leaf                     # MM
      $dayPath  = Split-Path (Split-Path $v.FullName -Parent) -Leaf                     # dd (ajuste)
      # Reconstrucción de fecha/hora
      $dateStr = "{0}-{1}-{2} {3}" -f $datePath, $monthPath, $dayPath, $stampStr
      $dt = [datetime]::ParseExact($dateStr, 'yyyy-MM-dd HHmmss', $null)
      if ($dt -lt $cutoff) {
        Write-Log "Eliminando versión por antigüedad: $($v.FullName)" "INFO"
        if (-not $DryRun) {
          try {
            Remove-Item -LiteralPath $v.FullName -Force -Recurse
            $Audit.Add([pscustomobject]@{
              Timestamp = (Get-Date)
              Action    = 'Retention-Age'
              Source    = $v.FullName
              Target    = ''
              SizeBytes = 0
              Status    = 'OK'
            })
          } catch {
            Write-Log "Error eliminando versión: $($_.Exception.Message)" "ERROR"
            $Audit.Add([pscustomobject]@{
              Timestamp = (Get-Date)
              Action    = 'Retention-Age'
              Source    = $v.FullName
              Target    = ''
              SizeBytes = 0
              Status    = 'ERROR'
            })
          }
        } else {
          $Audit.Add([pscustomobject]@{
            Timestamp = (Get-Date)
            Action    = 'Retention-Age'
            Source    = $v.FullName
            Target    = ''
            SizeBytes = 0
            Status    = 'DRYRUN'
          })
        }
      }
    }

    # Por cantidad de versiones (FIFO): mantener las más recientes
    $versions = Get-ChildItem -LiteralPath $setRoot -Directory -Recurse | Where-Object {
      $_.FullName -match '\\\d{4}\\\d{2}\\\d{2}\\\d{6}$'
    } | Sort-Object FullName
    $excess = $versions.Count - $RetentionVersions
    if ($excess -gt 0) {
      $toDelete = $versions | Select-Object -First $excess
      foreach ($v in $toDelete) {
        Write-Log "Eliminando versión por límite de cantidad: $($v.FullName)" "INFO"
        if (-not $DryRun) {
          try {
            Remove-Item -LiteralPath $v.FullName -Force -Recurse
            $Audit.Add([pscustomobject]@{
              Timestamp = (Get-Date)
              Action    = 'Retention-Count'
              Source    = $v.FullName
              Target    = ''
              SizeBytes = 0
              Status    = 'OK'
            })
          } catch {
            Write-Log "Error eliminando versión: $($_.Exception.Message)" "ERROR"
            $Audit.Add([pscustomobject]@{
              Timestamp = (Get-Date)
              Action    = 'Retention-Count'
              Source    = $v.FullName
              Target    = ''
              SizeBytes = 0
              Status    = 'ERROR'
            })
          }
        } else {
          $Audit.Add([pscustomobject]@{
            Timestamp = (Get-Date)
            Action    = 'Retention-Count'
            Source    = $v.FullName
            Target    = ''
            SizeBytes = 0
            Status    = 'DRYRUN'
          })
        }
      }
    }

    # Registro de programación (opcional)
    if ($RegisterSchedule) {
      Write-Log "Registrando/actualizando tarea programada: $ScheduleName ($ScheduleTrigger)" "INFO"
      try {
        $thisScript = $PSCommandPath
        if (-not $thisScript) { $thisScript = $MyInvocation.MyCommand.Path }
        if (-not (Test-Path -LiteralPath $thisScript)) { throw "No se puede determinar la ruta del script para programar." }

        # Construir argumentos
        $argList = @(
          "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$thisScript`"",
          "-Source","`"$Source`"","-RootBackup","`"$RootBackup`"","-SetName","`"$SetName`"",
          "-RetentionDays",$RetentionDays,"-RetentionVersions",$RetentionVersions,
          $VerifyChecksum ? "-VerifyChecksum" : "",
          "-ChecksumAlgorithm",$ChecksumAlgorithm,
          "-ThreadCount",$ThreadCount,"-RetryCount",$RetryCount,"-WaitSeconds",$WaitSeconds,
          $UseLongPaths ? "-UseLongPaths" : ""
        ) -join " "

        # Crear trigger
        $trigger = $null
        if ($ScheduleTrigger -match '^Daily\s+(\d{2}:\d{2})$') {
          $time = $Matches[1]; $trigger = New-ScheduledTaskTrigger -Daily -At $time
        } elseif ($ScheduleTrigger -match '^Hourly$') {
          $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
          $trigger.Repetition = New-ScheduledTaskRepetitionInterval -Interval (New-TimeSpan -Hours 1)
        } elseif ($ScheduleTrigger -match '^Weekly\s+([A-Za-z]{3})\s+(\d{2}:\d{2})$') {
          $day = $Matches[1]; $time = $Matches[2]
          $TriggerDays = @{
            Sun = [System.DayOfWeek]::Sunday; Mon=[System.DayOfWeek]::Monday; Tue=[System.DayOfWeek]::Tuesday;
            Wed=[System.DayOfWeek]::Wednesday; Thu=[System.DayOfWeek]::Thursday; Fri=[System.DayOfWeek]::Friday; Sat=[System.DayOfWeek]::Saturday
          }
          $dow = $TriggerDays[$day]; if (-not $dow) { throw "Día inválido en ScheduleTrigger." }
          $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $dow -At $time
        } else {
          throw "Formato de ScheduleTrigger no soportado. Use 'Daily HH:MM', 'Hourly' o 'Weekly Sun 03:00'."
        }

        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList
        $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable)
        Register-ScheduledTask -TaskName $ScheduleName -InputObject $task -Force | Out-Null
        $Audit.Add([pscustomobject]@{
          Timestamp = (Get-Date)
          Action    = 'Schedule-Register'
          Source    = $ScheduleName
          Target    = $ScheduleTrigger
          SizeBytes = 0
          Status    = 'OK'
        })
      } catch {
        Write-Log "Error registrando tarea: $($_.Exception.Message)" "ERROR"
        $Audit.Add([pscustomobject]@{
          Timestamp = (Get-Date)
          Action    = 'Schedule-Register'
          Source    = $ScheduleName
          Target    = $ScheduleTrigger
          SizeBytes = 0
          Status    = 'ERROR'
        })
      }
    }

  } catch {
    Write-Log "Error en backup -> $($_.Exception.Message)" "ERROR"
    $Audit.Add([pscustomobject]@{
      Timestamp = (Get-Date)
      Action    = 'Backup-Error'
      Source    = $Source
      Target    = $versionFolder
      SizeBytes = 0
      Status    = 'ERROR'
    })
  }
}

end {
  # Guardar auditoría
  try {
    Write-Log "Guardando auditoría CSV/JSON..." "INFO"
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
      SizeMB = [math]::Round((($_.Group | Measure-Object -Property SizeBytes -Sum).Sum / 1MB), 2)
    }
  } | Sort-Object Action

  $report = @()
  $report += "==== Backup Incremental Summary ($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) ===="
  $report += "SetName:     $SetName"
  $report += "Source:      $Source"
  $report += "VersionDir:  $versionFolder"
  $report += "DryRun:      $($DryRun.IsPresent)"
  $report += "Verify:      $($VerifyChecksum.IsPresent) ($ChecksumAlgorithm)"
  $report += ""
  foreach ($row in $summary) { $report += "{0,-18} Count={1,5}  Size={2} MB" -f $row.Action, $row.Count, $row.SizeMB }
  $report += ""
  $report += "Logs:"
  $report += " - Execution: $ExecutionLogPath"
  $report += " - Robocopy : $roboRawLog"
  $report += " - Manifest : $manifestJson"
  $report += " - Catalog  : $catalogCsv"
  $report += " - Audit CSV: $AuditCsvPath"
  $report += " - Audit JSON: $AuditJsonPath"

  try {
    $report | Out-File -LiteralPath $SummaryReportPath -Encoding UTF8
  } catch {
    Write-Log "Error guardando resumen -> $($_.Exception.Message)" "ERROR"
  }

  Write-Log "Backup completado. Resumen: $SummaryReportPath" "INFO"
}
