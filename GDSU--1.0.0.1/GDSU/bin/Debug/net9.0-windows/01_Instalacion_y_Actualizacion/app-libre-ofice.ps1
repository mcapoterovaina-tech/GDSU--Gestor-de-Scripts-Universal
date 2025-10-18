<# 
.SYNOPSIS
Descarga automáticamente el instalador oficial de LibreOffice (MSI) desde los servidores de The Document Foundation,
mostrando progreso en consola y manteniéndola abierta al final.
#>

param(
    [ValidateSet('Fresh','Still')]
    [string]$Channel = 'Fresh',
    [string]$OutputDir = "$env:USERPROFILE\Downloads\LibreOffice",
    [switch]$DryRun
)

function Get-OsArch {
    if ([Environment]::Is64BitOperatingSystem) {
        return @{ ArchFolder = 'x86_64'; ArchLabel = 'x86-64' }
    } else {
        return @{ ArchFolder = 'x86'; ArchLabel = 'x86' }
    }
}

function Get-LibreOfficeLatestVersion {
    param([string]$Channel)

    $indexUrl = 'https://download.documentfoundation.org/libreoffice/stable/'
    try {
        $resp = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -TimeoutSec 30
    } catch {
        throw "No se pudo acceder a $indexUrl. Detalle: $($_.Exception.Message)"
    }

    $versions = @()
    foreach ($link in $resp.Links) {
        # Solo aceptar versiones con formato mayor.menor(.parche)
        if ($link.href -match '^\d+\.\d+(\.\d+)?/$') {
            $candidate = $link.href.TrimEnd('/')
            try {
                # Validar que realmente se pueda convertir a [Version]
                [void][Version]$candidate
                $versions += $candidate
            } catch {
                # Ignorar entradas que no sean versiones válidas
            }
        }
    }

    if (-not $versions) {
        throw "No se encontraron versiones válidas en el índice oficial."
    }

    # Ordenar versiones usando objetos [Version]
    $sorted = $versions | Sort-Object { [Version]$_ } -Descending

    # Fresh = la más reciente, Still = la segunda más reciente
    if ($Channel -eq 'Fresh') {
        return $sorted[0]
    } else {
        return if ($sorted.Count -gt 1) { $sorted[1] } else { $sorted[0] }
    }
}

function Build-DownloadUrl {
    param($Version, $ArchFolder, $ArchLabel)
    return "https://download.documentfoundation.org/libreoffice/stable/$Version/win/$ArchFolder/LibreOffice_${Version}_Win_${ArchLabel}.msi"
}

function Download-WithProgress {
    param($Url, $Destination)

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $resp = $req.GetResponse()
    } catch {
        Write-Host "❌ Error al conectar con el servidor: $($_.Exception.Message)"
        return
    }

    if (-not $resp) {
        Write-Host "❌ No se pudo obtener respuesta del servidor."
        return
    }

    $total = $resp.ContentLength
    $stream = $resp.GetResponseStream()
    $fs = New-Object IO.FileStream($Destination, [IO.FileMode]::Create)

    $buffer = New-Object byte[] 8192
    $totalRead = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fs.Write($buffer, 0, $read)
            $totalRead += $read
            $percent = [math]::Round(($totalRead / $total) * 100, 2)
            Write-Progress -Activity "Descargando LibreOffice" -Status "$percent% completado" -PercentComplete $percent
        }
    } finally {
        $fs.Close()
        if ($stream) { $stream.Close() }
        if ($resp) { $resp.Close() }
    }

    $sw.Stop()
    Write-Host "✅ Descarga finalizada en $($sw.Elapsed.TotalSeconds) segundos."
}

# --- Flujo principal ---
$arch = Get-OsArch
$version = Get-LibreOfficeLatestVersion -Channel $Channel
$url = Build-DownloadUrl -Version $version -ArchFolder $arch.ArchFolder -ArchLabel $arch.ArchLabel
$filename = Split-Path -Leaf $url
$destPath = Join-Path $OutputDir $filename

Write-Host "Canal: $Channel"
Write-Host "Versión: $version"
Write-Host "Arquitectura: $($arch.ArchLabel)"
Write-Host "URL: $url"
Write-Host "Destino: $destPath"

if ($DryRun) {
    Write-Host "🔎 DryRun activado. No se descargará el archivo."
} else {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    Download-WithProgress -Url $url -Destination $destPath
    if (Test-Path $destPath) {
        Write-Host "📂 Archivo guardado en: $destPath"
    } else {
        Write-Host "❌ No se pudo guardar el archivo."
    }


# Mantener consola abierta
Write-Host "`nPresiona ENTER para salir..."
[void][System.Console]::ReadLine()
