<#
.SYNOPSIS
  Restauración rápida: reconstruir perfiles o apps desde backup con reporte final.

.DESCRIPTION
  - Detecta versiones disponibles de un conjunto en RootBackup\<SetName>\YYYY\MM\DD\HHmmss.
  - UI simple para seleccionar versión y subcarpetas a restaurar (Out-GridView, con fallback a consola).
  - Restaura diferencial: copia solo archivos faltantes o con diferencia (Robocopy).
  - Opcional: verificación de checksum posterior (SHA256 por defecto).
  - Genera auditoría CSV/JSON y resumen TXT, con conteos y tamaños por acción.
  - Seguro e idempotente: DryRun disponible, exclusiones y control de sobreescritura.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory=$true)]
  [string]$RootBackup,

  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[A-Za-z0-9_\-]+$')]
  [string]$SetName,

  [string]$VersionPath,                          # opcional; si no se pasa, se elige con UI simple
  [Parameter(Mandatory=$true)]
  [string]$RestoreTarget,                         # destino donde se reconstruye

  [switch]$Overwrite,                             # sobreescribir si difiere (por defecto robocopy lo hace)
  [string[]]$IncludeSubpaths = @("*"),            # subcarpetas/paths relativos del backup a incluir
  [string[]]$ExcludePatterns = @("*.tmp","*.lck","Thumbs.db","*.lock"),

  [switch]$VerifyChecksum,
  [ValidateSet("SHA256","SHA1","MD5")]
  [string]$ChecksumAlgorithm = "SHA256",

  [int]$ThreadCount = 8,
  [int]$RetryCount  = 2,
  [int]$WaitSeconds = 2,

  [switch]$UseLongPaths,
  [switch]$DryRun,

  [string]$ExecutionLogPath,
  [string]$AuditCsvPath,
  [string]$AuditJsonPath,
  [string]$SummaryReportPath
)

begin {
  function New-SafeDirectory { param([string]$Path) if ($Path -and -not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
  function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); $line = "[$ts][$Level] $Message"
    Write-Host $line; if ($ExecutionLogPath) { Add-Content -LiteralPath $ExecutionLogPath -Value $line } }
  function Get-IsExcluded { param([string]$Name, [string[]]$Patterns) foreach ($p in $Patterns) { if ($Name -like $p) { return $true } } return $false }
  function Get-Checksum { param([string]$Path, [string]$Algo = "SHA256") try { (Get-FileHash -LiteralPath $Path -Algorithm $Algo -ErrorAction Stop).Hash } catch { $null } }
  function Normalize-Path { param([string]$Path)
    if ($UseLongPaths) {
      if ($Path -match '^[A-Za-z]:\\') { return "\\?\$Path" }
      if ($Path -match '^\\\\')        { return "\\?\UNC\$($Path.TrimStart('\'))" }
    } return $Path
  }

  $Audit = New-Object System.Collections.Generic.List[Object]
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $defaultLogDir = Join-Path $env:TEMP "RestoreQuick"
  New-SafeDirectory $defaultLogDir
  if (-not $ExecutionLogPath)  { $ExecutionLogPath  = Join-Path $defaultLogDir "restore_$timestamp.log" }
  if (-not $AuditCsvPath)      { $AuditCsvPath      = Join-Path $defaultLogDir "restore_$timestamp.csv" }
  if (-not $AuditJsonPath)     { $AuditJsonPath     = Join-Path $defaultLogDir "restore_$timestamp.json" }
  if (-not $SummaryReportPath) { $SummaryReportPath = Join-Path $defaultLogDir "summary_$timestamp.txt" }

  # Validaciones de raíz y conjunto
  $setRoot = Join-Path $RootBackup $SetName
  if (-not (Test-Path -LiteralPath $setRoot)) { throw "SetName no existe en RootBackup: $setRoot" }
  New-SafeDirectory $RestoreTarget

  Write-Log "Inicio restauración | SetName=$SetName | RootBackup=$RootBackup | RestoreTarget=$RestoreTarget | DryRun=$($DryRun.IsPresent)" "INFO"

  # Detectar versiones
  $versions = Get-ChildItem -LiteralPath $setRoot -Directory -Recurse | Where-Object {
    $_.FullName -match '\\\d{4}\\\d{2}\\\d{2}\\\d{6}$'
  } | Sort-Object FullName

  if (-not $VersionPath) {
    # UI simple: seleccionar versión (Out-GridView si disponible, fallback a la más reciente)
    $versionView = $versions | ForEach-Object {
      [pscustomobject]@{
        VersionPath = $_.FullName
        Timestamp   = try {
          $leaf = Split-Path $_.FullName -Leaf
          $y = (Split-Path (Split-Path (Split-Path $_.FullName -Parent) -Parent) -Leaf)
          $m = (Split-Path (Split-Path (Split-Path $_.FullName -Parent) -Parent) -Parent | Split-Path -Leaf)
          # Para claridad de UI, extraer adecuadamente:
          $month = (Split-Path (Split-Path $_.FullName -Parent) -Leaf)
          $day   = (Split-Path (Split-Path $_.FullName -Parent) -Leaf)
          [datetime]::ParseExact("$y-$month-$day $leaf",'yyyy-MM-dd HHmmss',$null)
        } catch { $_.LastWriteTime }
        SizeMB      = [math]::Round(((Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1MB),2)
      }
    }
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
      $sel = $versionView | Out-GridView -Title "Seleccione versión de backup para $SetName" -PassThru -OutputMode Single
      if ($sel) { $VersionPath = $sel.VersionPath }
    }
    if (-not $VersionPath) {
      # fallback: última versión por orden (más reciente)
      $VersionPath = ($versionView | Sort-Object Timestamp -Descending | Select-Object -First 1).VersionPath
      Write-Log "UI no disponible o no seleccionada; usando versión más reciente: $VersionPath" "WARN"
    }
  }

  if (-not (Test-Path -LiteralPath $VersionPath)) { throw "VersionPath inválido: $VersionPath" }

  # UI simple: seleccionar subcarpetas a restaurar (relativas al VersionPath)
  $subdirs = Get-ChildItem -LiteralPath $VersionPath -Directory -ErrorAction SilentlyContinue
  $includeRel = @()
  if ($subdirs.Count -gt 0 -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
    $selDirs = $subdirs | Select-Object FullName, Name | Out-GridView -Title "Seleccione subcarpetas a restaurar (Ctrl para múltiples). Deje vacío para todo." -PassThru
    if ($selDirs) { $includeRel = $selDirs.Name }
  }
  if ($includeRel.Count -eq 0) { $includeRel = $IncludeSubpaths } # usar lo pasado por parámetro o "*"

  # Rutas normalizadas
  $VersionNorm = Normalize-Path -Path $VersionPath
  $TargetNorm  = Normalize-Path -Path $RestoreTarget

  # Construir opciones Robocopy para restauración diferencial
  $roboOptions = @("/COPY:DAT","/DCOPY:T","/R:$RetryCount","/W:$WaitSeconds","/MT:$ThreadCount","/FFT","/TEE","/NP","/NFL","/NDL","/XJ","/E")
  foreach ($exc in $ExcludePatterns) { $roboOptions += "/XF:$exc" }
  if ($DryRun) { $roboOptions += "/L" }
  # Log crudo de robocopy
  $roboRawLog = Join-Path $defaultLogDir "robocopy_restore_$timestamp.log"
  $roboOptions += "/LOG:`"$roboRawLog`""

  Write-Log "Version seleccionada: $VersionPath" "INFO"
  Write-Log "Subpaths a incluir: $($includeRel -join ', ')" "INFO"
}

process {
  try {
    # Ejecutar restauración por cada subpath incluido (si incluye '*', se hace una sola corrida raíz)
    $maskArgs = @("*") # por defecto restaurar todo
    $runAsWhole = ($includeRel.Count -eq 1 -and $includeRel[0] -eq "*")
    if ($runAsWhole) {
      $cmdArgs = @($VersionNorm, $TargetNorm) + $maskArgs + $roboOptions
      Write-Log "Ejecutando Robocopy (completo)..." "INFO"
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
      Write-Log "Robocopy (completo) finalizado con código $exitCode" "INFO"
      $Audit.Add([pscustomobject]@{
        Timestamp = (Get-Date)
        Action    = 'Restore-Run'
        Source    = $VersionPath
        Target    = $RestoreTarget
        SizeBytes = (Get-ChildItem -LiteralPath $VersionPath -Recurse -File | Measure-Object Length -Sum).Sum
        Status    = $DryRun ? 'DRYRUN' : 'OK'
      })
    } else {
      foreach ($rel in $includeRel) {
        $srcSub = Join-Path $VersionPath $rel
        if (-not (Test-Path -LiteralPath $srcSub)) { Write-Log "Subruta no existe en la versión: $rel" "WARN"; continue }
        $srcSubNorm = Normalize-Path -Path $srcSub
        $dstSubNorm = Normalize-Path -Path (Join-Path $RestoreTarget $rel)
        New-SafeDirectory (Join-Path $RestoreTarget $rel)

        $cmdArgs = @($srcSubNorm, $dstSubNorm) + @("*") + $roboOptions
        Write-Log "Ejecutando Robocopy (subpath=$rel)..." "INFO"
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
        Write-Log "Robocopy (subpath=$rel) finalizado con código $exitCode" "INFO"

        $Audit.Add([pscustomobject]@{
          Timestamp = (Get-Date)
          Action    = 'Restore-Run'
          Source    = $srcSub
          Target    = (Join-Path $RestoreTarget $rel)
          SizeBytes = (Get-ChildItem -LiteralPath $srcSub -Recurse -File | Measure-Object Length -Sum).Sum
          Status    = $DryRun ? 'DRYRUN' : 'OK'
        })
      }
    }

    # Verificación de checksum (si corresponde y no es DryRun)
    if ($VerifyChecksum -and -not $DryRun) {
      Write-Log "Verificando integridad ($ChecksumAlgorithm) post-restauración..." "INFO"
      $restoredRoot = $RestoreTarget
      $srcRoot      = $VersionPath

      $srcFiles = Get-ChildItem -LiteralPath $srcRoot -Recurse -File -ErrorAction SilentlyContinue
      foreach ($sf in $srcFiles) {
        if (Get-IsExcluded -Name $sf.Name -Patterns $ExcludePatterns) { continue }
        $rel = $sf.FullName.Substring($srcRoot.Length).TrimStart('\')
        # si se seleccionaron subpaths específicos, limitar verificación
        if (-not ($includeRel | Where-Object { $rel -like ("{0}\*" -f $_) -or $_ -eq "*" })) { continue }

        $dstFile = Join-Path $restoredRoot $rel
        if (-not (Test-Path -LiteralPath $dstFile)) { 
          $Audit.Add([pscustomobject]@{
            Timestamp = (Get-Date)
            Action    = 'Verify'
            Source    = $sf.FullName
            Target    = $dstFile
            SizeBytes = $sf.Length
            Status    = 'MISSING'
          })
          Write-Log "Falta en destino: $rel" "WARN"
          continue
        }

        $hSrc = Get-Checksum -Path $sf.FullName -Algo $ChecksumAlgorithm
        $hDst = Get-Checksum -Path $dstFile   -Algo $ChecksumAlgorithm
        $ok = ($hSrc -and $hDst -and ($hSrc -eq $hDst))
        $Audit.Add([pscustomobject]@{
          Timestamp = (Get-Date)
          Action    = 'Verify'
          Source    = $sf.FullName
          Target    = $dstFile
          SizeBytes = $sf.Length
          Status    = $ok ? 'OK' : 'MISMATCH'
        })
        if (-not $ok) { Write-Log "Checksum mismatch: $rel" "WARN" }
      }
    }

  } catch {
    Write-Log "Error en restauración -> $($_.Exception.Message)" "ERROR"
    $Audit.Add([pscustomobject]@{
      Timestamp = (Get-Date)
      Action    = 'Restore-Error'
      Source    = $VersionPath
      Target    = $RestoreTarget
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
  $report += "==== Restore Quick Summary ($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) ===="
  $report += "SetName:      $SetName"
  $report += "VersionPath:  $VersionPath"
  $report += "RestoreTarget:$RestoreTarget"
  $report += "DryRun:       $($DryRun.IsPresent)"
  $report += "Verify:       $($VerifyChecksum.IsPresent) ($ChecksumAlgorithm)"
  $report += ""
  foreach ($row in $summary) { $report += "{0,-16} Count={1,5}  Size={2} MB" -f $row.Action, $row.Count, $row.SizeMB }
  $report += ""
  $report += "Logs:"
  $report += " - Execution: $ExecutionLogPath"
  $report += " - Robocopy : $roboRawLog"
  $report += " - Audit CSV: $AuditCsvPath"
  $report += " - Audit JSON: $AuditJsonPath"

  try { $report | Out-File -LiteralPath $SummaryReportPath -Encoding UTF8 } catch { Write-Log "Error guardando resumen -> $($_.Exception.Message)" "ERROR" }
  Write-Log "Restauración completada. Resumen: $SummaryReportPath" "INFO"
}
