Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Formulario base ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Gestor de Scripts Universal"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(900, 640)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

# Estilo general
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 248, 250) # casi blanco con tono frío
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Ruta a tu icono personalizado (.ico)
$iconPath = Join-Path $PSScriptRoot "logo.ico"
$form.Icon = New-Object System.Drawing.Icon($iconPath)



# --- Barra superior (header) ---
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Size = New-Object System.Drawing.Size($form.ClientSize.Width, 52)
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(28, 42, 66) # azul profundo
$headerPanel.Anchor = 'Top,Left,Right'
$form.Controls.Add($headerPanel)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Gestor de Scripts Universal"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12.5)
$lblTitle.Location = New-Object System.Drawing.Point(20, 14)
$lblTitle.AutoSize = $true
$headerPanel.Controls.Add($lblTitle)

# --- Contenedor principal con margen ---
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Location = New-Object System.Drawing.Point(16, 60)
$contentPanel.Size = New-Object System.Drawing.Size(868, 520)
$contentPanel.BackColor = [System.Drawing.Color]::FromArgb(252, 253, 254)
$contentPanel.Anchor = 'Top,Left,Right,Bottom'
$contentPanel.Padding = New-Object System.Windows.Forms.Padding(12)
$form.Controls.Add($contentPanel)

# --- GroupBox Log ---
$gbLog = New-Object System.Windows.Forms.GroupBox
$gbLog.Text = " Registro "
$gbLog.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$gbLog.ForeColor = [System.Drawing.Color]::FromArgb(50, 60, 70)
$gbLog.Size = New-Object System.Drawing.Size(840, 220)
$gbLog.Location = New-Object System.Drawing.Point(12, 12)
$contentPanel.Controls.Add($gbLog)

$tbLog = New-Object System.Windows.Forms.TextBox
$tbLog.Location = New-Object System.Drawing.Point(16, 28)
$tbLog.Size = New-Object System.Drawing.Size(808, 170)
$tbLog.Multiline = $true
$tbLog.ScrollBars = 'Vertical'
$tbLog.ReadOnly = $true
$tbLog.BorderStyle = 'FixedSingle'
$tbLog.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$tbLog.Font = New-Object System.Drawing.Font("Cascadia Mono", 9) # Monoespaciada para logs
$gbLog.Controls.Add($tbLog)

# --- GroupBox Scripts ---
$gbTree = New-Object System.Windows.Forms.GroupBox
$gbTree.Text = " Scripts disponibles "
$gbTree.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$gbTree.ForeColor = [System.Drawing.Color]::FromArgb(50, 60, 70)
$gbTree.Size = New-Object System.Drawing.Size(840, 220)
$gbTree.Location = New-Object System.Drawing.Point(12, 242)
$contentPanel.Controls.Add($gbTree)

$tree = New-Object System.Windows.Forms.TreeView
$tree.Location = New-Object System.Drawing.Point(16, 28)
$tree.Size = New-Object System.Drawing.Size(808, 170)
$tree.CheckBoxes = $true
$tree.HideSelection = $false
$tree.BorderStyle = 'FixedSingle'
$tree.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$tree.Font = New-Object System.Drawing.Font("Segoe UI", 9)
# Mejora visual de líneas del TreeView
$tree.ShowLines = $true
$tree.ShowRootLines = $true
$tree.ShowNodeToolTips = $true
$gbTree.Controls.Add($tree)

# --- Botonera inferior ---
$btnPanel = New-Object System.Windows.Forms.Panel
$btnPanel.Size = New-Object System.Drawing.Size(840, 40)
$btnPanel.Location = New-Object System.Drawing.Point(12, 472)
$btnPanel.Anchor = 'Left,Right,Bottom'
$contentPanel.Controls.Add($btnPanel)

function New-StyledButton($text, $location) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = $location
    $btn.Size = New-Object System.Drawing.Size(190, 30)
    $btn.FlatStyle = 'System' # más nativo; si quieres Flat, cambia a 'Flat' y ajusta colores
    return $btn
}

$btnRun = New-StyledButton "Ejecutar seleccionados" ([System.Drawing.Point]::new(0, 5))
$btnRefresh = New-StyledButton "Refrescar" ([System.Drawing.Point]::new(205, 5))
$btnClose = New-StyledButton "Cerrar" ([System.Drawing.Point]::new(650, 5))
$btnClose.Size = New-Object System.Drawing.Size(190, 30)

$btnPanel.Controls.AddRange(@($btnRun, $btnRefresh, $btnClose))

# --- Barra de estado ---
$status = New-Object System.Windows.Forms.StatusStrip
$status.SizingGrip = $false
$status.BackColor = [System.Drawing.Color]::FromArgb(236, 240, 244)
$status.ForeColor = [System.Drawing.Color]::FromArgb(60, 70, 80)

$sslStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$sslStatus.Text = "Listo"
$sslStatus.Spring = $true

$sslTime = New-Object System.Windows.Forms.ToolStripStatusLabel
$sslTime.Text = (Get-Date).ToString("HH:mm")
$sslTime.BorderSides = "Left"
$sslTime.BorderStyle = "Raised"
$status.Items.AddRange(@($sslStatus, $sslTime))
$form.Controls.Add($status)

# --- Utilidades ---
function Write-Log($text) {
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $tbLog.AppendText("[$timestamp] $text`r`n")
    $sslStatus.Text = $text
    $sslTime.Text = (Get-Date).ToString("HH:mm")
}

function Is-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Carga de árbol ---
$rootPath = $PSScriptRoot  # Carpeta donde está este script

function Load-Tree {
    $tree.BeginUpdate()
    $tree.Nodes.Clear()

    if (-not (Test-Path $rootPath -PathType Container)) {
        Write-Log "ERROR: Ruta raíz inválida: $rootPath"
        $tree.EndUpdate()
        return
    }

    # Listar solo subcarpetas inmediatas de la raíz
    $topFolders = Get-ChildItem -Path $rootPath -Directory -ErrorAction SilentlyContinue
    if (-not $topFolders) {
        Write-Log "No hay subcarpetas en la raíz: $rootPath"
    }

    foreach ($folder in $topFolders) {
        # Nodo de carpeta
        $folderNode = New-Object System.Windows.Forms.TreeNode($folder.Name)
        $folderNode.Tag = $folder.FullName
        $folderNode.NodeFont = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
        $folderNode.ToolTipText = $folder.FullName

        # Archivos dentro de la carpeta (solo .bat y .ps1)
        $scripts = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -in '.bat', '.ps1' }

        if (-not $scripts) {
            Write-Log "Carpeta sin scripts: $($folder.FullName)"
        } else {
            foreach ($script in $scripts) {
                $child = New-Object System.Windows.Forms.TreeNode($script.Name)
                $child.Tag = $script.FullName  # Ruta completa del archivo
                $child.ToolTipText = $script.FullName
                $folderNode.Nodes.Add($child) | Out-Null
            }
        }

        $tree.Nodes.Add($folderNode) | Out-Null
    }

    $tree.ExpandAll()
    $tree.EndUpdate()
    Write-Log "Árbol cargado desde: $rootPath"
}

# Propagar check de carpeta a hijos
$tree.Add_AfterCheck({
    if ($_.Action -eq [System.Windows.Forms.TreeViewAction]::ByKeyboard -or
        $_.Action -eq [System.Windows.Forms.TreeViewAction]::ByMouse) {
        $node = $_.Node
        if ((Test-Path $node.Tag -PathType Container) -and $node.Nodes.Count -gt 0) {
            foreach ($child in $node.Nodes) {
                $child.Checked = $node.Checked
            }
        }
    }
})

# --- Ejecución de seleccionados en paralelo ---
# Mantenemos referencias para eventos de salida
$global:RunningProcesses = @{}

function Run-Selected {
    $started = 0

    foreach ($folderNode in $tree.Nodes) {
        foreach ($child in $folderNode.Nodes) {
            if ($child.Checked -and $child.Tag -and (Test-Path $child.Tag -PathType Leaf)) {
                $path = $child.Tag
                $ext  = [IO.Path]::GetExtension($path).ToLowerInvariant()
                $wd   = [IO.Path]::GetDirectoryName($path)

                try {
                    switch ($ext) {
                        ".bat" {
                            $p = Start-Process -FilePath "cmd.exe" `
                                -ArgumentList "/c `"$path`"" `
                                -WorkingDirectory $wd `
                                -WindowStyle Normal `
                                -PassThru
                        }
                        ".ps1" {
                            $p = Start-Process -FilePath "powershell.exe" `
                                -ArgumentList "-ExecutionPolicy Bypass -NoLogo -NoProfile -File `"$path`"" `
                                -WorkingDirectory $wd `
                                -WindowStyle Normal `
                                -PassThru
                        }
                        default {
                            Write-Log "Saltado (extensión no soportada): $path"
                            continue
                        }
                    }

                    if ($p) {
                        $p.EnableRaisingEvents = $true
                        Register-ObjectEvent -InputObject $p -EventName Exited -Action {
                            $proc = $Event.Sender
                            $code = $proc.ExitCode
                            $null = $global:RunningProcesses.Remove($proc.Id)
                            Write-Log "FIN (PID $($proc.Id), exit code $code)"
                        } | Out-Null

                        $global:RunningProcesses[$p.Id] = @{ Path = $path; Type = $ext }
                        Write-Log "Lanzado: $path (PID $($p.Id))"
                        $started++
                    } else {
                        Write-Log "No se pudo iniciar: $path"
                    }
                } catch {
                    Write-Log "Excepción al iniciar $path -> $($_.Exception.Message)"
                }
            }
        }
    }

    if ($started -eq 0) {
        Write-Log "No hay scripts seleccionados."
    } else {
        Write-Log "Procesos lanzados en paralelo: $started"
    }
}

# --- Eventos de botones ---
$btnRun.Add_Click({
    if (-not (Is-Admin)) {
        Write-Log "Advertencia: ejecuta como Administrador para evitar permisos bloqueados."
    }
    Run-Selected
})
$btnRefresh.Add_Click({ Load-Tree })
$btnClose.Add_Click({ $form.Close() })

# Botones rápidos del teclado
$form.AcceptButton = $btnRun
$form.CancelButton = $btnClose

# --- Inicio ---
Load-Tree
[void]$form.ShowDialog()
