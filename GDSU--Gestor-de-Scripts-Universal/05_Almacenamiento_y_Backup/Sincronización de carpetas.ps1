<#
.SYNOPSIS
  Sincronización de carpetas: copiado diferencial con verificación de checksum (Robocopy + resumen).

.DESCRIPTION
  - Usa Robocopy para copiar solo cambios (diferencial) con múltiples hilos y reintentos controlados.
  - Opcionalmente opera en modo espejo (Mirror) para eliminar en destino lo que ya no existe en origen.
  - Verifica integridad con checksum (SHA256 por defecto) para archivos copiados/actualizados.
  - Genera auditoría en CSV/JSON y log de ejecución con resumen de acciones.
  - Idempotente y seguro: DryRun disponible, exclusiones configurables, límites de reintento.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory=$true)]
  [string]$Source,

  [Parameter(Mandatory=$true)]
  [string]$Destination,

  [string[]]$IncludePatterns = @("*"),     # patrones incluidos (wildcards)
  [string[]]$ExcludePatterns = @("*.tmp","*.lck","*.lock","*.bak"),

  [switch]$Mirror,                          # si está activo, elimina en destino lo que falta en origen (como /MIR)

  [switch]$VerifyChecksum,                  # verificar integridad con hash tras el copiado
  [ValidateSet("SHA256","SHA1","MD5")]
  [string]$ChecksumAlgorithm = "SHA256",

  [int]$ThreadCount = 8,                    # /MT:n
  [int]$RetryCount = 2,                     # /R:n
  [int]$WaitSeconds = 2,                    # /W:n

  [switch]$PreserveAttributes,              # copia atributos extendidos (DAT / DCOPY:T)
  [switch]$UseLongPaths,                    # habilita prefijo \\?\ para rutas largas

  [switch]$CopyHiddenSystem,                # incluye archivos Hidden+System si se requiere

  [switch]$DryRun,                          # simula (usa robocopy /L y no altera)

  [string]$ExecutionLogPath,                # log detallado (si no se especifica, se crea en %TEMP%)
  [string]$AuditCsvPath,                    # auditoría CSV
  [string]$AuditJsonPath,                   # auditoría JSON
  [string]$SummaryReportPath                # resumen TXT/MD al final
)

begin {
  # Utilidades
  function New-SafeDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
  }

  function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    if ($ExecutionLogPath) { Add-Content -LiteralPath $ExecutionLogPath -Value $line }
  }

  function Get-Checksum {
    param([string]$Path, [string]$Algo = "SHA256")
    try {
      $hash = Get-FileHash -LiteralPath $Path -Algorithm $Algo -ErrorAction Stop
      return $hash.Hash
    } catch {
      return $null
    }
  }

  function Get-IsExcluded {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pat in $Patterns) { if ($Name -like $pat) { return $true } }
    return $false
  }

  # Auditoría acumulada
  $Audit = New-Object System.Collections.Generic.List[Object]

  # Defaults de rutas para log/auditoría
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $defaultLogDir = Join-Path -Path $env:TEMP -ChildPath "FolderSync"
  New-SafeDirectory $defaultLogDir

  if (-not $ExecutionLogPath) { $ExecutionLogPath = Join-Path $defaultLogDir "sync_$timestamp.log" }
  if (-not $AuditCsvPath)     { $AuditCsvPath     = Join-Path $defaultLogDir "sync_$timestamp.csv" }
  if (-not $AuditJsonPath)    { $AuditJsonPath    = Join-Path $defaultLogDir "sync_$timestamp.json" }
  if (-not $SummaryReportPath){ $SummaryReportPath= Join-Path $defaultLogDir "summary_$timestamp.txt" }

  # Validaciones
  if (-not (Test-Path -LiteralPath $Source))     { throw "Source no existe: $Source" }
  New-SafeDirectory $Destination
  Write-Log "Inicio sincronización | Source=$Source | Destination=$Destination | DryRun=$($DryRun.IsPresent) | Mirror=$($Mirror.IsPresent)" "INFO"

  # Normalizar rutas largas si se solicita
  function Normalize-Path {
    param([string]$Path)
    if ($UseLongPaths) {
      if ($Path -match '^[A-Za-z]:\\') { return "\\?\$Path" }
      if ($Path -match '^\\\\')        { return "\\?\UNC\$($Path.TrimStart('\'))" }
    }
    return $Path
  }
  $SourceNorm      = Normalize-Path -Path $Source
  $DestinationNorm = Normalize-Path -Path $Destination

  # Construir opciones de Robocopy
  $roboOptions = @()
  # Diferencial por timestamps, atributos, tamaño; robusto y rápido
  if ($PreserveAttributes) {
    $roboOptions += @("/COPY:DAT","/DCOPY:T")    # datos, atributos, timestamps
  } else {
    $roboOptions += @("/COPY:DAT")               # datos+atributos+timestamps por defecto
  }
  if ($CopyHiddenSystem) { $roboOptions += "/A+" }  # incluye Hidden/System; alternativa: /XA:H /XA:S para excluir
  $roboOptions += @("/R:$RetryCount","/W:$WaitSeconds","/MT:$ThreadCount","/FFT","/TEE","/NP","/NFL","/NDL","/XJ")  # rápido, sin listas de archivos/directorios (los generamos nosotros), muestra en consola y log
  # Inclusión/exclusión
  foreach ($inc in $IncludePatterns) { $roboOptions += ("/IF") ; break } # /IF: fuerza copy si coincide con patterns; usaremos /IF para aplicar inclusión
  foreach ($exc in $ExcludePatterns) { $roboOptions += ("/XF:$exc") }

  # Modo espejo (mirror) con cautela; si no, solo copy diferencial sin eliminar
  if ($Mirror) { $roboOptions += "/MIR" } else { $roboOptions += "/E" }  # /E: incluye subdirectorios vacíos
  # Simulación
  if ($DryRun) { $roboOptions += "/L" }

  # Log de Robocopy adicional (texto crudo, útil para parseo)
  $roboRawLog = Join-Path $defaultLogDir "robocopy_$timestamp.log"
  $roboOptions += "/LOG:`"$roboRawLog`""

  Write-Log "Opciones Robocopy: $($roboOptions -join ' ')" "INFO"
}

process {
  try {
    # Preparar lista de máscaras (Robocopy acepta especificar archivos/patrones al final)
    $maskArgs = @()
    foreach ($inc in $IncludePatterns) {
      $maskArgs += $inc
    }

    # Ejecutar Robocopy
    $cmdArgs = @($SourceNorm, $DestinationNorm) + $maskArgs + $roboOptions
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

    # Guardar salida en log
    Add-Content -LiteralPath $ExecutionLogPath -Value $stdout
    if ($stderr) { Add-Content -LiteralPath $ExecutionLogPath -Value $stderr }

    Write-Log "Robocopy finalizado con código $exitCode" "INFO"

    # Parseo básico del log para determinar acciones (copiados/actualizados/eliminados/omitidos)
    # Nota: Robocopy presenta una tabla Report con "Dirs :", "Files :", "Bytes :"
    $copiedFiles    = 0
    $skippedFiles   = 0
    $mismatchFiles  = 0
    $deletedFiles   = 0
    $totalBytesCopy = 0

    $lines = $stdout -split "`r?`n"
    foreach ($line in $lines) {
      if ($line -match '^\s*Files:\s+\d+\s+(\d+)\s+(\d+)\s+(\d+)') {
        # La tabla suele ser: Files : total  copied  skipped  mismatch  failed  extras
        # Pero el formato puede variar según versión; haremos un parseo flexible
        try {
          $nums = ($line -replace '[^\d\s]', '') -split '\s+' | Where-Object { $_ -match '^\d+$' }
          # Esperamos orden: total copied skipped mismatch failed extras
          if ($nums.Count -ge 6) {
            $copiedFiles   = [int]$nums[1]
            $skippedFiles  = [int]$nums[2]
            $mismatchFiles = [int]$nums[3]
            # $failedFiles = [int]$nums[4]  # opcional
            # $extraFiles  = [int]$nums[5]
          }
        } catch { }
      } elseif ($line -match '^\s*Deleted\s+:\s+(\d+)') {
        $deletedFiles = [int]$Matches[1]
      } elseif ($line -match '^\s*Bytes\s+:\s+\d+\s+([0-9,]+)\s+[0-9,]+') {
        try {
          $bytesStr = $Matches[1] -replace ',', ''
          $totalBytesCopy = [int64]$bytesStr
        } catch { }
      }
    }

    # Registrar resumen parcial en auditoría
    $Audit.Add([pscustomobject]@{
      Timestamp = (Get-Date)
      Action    = 'Robocopy-Run'
      Source    = $Source
      Target    = $Destination
      Copied    = $copiedFiles
      Skipped   = $skippedFiles
      Deleted   = $deletedFiles
      Mismatch  = $mismatchFiles
      Bytes     = $totalBytesCopy
      Status    = if ($DryRun) { 'DRYRUN' } else { 'OK' }
    })

    # Verificación de checksum para archivos copiados/actualizados (si procede y no es DryRun)
    if ($VerifyChecksum -and -not $DryRun) {
      Write-Log "Verificando checksum ($ChecksumAlgorithm) para archivos copiados..." "INFO"

      # Enumerar archivos en origen y destino según patrones y exclusión
      $sourceFiles = Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue
      foreach ($sf in $sourceFiles) {
        if (Get-IsExcluded -Name $sf.Name -Patterns $ExcludePatterns) { continue }
        # Mapear ruta en destino
        $relPath = $sf.FullName.Substring($Source.Length).TrimStart('\')
        $dfPath  = Join-Path $Destination $relPath
        if (-not (Test-Path -LiteralPath $dfPath)) { continue } # si no existe en destino, no verificar (posible exclusión)

        # Calcular hash en ambos
        $hSrc = Get-Checksum -Path $sf.FullName -Algo $ChecksumAlgorithm
        $hDst = Get-Checksum -Path $dfPath     -Algo $ChecksumAlgorithm
        $equal = ($hSrc -and $hDst -and ($hSrc -eq $hDst))

        if ($equal) {
          $Audit.Add([pscustomobject]@{
            Timestamp = (Get-Date)
            Action    = 'Verify'
            Source    = $sf.FullName
            Target    = $dfPath
            SizeBytes = $sf.Length
            Status    = 'OK'
          })
        } else {
          Write-Log "Checksum mismatch: $relPath" "WARN"
          $Audit.Add([pscustomobject]@{
            Timestamp = (Get-Date)
            Action    = 'Verify'
            Source    = $sf.FullName
            Target    = $dfPath
            SizeBytes = $sf.Length
            Status    = 'MISMATCH'
          })
        }
      }
    }

    # Si Mirror y no es DryRun, registramos eliminaciones en auditoría (basado en log crudo)
    if ($Mirror) {
      # Intento de detección de líneas "EXTRA File" -> eliminado; depende de /MIR
      foreach ($line in (Get-Content -LiteralPath $roboRawLog)) {
        if ($line -match '^\s*Deleting\s+File') {
          $path = ($line -replace '^\s*Deleting\s+File\s+', '').Trim()
          $Audit.Add([pscustomobject]@{
            Timestamp = (Get-Date)
            Action    = 'Delete'
            Source    = $path
            Target    = ''
            SizeBytes = 0
            Status    = $DryRun ? 'DRYRUN' : 'OK'
          })
        }
      }
    }

  } catch {
    Write-Log "Error en sincronización -> $($_.Exception.Message)" "ERROR"
    $Audit.Add([pscustomobject]@{
      Timestamp = (Get-Date)
      Action    = 'Sync-Error'
      Source    = $Source
      Target    = $Destination
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

  # Construir resumen legible
  $summary = $Audit | Group-Object Action | ForEach-Object {
    [pscustomobject]@{
      Action = $_.Name
      Count  = $_.Count
      SizeMB = [math]::Round((($_.Group | Measure-Object -Property SizeBytes -Sum).Sum / 1MB), 2)
    }
  } | Sort-Object Action

  $report = @()
  $report += "==== FolderSync Summary ($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) ===="
  $report += "Source:      $Source"
  $report += "Destination: $Destination"
  $report += "DryRun:      $($DryRun.IsPresent)"
  $report += "Mirror:      $($Mirror.IsPresent)"
  $report += ""
  foreach ($row in $summary) {
    $report += "{0,-14} Count={1,5}  Size={2} MB" -f $row.Action, $row.Count, $row.SizeMB
  }
  $report += ""
  $report += "Logs:"
  $report += " - Execution: $ExecutionLogPath"
  $report += " - Robocopy : $roboRawLog"
  $report += " - Audit CSV: $AuditCsvPath"
  $report += " - Audit JSON: $AuditJsonPath"

  try {
    $report | Out-File -LiteralPath $SummaryReportPath -Encoding UTF8
  } catch {
    Write-Log "Error guardando resumen -> $($_.Exception.Message)" "ERROR"
  }

  Write-Log "Sincronización completada. Resumen: $SummaryReportPath" "INFO"
}
