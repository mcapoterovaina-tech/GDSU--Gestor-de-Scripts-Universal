<# 
.SYNOPSIS
  Dashboard WPF para inventario de hardware: CPU, RAM, Discos, GPU, BIOS/Board y Sistema.
.DESCRIPTION
  - Recolecta datos vía CIM/WMI con fallbacks.
  - Presenta tablas por categoría con filtro y exportación.
  - Exporta CSV/JSON por categoría y resumen consolidado.
.NOTES
  PowerShell 5+ en Windows 10/11/Server. Ejecutar como admin para máxima cobertura.
#>

param(
  [string]$OutputPath = "C:\HardwareInventory",
  [switch]$IncludePerDeviceCSV,
  [string]$Tag = "GSU",
  [string]$LogPath = "C:\Logs"
)

begin {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

  # Preparación de carpetas
  foreach ($p in @($OutputPath, $LogPath)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
  }

  $TimeStamp     = Get-Date -Format "yyyyMMdd_HHmmss"
  $SnapshotDir   = Join-Path $OutputPath "Snapshot_$TimeStamp"
  New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null

  $LogFile       = Join-Path $LogPath "HWInventory_$TimeStamp.log"
  $SummaryJson   = Join-Path $SnapshotDir "summary.json"
  $SummaryCsv    = Join-Path $SnapshotDir "summary.csv"

  function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Green" } }
    Write-Host $line -ForegroundColor $color
  }

  function Try-Cim {
    param([string]$Class)
    try { Get-CimInstance -ClassName $Class -ErrorAction Stop }
    catch {
      Write-Log "Fallo CIM $Class. Probando WMI..." "WARN"
      try { Get-WmiObject -Class $Class -ErrorAction Stop }
      catch { Write-Log "Fallo WMI $Class: $($_.Exception.Message)" "ERROR"; @() }
    }
  }

  # Estado compartido
  $State = [pscustomobject]@{
    Tag            = $Tag
    SnapshotDir    = $SnapshotDir
    IncludeCSV     = $IncludePerDeviceCSV.IsPresent
    FilterText     = ''
    Counts         = @{}
  }
}

process {
  # XAML del dashboard
  $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hardware Inventory Dashboard" Height="720" Width="1080" Background="#1E1E1E" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#1E1E1E"/>
      <Setter Property="Foreground" Value="#DDDDDD"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="AlternationCount" Value="2"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="#202020"/>
      <Setter Property="AlternationIndex" Value="1"/>
      <Style.Triggers>
        <Trigger Property="ItemsControl.AlternationIndex" Value="1">
          <Setter Property="Background" Value="#242424"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="3,1"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="Background" Value="#333"/>
      <Setter Property="BorderBrush" Value="#555"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
  </Window.Resources>

  <DockPanel LastChildFill="True" Margin="12">
    <!-- Header -->
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBox x:Name="FilterBox" Width="280" Margin="0,0,8,0" ToolTip="Filtrar por texto en la tabla actual"/>
      <Button x:Name="RefreshBtn" Content="Refrescar" Padding="10,4" Margin="0,0,8,0"/>
      <Button x:Name="ExportAllBtn" Content="Exportar todo (CSV/JSON)" Padding="10,4" Margin="0,0,8,0"/>
      <Button x:Name="OpenFolderBtn" Content="Abrir carpeta Snapshot" Padding="10,4" Margin="0,0,8,0"/>
      <TextBlock Text="Tag:" Foreground="#CCCCCC" Margin="12,0,4,0"/>
      <TextBlock x:Name="TagText" Foreground="#FFFFFF"/>
      <TextBlock Text="  |  Snapshot:" Foreground="#888888" Margin="12,0,4,0"/>
      <TextBlock x:Name="SnapshotPathText" Foreground="#CCCCCC"/>
      <TextBlock Text="  |  Items:" Foreground="#888888" Margin="12,0,4,0"/>
      <TextBlock x:Name="CountText" Foreground="#CCCCCC"/>
    </StackPanel>

    <!-- Tabs -->
    <TabControl x:Name="Tabs">
      <TabItem Header="Sistema">
        <DataGrid x:Name="GridSys" AutoGenerateColumns="False" IsReadOnly="True">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Fabricante" Binding="{Binding Manufacturer}" Width="180"/>
            <DataGridTextColumn Header="Modelo" Binding="{Binding Model}" Width="220"/>
            <DataGridTextColumn Header="RAM Total (GB)" Binding="{Binding TotalRAM_GB}" Width="120"/>
            <DataGridTextColumn Header="OS" Binding="{Binding OS}" Width="220"/>
            <DataGridTextColumn Header="Version" Binding="{Binding OSVersion}" Width="120"/>
            <DataGridTextColumn Header="Arquitectura" Binding="{Binding Architecture}" Width="120"/>
            <DataGridTextColumn Header="Build" Binding="{Binding Build}" Width="80"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="CPU">
        <DataGrid x:Name="GridCPU" AutoGenerateColumns="False" IsReadOnly="True">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Nombre" Binding="{Binding Name}" Width="*"/>
            <DataGridTextColumn Header="Fabricante" Binding="{Binding Manufacturer}" Width="160"/>
            <DataGridTextColumn Header="Cores" Binding="{Binding NumberOfCores}" Width="80"/>
            <DataGridTextColumn Header="Threads" Binding="{Binding NumberOfLogicalProcessors}" Width="90"/>
            <DataGridTextColumn Header="Max MHz" Binding="{Binding MaxClockSpeed}" Width="90"/>
            <DataGridTextColumn Header="L2 KB" Binding="{Binding L2CacheSize}" Width="80"/>
            <DataGridTextColumn Header="L3 KB" Binding="{Binding L3CacheSize}" Width="80"/>
            <DataGridTextColumn Header="ProcessorId" Binding="{Binding ProcessorId}" Width="240"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="RAM">
        <DataGrid x:Name="GridRAM" AutoGenerateColumns="False" IsReadOnly="True">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Bank" Binding="{Binding BankLabel}" Width="160"/>
            <DataGridTextColumn Header="Capacidad (GB)" Binding="{Binding Capacity_GB}" Width="120"/>
            <DataGridTextColumn Header="Speed (MHz)" Binding="{Binding Speed_MHz}" Width="120"/>
            <DataGridTextColumn Header="Manufacturer" Binding="{Binding Manufacturer}" Width="160"/>
            <DataGridTextColumn Header="PartNumber" Binding="{Binding PartNumber}" Width="160"/>
            <DataGridTextColumn Header="Serial" Binding="{Binding SerialNumber}" Width="160"/>
            <DataGridTextColumn Header="ConfiguredClock" Binding="{Binding ConfiguredClockSpeed}" Width="140"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="Discos">
        <DataGrid x:Name="GridDisk" AutoGenerateColumns="False" IsReadOnly="True">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Modelo" Binding="{Binding Model}" Width="220"/>
            <DataGridTextColumn Header="Fabricante" Binding="{Binding Manufacturer}" Width="160"/>
            <DataGridTextColumn Header="Interfaz" Binding="{Binding Interface}" Width="120"/>
            <DataGridTextColumn Header="Tipo" Binding="{Binding MediaType}" Width="120"/>
            <DataGridTextColumn Header="Serial" Binding="{Binding SerialNumber}" Width="220"/>
            <DataGridTextColumn Header="Tamaño (GB)" Binding="{Binding Size_GB}" Width="120"/>
            <DataGridTextColumn Header="Firmware" Binding="{Binding Firmware}" Width="120"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="GPU">
        <DataGrid x:Name="GridGPU" AutoGenerateColumns="False" IsReadOnly="True">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Nombre" Binding="{Binding Name}" Width="260"/>
            <DataGridTextColumn Header="Driver" Binding="{Binding DriverVersion}" Width="160"/>
            <DataGridTextColumn Header="Vendor" Binding="{Binding Vendor}" Width="160"/>
            <DataGridTextColumn Header="VRAM (GB)" Binding="{Binding VRAM_GB}" Width="120"/>
            <DataGridTextColumn Header="VideoProcessor" Binding="{Binding VideoProcessor}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="BIOS / Board">
        <DataGrid x:Name="GridFW" AutoGenerateColumns="False" IsReadOnly="True">
          <DataGrid.Columns>
            <DataGridTextColumn Header="BIOS Fabricante" Binding="{Binding BIOS_Manufacturer}" Width="220"/>
            <DataGridTextColumn Header="BIOS Versión" Binding="{Binding BIOS_Version}" Width="220"/>
            <DataGridTextColumn Header="ReleaseDate" Binding="{Binding BIOS_ReleaseDate}" Width="160"/>
            <DataGridTextColumn Header="BIOS Serial" Binding="{Binding BIOS_Serial}" Width="160"/>
            <DataGridTextColumn Header="Board Fabricante" Binding="{Binding Board_Manufacturer}" Width="220"/>
            <DataGridTextColumn Header="Board Producto" Binding="{Binding Board_Product}" Width="220"/>
            <DataGridTextColumn Header="Board Serial" Binding="{Binding Board_Serial}" Width="160"/>
            <DataGridTextColumn Header="Board Version" Binding="{Binding Board_Version}" Width="160"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>
    </TabControl>

    <!-- Footer -->
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock x:Name="StatusText" Foreground="#BBBBBB"/>
    </StackPanel>
  </DockPanel>
</Window>
"@

  # Cargar XAML
  $reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
  $window = [Windows.Markup.XamlReader]::Load($reader)

  # Referencias UI
  $FilterBox         = $window.FindName('FilterBox')
  $RefreshBtn        = $window.FindName('RefreshBtn')
  $ExportAllBtn      = $window.FindName('ExportAllBtn')
  $OpenFolderBtn     = $window.FindName('OpenFolderBtn')
  $TagText           = $window.FindName('TagText')
  $SnapshotPathText  = $window.FindName('SnapshotPathText')
  $CountText         = $window.FindName('CountText')
  $StatusText        = $window.FindName('StatusText')

  $GridSys = $window.FindName('GridSys')
  $GridCPU = $window.FindName('GridCPU')
  $GridRAM = $window.FindName('GridRAM')
  $GridDisk= $window.FindName('GridDisk')
  $GridGPU = $window.FindName('GridGPU')
  $GridFW  = $window.FindName('GridFW')

  $TagText.Text = $State.Tag
  $SnapshotPathText.Text = $State.SnapshotDir

  # Datos
  $sysSummary = $null
  $cpu = $null
  $ramNormalized = $null
  $diskNormalized = $null
  $gpuNormalized = $null
  $fwSummary = $null

  function Collect-Inventory {
    Write-Log "Recolectando inventario. Tag: $($State.Tag)"

    # Sistema
    $cs = Try-Cim -Class "Win32_ComputerSystem" | Select-Object Manufacturer, Model, TotalPhysicalMemory
    $os = Try-Cim -Class "Win32_OperatingSystem" | Select-Object Caption, Version, OSArchitecture, BuildNumber
    $sysSummary = [pscustomobject]@{
      Manufacturer        = $cs.Manufacturer
      Model               = $cs.Model
      TotalRAM_GB         = [Math]::Round(($cs.TotalPhysicalMemory/1GB),2)
      OS                  = $os.Caption
      OSVersion           = $os.Version
      Architecture        = $os.OSArchitecture
      Build               = $os.BuildNumber
    }

    # CPU
    $cpuRaw = Try-Cim -Class "Win32_Processor"
    $cpu = $cpuRaw | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, L2CacheSize, L3CacheSize, ProcessorId

    # RAM
    $ramRaw = Try-Cim -Class "Win32_PhysicalMemory"
    $ram = $ramRaw | Select-Object BankLabel, Capacity, Speed, Manufacturer, PartNumber, SerialNumber, ConfiguredClockSpeed
    $ramNormalized = $ram | ForEach-Object {
      [pscustomobject]@{
        BankLabel            = $_.BankLabel
        Capacity_GB          = [Math]::Round(($_.Capacity/1GB),2)
        Speed_MHz            = $_.Speed
        Manufacturer         = $_.Manufacturer
        PartNumber           = $_.PartNumber
        SerialNumber         = $_.SerialNumber
        ConfiguredClockSpeed = $_.ConfiguredClockSpeed
      }
    }

    # Discos
    $diskRaw = Try-Cim -Class "Win32_DiskDrive"
    $disk = $diskRaw | Select-Object Model, Manufacturer, InterfaceType, MediaType, SerialNumber, Size, FirmwareRevision
    $diskNormalized = $disk | ForEach-Object {
      [pscustomobject]@{
        Model         = $_.Model
        Manufacturer  = $_.Manufacturer
        Interface     = $_.InterfaceType
        MediaType     = $_.MediaType
        SerialNumber  = $_.SerialNumber
        Size_GB       = if ($_.Size) { [Math]::Round(($_.Size/1GB),2) } else { $null }
        Firmware      = $_.FirmwareRevision
      }
    }

    # GPU
    $gpuRaw = Try-Cim -Class "Win32_VideoController"
    $gpu = $gpuRaw | Select-Object Name, DriverVersion, AdapterCompatibility, AdapterRAM, VideoProcessor
    $gpuNormalized = $gpu | ForEach-Object {
      [pscustomobject]@{
        Name                 = $_.Name
        DriverVersion        = $_.DriverVersion
        Vendor               = $_.AdapterCompatibility
        VRAM_GB              = if ($_.AdapterRAM) { [Math]::Round(($_.AdapterRAM/1GB),2) } else { $null }
        VideoProcessor       = $_.VideoProcessor
      }
    }

    # BIOS / Board
    $biosRaw = Try-Cim -Class "Win32_BIOS"
    $bios = $biosRaw | Select-Object Manufacturer, SMBIOSBIOSVersion, BIOSVersion, ReleaseDate, SerialNumber
    $mbRaw = Try-Cim -Class "Win32_BaseBoard"
    $mb = $mbRaw | Select-Object Manufacturer, Product, SerialNumber, Version

    $fwSummary = [pscustomobject]@{
      BIOS_Manufacturer     = $bios.Manufacturer -join "; "
      BIOS_Version          = if ($bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion } else { ($bios.BIOSVersion -join "; ") }
      BIOS_ReleaseDate      = ($bios.ReleaseDate | Select-Object -First 1)
      BIOS_Serial           = ($bios.SerialNumber | Select-Object -First 1)
      Board_Manufacturer    = $mb.Manufacturer -join "; "
      Board_Product         = $mb.Product -join "; "
      Board_Serial          = $mb.SerialNumber -join "; "
      Board_Version         = $mb.Version -join "; "
    }

    # Contadores
    $State.Counts = @{
      Sys   = 1
      CPU   = ($cpu | Measure-Object).Count
      RAM   = ($ramNormalized | Measure-Object).Count
      Disk  = ($diskNormalized | Measure-Object).Count
      GPU   = ($gpuNormalized | Measure-Object).Count
      FW    = 1
    }
  }

  function Bind-Tables {
    $GridSys.ItemsSource  = ,$sysSummary
    $GridCPU.ItemsSource  = $cpu
    $GridRAM.ItemsSource  = $ramNormalized
    $GridDisk.ItemsSource = $diskNormalized
    $GridGPU.ItemsSource  = $gpuNormalized
    $GridFW.ItemsSource   = ,$fwSummary

    $CountText.Text = "Sys:$($State.Counts.Sys) CPU:$($State.Counts.CPU) RAM:$($State.Counts.RAM) Disk:$($State.Counts.Disk) GPU:$($State.Counts.GPU) FW:$($State.Counts.FW)"
    $StatusText.Text = "Última actualización: $(Get-Date -Format 'HH:mm:ss')"
  }

  function Passes-Filter { param($item, [string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return $true }
    $t = $text.ToLowerInvariant()
    foreach ($field in $item.PSObject.Properties) {
      $val = [string]$field.Value
      if ($val -and ($val.ToLowerInvariant().Contains($t))) { return $true }
    }
    return $false
  }

  function Apply-Filter {
    $tab = $window.FindName('Tabs').SelectedItem.Header
    switch ($tab) {
      'Sistema' {
        $GridSys.ItemsSource = (, $sysSummary | Where-Object { Passes-Filter $_ $State.FilterText })
      }
      'CPU'    { $GridCPU.ItemsSource  = ($cpu | Where-Object { Passes-Filter $_ $State.FilterText }) }
      'RAM'    { $GridRAM.ItemsSource  = ($ramNormalized | Where-Object { Passes-Filter $_ $State.FilterText }) }
      'Discos' { $GridDisk.ItemsSource = ($diskNormalized | Where-Object { Passes-Filter $_ $State.FilterText }) }
      'GPU'    { $GridGPU.ItemsSource  = ($gpuNormalized | Where-Object { Passes-Filter $_ $State.FilterText }) }
      'BIOS / Board' { $GridFW.ItemsSource = (, $fwSummary | Where-Object { Passes-Filter $_ $State.FilterText }) }
    }
  }

  function Export-All {
    try {
      Write-Log "Exportando CPU..."
      $cpu        | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "cpu.csv")
      $cpu        | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $State.SnapshotDir "cpu.json") -Encoding UTF8

      Write-Log "Exportando RAM..."
      $ramNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "ram.csv")
      $ramNormalized | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $State.SnapshotDir "ram.json") -Encoding UTF8

      Write-Log "Exportando Discos..."
      $diskNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "disks.csv")
      $diskNormalized | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $State.SnapshotDir "disks.json") -Encoding UTF8

      Write-Log "Exportando GPU..."
      $gpuNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "gpu.csv")
      $gpuNormalized | ConvertTo-Json -Depth 4 | Out-File -Path (Join-Path $State.SnapshotDir "gpu.json") -Encoding UTF8

      Write-Log "Exportando BIOS/Board..."
      (, $fwSummary) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "bios_board.csv")
      $fwSummary | ConvertTo-Json -Depth 4 | Out-File -Path (Join-Path $State.SnapshotDir "bios_board.json") -Encoding UTF8

      # Resumen consolidado
      $summary = [pscustomobject]@{
        Tag                 = $State.Tag
        Timestamp           = $TimeStamp
        System              = $sysSummary
        CPU                 = $cpu
        RAM_Modules         = $ramNormalized
        Disks               = $diskNormalized
        GPU                 = $gpuNormalized
        Firmware_And_Board  = $fwSummary
      }
      $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $SummaryJson -Encoding UTF8

      # CSV plano
      $flat = [pscustomobject]@{
        Tag              = $State.Tag
        Timestamp        = $TimeStamp
        Manufacturer     = $sysSummary.Manufacturer
        Model            = $sysSummary.Model
        TotalRAM_GB      = $sysSummary.TotalRAM_GB
        CPU_Name         = ($cpu | Select-Object -First 1).Name
        CPU_Cores        = ($cpu | Select-Object -First 1).NumberOfCores
        CPU_Threads      = ($cpu | Select-Object -First 1).NumberOfLogicalProcessors
        Disk_Count       = $diskNormalized.Count
        Disk_Total_GB    = [Math]::Round(($diskNormalized | Measure-Object -Property Size_GB -Sum).Sum,2)
        GPU_Primary      = ($gpuNormalized | Select-Object -First 1).Name
        BIOS_Version     = $fwSummary.BIOS_Version
      }
      $flat | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $SummaryCsv

      # Por-dispositivo CSV opcional
      if ($State.IncludeCSV) {
        Write-Log "IncludePerDeviceCSV activo: exportando por categoría..."
        $cpu | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "cpu_per_device.csv")
        $ramNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "ram_per_device.csv")
        $diskNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "disks_per_device.csv")
        $gpuNormalized | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $State.SnapshotDir "gpu_per_device.csv")
      }

      [System.Windows.MessageBox]::Show("Exportación completada en:`n$($State.SnapshotDir)","Exportación", 'OK','Information') | Out-Null
    } catch {
      Write-Log "Error exportando: $($_.Exception.Message)" "ERROR"
      [System.Windows.MessageBox]::Show("Error exportando:`n$($_.Exception.Message)","Error", 'OK','Error') | Out-Null
    }
  }

  # Eventos
  $FilterBox.Add_TextChanged({
    $State.FilterText = $FilterBox.Text
    Apply-Filter
  })
  $RefreshBtn.Add_Click({
    Collect-Inventory
    Bind-Tables
    Apply-Filter
  })
  $ExportAllBtn.Add_Click({ Export-All })
  $OpenFolderBtn.Add_Click({
    try { Start-Process explorer.exe $State.SnapshotDir } catch { }
  })

  # Primera carga
  Collect-Inventory
  Bind-Tables

  # Mostrar ventana
  $null = $window.ShowDialog()
}

end {
  Write-Log "Inventario completado. Carpeta: $($State.SnapshotDir)"
  Write-Log "Archivos: cpu.*, ram.*, disks.*, gpu.*, bios_board.*, summary.json, summary.csv"
  Write-Log "✅ Listo."
}
