using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Windows.Forms;
using System.Threading;
using GDSU.Core;
using GDSU.Utils;

namespace GDSU.UI
{
    /// <summary>
    /// UIX: suscribe eventos y adapta la interacción entre UIBuilder y los servicios core.
    /// - No realiza enumeración de disco (usa ScriptTreeLoader).
    /// - No ejecuta scripts directamente (puede delegar a ScriptRunner en futuras iteraciones).
    /// - Crea el botón que se necesita para ShowTaskLayout y lo inyecta en la UI.
    /// </summary>
    public class UIX : IDisposable
    {
        private readonly UIBuilder ui;
        private readonly ScriptTreeLoader treeLoader;
        private string rootPath;
        private readonly Dictionary<int, ScriptProcessInfoLocal> runningProcesses = new Dictionary<int, ScriptProcessInfoLocal>();
        private System.Windows.Forms.Timer sysTimer;
        private PerformanceCounter cpuCounter;
        private PerformanceCounter ramCounter;

        // Estadísticas locales (pueden delegarse a StatsService)
        private int totalLaunched = 0;
        private int totalCompleted = 0;
        private int totalErrors = 0;

        private class ScriptProcessInfoLocal
        {
            public string Path { get; set; } = "";
            public string Ext { get; set; } = "";
            public DateTime StartTime { get; set; }
            public DateTime? EndTime { get; set; }
            public int? ExitCode { get; set; }
        }

        public UIX(UIBuilder builder, string initialRoot = null)
        {
            ui = builder ?? throw new ArgumentNullException(nameof(builder));
            treeLoader = new ScriptTreeLoader(msg => AppendLog(msg));
            rootPath = string.IsNullOrWhiteSpace(initialRoot) ? AppContext.BaseDirectory : initialRoot;

            // Inicializar monitor (PerformanceService sería mejor; por ahora envolvemos PerformanceCounter)
            try
            {
                cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total");
                ramCounter = new PerformanceCounter("Memory", "% Committed Bytes In Use");
            }
            catch (Exception ex)
            {
                cpuCounter = null;
                ramCounter = null;
                AppendLog($"Monitor deshabilitado: no se pudo inicializar PerformanceCounter -> {ex.Message}");
            }

            sysTimer = new System.Windows.Forms.Timer { Interval = 2000 };
            sysTimer.Tick += SysTimer_Tick;
            sysTimer.Start();

            WireEvents();

            // Poblado inicial
            LoadTree();
            UpdateStatsUI();
        }

        public void Dispose()
        {
            try
            {
                sysTimer?.Stop();
                sysTimer?.Dispose();
                cpuCounter?.Dispose();
                ramCounter?.Dispose();
            }
            catch { }
        }

        private void SysTimer_Tick(object? sender, EventArgs e)
        {
            try
            {
                if (cpuCounter != null && ui.PbCPU != null)
                {
                    int cpuVal = (int)cpuCounter.NextValue();
                    UIThread.SafeInvoke(ui.Form, () => ui.PbCPU.Value = Math.Max(0, Math.Min(100, cpuVal)));
                }

                if (ramCounter != null && ui.PbRAM != null)
                {
                    int ramVal = (int)ramCounter.NextValue();
                    UIThread.SafeInvoke(ui.Form, () => ui.PbRAM.Value = Math.Max(0, Math.Min(100, ramVal)));
                }
            }
            catch
            {
                // Ignorar errores de lectura
            }
        }

        private void WireEvents()
        {
            if (ui.BtnRun != null)
                ui.BtnRun.Click += (s, e) =>
                {
                    if (!IsAdmin())
                        AppendLog("Advertencia: ejecuta como Administrador para evitar permisos bloqueados.");
                    RunSelected();
                };

            if (ui.BtnRefresh != null)
                ui.BtnRefresh.Click += (s, e) =>
                {
                    LoadTree();
                    UpdateStatsUI();
                };

            if (ui.BtnSelectFolder != null)
                ui.BtnSelectFolder.Click += (s, e) =>
                {
                    using var fbd = new FolderBrowserDialog
                    {
                        Description = "Selecciona la carpeta raíz de scripts",
                        SelectedPath = rootPath
                    };
                    if (fbd.ShowDialog() == DialogResult.OK)
                    {
                        rootPath = fbd.SelectedPath;
                        AppendLog($"Carpeta raíz cambiada a: {rootPath}");
                        if (ui.SslPath != null) UIThread.SafeInvoke(ui.Form, () => ui.SslPath.Text = $"Ruta: {rootPath}");
                        LoadTree();
                        UpdateStatsUI();
                    }
                };

            if (ui.BtnClose != null)
                ui.BtnClose.Click += (s, e) =>
                {
                    var f = ui.Form;
                    if (f != null) UIThread.SafeInvoke(f, () => f.Close());
                };

            // Log menu header: conectar acciones definidas en UIBuilder.LogMenu
            if (ui.BtnLogTitle != null && ui.LogMenu != null)
            {
                ui.BtnLogTitle.Click += (s, e) =>
                {
                    // Asociar handlers a los items si no lo están
                    if (ui.LogMenu.Items.Count >= 2)
                    {
                        ui.LogMenu.Items[0].Click -= LogMenu_VerLog;
                        ui.LogMenu.Items[0].Click += LogMenu_VerLog;
                        ui.LogMenu.Items[1].Click -= LogMenu_GestionTareas;
                        ui.LogMenu.Items[1].Click += LogMenu_GestionTareas;
                    }
                    ui.LogMenu.Show(ui.BtnLogTitle, new Point(0, ui.BtnLogTitle.Height));
                };
            }

            if (ui.Tree != null)
                ui.Tree.AfterCheck += Tree_AfterCheck;
        }

        private void LogMenu_VerLog(object? s, EventArgs e) => ShowLogLayout();
        private void LogMenu_GestionTareas(object? s, EventArgs e) => ShowTaskLayout();

        // Mostrar layout de log (delegado a UIBuilder)
        public void ShowLogLayout()
        {
            UIThread.SafeInvoke(ui.Form, () => ui.ShowLogLayout());
        }

        // Crear botón aquí y pasarlo a UIBuilder para evitar fallback en UI.cs
        public void ShowTaskLayout()
        {
            var btnNewTask = new Button
            {
                Text = "Crear nueva tarea",
                Dock = DockStyle.Bottom,
                Height = 30
            };
            btnNewTask.Click += (s, e) => AddNewTaskRow();
            UIThread.SafeInvoke(ui.Form, () => ui.ShowTaskLayout(btnNewTask));
        }

        // Inserta una fila en el TaskLayout expuesto por UIBuilder
        private void AddNewTaskRow()
        {
            UIThread.SafeInvoke(ui.Form, () =>
            {
                var layout = ui.TaskLayout;
                if (layout == null) return;

                int row = layout.RowCount++;
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

                var lblTask = new Label { Text = $"Tarea {row}", AutoSize = true, Anchor = AnchorStyles.Left };
                var txtDesc = new TextBox { Dock = DockStyle.Fill };
                var chkDone = new CheckBox { Text = "Hecho", Anchor = AnchorStyles.Left };

                layout.Controls.Add(lblTask, 0, row);
                layout.Controls.Add(txtDesc, 1, row);
                layout.Controls.Add(chkDone, 2, row);
            });
        }

        // Escribe en el log y actualiza status (UI only)
        private void AppendLog(string text)
        {
            string timestamp = DateTime.Now.ToString("HH:mm:ss");
            UIThread.SafeInvoke(ui.Form, () =>
            {
                if (ui.TbLog != null)
                    ui.TbLog.AppendText($"[{timestamp}] {text}{Environment.NewLine}");
                if (ui.SslStatus != null) ui.SslStatus.Text = text;
                if (ui.SslTime != null) ui.SslTime.Text = DateTime.Now.ToString("HH:mm");
                if (ui.LblLastAction != null) ui.LblLastAction.Text = $"Última acción: {text}";
            });
        }

        private bool IsAdmin()
        {
            try
            {
                using var identity = WindowsIdentity.GetCurrent();
                var principal = new WindowsPrincipal(identity);
                return principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        // Carga el árbol delegando a ScriptTreeLoader; convierte ScriptNode a TreeNodes de UI
        public void LoadTree()
        {
            UIThread.SafeInvoke(ui.Form, () =>
            {
                var tree = ui.Tree;
                if (tree == null) return;
                tree.BeginUpdate();
                tree.Nodes.Clear();
            });

            if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
            {
                AppendLog($"ERROR: Ruta raíz inválida: {rootPath}");
                UIThread.SafeInvoke(ui.Form, () =>
                {
                    ui.Tree?.EndUpdate();
                    UpdateStatsUI();
                });
                return;
            }

            IEnumerable<Models.ScriptNode> folders;
            try
            {
                folders = treeLoader.LoadRoot(rootPath) ?? Enumerable.Empty<Models.ScriptNode>();
            }
            catch (Exception ex)
            {
                AppendLog($"Error cargando árbol: {ex.Message}");
                folders = Enumerable.Empty<Models.ScriptNode>();
            }

            UIThread.SafeInvoke(ui.Form, () =>
            {
                var tree = ui.Tree;
                if (tree == null) return;

                foreach (var folder in folders.Where(f => f.IsFolder))
                {
                    var folderNode = new TreeNode(folder.Name)
                    {
                        Tag = folder.FullPath,
                        ToolTipText = folder.FullPath
                    };
                    ui.ApplyFolderNodeStyle(folderNode);

                    // Si ScriptNode incluye Children, agregarlos; si no, intentamos leer files
                    if (folder.Children != null && folder.Children.Any())
                    {
                        foreach (var child in folder.Children.Where(c => !c.IsFolder))
                        {
                            var childNode = new TreeNode(child.Name)
                            {
                                Tag = child.FullPath,
                                ToolTipText = child.FullPath
                            };
                            folderNode.Nodes.Add(childNode);
                        }
                    }
                    else
                    {
                        // Fallback mínimo: leer archivos directos (seguro dentro de UI thread)
                        try
                        {
                            var files = Directory.EnumerateFiles(folder.FullPath)
                                .Select(p => new FileInfo(p))
                                .Where(fi => fi.Exists && (fi.Extension.Equals(".bat", StringComparison.OrdinalIgnoreCase) || fi.Extension.Equals(".ps1", StringComparison.OrdinalIgnoreCase)));
                            foreach (var f in files)
                                folderNode.Nodes.Add(new TreeNode(f.Name) { Tag = f.FullName, ToolTipText = f.FullName });
                        }
                        catch { /* ignorar aquí; treeLoader ya debería haberlo hecho */ }
                    }

                    tree.Nodes.Add(folderNode);
                }

                tree.ExpandAll();
                tree.EndUpdate();
                if (ui.SslPath != null) ui.SslPath.Text = $"Ruta: {rootPath}";
                AppendLog($"Árbol cargado desde: {rootPath}");
                UpdateStatsUI();
            });
        }

        // Propagate folder checkbox to children (hooked to ui.Tree.AfterCheck)
        private void Tree_AfterCheck(object? sender, TreeViewEventArgs e)
        {
            if (e.Action == TreeViewAction.ByMouse || e.Action == TreeViewAction.ByKeyboard)
            {
                var node = e.Node;
                if (node.Tag is string tag && Directory.Exists(tag) && node.Nodes.Count > 0)
                {
                    foreach (TreeNode child in node.Nodes)
                        child.Checked = node.Checked;
                }
            }

            UpdateStatsUI();
        }

        // Recolecta scripts seleccionados en el TreeView y los lanza usando Process (lightweight)
        // Nota: idealmente ScriptRunner debería usarse; aquí se mantiene comportamiento existente
        public void RunSelected()
        {
            // Recolectar rutas en UI thread
            var toRun = new List<string>();
            UIThread.SafeInvoke(ui.Form, () =>
            {
                if (ui.Tree == null) return;
                foreach (TreeNode folderNode in ui.Tree.Nodes)
                {
                    foreach (TreeNode child in folderNode.Nodes)
                    {
                        if (child.Checked && child.Tag is string fullPath && File.Exists(fullPath))
                            toRun.Add(fullPath);
                    }
                }
            });

            if (!toRun.Any())
            {
                AppendLog("No hay scripts seleccionados.");
                return;
            }

            int started = 0;
            foreach (var fullPath in toRun)
            {
                string ext = Path.GetExtension(fullPath).ToLowerInvariant();
                string wd = Path.GetDirectoryName(fullPath) ?? AppContext.BaseDirectory;

                try
                {
                    Process proc = null;
                    switch (ext)
                    {
                        case ".bat":
                            proc = StartProcess("cmd.exe", $"/c \"{fullPath}\"", wd);
                            break;
                        case ".ps1":
                            proc = StartProcess("powershell.exe", $"-ExecutionPolicy Bypass -NoLogo -NoProfile -File \"{fullPath}\"", wd);
                            break;
                        default:
                            AppendLog($"Saltado (extensión no soportada): {fullPath}");
                            continue;
                    }

                    if (proc == null)
                    {
                        AppendLog($"ERROR: no se pudo iniciar {fullPath}");
                        continue;
                    }

                    var info = new ScriptProcessInfoLocal { Path = fullPath, Ext = ext, StartTime = DateTime.Now };
                    lock (runningProcesses) { runningProcesses[proc.Id] = info; }

                    proc.EnableRaisingEvents = true;
                    proc.Exited += (s, e) =>
                    {
                        try
                        {
                            var p = (Process)s;
                            int pid = -1;
                            int code = -1;
                            try { pid = p.Id; } catch { }
                            try { code = p.ExitCode; } catch { }

                            lock (runningProcesses)
                            {
                                if (runningProcesses.TryGetValue(pid, out var pi))
                                {
                                    pi.EndTime = DateTime.Now;
                                    pi.ExitCode = code;
                                }
                                if (pid > 0) runningProcesses.Remove(pid);
                            }

                            if (code != 0) Interlocked.Increment(ref totalErrors);
                            Interlocked.Increment(ref totalCompleted);

                            AppendLog($"FIN (PID {pid}, exit code {code})");
                            UpdateStatsUI();

                            try { p.Dispose(); } catch { }
                        }
                        catch (Exception ex)
                        {
                            AppendLog($"Error en evento Exited: {ex.Message}");
                            UpdateStatsUI();
                        }
                    };

                    AppendLog($"Lanzado: {fullPath} (PID {proc.Id})");
                    started++;
                    Interlocked.Increment(ref totalLaunched);
                    UpdateStatsUI();
                }
                catch (Exception ex)
                {
                    AppendLog($"Excepción al iniciar {fullPath} -> {ex.Message}");
                    Interlocked.Increment(ref totalErrors);
                    UpdateStatsUI();
                }
            }

            AppendLog($"Procesos lanzados en paralelo: {started}");
            UpdateStatsUI();
        }

        // Inicia proceso y engancha salidas (Output/Error)
        private Process StartProcess(string fileName, string arguments, string workingDir)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = workingDir,
                UseShellExecute = false,
                CreateNoWindow = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WindowStyle = ProcessWindowStyle.Normal
            };

            var process = Process.Start(psi);
            if (process == null)
            {
                AppendLog($"ERROR: No se pudo iniciar el proceso {fileName} {arguments}");
                return null;
            }

            process.OutputDataReceived += (s, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data)) AppendLog($"[OUT] {e.Data}");
            };

            process.ErrorDataReceived += (s, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data)) AppendLog($"[ERR] {e.Data}");
            };

            try { process.BeginOutputReadLine(); } catch { }
            try { process.BeginErrorReadLine(); } catch { }

            return process;
        }

        // Actualiza etiquetas de estadísticas en la UI
        public void UpdateStatsUI()
        {
            UIThread.SafeInvoke(ui.Form, () =>
            {
                int totalScripts = ui.Tree?.Nodes.Cast<TreeNode>().Sum(folder => folder.Nodes.Count) ?? 0;
                int selectedScripts = ui.Tree?.Nodes.Cast<TreeNode>().SelectMany(folder => folder.Nodes.Cast<TreeNode>()).Count(n => n.Checked) ?? 0;
                int running;
                lock (runningProcesses) { running = runningProcesses.Count; }

                if (ui.LblScriptsTotal != null) ui.LblScriptsTotal.Text = $"Scripts cargados: {totalScripts}";
                if (ui.LblScriptsSelected != null) ui.LblScriptsSelected.Text = $"Seleccionados: {selectedScripts}";
                if (ui.LblRunning != null) ui.LblRunning.Text = $"Procesos activos: {running}";
                if (ui.LblCompleted != null) ui.LblCompleted.Text = $"Completados: {totalCompleted}";
                if (ui.LblErrors != null) ui.LblErrors.Text = $"Errores: {totalErrors}";

                if (ui.LblRunning != null) ui.LblRunning.ForeColor = running > 0 ? Styl.BtnPrimaryHover : Styl.TextDefault;
                if (ui.LblErrors != null) ui.LblErrors.ForeColor = totalErrors > 0 ? Color.FromArgb(192, 57, 43) : Styl.TextDefault;
            });
        }
    }
}
