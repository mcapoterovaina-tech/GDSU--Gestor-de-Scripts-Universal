<# 
.SYNOPSIS
  Panel WPF en tiempo real para gestión de procesos: monitoreo, filtros, colores y acciones por fila.
.DESCRIPTION
  - Reutiliza criterios: NotResponding, ZeroCPU, ExceededRuntime.
  - Refresca cada N segundos con DispatcherTimer (UI no bloqueante).
  - DataGrid con columnas ricas: CPUΔ, Runtime, Razón (chips), Usuario, Ruta, HasUI, Responde.
  - Acciones por fila: Kill, Tree Kill, y selección múltiple + acciones masivas.
  - Filtros: texto (Nombre/Usuario/Razón), toggles OnlyNR/IncludeServices, sliders para intervalo y MaxRuntime.
  - Auditoría: CSV/JSON/summary con razón y estado; DryRun conserva simulación.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [int]$SampleIntervalSeconds = 3,
  [int]$MaxRuntimeMinutes     = 240,
  [switch]$OnlyNotResponding,
  [switch]$IncludeServices,
  [string[]]$WhitelistNames   = @("explorer","cmd","powershell","svchost"),
  [string[]]$WhitelistPaths   = @(),
  [string[]]$WhitelistUsers   = @(),
  [string[]]$ExtraCriticalNames = @("wininit","winlogon","csrss","lsass","smss","services","System","Idle"),
  [switch]$DryRun,
  [switch]$ForceKill = $true,
  [switch]$KillChildren,
  [string]$ExecutionLogPath,
  [string]$AuditCsvPath,
  [string]$AuditJsonPath,
  [string]$SummaryReportPath
)

begin {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

  function Write-Log { param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    if ($ExecutionLogPath) { Add-Content -LiteralPath $ExecutionLogPath -Value $line }
  }

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
    param([string]$Name,[string]$Path,[string]$User,[string[]]$Names,[string[]]$Paths,[string[]]$Users,[string[]]$CriticalNames)
    if ($CriticalNames -contains $Name) { return $true }
    if ($Names -contains $Name) { return $true }
    if ($Path -and ($Paths | Where-Object { $_ -eq $Path })) { return $true }
    if ($User -and ($Users -contains $User)) { return $true }
    return $false
  }

  function Get-Owner { param([System.Diagnostics.Process]$Proc)
    try {
      $wmi = Get-CimInstance Win32_Process -Filter "ProcessId = $($Proc.Id)" -ErrorAction Stop
      $owner = $wmi | Invoke-CimMethod -MethodName GetOwner
      if ($owner.ReturnValue -eq 0) { if ($owner.Domain) { return "$($owner.Domain)\$($owner.User)" } else { return $owner.User } }
    } catch { }
    return $null
  }

  function Get-ExePath { param([System.Diagnostics.Process]$Proc)
    try { return $Proc.MainModule.FileName } catch { return $null }
  }

  # Estado UI y auditoría
  New-SafeFilePaths
  $Audit = New-Object System.Collections.Generic.List[Object]
  $State = [pscustomobject]@{
    IntervalSec     = $SampleIntervalSeconds
    MaxRuntimeMin   = $MaxRuntimeMinutes
    OnlyNR          = $OnlyNotResponding.IsPresent
    IncludeServices = $IncludeServices.IsPresent
    DryRun          = $DryRun.IsPresent
    ForceKill       = $ForceKill.IsPresent
    KillChildren    = $KillChildren.IsPresent
    FilterText      = ''
  }

  Write-Log "Inicio panel | DryRun=$($State.DryRun) Interval=$($State.IntervalSec)s MaxRuntime=$($State.MaxRuntimeMin) OnlyNR=$($State.OnlyNR) IncludeSrv=$($State.IncludeServices)" "INFO"
}

process {
  # Construcción XAML
  $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gestión de procesos en tiempo real" Height="720" Width="1080" Background="#1E1E1E" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="3,1"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="Background" Value="#333"/>
      <Setter Property="BorderBrush" Value="#555"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#1E1E1E"/>
      <Setter Property="Foreground" Value="#DDDDDD"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
    </Style>
  </Window.Resources>
  <DockPanel LastChildFill="True" Margin="12">
    <!-- Header / Filtros -->
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8" VerticalAlignment="Center">
      <TextBox x:Name="FilterBox" Width="240" Margin="0,0,8,0" ToolTip="Filtrar por Nombre, Usuario o Razón" />
      <CheckBox x:Name="OnlyNR" Content="Only NotResponding" Margin="0,0,8,0" Foreground="#DDDDDD"/>
      <CheckBox x:Name="IncludeServices" Content="Incluir servicios" Margin="0,0,8,0" Foreground="#DDDDDD"/>
      <StackPanel Orientation="Horizontal" Margin="12,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="Intervalo (s)" Foreground="#CCCCCC" Margin="0,0,6,0"/>
        <Slider x:Name="IntervalSlider" Minimum="1" Maximum="10" Width="120" TickFrequency="1" IsSnapToTickEnabled="True"/>
        <TextBlock x:Name="IntervalValue" Foreground="#CCCCCC" Margin="6,0,0,0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="12,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="Max Runtime (min)" Foreground="#CCCCCC" Margin="0,0,6,0"/>
        <Slider x:Name="MaxRuntimeSlider" Minimum="10" Maximum="480" Width="160" TickFrequency="10" IsSnapToTickEnabled="True"/>
        <TextBlock x:Name="MaxRuntimeValue" Foreground="#CCCCCC" Margin="6,0,0,0"/>
      </StackPanel>
      <Button x:Name="KillSelected" Content="Kill seleccionados" Margin="12,0,0,0" Padding="10,4"/>
      <Button x:Name="TreeKillSelected" Content="Tree Kill seleccionados" Margin="6,0,0,0" Padding="10,4"/>
      <Button x:Name="ExportAudit" Content="Exportar auditoría" Margin="6,0,0,0" Padding="10,4"/>
    </StackPanel>

    <!-- DataGrid -->
    <DataGrid x:Name="Grid" AutoGenerateColumns="False" SelectionMode="Extended" SelectionUnit="FullRow"
              IsReadOnly="True" HeadersVisibility="Column" >
      <DataGrid.Columns>
        <DataGridTextColumn Header="PID" Binding="{Binding Id}" Width="60"/>
        <DataGridTextColumn Header="Nombre" Binding="{Binding Name}" Width="140"/>
        <DataGridTextColumn Header="Usuario" Binding="{Binding User}" Width="180"/>
        <DataGridTextColumn Header="CPUΔ (ms)" Binding="{Binding CPUmsDelta}" Width="90"/>
        <DataGridTextColumn Header="Runtime (min)" Binding="{Binding RuntimeMin}" Width="110"/>
        <DataGridTemplateColumn Header="Razón" Width="200">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <StackPanel Orientation="Horizontal">
                <ItemsControl ItemsSource="{Binding ReasonTokens}">
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Border Style="{StaticResource Chip}" Background="{Binding Background}">
                        <TextBlock Text="{Binding Text}" Foreground="#EEEEEE" FontSize="12"/>
                      </Border>
                    </DataTemplate>
                  </ItemsControl.ItemTemplate>
                </ItemsControl>
              </StackPanel>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
        <DataGridTemplateColumn Header="CPU bar" Width="120">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <Grid Height="16" Background="#2A2A2A">
                <Rectangle Fill="#4CAF50" Width="{Binding CPUBarWidth}"/>
              </Grid>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
        <DataGridTextColumn Header="UI" Binding="{Binding HasUI}" Width="50"/>
        <DataGridTextColumn Header="Responde" Binding="{Binding Responding}" Width="80"/>
        <DataGridTextColumn Header="Ruta" Binding="{Binding Path}" Width="*" />
        <DataGridTemplateColumn Header="Acción" Width="170">
          <DataGridTemplateColumn.CellTemplate>
            <DataTemplate>
              <StackPanel Orientation="Horizontal">
                <Button Content="Kill" Padding="6,2" Margin="0,0,4,0" Tag="{Binding Id}"/>
                <Button Content="Tree Kill" Padding="6,2" Tag="{Binding Id}"/>
              </StackPanel>
            </DataTemplate>
          </DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
      </DataGrid.Columns>
    </DataGrid>

    <!-- Footer / Estado -->
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock x:Name="StatusText" Foreground="#BBBBBB"/>
      <TextBlock Text="  |  " Foreground="#555555"/>
      <TextBlock Text="DryRun:" Foreground="#888888"/>
      <TextBlock x:Name="DryRunState" Foreground="#CCCCCC"/>
      <TextBlock Text="  | Logs ->" Foreground="#888888" Margin="12,0,0,0"/>
      <TextBlock x:Name="LogPath" Foreground="#CCCCCC"/>
    </StackPanel>
  </DockPanel>
</Window>
"@

  # Cargar XAML
  $reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
  $window = [Windows.Markup.XamlReader]::Load($reader)

  # Referencias UI
  $Grid              = $window.FindName('Grid')
  $FilterBox         = $window.FindName('FilterBox')
  $OnlyNRChk         = $window.FindName('OnlyNR')
  $IncludeSrvChk     = $window.FindName('IncludeServices')
  $IntervalSlider    = $window.FindName('IntervalSlider')
  $IntervalValue     = $window.FindName('IntervalValue')
  $MaxRuntimeSlider  = $window.FindName('MaxRuntimeSlider')
  $MaxRuntimeValue   = $window.FindName('MaxRuntimeValue')
  $KillSelectedBtn   = $window.FindName('KillSelected')
  $TreeKillSelectedBtn = $window.FindName('TreeKillSelected')
  $ExportAuditBtn    = $window.FindName('ExportAudit')
  $StatusText        = $window.FindName('StatusText')
  $DryRunState       = $window.FindName('DryRunState')
  $LogPathText       = $window.FindName('LogPath')

  $OnlyNRChk.IsChecked = $State.OnlyNR
  $IncludeSrvChk.IsChecked = $State.IncludeServices
  $IntervalSlider.Value = [double]$State.IntervalSec
  $MaxRuntimeSlider.Value = [double]$State.MaxRuntimeMin
  $IntervalValue.Text = "$($State.IntervalSec)s"
  $MaxRuntimeValue.Text = "$($State.MaxRuntimeMin) min"
  $DryRunState.Text = $State.DryRun
  $LogPathText.Text = $ExecutionLogPath

  # Fuente de datos observable
  $obs = New-Object System.Collections.ObjectModel.ObservableCollection[object]
  $Grid.ItemsSource = $obs

  # Helpers de presentación
  function Tokenize-Reason { param([string]$Reason)
    $tokens = @()
    foreach ($r in ($Reason -split ',' | Where-Object { $_ })) {
      $bg = switch ($r) {
        'NotResponding'   { '#E53935' } # rojo
        'ZeroCPU'         { '#FDD835' } # amarillo
        'ExceededRuntime' { '#1E88E5' } # azul
        default           { '#616161' }
      }
      $tokens += [pscustomobject]@{ Text = $r; Background = $bg }
    }
    return $tokens
  }
  function CPU-BarWidth { param([double]$Delta, [int]$MaxDelta = 200)
    if ($Delta -lt 0) { $Delta = 0 }
    $ratio = [math]::Min($Delta / $MaxDelta, 1.0)
    return [int](120 * $ratio) # 120px como ancho máximo
  }

  # Muestreo con estado previo para CPUΔ
  $prevSnap = @{}

  function Sample-ProcessesUI {
    # Primera muestra
    $procs1 = Get-Process -ErrorAction SilentlyContinue
    $snap1 = @{}
    foreach ($p in $procs1) {
      $snap1[$p.Id] = [pscustomobject]@{
        Id    = $p.Id
        CPUms = $p.TotalProcessorTime.TotalMilliseconds
        Start = $p.StartTime
        HasUI = ($null -ne $p.MainWindowHandle -and $p.MainWindowHandle -ne 0)
        NR    = ($p.Responding -eq $false)
        Name  = $p.Name
      }
    }
    Start-Sleep -Milliseconds ([int]($State.IntervalSec * 1000))
    # Segunda muestra
    $procs2 = Get-Process -ErrorAction SilentlyContinue
    $candidates = @()
    foreach ($p in $procs2) {
      if (-not $snap1.ContainsKey($p.Id)) { continue }
      $prev = $snap1[$p.Id]
      $path = Get-ExePath -Proc $p
      $user = Get-Owner  -Proc $p
      $cpu2 = $p.TotalProcessorTime.TotalMilliseconds
      $cpuDelta = [math]::Round($cpu2 - $prev.CPUms, 2)
      $hasUI = $prev.HasUI
      $nr = ($p.Responding -eq $false)
      $runtimeMin = $null
      try { $runtimeMin = ((Get-Date) - $prev.Start).TotalMinutes } catch { $runtimeMin = $null }

      $critNR    = ($hasUI -and $nr)
      $critZero  = ($cpuDelta -le 1)
      $critLong  = ($runtimeMin -ne $null -and $runtimeMin -ge $State.MaxRuntimeMin)

      if ($State.OnlyNR) {
        if (-not $critNR) { continue }
      } else {
        if (-not ($critNR -or $critZero -or $critLong)) { continue }
      }

      if (-not $State.IncludeServices) {
        if (-not $hasUI -and $p.SessionId -eq 0) { continue }
      }

      $reason = @()
      if ($critNR)   { $reason += "NotResponding" }
      if ($critZero) { $reason += "ZeroCPU" }
      if ($critLong) { $reason += "ExceededRuntime" }

      $isWL = Is-Whitelisted -Name $p.Name -Path $path -User $user -Names $WhitelistNames -Paths $WhitelistPaths -Users $WhitelistUsers -CriticalNames $ExtraCriticalNames
      if ($isWL) {
        # auditoría de skip en tiempo real
        $Audit.Add([pscustomobject]@{
          Timestamp = (Get-Date); Action='Skip-Whitelist'; Source="$($p.Name)($($p.Id))"; Target=''; SizeBytes=0; Status='SKIP'; Reason=($reason -join ",")
        })
        continue
      }

      $candidates += [pscustomobject]@{
        Id         = $p.Id
        Name       = $p.Name
        Path       = $path
        User       = $user
        CPUmsDelta = $cpuDelta
        CPUBarWidth= (CPU-BarWidth -Delta $cpuDelta)
        HasUI      = $hasUI
        Responding = (-not $nr)
        RuntimeMin = [math]::Round($runtimeMin,2)
        Reason     = ($reason -join ",")
        ReasonTokens = (Tokenize-Reason -Reason ($reason -join ","))
      }
    }
    return $candidates
  }

  # Filtro de texto
  function Passes-Filter { param($item, [string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }
    $t = $text.ToLowerInvariant()
    foreach ($field in @($item.Name,$item.User,$item.Reason,$item.Path)) {
      if ($field -and ($field.ToLowerInvariant().Contains($t))) { return $true }
    }
    return $false
  }

  # Render refresh
  function Refresh-Grid {
    try {
      $items = Sample-ProcessesUI
      # Reemplazar items manteniendo colección observable
      $obs.Clear()
      foreach ($it in $items) {
        if (Passes-Filter -item $it -text $State.FilterText) { $obs.Add($it) }
      }
      $StatusText.Text = "Candidatos: $($obs.Count) | Intervalo: $($State.IntervalSec)s | MaxRuntime: $($State.MaxRuntimeMin) min"
    } catch {
      Write-Log "Error en refresco -> $($_.Exception.Message)" "ERROR"
    }
  }

  # Kill helpers
  function Kill-ProcessAndChildren { param([int]$Pid, [switch]$Tree)
    $exists = Get-Process -Id $Pid -ErrorAction SilentlyContinue
    if (-not $exists) {
      Write-Log "Proceso no existe PID=$Pid" "WARN"
      $Audit.Add([pscustomobject]@{ Timestamp=(Get-Date); Action='Already-Exited'; Source="($Pid)"; Target=''; SizeBytes=0; Status='SKIP'; Reason=''} )
      return
    }
    $name = $exists.Name
    Write-Log ("Terminar PID={0} Name={1} Tree={2}" -f $Pid,$name,$Tree.IsPresent) "WARN"
    if (-not $State.DryRun) {
      try {
        Stop-Process -Id $Pid -Force:$State.ForceKill -ErrorAction Stop
        if ($Tree) {
          try {
            $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $Pid" -ErrorAction SilentlyContinue
            foreach ($ch in $children) {
              try { Stop-Process -Id $ch.ProcessId -Force:$State.ForceKill -ErrorAction Stop } catch { Write-Log "No se pudo cerrar hijo PID=$($ch.ProcessId) -> $($_.Exception.Message)" "ERROR" }
            }
          } catch { Write-Log "Error obteniendo hijos PID=$Pid -> $($_.Exception.Message)" "ERROR" }
        }
        $Audit.Add([pscustomobject]@{ Timestamp=(Get-Date); Action='Terminate'; Source="$name($Pid)"; Target=''; SizeBytes=0; Status='OK'; Reason='Manual' })
      } catch {
        Write-Log "Error al terminar PID=$Pid -> $($_.Exception.Message)" "ERROR"
        $Audit.Add([pscustomobject]@{ Timestamp=(Get-Date); Action='Terminate'; Source="$name($Pid)"; Target=''; SizeBytes=0; Status='ERROR'; Reason='Manual' })
      }
    } else {
      $Audit.Add([pscustomobject]@{ Timestamp=(Get-Date); Action='Terminate'; Source="$name($Pid)"; Target=''; SizeBytes=0; Status='DRYRUN'; Reason='Manual' })
    }
    Refresh-Grid
  }

  # Wire eventos UI
  $FilterBox.Add_TextChanged({
    $State.FilterText = $FilterBox.Text
    Refresh-Grid
  })
  $OnlyNRChk.Add_Checked({ $State.OnlyNR = $true; Refresh-Grid })
  $OnlyNRChk.Add_Unchecked({ $State.OnlyNR = $false; Refresh-Grid })
  $IncludeSrvChk.Add_Checked({ $State.IncludeServices = $true; Refresh-Grid })
  $IncludeSrvChk.Add_Unchecked({ $State.IncludeServices = $false; Refresh-Grid })
  $IntervalSlider.Add_ValueChanged({ $State.IntervalSec = [int]$IntervalSlider.Value; $IntervalValue.Text = "$($State.IntervalSec)s" })
  $MaxRuntimeSlider.Add_ValueChanged({ $State.MaxRuntimeMin = [int]$MaxRuntimeSlider.Value; $MaxRuntimeValue.Text = "$($State.MaxRuntimeMin) min" })

  # Botones por fila (usamos eventos de routed button)
  $window.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender,$args)
    $btn = [System.Windows.Controls.Button]$sender
    if ($btn.Content -eq 'Kill' -or $btn.Content -eq 'Tree Kill') {
      $pid = [int]$btn.Tag
      Kill-ProcessAndChildren -Pid $pid -Tree:($btn.Content -eq 'Tree Kill')
      $args.Handled = $true
    }
  })

  # Botones masivos
  $KillSelectedBtn.Add_Click({
    $sel = $Grid.SelectedItems
    foreach ($row in $sel) { Kill-ProcessAndChildren -Pid $row.Id }
  })
  $TreeKillSelectedBtn.Add_Click({
    $sel = $Grid.SelectedItems
    foreach ($row in $sel) { Kill-ProcessAndChildren -Pid $row.Id -Tree }
  })
  $ExportAuditBtn.Add_Click({
    try {
      $Audit | Export-Csv -LiteralPath $AuditCsvPath -NoTypeInformation -Encoding UTF8
      $Audit | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $AuditJsonPath -Encoding UTF8
      [System.Windows.MessageBox]::Show("Auditoría exportada a:`n$AuditCsvPath`n$AuditJsonPath","Exportación", 'OK','Information') | Out-Null
    } catch {
      [System.Windows.MessageBox]::Show("Error exportando auditoría:`n$($_.Exception.Message)","Error", 'OK','Error') | Out-Null
    }
  })

  # Timer de refresco (no bloqueante)
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromSeconds([double]$State.IntervalSec)
  $timer.Add_Tick({ Refresh-Grid })
  $timer.Start()

  # Ajustar el intervalo del timer si cambia el slider sin cortar el flujo
  $IntervalSlider.Add_ValueChanged({
    $timer.Interval = [TimeSpan]::FromSeconds([double]$State.IntervalSec)
  })

  # Primer render
  Refresh-Grid

  # Mostrar ventana (modal)
  $null = $window.ShowDialog()
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
    [pscustomobject]@{ Action = $_.Name; Count = $_.Count; SizeMB = 0 }
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
  Write-Log "Panel de procesos completado. Resumen: $SummaryReportPath" "INFO"
}
