#requires -version 5.1
# Politicas de firewall con GUI y auditoria diff
# Autor: Copilot (para Maikol)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =========================
# Configuracion
# =========================
$Global:AppTitle    = "Politicas de Firewall (GDSU)"
$Global:LogRoot     = "C:\Logs\FirewallGDSU"
$Global:AuditRoot   = Join-Path $env:USERPROFILE "Documents\FirewallGDSU"
$Global:LogFile     = Join-Path $Global:LogRoot ("FW_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Global:RuleGroup   = "GDSU-FW"
$Global:BaseLabel   = "GDSU"

foreach ($p in @($Global:LogRoot, $Global:AuditRoot)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

# =========================
# Utilidades y logging
# =========================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpper(), $Message
    try { Add-Content -Path $Global:LogFile -Value $line } catch { }
    if ($Global:LogBox -and !$Global:LogBox.IsDisposed) {
        $Global:LogBox.AppendText("$line`r`n")
        $Global:LogBox.SelectionStart = $Global:LogBox.Text.Length
        $Global:LogBox.ScrollToCaret()
    }
}

function Get-FwSnapshot {
    try {
        $rules = Get-NetFirewallRule -ErrorAction Stop |
            Select-Object Name, DisplayName, Enabled, Direction, Action, Profile, Group, @{n="InterfaceTypes";e={$_.InterfaceType}}
        $ports = foreach ($r in $rules) {
            try {
                $flt = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $r.Name -ErrorAction SilentlyContinue |
                       Select-Object Protocol, LocalPort, RemotePort
                [PSCustomObject]@{
                    RuleName    = $r.Name
                    Protocol    = ($flt.Protocol -join ",")
                    LocalPort   = ($flt.LocalPort -join ",")
                    RemotePort  = ($flt.RemotePort -join ",")
                }
            } catch { }
        }
        return @{
            Timestamp = (Get-Date).ToString("s")
            Rules     = $rules
            Ports     = $ports
        }
    } catch {
        Write-Log "Error capturando snapshot -> $($_.Exception.Message)" "ERROR"
        return @{ Timestamp = (Get-Date).ToString("s"); Rules=@(); Ports=@() }
    }
}

function Save-Audit {
    param([Parameter(Mandatory)][hashtable]$Before,
          [Parameter(Mandatory)][hashtable]$After,
          [Parameter(Mandatory)][string]$OperationLabel)

    $auditFolder = Join-Path $Global:AuditRoot ("Audit_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    if (!(Test-Path $auditFolder)) { New-Item -ItemType Directory -Path $auditFolder | Out-Null }

    $beforeJson = $Before | ConvertTo-Json -Depth 6
    $afterJson  = $After  | ConvertTo-Json -Depth 6
    Set-Content -Path (Join-Path $auditFolder "before.json") -Value $beforeJson -Encoding UTF8
    Set-Content -Path (Join-Path $auditFolder "after.json")  -Value $afterJson  -Encoding UTF8

    # Diff simple por Name (alta/baja/mod)
    $bNames = @($Before.Rules | Select-Object -ExpandProperty Name)
    $aNames = @($After.Rules  | Select-Object -ExpandProperty Name)
    $added  = $aNames | Where-Object { $_ -notin $bNames }
    $removed= $bNames | Where-Object { $_ -notin $aNames }
    $common = $aNames | Where-Object { $_ -in $bNames }

    $mods = @()
    foreach ($n in $common) {
        $br = $Before.Rules | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        $ar = $After.Rules  | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if ($br -and $ar) {
            if ($br.Enabled -ne $ar.Enabled -or $br.Action -ne $ar.Action -or $br.Profile -ne $ar.Profile -or $br.Direction -ne $ar.Direction -or $br.Group -ne $ar.Group) {
                $mods += $n
            } else {
                # Comprobar puertos/ protocolo
                $bp = $Before.Ports | Where-Object { $_.RuleName -eq $n } | Select-Object -First 1
                $ap = $After.Ports  | Where-Object { $_.RuleName -eq $n } | Select-Object -First 1
                if ($bp -and $ap) {
                    if ($bp.Protocol -ne $ap.Protocol -or $bp.LocalPort -ne $ap.LocalPort -or $bp.RemotePort -ne $ap.RemotePort) {
                        $mods += $n
                    }
                }
            }
        }
    }

    $report = @(
        [PSCustomObject]@{ Change="Added";   Items=($added -join ", ") },
        [PSCustomObject]@{ Change="Removed"; Items=($removed -join ", ") },
        [PSCustomObject]@{ Change="Modified";Items=($mods   -join ", ") }
    )
    $report | Export-Csv -Path (Join-Path $auditFolder "diff.csv") -NoTypeInformation -Encoding UTF8
    Set-Content -Path (Join-Path $auditFolder "operation.txt") -Value $OperationLabel -Encoding UTF8

    Write-Log "Auditoria guardada en: $auditFolder"
}

function Parse-Ports {
    param([Parameter(Mandatory)][string]$PortsText)
    $clean = $PortsText -replace '\s',''
    if ([string]::IsNullOrWhiteSpace($clean)) { return @() }
    $parts = $clean.Split(',') | Where-Object { $_ -match '^\d{1,5}$' -and [int]$_ -ge 1 -and [int]$_ -le 65535 }
    return $parts
}

function Get-SelectedProfiles {
    param([bool]$Domain,[bool]$Private,[bool]$Public)
    $pf = 0
    if ($Domain)  { $pf = $pf -bor 1 }    # Domain
    if ($Private) { $pf = $pf -bor 2 }    # Private
    if ($Public)  { $pf = $pf -bor 4 }    # Public
    if ($pf -eq 0) { throw "Debe seleccionar al menos un perfil (Domain/Private/Public)." }
    return $pf
}

function New-GdsuFwRule {
    param(
        [Parameter(Mandatory)][string]$NameLabel,
        [Parameter(Mandatory)][int[]]$Ports,
        [Parameter(Mandatory)][ValidateSet("TCP","UDP")][string]$Protocol,
        [Parameter(Mandatory)][ValidateSet("Inbound","Outbound")][string]$Direction,
        [Parameter(Mandatory)][int]$ProfileBitmask
    )
    foreach ($p in $Ports) {
        $ruleName = "{0}-{1}-{2}-{3}" -f $Global:BaseLabel, $Protocol, $Direction, $p
        try {
            New-NetFirewallRule -DisplayName $ruleName `
                -Name $ruleName `
                -Group $Global:RuleGroup `
                -Enabled True `
                -Action Allow `
                -Direction $Direction `
                -Protocol $Protocol `
                -LocalPort $p `
                -Profile $ProfileBitmask `
                -ErrorAction Stop | Out-Null
            Write-Log "Regla creada: $ruleName (perfil:$ProfileBitmask)"
        } catch {
            Write-Log "Error creando regla $ruleName -> $($_.Exception.Message)" "ERROR"
        }
    }
}

function Remove-GdsuFwRules {
    try {
        $rules = Get-NetFirewallRule -Group $Global:RuleGroup -ErrorAction SilentlyContinue
        if ($rules) {
            $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            Write-Log "Reglas del grupo $($Global:RuleGroup) eliminadas."
        } else {
            Write-Log "No hay reglas para eliminar en el grupo $($Global:RuleGroup)" "WARN"
        }
    } catch {
        Write-Log "Error eliminando reglas -> $($_.Exception.Message)" "ERROR"
    }
}

# =========================
# GUI
# =========================
$form = New-Object System.Windows.Forms.Form
$form.Text = $Global:AppTitle
$form.Size = New-Object System.Drawing.Size(920, 600)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

# Título
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Políticas de Firewall (GDSU)"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20,20)
$form.Controls.Add($lblTitle)

# =========================
# Configuración de reglas
# =========================
$gbConfig = New-Object System.Windows.Forms.GroupBox
$gbConfig.Text = "Configuración de reglas"
$gbConfig.ForeColor = [System.Drawing.Color]::White
$gbConfig.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbConfig.Size = New-Object System.Drawing.Size(880, 180)
$gbConfig.Location = New-Object System.Drawing.Point(20,60)
$gbConfig.Anchor = "Top,Left,Right"
$form.Controls.Add($gbConfig)

# Perfiles
$lblProfiles = New-Object System.Windows.Forms.Label
$lblProfiles.Text = "Perfiles:"
$lblProfiles.ForeColor = [System.Drawing.Color]::White
$lblProfiles.AutoSize = $true
$lblProfiles.Location = New-Object System.Drawing.Point(20,35)
$gbConfig.Controls.Add($lblProfiles)

$chkDomain = New-Object System.Windows.Forms.CheckBox
$chkDomain.Text = "Dominio"
$chkDomain.AutoSize = $true
$chkDomain.ForeColor = [System.Drawing.Color]::White
$chkDomain.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$chkDomain.Location = New-Object System.Drawing.Point(90,32)
$chkDomain.TabIndex = 0
$gbConfig.Controls.Add($chkDomain)

$chkPrivate = New-Object System.Windows.Forms.CheckBox
$chkPrivate.Text = "Privado"
$chkPrivate.AutoSize = $true
$chkPrivate.ForeColor = [System.Drawing.Color]::White
$chkPrivate.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$chkPrivate.Location = New-Object System.Drawing.Point(170,32)
$chkPrivate.TabIndex = 1
$gbConfig.Controls.Add($chkPrivate)

$chkPublic = New-Object System.Windows.Forms.CheckBox
$chkPublic.Text = "Público"
$chkPublic.AutoSize = $true
$chkPublic.ForeColor = [System.Drawing.Color]::White
$chkPublic.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$chkPublic.Location = New-Object System.Drawing.Point(250,32)
$chkPublic.TabIndex = 2
$gbConfig.Controls.Add($chkPublic)

# Dirección
$lblDir = New-Object System.Windows.Forms.Label
$lblDir.Text = "Dirección:"
$lblDir.ForeColor = [System.Drawing.Color]::White
$lblDir.AutoSize = $true
$lblDir.Location = New-Object System.Drawing.Point(20,70)
$gbConfig.Controls.Add($lblDir)

$rbIn = New-Object System.Windows.Forms.RadioButton
$rbIn.Text = "Entrante"
$rbIn.AutoSize = $true
$rbIn.ForeColor = [System.Drawing.Color]::White
$rbIn.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$rbIn.Location = New-Object System.Drawing.Point(90,68)
$rbIn.Checked = $true
$rbIn.TabIndex = 3
$gbConfig.Controls.Add($rbIn)

$rbOut = New-Object System.Windows.Forms.RadioButton
$rbOut.Text = "Saliente"
$rbOut.AutoSize = $true
$rbOut.ForeColor = [System.Drawing.Color]::White
$rbOut.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$rbOut.Location = New-Object System.Drawing.Point(180,68)
$rbOut.TabIndex = 4
$gbConfig.Controls.Add($rbOut)

# Protocolo
$lblProto = New-Object System.Windows.Forms.Label
$lblProto.Text = "Protocolo:"
$lblProto.ForeColor = [System.Drawing.Color]::White
$lblProto.AutoSize = $true
$lblProto.Location = New-Object System.Drawing.Point(20,105)
$gbConfig.Controls.Add($lblProto)

$rbTCP = New-Object System.Windows.Forms.RadioButton
$rbTCP.Text = "TCP"
$rbTCP.AutoSize = $true
$rbTCP.ForeColor = [System.Drawing.Color]::White
$rbTCP.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$rbTCP.Location = New-Object System.Drawing.Point(90,102)
$rbTCP.Checked = $true
$rbTCP.TabIndex = 5
$gbConfig.Controls.Add($rbTCP)

$rbUDP = New-Object System.Windows.Forms.RadioButton
$rbUDP.Text = "UDP"
$rbUDP.AutoSize = $true
$rbUDP.ForeColor = [System.Drawing.Color]::White
$rbUDP.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$rbUDP.Location = New-Object System.Drawing.Point(150,102)
$rbUDP.TabIndex = 6
$gbConfig.Controls.Add($rbUDP)

# Puertos
$lblPorts = New-Object System.Windows.Forms.Label
$lblPorts.Text = "Puertos (separados por coma):"
$lblPorts.ForeColor = [System.Drawing.Color]::White
$lblPorts.AutoSize = $true
$lblPorts.Location = New-Object System.Drawing.Point(320,35)
$gbConfig.Controls.Add($lblPorts)

$tbPorts = New-Object System.Windows.Forms.TextBox
$tbPorts.Size = New-Object System.Drawing.Size(250, 24)
$tbPorts.Location = New-Object System.Drawing.Point(520,32)
$tbPorts.TabIndex = 7
$tbPorts.Anchor = "Top,Left,Right"
$gbConfig.Controls.Add($tbPorts)

# Acciones
$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "Aplicar reglas"
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
$btnApply.ForeColor = [System.Drawing.Color]::White
$btnApply.Size = New-Object System.Drawing.Size(160, 34)
$btnApply.Location = New-Object System.Drawing.Point(320,95)
$btnApply.TabIndex = 8
$gbConfig.Controls.Add($btnApply)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = "Eliminar reglas GDSU"
$btnRemove.BackColor = [System.Drawing.Color]::FromArgb(217,96,0)
$btnRemove.ForeColor = [System.Drawing.Color]::White
$btnRemove.Size = New-Object System.Drawing.Size(180, 34)
$btnRemove.Location = New-Object System.Drawing.Point(490,95)
$btnRemove.TabIndex = 9
$gbConfig.Controls.Add($btnRemove)


# =========================
# Vista previa y logs
# =========================
$gbPreview = New-Object System.Windows.Forms.GroupBox
$gbPreview.Text = "Auditoría y estado"
$gbPreview.ForeColor = [System.Drawing.Color]::White
$gbPreview.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$gbPreview.Size = New-Object System.Drawing.Size(880, 300)
$gbPreview.Location = New-Object System.Drawing.Point(20,250)
$gbPreview.Anchor = "Top,Left,Right,Bottom"
$form.Controls.Add($gbPreview)

# LogBox
$Global:LogBox = New-Object System.Windows.Forms.TextBox
$Global:LogBox.Multiline = $true
$Global:LogBox.ReadOnly = $true
$Global:LogBox.ScrollBars = "Vertical"
$Global:LogBox.BackColor = [System.Drawing.Color]::Black
$Global:LogBox.ForeColor = [System.Drawing.Color]::LightGreen
$Global:LogBox.Size = New-Object System.Drawing.Size(840, 100)
$Global:LogBox.Location = New-Object System.Drawing.Point(20,30)
$Global:LogBox.Anchor = "Top,Left,Right"
$gbPreview.Controls.Add($Global:LogBox)

# Auditoría
$tbAudit = New-Object System.Windows.Forms.TextBox
$tbAudit.Multiline = $true
$tbAudit.ReadOnly = $true
$tbAudit.ScrollBars = "Vertical"
$tbAudit.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$tbAudit.ForeColor = [System.Drawing.Color]::Gainsboro
$tbAudit.Size = New-Object System.Drawing.Size(840, 150)
$tbAudit.Location = New-Object System.Drawing.Point(20,140)
$tbAudit.Anchor = "Top,Left,Right,Bottom"
$gbPreview.Controls.Add($tbAudit)

# =========================
# Eventos
# =========================
$btnApply.Add_Click({
    try {
        $before = Get-FwSnapshot

        $ports = Parse-Ports -PortsText $tbPorts.Text
        if (-not $ports -or $ports.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Ingrese puertos validos (ej: 80,443,8080).", "Validacion", "OK", "Information") | Out-Null
            return
        }

        $pfMask = Get-SelectedProfiles -Domain:$chkDomain.Checked -Private:$chkPrivate.Checked -Public:$chkPublic.Checked
        $proto  = if ($rbTCP.Checked) { "TCP" } else { "UDP" }
        $dir    = if ($rbIn.Checked)  { "Inbound" } else { "Outbound" }

        Write-Log "Aplicando reglas: Proto=$proto Dir=$dir Puertos=$($ports -join ',') PerfilMask=$pfMask"
        New-GdsuFwRule -NameLabel $Global:BaseLabel -Ports $ports -Protocol $proto -Direction $dir -ProfileBitmask $pfMask

        $after = Get-FwSnapshot
        Save-Audit -Before $before -After $after -OperationLabel "Apply $proto-$dir ports=[$($ports -join ',')] profiles=$pfMask"

        # Resumen audit
        $tbAudit.Text = "Reglas aplicadas.`r`nPuertos: $($ports -join ', ')`r`nProtocolo: $proto`r`nDireccion: $dir`r`nPerfiles: $pfMask"
    } catch {
        Write-Log "Error aplicando reglas -> $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
    }
})

$btnRemove.Add_Click({
    try {
        $before = Get-FwSnapshot
        Remove-GdsuFwRules
        $after = Get-FwSnapshot
        Save-Audit -Before $before -After $after -OperationLabel "Remove group $($Global:RuleGroup)"
        $tbAudit.Text = "Reglas del grupo $($Global:RuleGroup) eliminadas."
    } catch {
        Write-Log "Error eliminando reglas -> $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
    }
})

# =========================
# Inicializar
# =========================
try {
    Write-Log "Log: $Global:LogFile"
    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
} catch {
    Write-Log "Error critico de GUI -> $($_.Exception.Message)" "ERROR"
}
