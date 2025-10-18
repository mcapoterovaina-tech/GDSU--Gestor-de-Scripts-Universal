<#
.SYNOPSIS
  Rotación de logs: comprimir, mover a archivo y purgar por antigüedad y tamaño.

.DESCRIPTION
  - Comprime logs más antiguos que CompressAfterDays.
  - Mueve ZIPs y/o logs a ArchivePath con estructura YYYY\MM\DD

\[source].
  - Purga archivos más antiguos que PurgeAfterDays.
  - Controla tamaño máximo del archivo con MaxArchiveSizeMB.
  - Genera auditoría en CSV/JSON y log de ejecución.
  - Idempotente: evita recomprimir/mover/purgar duplicados.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory=$true)]
  [string[]]$LogRoots,

  [Parameter(Mandatory=$true)]
  [string]$ArchivePath,

  [int]$CompressAfterDays = 7,

  [int]$PurgeAfterDays = 30,

  [int]$MaxArchiveSizeMB = 2048,

  [switch]$DryRun,

  [string[]]$ExcludePatterns = @('*.lock', '*.lck', '*.tmp'),

  [string]$ExecutionLogPath,

  [string]$AuditCsvPath,
  [string]$AuditJsonPath,

  [switch]$VerboseConsole,

  [switch]$IncludeEmptyDirs
)

begin {
  function New-SafeDirectory {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
      if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
      }
    }
  }

  function Get-IsExcluded {
    param(
      [string]$Name,
      [string[]]$Patterns
    )
    foreach ($pat in $Patterns) {
      if ($Name -like $pat) { return $true }
    }
    return $false
  }

  function Get-ArchiveSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return (Get-ChildItem -LiteralPath $Path -Recurse -File | Measure-Object -Property Length -Sum).Sum
  }

  function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts][$Level] $Message"
    if ($VerboseConsole) { Write-Host $line }
    if ($ExecutionLogPath) { Add-Content -LiteralPath $ExecutionLogPath -Value $line }
  }

  function Test-FileLocked {
    param([string]$FilePath)
    try {
      $stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
      $stream.Close()
      return $false
    } catch {
      return $true
    }
  }

  # Auditoría acumulada
  $Audit = New-Object System.Collections.Generic.List[Object]

  # Preparar rutas por defecto para logs/auditoría
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $defaultLogDir = Join-Path -Path $env:TEMP -ChildPath "LogRotation"
  New-SafeDirectory $defaultLogDir

  if (-not $ExecutionLogPath) {
    $ExecutionLogPath = Join-Path $defaultLogDir "rotation_$timestamp.log"
  }
  if (-not $AuditCsvPath) {
    $AuditCsvPath = Join-Path $defaultLogDir "rotation_$timestamp.csv"
  }
  if (-not $AuditJsonPath) {
    $AuditJsonPath = Join-Path $defaultLogDir "rotation_$timestamp.json"
  }

  Write-Log "Inicio rotación. DryRun=$($DryRun.IsPresent) CompressAfterDays=$CompressAfterDays PurgeAfterDays=$PurgeAfterDays MaxArchiveSizeMB=$MaxArchiveSizeMB" 'INFO'

  # Validaciones iniciales
  foreach ($root in $LogRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
      throw "LogRoot no existe: $root"
    }
  }
  New-SafeDirectory $ArchivePath

  # Control de tamaño inicial del archivo
  $MaxArchiveSizeBytes = [math]::Max(0, $MaxArchiveSizeMB) * 1MB
}

process {
  foreach ($root in $LogRoots) {
    try {
      Write-Log "Procesando raíz: $root" 'INFO'

      $cutoffCompress = (Get-Date).AddDays(-$CompressAfterDays)
      $cutoffPurge = (Get-Date).AddDays(-$PurgeAfterDays)

      # Enumerar archivos de log
      $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop

      # Opcional: incluir directorios vacíos para limpiar (solo si se desea)
      if ($IncludeEmptyDirs) {
        $dirs = Get-ChildItem -LiteralPath $root -Recurse -Directory
      }

      # Estructura en archivo por fecha y fuente
      $dateFolder = Join-Path $ArchivePath (Get-Date -Format 'yyyy\\MM\\dd')
      $sourceFolder = Split-Path -Path $root -Leaf
      $targetBase = Join-Path $dateFolder $sourceFolder
      New-SafeDirectory $targetBase

      # 1) COMPRESIÓN: agrupar por carpeta para ZIP idempotente por día
      # Estrategia: crear zip por carpeta fuente + marca de fecha (YYYYMMDD)
      $groupByDir = $files | Group-Object { $_.DirectoryName }

      foreach ($grp in $groupByDir) {
        $dirPath = $grp.Name
        $toCompress = @()
        foreach ($f in $grp.Group) {
          if (Get-IsExcluded -Name $f.Name -Patterns $ExcludePatterns) { 
            Write-Log "Excluido por patrón: $($f.FullName)" 'INFO'
            continue 
          }
          if ($f.LastWriteTime -gt $cutoffCompress) { continue }
          if (Test-FileLocked -FilePath $f.FullName) { 
            Write-Log "Saltado por bloqueo: $($f.FullName)" 'WARN'
            continue 
          }
          $toCompress += $f
        }

        if ($toCompress.Count -gt 0) {
          $stamp = (Get-Date).ToString('yyyyMMdd')
          $zipName = "{0}_{1}.zip" -f (Split-Path -Path $dirPath -Leaf), $stamp
          $zipPath = Join-Path $targetBase $zipName

          # Idempotencia: si ZIP existe, no duplicar. Verificar contenido utilizando hash de lista.
          $alreadyExists = Test-Path -LiteralPath $zipPath
          if (-not $alreadyExists) {
            Write-Log "Creando ZIP: $zipPath (files=$($toCompress.Count))" 'INFO'
            if (-not $DryRun) {
              # Crear zip con System.IO.Compression (sin dependencias externas)
              Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

              # Crear ZIP vacío
              if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
              [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create).Dispose()

              # Abrir y añadir entradas
              $zipArchive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
              foreach ($file in $toCompress) {
                $entryName = Join-Path (Split-Path -Path $dirPath -Leaf) $file.Name
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
              }
              $zipArchive.Dispose()
            }

            # Auditoría de compresión
            foreach ($file in $toCompress) {
              $Audit.Add([pscustomobject]@{
                Timestamp = (Get-Date)
                Action    = 'Compress'
                Source    = $file.FullName
                Target    = $zipPath
                SizeBytes = $file.Length
                Status    = if ($DryRun) { 'DRYRUN' } else { 'OK' }
              })
            }
          } else {
            Write-Log "ZIP ya existe, manteniendo idempotencia: $zipPath" 'INFO'
          }
        }
      }

      # 2) MOVER: mover ZIPs y/o archivos sueltos (si aplica) hacia $targetBase
      # En esta implementación los ZIP ya se crean directamente en $targetBase => movimiento implícito

      # 3) PURGA POR ANTIGÜEDAD: eliminar archivos de log que superen PurgeAfterDays
      foreach ($f in $files) {
        if ($f.LastWriteTime -le $cutoffPurge) {
          if (Get-IsExcluded -Name $f.Name -Patterns $ExcludePatterns) {
            continue
          }
          if (Test-FileLocked -FilePath $f.FullName) {
            Write-Log "No se purga por bloqueo: $($f.FullName)" 'WARN'
            continue
          }

          Write-Log "Purga por antigüedad: $($f.FullName)" 'INFO'
          if (-not $DryRun) {
            try {
              Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
              $Audit.Add([pscustomobject]@{
                Timestamp = (Get-Date)
                Action    = 'Purge-Age'
                Source    = $f.FullName
                Target    = ''
                SizeBytes = $f.Length
                Status    = 'OK'
              })
            } catch {
              Write-Log "Error al purgar: $($f.FullName) -> $($_.Exception.Message)" 'ERROR'
              $Audit.Add([pscustomobject]@{
                Timestamp = (Get-Date)
                Action    = 'Purge-Age'
                Source    = $f.FullName
                Target    = ''
                SizeBytes = $f.Length
                Status    = 'ERROR'
              })
            }
          } else {
            $Audit.Add([pscustomobject]@{
              Timestamp = (Get-Date)
              Action    = 'Purge-Age'
              Source    = $f.FullName
              Target    = ''
              SizeBytes = $f.Length
              Status    = 'DRYRUN'
            })
          }
        }
      }

      # 4) CONTROL DE TAMAÑO DEL ARCHIVO: si excede, purgar ZIPs más antiguos primero
      $archiveSize = Get-ArchiveSizeBytes -Path $ArchivePath
      if ($archiveSize -gt $MaxArchiveSizeBytes) {
        Write-Log "Archive supera límite: $([math]::Round($archiveSize/1MB,2))MB > $MaxArchiveSizeMB MB. Se purgarán ZIPs antiguos." 'WARN'

        $zips = Get-ChildItem -LiteralPath $ArchivePath -Recurse -File -Filter *.zip | Sort-Object LastWriteTime
        foreach ($zip in $zips) {
          if (Get-ArchiveSizeBytes -Path $ArchivePath -le $MaxArchiveSizeBytes) { break }
          Write-Log "Eliminar ZIP antiguo: $($zip.FullName)" 'INFO'
          if (-not $DryRun) {
            try {
              $size = $zip.Length
              Remove-Item -LiteralPath $zip.FullName -Force -ErrorAction Stop
              $Audit.Add([pscustomobject]@{
                Timestamp = (Get-Date)
                Action    = 'Purge-Size'
                Source    = $zip.FullName
                Target    = ''
                SizeBytes = $size
                Status    = 'OK'
              })
            } catch {
              Write-Log "Error al eliminar ZIP: $($zip.FullName) -> $($_.Exception.Message)" 'ERROR'
              $Audit.Add([pscustomobject]@{
                Timestamp = (Get-Date)
                Action    = 'Purge-Size'
                Source    = $zip.FullName
                Target    = ''
                SizeBytes = $zip.Length
                Status    = 'ERROR'
              })
            }
          } else {
            $Audit.Add([pscustomobject]@{
              Timestamp = (Get-Date)
              Action    = 'Purge-Size'
              Source    = $zip.FullName
              Target    = ''
              SizeBytes = $zip.Length
              Status    = 'DRYRUN'
            })
          }
        }
      }

      # Opcional: eliminar directorios vacíos
      if ($IncludeEmptyDirs) {
        foreach ($d in $dirs | Sort-Object FullName -Descending) {
          $hasFiles = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File | Measure-Object).Count -gt 0
          if (-not $hasFiles) {
            Write-Log "Eliminar directorio vacío: $($d.FullName)" 'INFO'
            if (-not $DryRun) {
              Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
              $Audit.Add([pscustomobject]@{
                Timestamp = (Get-Date)
                Action    = 'Remove-EmptyDir'
                Source    = $d.FullName
                Target    = ''
                SizeBytes = 0
                Status    = 'OK'
              })
            } else {
              $Audit.Add([pscustomobject]@{
                Timestamp = (Get-Date)
                Action    = 'Remove-EmptyDir'
                Source    = $d.FullName
                Target    = ''
                SizeBytes = 0
                Status    = 'DRYRUN'
              })
            }
          }
        }
      }

      Write-Log "Finalizado raíz: $root" 'INFO'
    } catch {
      Write-Log "Error raíz $root -> $($_.Exception.Message)" 'ERROR'
      $Audit.Add([pscustomobject]@{
        Timestamp = (Get-Date)
        Action    = 'Root-Error'
        Source    = $root
        Target    = ''
        SizeBytes = 0
        Status    = 'ERROR'
      })
    }
  }
}

end {
  # Guardar auditoría
  try {
    Write-Log "Guardando auditoría en CSV: $AuditCsvPath y JSON: $AuditJsonPath" 'INFO'
    if ($Audit.Count -gt 0) {
      if (-not $DryRun) {
        $Audit | Export-Csv -LiteralPath $AuditCsvPath -NoTypeInformation -Encoding UTF8
        $Audit | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $AuditJsonPath -Encoding UTF8
      } else {
        # En DryRun igual entregamos snapshot simulado
        $Audit | Export-Csv -LiteralPath $AuditCsvPath -NoTypeInformation -Encoding UTF8
        $Audit | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $AuditJsonPath -Encoding UTF8
      }
    } else {
      Write-Log "No hubo acciones para auditar." 'INFO'
    }
  } catch {
    Write-Log "Error guardando auditoría -> $($_.Exception.Message)" 'ERROR'
  }

  # Resumen
  $summary = $Audit | Group-Object Action | ForEach-Object {
    [pscustomobject]@{
      Action = $_.Name
      Count  = $_.Count
      SizeMB = [math]::Round((($_.Group | Measure-Object -Property SizeBytes -Sum).Sum / 1MB), 2)
    }
  }

  if ($summary) {
    Write-Log "Resumen de acciones:" 'INFO'
    $summary | Sort-Object Action | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
  }

  Write-Log "Rotación completada. Log: $ExecutionLogPath | CSV: $AuditCsvPath | JSON: $AuditJsonPath" 'INFO'
}
