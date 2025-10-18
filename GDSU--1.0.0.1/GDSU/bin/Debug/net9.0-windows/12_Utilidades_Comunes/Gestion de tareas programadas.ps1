#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Utilidades comunes (logs, validaciones, exec)
$script:SessionId = [Guid]::NewGuid().ToString()
$script:LogPath   = Join-Path $env:ProgramData "GDSU\logs\tasks"
$script:ExportDir = Join-Path $env:ProgramData "GDSU\exports\tasks"
$script:Color     = @{
    Bg    = [System.Drawing.Color]::FromArgb(24,24,28)
    Panel = [System.Drawing.Color]::FromArgb(32,32,36)
    Accent= [System.Drawing.Color]::FromArgb(0,122,204)
    Text  = [System.Drawing.Color]::WhiteSmoke
    Warn  = [System.Drawing.Color]::FromArgb(255,193,7)
    Error = [System.Drawing.Color]::FromArgb(220,53,69)
    Ok    = [System.Drawing.Color]::FromArgb(40,167,69)
}

function Ensure-Dirs {
    foreach ($d in @($script:LogPath, $script:ExportDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Write-StructuredLog {
    param(
        [string] $Operation,
        [string] $Message,
        [string] $Level = "Info",
        [hashtable] $Data
    )
    Ensure-Dirs
    $logFile = Join-Path $script:LogPath ("tasks_" + (Get-Date -Format "yyyyMMdd") + ".json")
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        sessionId = $script:SessionId
        op        = $Operation
        level     = $Level
        message   = $Message
        data      = $Data
    }
    ($entry | ConvertTo-Json -Depth 6) + [Environment]::NewLine | Out-File -FilePath $logFile -Append -Encoding UTF8
}

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExistingTasks {
    try {
        $out = schtasks.exe /Query /FO CSV /V 2>$null
        if (-not $out) { return @() }
        $csv = $out -join [Environment]::NewLine | ConvertFrom-Csv
        return $csv
    } catch {
        Write-StructuredLog -Operation "ListTasks" -Message $_.Exception.Message -Level "Error"
        return @()
    }
}

function Validate-Trigger {
    param(
        [string] $Type,     # Once|Daily|Weekly|OnLogon
        [datetime] $StartAt,
        [int] $IntervalDays,
        [string[]] $DaysOfWeek
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $validDays = "MON","TUE","WED","THU","FRI","SAT","SUN"

    switch ($Type) {
        "Once"   { if (-not $StartAt) { $errors.Add("Debe especificar fecha y hora de inicio (HH:mm).") } }
        "Daily"  {
            if (-not $StartAt) { $errors.Add("Debe especificar hora de inicio (HH:mm).") }
            if ($IntervalDays -lt 1) { $errors.Add("Intervalo de días debe ser >= 1.") }
        }
        "Weekly" {
            if (-not $StartAt) { $errors.Add("Debe especificar hora de inicio (HH:mm).") }
            if (-not $DaysOfWeek -or $DaysOfWeek.Count -eq 0) { 
                $errors.Add("Debe seleccionar al menos un día de la semana.") 
            } else {
                foreach ($d in $DaysOfWeek) {
                    if ($validDays -notcontains $d.ToUpper()) {
                        $errors.Add("Día inválido: $d. Use MON..SUN.")
                    }
                }
            }
        }
        "OnLogon" { }
        default  { $errors.Add("Tipo de trigger inválido.") }
    }
    return $errors
}

function Build-SchtasksArgs {
    param(
        [string] $TaskName,
        [string] $ScriptPath,
        [string] $Arguments,
        [string] $UserContext,  # "SYSTEM" | username
        [string] $TriggerType,  # Once|Daily|Weekly|OnLogon
        [datetime] $StartAt,
        [int] $IntervalDays = 1,
        [string[]] $DaysOfWeek
    )

    # Validar nombre de tarea (sin caracteres especiales)
    if ($TaskName -match '[^\w\-\.\ ]') {
        throw "El nombre de la tarea contiene caracteres inválidos. Solo letras, números, guiones y puntos."
    }

    # Comando PowerShell a ejecutar (escapado seguro)
    $exe   = "powershell.exe"
    $escapedScript = '"' + $ScriptPath.Replace('"','""') + '"'
    $arg0  = "-NoProfile -ExecutionPolicy Bypass -File $escapedScript"
    if ($Arguments) { 
        $arg0 += " " + ($Arguments -replace '"','\"') 
    }

    $base = @("/Create","/TN",$TaskName,"/TR","$exe $arg0")

    switch ($TriggerType) {
        "Once"   { $base += @("/SC","ONCE","/ST",$StartAt.ToString("HH:mm")) }
        "Daily"  { $base += @("/SC","DAILY","/ST",$StartAt.ToString("HH:mm"),"/MO",$IntervalDays) }
        "Weekly" {
            $days = ($DaysOfWeek -join ",").ToUpper()
            $base += @("/SC","WEEKLY","/ST",$StartAt.ToString("HH:mm"),"/D",$days)
        }
        "OnLogon" { $base += @("/SC","ONLOGON") }
    }

    if ($UserContext -eq "SYSTEM") {
        $base += @("/RU","SYSTEM")
    } else {
        $base += @("/RU",$UserContext)
    }

    return $base
}
#endregion


#region Exportación de definición (XML + JSON)
function Export-TaskDefinition {
    param(
        [Parameter(Mandatory=$true)][string] $TaskName,
        [Parameter(Mandatory=$true)][hashtable] $Definition
    )
    Ensure-Dirs

    # Normalizar nombre de archivo seguro
    $safe = ($TaskName -replace '[^\w\-\.]', '_')
    $jsonFile = Join-Path $script:ExportDir "$safe.json"
    $xmlFile  = Join-Path $script:ExportDir "$safe.xml"

    try {
        # JSON descriptivo
        $Definition | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonFile -Encoding UTF8 -Force

        # XML simplificado (plantilla base)
        $xml = New-Object System.Xml.XmlDocument
        $xml.AppendChild($xml.CreateXmlDeclaration("1.0","UTF-8",$null)) | Out-Null

        $task = $xml.CreateElement("Task")
        $task.SetAttribute("version","1.4")

        # Settings básicos
        $settings = $xml.CreateElement("Settings")
        $settings.AppendChild($xml.CreateElement("MultipleInstancesPolicy")).InnerText = "IgnoreNew"
        $settings.AppendChild($xml.CreateElement("DisallowStartIfOnBatteries")).InnerText = "true"
        $task.AppendChild($settings) | Out-Null

        # Triggers
        if ($Definition.Trigger) {
            $triggers = $xml.CreateElement("Triggers")
            $tr = $xml.CreateElement("Trigger")
            $tr.SetAttribute("type",$Definition.Trigger.Type)

            if ($Definition.Trigger.StartAt) {
                $tr.AppendChild($xml.CreateElement("StartBoundary")).InnerText = ([datetime]$Definition.Trigger.StartAt).ToString("o")
            }
            if ($Definition.Trigger.DaysOfWeek) {
                $tr.AppendChild($xml.CreateElement("DaysOfWeek")).InnerText = ($Definition.Trigger.DaysOfWeek -join ",")
            }
            $triggers.AppendChild($tr) | Out-Null
            $task.AppendChild($triggers) | Out-Null
        }

        # Actions
        if ($Definition.Action) {
            $actions = $xml.CreateElement("Actions")
            $exec = $xml.CreateElement("Exec")
            $exec.AppendChild($xml.CreateElement("Command")).InnerText = "powershell.exe"

            # Escapado seguro de ruta y argumentos
            $scriptPathEscaped = '"' + $Definition.Action.ScriptPath.Replace('"','""') + '"'
            $argsEscaped = if ($Definition.Action.Arguments) { $Definition.Action.Arguments } else { "" }
            $exec.AppendChild($xml.CreateElement("Arguments")).InnerText = "-NoProfile -ExecutionPolicy Bypass -File $scriptPathEscaped $argsEscaped"

            $actions.AppendChild($exec) | Out-Null
            $task.AppendChild($actions) | Out-Null
        }

        $xml.AppendChild($task) | Out-Null
        $xml.Save($xmlFile)

        Write-StructuredLog -Operation "ExportTask" -Message "Exportada definición" -Data @{ task = $TaskName; json = $jsonFile; xml = $xmlFile }
        return @{ Success=$true; Json = $jsonFile; Xml = $xmlFile }

    } catch {
        Write-StructuredLog -Operation "ExportTask" -Message $_.Exception.Message -Level "Error"
        return @{ Success=$false; Errors=@($_.Exception.Message) }
    }
}
#endregion

#region Creación de tareas
function New-ScheduledTask {
    param(
        [Parameter(Mandatory=$true)][string] $TaskName,
        [Parameter(Mandatory=$true)][string] $ScriptPath,
        [string] $Arguments,
        [string] $UserContext,   # "SYSTEM" o nombre de usuario
        [string] $TriggerType,   # Once|Daily|Weekly|OnLogon
        [datetime] $StartAt,
        [int] $IntervalDays = 1,
        [string[]] $DaysOfWeek,
        [switch] $DryRun
    )

    $errors = @()

    # Validaciones básicas
    if ([string]::IsNullOrWhiteSpace($TaskName)) { $errors += "Nombre de tarea obligatorio." }
    elseif ($TaskName -match '[^\w\-\.\ ]') { $errors += "El nombre de la tarea contiene caracteres inválidos." }

    if (-not (Test-Path -LiteralPath $ScriptPath)) { $errors += "El script no existe: $ScriptPath" }

    $tErrors = Validate-Trigger -Type $TriggerType -StartAt $StartAt -IntervalDays $IntervalDays -DaysOfWeek $DaysOfWeek
    if ($tErrors.Count -gt 0) { $errors += $tErrors }

    if ($errors.Count -gt 0) {
        Write-StructuredLog -Operation "CreateTask" -Message "Validación fallida" -Level "Warn" -Data @{ errors = $errors; task=$TaskName }
        return @{ Success=$false; Errors=$errors }
    }

    # Construir argumentos
    $args = Build-SchtasksArgs -TaskName $TaskName -ScriptPath $ScriptPath -Arguments $Arguments `
                               -UserContext $UserContext -TriggerType $TriggerType -StartAt $StartAt `
                               -IntervalDays $IntervalDays -DaysOfWeek $DaysOfWeek

    if ($DryRun) {
        Write-StructuredLog -Operation "CreateTask" -Message "DryRun" -Data @{ args = $args; task=$TaskName }
        return @{ Success=$true; DryRun=$true; Command="schtasks " + ($args -join " ") }
    }

    try {
        # Ejecutar schtasks.exe
        $proc = Start-Process -FilePath "schtasks.exe" -ArgumentList $args -NoNewWindow -PassThru -Wait
        if ($proc.ExitCode -eq 0) {
            Write-StructuredLog -Operation "CreateTask" -Message "Tarea creada correctamente" -Level "Info" -Data @{ args = $args; task=$TaskName }
            return @{ Success=$true; DryRun=$false; Message="Tarea creada correctamente." }
        } else {
            Write-StructuredLog -Operation "CreateTask" -Message "Error al crear tarea" -Level "Error" -Data @{ code=$proc.ExitCode; args=$args; task=$TaskName }
            return @{ Success=$false; Errors=@("Error al crear tarea. Código: $($proc.ExitCode)") }
        }
    } catch {
        Write-StructuredLog -Operation "CreateTask" -Message $_.Exception.Message -Level "Error" -Data @{ task=$TaskName }
        return @{ Success=$false; Errors=@($_.Exception.Message) }
    }
}
#endregion


#region UI principal
function New-ScheduledTaskUI {
    Ensure-Dirs

    # Form base
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "GDSU - Gestión de Tareas Programadas"
    $form.Size = New-Object System.Drawing.Size(900,560)
    $form.MinimumSize = New-Object System.Drawing.Size(820,520)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = $script:Color.Bg
    $form.Font = New-Object System.Drawing.Font("Segoe UI",9)

    # ToolTip y ErrorProvider
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.IsBalloon = $true
    $toolTip.ToolTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $errorProvider = New-Object System.Windows.Forms.ErrorProvider
    $errorProvider.BlinkStyle = [System.Windows.Forms.ErrorBlinkStyle]::NeverBlink

    # StatusStrip
    $status = New-Object System.Windows.Forms.StatusStrip
    $status.BackColor = $script:Color.Panel
    $status.ForeColor = $script:Color.Text
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = "Listo"
    [void]$status.Items.Add($statusLabel)
    $form.Controls.Add($status)

    # Split principal
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.SplitterDistance = 380
    $split.IsSplitterFixed = $false
    $split.BackColor = $script:Color.Bg
    $split.Panel1.BackColor = $script:Color.Panel
    $split.Panel2.BackColor = $script:Color.Panel
    $form.Controls.Add($split)

    # -------- Panel izquierdo: listado --------
    $lblTasks = New-Object System.Windows.Forms.Label
    $lblTasks.Text = "Tareas existentes"
    $lblTasks.ForeColor = $script:Color.Text
    $lblTasks.AutoSize = $true
    $lblTasks.Location = New-Object System.Drawing.Point -ArgumentList 10, 10
    $split.Panel1.Controls.Add($lblTasks)

    $grid = New-Object System.Windows.Forms.ListView
    $grid.View = "Details"
    $grid.FullRowSelect = $true
    $grid.GridLines = $true
    $grid.Size = New-Object System.Drawing.Size 360, 420
    $grid.Location = New-Object System.Drawing.Point -ArgumentList 10, 35
    $grid.Anchor = "Top,Bottom,Left,Right"
    [void]$grid.Columns.Add("Nombre",180)
    [void]$grid.Columns.Add("Programación",120)
    [void]$grid.Columns.Add("Estado",60)
    $split.Panel1.Controls.Add($grid)

    # Reducir flicker
    $grid.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags] "NonPublic, Instance").SetValue($grid, $true, $null)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Actualizar lista"
    $btnRefresh.Size = New-Object System.Drawing.Size 120, 30
    $btnRefresh.Location = New-Object System.Drawing.Point -ArgumentList 10, 465
    $btnRefresh.TabIndex = 100
    $split.Panel1.Controls.Add($btnRefresh)
    $toolTip.SetToolTip($btnRefresh,"Recarga las tareas desde el Programador de Windows")

    # -------- Panel derecho: creación/edición --------
    $marginLeft = 10
    $top = 10

    # Nombre de la tarea
    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "Nombre de la tarea"
    $lblName.ForeColor = $script:Color.Text
    $lblName.AutoSize = $true
    $lblName.Location = New-Object System.Drawing.Point -ArgumentList $marginLeft, $top
    $split.Panel2.Controls.Add($lblName)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Size = New-Object System.Drawing.Size 420, 24
    $txtName.Location = New-Object System.Drawing.Point -ArgumentList $marginLeft, ($top + 20)
    $txtName.TabIndex = 0
    $split.Panel2.Controls.Add($txtName)
    $toolTip.SetToolTip($txtName,"Usa un nombre único. Evita símbolos raros.")

    # Validación inline segura para Nombre
    $txtName.Add_TextChanged({
        if ([string]::IsNullOrWhiteSpace($txtName.Text)) {
            $errorProvider.SetError($txtName, "Nombre obligatorio")
        } elseif ($txtName.Text -match '[^\w\-\.\ ]') {
            $errorProvider.SetError($txtName, "Caracteres inválidos (solo letras, números, guiones y puntos).")
        } else {
            $errorProvider.SetError($txtName, "")
        }
    })

    # Script a ejecutar
    $lblScript = New-Object System.Windows.Forms.Label
    $lblScript.Text = "Script (.ps1) a ejecutar"
    $lblScript.ForeColor = $script:Color.Text
    $lblScript.AutoSize = $true
    $lblScript.Location = New-Object System.Drawing.Point -ArgumentList $marginLeft, 65
    $split.Panel2.Controls.Add($lblScript)

    $txtScript = New-Object System.Windows.Forms.TextBox
    $txtScript.Size = New-Object System.Drawing.Size 370, 24
    $txtScript.Location = New-Object System.Drawing.Point -ArgumentList $marginLeft, 85
    $txtScript.TabIndex = 1
    $split.Panel2.Controls.Add($txtScript)
    $toolTip.SetToolTip($txtScript,"Ruta completa del script PowerShell (.ps1)")

    # Validación inline segura para Script
    $txtScript.Add_TextChanged({
        $val = $txtScript.Text
        if ([string]::IsNullOrWhiteSpace($val)) {
            $errorProvider.SetError($txtScript, "Ruta vacía")
        } elseif (-not (Test-Path -LiteralPath $val)) {
            $errorProvider.SetError($txtScript, "Ruta inválida o inexistente")
        } else {
            $errorProvider.SetError($txtScript, "")
        }
    })

    #endregion

    # --- Botón Crear tarea ---
    $btnCreate.Add_Click({
        $txtValidation.Text = ""
        $txtValidation.ForeColor = $script:Color.Text

        # Preparar parámetros
        $taskName   = $txtName.Text
        $scriptPath = $txtScript.Text
        $arguments  = $txtArgs.Text
        $trigger    = $cmbTrigger.SelectedItem.ToString()
        $startAt    = $null
        if ($trigger -ne "OnLogon") {
            try { $startAt = [datetime]::ParseExact($txtTime.Text,"HH:mm",$null) } catch { }
        }
        $days = $null
        if ($trigger -eq "Weekly") { $days = ($txtDays.Text -split ",") | ForEach-Object { $_.Trim().ToUpper() } }
        $userCtx = if ($cmbUser.SelectedItem -eq "SYSTEM") { "SYSTEM" } else { $env:USERNAME }
        $dry     = $chkDry.Checked

        # Llamar a la función de creación
        $result = New-ScheduledTask -TaskName $taskName `
                                    -ScriptPath $scriptPath `
                                    -Arguments $arguments `
                                    -UserContext $userCtx `
                                    -TriggerType $trigger `
                                    -StartAt $startAt `
                                    -IntervalDays 1 `
                                    -DaysOfWeek $days `
                                    -DryRun:$dry

        # Mostrar resultado
        if ($result.Success) {
            if ($result.DryRun) {
                $txtValidation.ForeColor = $script:Color.Warn
                $txtValidation.Text = "DryRun:`r`n$result.Command"
                $statusLabel.Text = "Simulación completada"
            } else {
                $txtValidation.ForeColor = $script:Color.Ok
                $txtValidation.Text = $result.Message
                $statusLabel.Text = "Tarea creada correctamente"
            }
        } else {
            $txtValidation.ForeColor = $script:Color.Error
            $txtValidation.Text = ($result.Errors -join "`r`n")
            $statusLabel.Text = "Error al crear tarea"
        }
    })

    # --- Botón Exportar definición ---
    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = "Exportar definición"
    $btnExport.Size = New-Object System.Drawing.Size 140, 32
    $btnExport.Location = New-Object System.Drawing.Point -ArgumentList 140, 410
    $btnExport.TabIndex = 11
    $split.Panel2.Controls.Add($btnExport)

    $btnExport.Add_Click({
        try {
            $definition = @{
                Trigger = @{
                    Type      = $cmbTrigger.SelectedItem.ToString()
                    StartAt   = if ($cmbTrigger.SelectedItem -ne "OnLogon") { $txtTime.Text } else { $null }
                    DaysOfWeek= if ($cmbTrigger.SelectedItem -eq "Weekly") { ($txtDays.Text -split ",") } else { $null }
                }
                Action = @{
                    ScriptPath = $txtScript.Text
                    Arguments  = $txtArgs.Text
                }
            }
            $export = Export-TaskDefinition -TaskName $txtName.Text -Definition $definition
            if ($export.Success) {
                $txtValidation.ForeColor = $script:Color.Ok
                $txtValidation.Text = "Definición exportada:`r`nJSON: $($export.Json)`r`nXML: $($export.Xml)"
                $statusLabel.Text = "Definición exportada"
            } else {
                $txtValidation.ForeColor = $script:Color.Error
                $txtValidation.Text = ($export.Errors -join "`r`n")
                $statusLabel.Text = "Error al exportar"
            }
        } catch {
            $txtValidation.ForeColor = $script:Color.Error
            $txtValidation.Text = $_.Exception.Message
            $statusLabel.Text = "Error inesperado"
        }
    })

    # --- Botón Vista previa ---
    $btnPreview = New-Object System.Windows.Forms.Button
    $btnPreview.Text = "Vista previa comando"
    $btnPreview.Size = New-Object System.Drawing.Size 155, 32
    $btnPreview.Location = New-Object System.Drawing.Point -ArgumentList 285, 410
    $btnPreview.TabIndex = 12
    $split.Panel2.Controls.Add($btnPreview)

    $btnPreview.Add_Click({
        $taskName   = $txtName.Text
        $scriptPath = $txtScript.Text
        $arguments  = $txtArgs.Text
        $trigger    = $cmbTrigger.SelectedItem.ToString()
        $startAt    = $null
        if ($trigger -ne "OnLogon") {
            try { $startAt = [datetime]::ParseExact($txtTime.Text,"HH:mm",$null) } catch { }
        }
        $days = $null
        if ($trigger -eq "Weekly") { $days = ($txtDays.Text -split ",") | ForEach-Object { $_.Trim().ToUpper() } }
        $userCtx = if ($cmbUser.SelectedItem -eq "SYSTEM") { "SYSTEM" } else { $env:USERNAME }

        try {
            $args = Build-SchtasksArgs -TaskName $taskName -ScriptPath $scriptPath -Arguments $arguments `
                                       -UserContext $userCtx -TriggerType $trigger -StartAt $startAt `
                                       -IntervalDays 1 -DaysOfWeek $days
            $txtValidation.ForeColor = $script:Color.Warn
            $txtValidation.Text = "Vista previa:`r`n" + ("schtasks " + ($args -join " "))
            $statusLabel.Text = "Vista previa generada"
        } catch {
            $txtValidation.ForeColor = $script:Color.Error
            $txtValidation.Text = $_.Exception.Message
            $statusLabel.Text = "Error en vista previa"
        }
    })


     # --- Evento del botón Crear tarea ---
    $btnCreate.Add_Click({
        $txtValidation.Text = ""
        $txtValidation.ForeColor = $script:Color.Text

        # Preparar parámetros
        $taskName   = $txtName.Text
        $scriptPath = $txtScript.Text
        $arguments  = $txtArgs.Text
        $trigger    = $cmbTrigger.SelectedItem.ToString()
        $startAt    = $null
        if ($trigger -ne "OnLogon") {
            try { $startAt = [datetime]::ParseExact($txtTime.Text,"HH:mm",$null) } catch { }
        }
        $days = $null
        if ($trigger -eq "Weekly") { $days = ($txtDays.Text -split ",") | ForEach-Object { $_.Trim().ToUpper() } }
        $userCtx = if ($cmbUser.SelectedItem -eq "SYSTEM") { "SYSTEM" } else { $env:USERNAME }
        $dry     = $chkDry.Checked

        # Llamar a la función de creación
        $result = New-ScheduledTask -TaskName $taskName `
                                    -ScriptPath $scriptPath `
                                    -Arguments $arguments `
                                    -UserContext $userCtx `
                                    -TriggerType $trigger `
                                    -StartAt $startAt `
                                    -IntervalDays 1 `
                                    -DaysOfWeek $days `
                                    -DryRun:$dry

        # Mostrar resultado
        if ($result.Success) {
            if ($result.DryRun) {
                $txtValidation.ForeColor = $script:Color.Warn
                $txtValidation.Text = "DryRun:`r`n$result.Command"
                $statusLabel.Text = "Simulación completada"
            } else {
                $txtValidation.ForeColor = $script:Color.Ok
                $txtValidation.Text = $result.Message
                $statusLabel.Text = "Tarea creada correctamente"
                $btnRefresh.PerformClick() # refrescar lista
            }
        } else {
            $txtValidation.ForeColor = $script:Color.Error
            $txtValidation.Text = ($result.Errors -join "`r`n")
            $statusLabel.Text = "Error al crear tarea"
        }
    })

    # --- Evento del botón Exportar definición ---
    $btnExport.Add_Click({
        try {
            $definition = @{
                Trigger = @{
                    Type      = $cmbTrigger.SelectedItem.ToString()
                    StartAt   = if ($cmbTrigger.SelectedItem -ne "OnLogon") { $txtTime.Text } else { $null }
                    DaysOfWeek= if ($cmbTrigger.SelectedItem -eq "Weekly") { ($txtDays.Text -split ",") } else { $null }
                }
                Action = @{
                    ScriptPath = $txtScript.Text
                    Arguments  = $txtArgs.Text
                }
            }
            $export = Export-TaskDefinition -TaskName $txtName.Text -Definition $definition
            if ($export.Success) {
                $txtValidation.ForeColor = $script:Color.Ok
                $txtValidation.Text = "Definición exportada:`r`nJSON: $($export.Json)`r`nXML: $($export.Xml)"
                $statusLabel.Text = "Definición exportada"
            } else {
                $txtValidation.ForeColor = $script:Color.Error
                $txtValidation.Text = ($export.Errors -join "`r`n")
                $statusLabel.Text = "Error al exportar"
            }
        } catch {
            $txtValidation.ForeColor = $script:Color.Error
            $txtValidation.Text = $_.Exception.Message
            $statusLabel.Text = "Error inesperado"
        }
    })

    # --- Evento del botón Vista previa ---
    $btnPreview.Add_Click({
        $taskName   = $txtName.Text
        $scriptPath = $txtScript.Text
        $arguments  = $txtArgs.Text
        $trigger    = $cmbTrigger.SelectedItem.ToString()
        $startAt    = $null
        if ($trigger -ne "OnLogon") {
            try { $startAt = [datetime]::ParseExact($txtTime.Text,"HH:mm",$null) } catch { }
        }
        $days = $null
        if ($trigger -eq "Weekly") { $days = ($txtDays.Text -split ",") | ForEach-Object { $_.Trim().ToUpper() } }
        $userCtx = if ($cmbUser.SelectedItem -eq "SYSTEM") { "SYSTEM" } else { $env:USERNAME }

        try {
            $args = Build-SchtasksArgs -TaskName $taskName -ScriptPath $scriptPath -Arguments $arguments `
                                       -UserContext $userCtx -TriggerType $trigger -StartAt $startAt `
                                       -IntervalDays 1 -DaysOfWeek $days
            $txtValidation.ForeColor = $script:Color.Warn
            $txtValidation.Text = "Vista previa:`r`n" + ("schtasks " + ($args -join " "))
            $statusLabel.Text = "Vista previa generada"
        } catch {
            $txtValidation.ForeColor = $script:Color.Error
            $txtValidation.Text = $_.Exception.Message
            $statusLabel.Text = "Error en vista previa"
        }
    })

    # -------- Eventos UI (ya completos) --------
    $btnRefresh.Add_Click({
        try {
            $grid.BeginUpdate()
            $grid.Items.Clear()
            foreach ($t in Get-ExistingTasks) {
                $item = New-Object System.Windows.Forms.ListViewItem($t.TaskName)
                [void]$item.SubItems.Add($t.ScheduleType)
                [void]$item.SubItems.Add($t.Status)
                [void]$grid.Items.Add($item)
            }
            # Autoajuste de columnas
            for ($i=0; $i -lt $grid.Columns.Count; $i++) {
                $grid.AutoResizeColumn($i, [System.Windows.Forms.ColumnHeaderAutoResizeStyle]::HeaderSize)
                $grid.AutoResizeColumn($i, [System.Windows.Forms.ColumnHeaderAutoResizeStyle]::ColumnContent)
            }
            $statusLabel.Text = "Lista actualizada: $($grid.Items.Count) tareas"
            Write-StructuredLog -Operation "ListTasks" -Message "Lista actualizada"
        } catch {
            $statusLabel.Text = "Error al actualizar lista"
            Write-StructuredLog -Operation "ListTasks" -Message $_.Exception.Message -Level "Error"
        } finally {
            $grid.EndUpdate()
        }
    })

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "PowerShell script (*.ps1)|*.ps1|Todos los archivos (*.*)|*.*"
        $dlg.Title = "Seleccionar script de PowerShell"
        $dlg.InitialDirectory = [Environment]::GetFolderPath("MyDocuments")
        if ($dlg.ShowDialog() -eq "OK") {
            $txtScript.Text = $dlg.FileName
            $errorProvider.SetError($txtScript, "")
        }
    })

    # Validación inline básica (ya consistente con backend)
    $txtName.Add_TextChanged({
        if ([string]::IsNullOrWhiteSpace($txtName.Text)) {
            $errorProvider.SetError($txtName, "Nombre obligatorio")
        } elseif ($txtName.Text -match '[^\w\-\.\ ]') {
            $errorProvider.SetError($txtName, "Caracteres inválidos")
        } else {
            $errorProvider.SetError($txtName, "")
        }
    })
    $txtScript.Add_TextChanged({
        if (-not (Test-Path -LiteralPath $txtScript.Text)) {
            $errorProvider.SetError($txtScript, "Ruta inválida o inexistente")
        } else {
            $errorProvider.SetError($txtScript, "")
        }
    })
    $txtTime.Add_TextChanged({
        if ($cmbTrigger.SelectedItem -ne "OnLogon") {
            try { [datetime]::ParseExact($txtTime.Text,"HH:mm",$null) | Out-Null; $errorProvider.SetError($txtTime, "") }
            catch { $errorProvider.SetError($txtTime, "Formato HH:mm") }
        } else { $errorProvider.SetError($txtTime, "") }
    })

    # Primera carga
    $btnRefresh.PerformClick()
    $form.ShowDialog() | Out-Null
#endregion

# Entrypoint
New-ScheduledTaskUI

