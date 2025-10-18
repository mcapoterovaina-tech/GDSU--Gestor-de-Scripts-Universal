using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Windows.Forms;
using System.Collections.Generic;

namespace GDSU
{
    public class MainForm : Form
    {
        // UI
        private Panel headerPanel;
        private Label lblTitle;

        private Panel contentPanel;
        private GroupBox gbLog;
        private TextBox tbLog;

        private GroupBox gbTree;
        private TreeView tree;

        private Panel btnPanel;
        private Button btnRun;
        private Button btnRefresh;
        private Button btnClose;
        private Button btnSelectFolder;
        private Button btnDocs;

        private StatusStrip status;
        private ToolStripStatusLabel sslPath;
        private ToolStripStatusLabel sslStatus;
        private ToolStripStatusLabel sslTime;

        // NEW: Stats panel
        private GroupBox gbStats;
        private Label lblScriptsTotal;
        private Label lblScriptsSelected;
        private Label lblRunning;
        private Label lblCompleted;
        private Label lblErrors;
        private Label lblLastAction;

        // Logic
        private string rootPath;
        private readonly Dictionary<int, (string Path, string Ext)> runningProcesses = new();

        // === NUEVOS CAMPOS PARA EL MONITOR ===
        private GroupBox gbMonitor;
        private ProgressBar pbCPU;
        private ProgressBar pbRAM;
        private System.Windows.Forms.Timer sysTimer;
        private PerformanceCounter cpuCounter;
        private PerformanceCounter ramCounter;

        // NEW: Stats counters
        private int totalLaunched = 0;
        private int totalCompleted = 0;
        private int totalErrors = 0;

        public MainForm()
        {
            // Base form
            Text = "Gestor de Scripts Universal";
            StartPosition = FormStartPosition.CenterScreen;

            // NEW: Ancho ampliado para alojar el panel estadístico sin tocar tu layout actual
            Size = new Size(1140, 640);

            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            BackColor = Color.FromArgb(245, 248, 250);
            Font = new Font("Segoe UI", 9);

            // Icon from logo.ico next to executable
            try
            {
                string icoPath = Path.Combine(AppContext.BaseDirectory, "logo.ico");
                if (File.Exists(icoPath))
                    Icon = new Icon(icoPath);
            }
            catch { /* ignore icon load errors */ }

            rootPath = AppContext.BaseDirectory;

            BuildHeader();
            BuildContent();
            BuildLogGroup();
            BuildTreeGroup();
            BuildButtons();
            BuildStatusBar();

            // NEW: Build stats panel (desacoplado)
            BuildStatsPanel();
            BuildSystemMonitor();
            UpdateStatsUI();

            // Keyboard quick buttons
            AcceptButton = btnRun;
            CancelButton = btnClose;

            // Events
            btnRun.Click += (s, e) =>
            {
                if (!IsAdmin())
                    WriteLog("Advertencia: ejecuta como Administrador para evitar permisos bloqueados.");
                RunSelected();
            };

            btnRefresh.Click += (s, e) =>
            {
                LoadTree();
                UpdateStatsUI();
            };

            btnClose.Click += (s, e) => Close();

            btnSelectFolder.Click += (s, e) =>
            {
                using var fbd = new FolderBrowserDialog();
                fbd.Description = "Selecciona la carpeta raíz de scripts";
                fbd.SelectedPath = rootPath;
                if (fbd.ShowDialog() == DialogResult.OK)
                {
                    rootPath = fbd.SelectedPath;
                    WriteLog($"Carpeta raíz cambiada a: {rootPath}");
                    sslPath.Text = $"Ruta: {rootPath}";
                    LoadTree();
                    UpdateStatsUI();
                }
            };

            tree.AfterCheck += Tree_AfterCheck;

            // Start
            LoadTree();
            UpdateStatsUI();
        }

        private void BuildHeader()
        {
            headerPanel = new Panel
            {
                Size = new Size(ClientSize.Width, 52),
                Location = new Point(0, 0),
                BackColor = Color.FromArgb(28, 42, 66),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
            };
            Controls.Add(headerPanel);

            lblTitle = new Label
            {
                Text = "Gestor de Scripts Universal",
                ForeColor = Color.White,
                Font = new Font("Segoe UI Semibold", 12.5f),
                Location = new Point(20, 14),
                AutoSize = true
            };
            headerPanel.Controls.Add(lblTitle);
        }

        private void BuildContent()
        {
            contentPanel = new Panel
            {
                Location = new Point(16, 60),
                Size = new Size(868, 520),
                BackColor = Color.FromArgb(252, 253, 254),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom,
                Padding = new Padding(12)
            };
            Controls.Add(contentPanel);
        }

        private void BuildLogGroup()
        {
            gbLog = new GroupBox
            {
                Text = " Registro ",
                Font = new Font("Segoe UI", 9, FontStyle.Regular),
                ForeColor = Color.FromArgb(50, 60, 70),
                Size = new Size(840, 220),
                Location = new Point(12, 12)
            };
            contentPanel.Controls.Add(gbLog);

            tbLog = new TextBox
            {
                Location = new Point(16, 28),
                Size = new Size(808, 170),
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                ReadOnly = true,
                BorderStyle = BorderStyle.FixedSingle,
                BackColor = Color.FromArgb(248, 250, 252),
                Font = TryMonoFont(new Font("Cascadia Mono", 9))
            };
            gbLog.Controls.Add(tbLog);
        }

        private void BuildTreeGroup()
        {
            gbTree = new GroupBox
            {
                Text = " Scripts disponibles ",
                Font = new Font("Segoe UI", 9, FontStyle.Regular),
                ForeColor = Color.FromArgb(50, 60, 70),
                Size = new Size(840, 220),
                Location = new Point(12, 242)
            };
            contentPanel.Controls.Add(gbTree);

            tree = new TreeView
            {
                Location = new Point(16, 28),
                Size = new Size(808, 170),
                CheckBoxes = true,
                HideSelection = false,
                BorderStyle = BorderStyle.FixedSingle,
                BackColor = Color.FromArgb(248, 250, 252),
                Font = new Font("Segoe UI", 9),
                ShowLines = true,
                ShowRootLines = true
            };
            tree.ShowNodeToolTips = true;
            gbTree.Controls.Add(tree);
        }

        private void BuildButtons()
        {
            btnPanel = new Panel
            {
                Size = new Size(840, 40),
                Location = new Point(12, 472),
                Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom
            };
            contentPanel.Controls.Add(btnPanel);

            btnRun = NewStyledButton("Ejecutar seleccionados", new Point(0, 5));
            btnRefresh = NewStyledButton("Refrescar", new Point(205, 5));
            btnSelectFolder = NewStyledButton("Seleccionar carpeta", new Point(410, 5));
            btnClose = NewStyledButton("Cerrar", new Point(650, 5));
            btnClose.Size = new Size(190, 30);
            btnDocs = NewStyledButton("Documentación", new Point(650, 5));
            btnClose = NewStyledButton("Cerrar", new Point(860, 5));
            btnClose.Size = new Size(190, 30);

            btnPanel.Controls.AddRange(new Control[] { btnRun, btnRefresh, btnSelectFolder, btnDocs, btnClose });
            btnDocs.Click += (s, e) =>
            {
                var docForm = new DocForm();
                docForm.ShowDialog();
            };
        }

        private void BuildStatusBar()
        {
            status = new StatusStrip
            {
                SizingGrip = false,
                BackColor = Color.FromArgb(236, 240, 244),
                ForeColor = Color.FromArgb(60, 70, 80)
            };

            sslPath = new ToolStripStatusLabel
            {
                Text = $"Ruta: {AppContext.BaseDirectory}",
                Spring = true
            };

            sslStatus = new ToolStripStatusLabel
            {
                Text = "Listo"
            };

            sslTime = new ToolStripStatusLabel
            {
                Text = DateTime.Now.ToString("HH:mm"),
                BorderSides = ToolStripStatusLabelBorderSides.Left,
                BorderStyle = Border3DStyle.Raised
            };

            status.Items.Add(sslPath);
            status.Items.Add(sslStatus);
            status.Items.Add(sslTime);
            Controls.Add(status);
        }

        // NEW: Stats panel (desacoplado del contentPanel, ubicado a la derecha)
        private void BuildStatsPanel()
        {
            gbStats = new GroupBox
            {
                Text = " Estadísticas ",
                Font = new Font("Segoe UI", 9, FontStyle.Regular),
                ForeColor = Color.FromArgb(50, 60, 70),
                Size = new Size(210, 220),
                Location = new Point(900, 60), // espacio a la derecha del contentPanel
                BackColor = Color.FromArgb(252, 253, 254)
            };
            Controls.Add(gbStats);

            lblScriptsTotal = NewStatLabel("Scripts cargados: 0", new Point(16, 28));
            lblScriptsSelected = NewStatLabel("Seleccionados: 0", new Point(16, 56));
            lblRunning = NewStatLabel("Procesos activos: 0", new Point(16, 84));
            lblCompleted = NewStatLabel("Completados: 0", new Point(16, 112));
            lblErrors = NewStatLabel("Errores: 0", new Point(16, 140));
            lblLastAction = NewStatLabel("Última acción: —", new Point(16, 168));

            gbStats.Controls.Add(lblScriptsTotal);
            gbStats.Controls.Add(lblScriptsSelected);
            gbStats.Controls.Add(lblRunning);
            gbStats.Controls.Add(lblCompleted);
            gbStats.Controls.Add(lblErrors);
            gbStats.Controls.Add(lblLastAction);
        }

        // NUEVO MÉTODO
        private void BuildSystemMonitor()
        {
            gbMonitor = new GroupBox
            {
                Text = " Monitor del sistema ",
                Size = new Size(210, 120),
                Location = new Point(900, 300),
                ForeColor = Color.FromArgb(50, 60, 70),
                BackColor = Color.FromArgb(252, 253, 254)
            };
            Controls.Add(gbMonitor);

            var lblCPU = new Label { Text = "CPU", Location = new Point(16, 28), AutoSize = true };
            pbCPU = new ProgressBar { Location = new Point(60, 25), Size = new Size(120, 20) };
            gbMonitor.Controls.Add(lblCPU);
            gbMonitor.Controls.Add(pbCPU);

            var lblRAM = new Label { Text = "RAM", Location = new Point(16, 68), AutoSize = true };
            pbRAM = new ProgressBar { Location = new Point(60, 65), Size = new Size(120, 20) };
            gbMonitor.Controls.Add(lblRAM);
            gbMonitor.Controls.Add(pbRAM);

            cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total");
            ramCounter = new PerformanceCounter("Memory", "% Committed Bytes In Use");

            sysTimer = new System.Windows.Forms.Timer { Interval = 2000 };  // <- aquí
            sysTimer.Tick += (s, e) =>
            {
                try
                {
                    pbCPU.Value = Math.Min(100, (int)cpuCounter.NextValue());
                    pbRAM.Value = Math.Min(100, (int)ramCounter.NextValue());
                }
                catch { /* ignorar errores de lectura */ }
            };
            sysTimer.Start();
        }



        private Label NewStatLabel(string text, Point location)
        {
            return new Label
            {
                Text = text,
                Location = location,
                AutoSize = true,
                ForeColor = Color.FromArgb(50, 60, 70)
            };
        }

        private Button NewStyledButton(string text, Point location)
        {
            var btn = new Button
            {
                Text = text,
                Location = location,
                Size = new Size(190, 30),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(52, 152, 219),
                ForeColor = Color.White
            };
            btn.FlatAppearance.BorderSize = 0;
            btn.FlatAppearance.MouseOverBackColor = Color.FromArgb(41, 128, 185);
            return btn;
        }

        private Font TryMonoFont(Font preferred)
        {
            try { return preferred; } catch { return new Font("Consolas", 9); }
        }

        // Logging utilities
        private void WriteLog(string text)
        {
            string timestamp = DateTime.Now.ToString("HH:mm:ss");
            tbLog.AppendText($"[{timestamp}] {text}{Environment.NewLine}");
            sslStatus.Text = text;
            sslTime.Text = DateTime.Now.ToString("HH:mm");

            // NEW: reflejar en el panel estadístico la última acción
            lblLastAction.Text = $"Última acción: {text}";
        }

        private bool IsAdmin()
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        // Tree loading: root = chosen directory, immediate subfolders only
        private void LoadTree()
        {
            tree.BeginUpdate();
            tree.Nodes.Clear();

            if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
            {
                WriteLog($"ERROR: Ruta raíz inválida: {rootPath}");
                tree.EndUpdate();
                UpdateStatsUI();
                return;
            }

            var topFolders = SafeEnumerateDirectories(rootPath)
                              .Select(path => new DirectoryInfo(path))
                              .Where(di => di.Exists)
                              .ToList();

            if (!topFolders.Any())
                WriteLog($"No hay subcarpetas en la raíz: {rootPath}");

            foreach (var folder in topFolders)
            {
                // Folder node
                var folderNode = new TreeNode(folder.Name)
                {
                    Tag = folder.FullName,
                    ToolTipText = folder.FullName,
                    NodeFont = new Font("Segoe UI Semibold", 9)
                };

                // Files: only .bat and .ps1
                var scripts = SafeEnumerateFiles(folder.FullName)
                              .Select(p => new FileInfo(p))
                              .Where(fi => fi.Exists && (fi.Extension.Equals(".bat", StringComparison.OrdinalIgnoreCase)
                                                     || fi.Extension.Equals(".ps1", StringComparison.OrdinalIgnoreCase)))
                              .ToList();

                if (!scripts.Any())
                {
                    WriteLog($"Carpeta sin scripts: {folder.FullName}");
                }
                else
                {
                    foreach (var script in scripts)
                    {
                        var child = new TreeNode(script.Name)
                        {
                            Tag = script.FullName,
                            ToolTipText = script.FullName
                        };
                        folderNode.Nodes.Add(child);
                    }
                }

                tree.Nodes.Add(folderNode);
            }

            tree.ExpandAll();
            tree.EndUpdate();
            sslPath.Text = $"Ruta: {rootPath}";
            WriteLog($"Árbol cargado desde: {rootPath}");

            // NEW: actualizar estadísticas tras recarga
            UpdateStatsUI();
        }

        private IEnumerable<string> SafeEnumerateDirectories(string path)
        {
            try { return Directory.EnumerateDirectories(path); }
            catch (Exception ex)
            {
                WriteLog($"Error leyendo subcarpetas de {path} -> {ex.Message}");
                return Enumerable.Empty<string>();
            }
        }

        private IEnumerable<string> SafeEnumerateFiles(string path)
        {
            try { return Directory.EnumerateFiles(path); }
            catch (Exception ex)
            {
                WriteLog($"Error leyendo archivos de {path} -> {ex.Message}");
                return Enumerable.Empty<string>();
            }
        }

        // Propagate folder checkbox to children
        private void Tree_AfterCheck(object sender, TreeViewEventArgs e)
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

            // NEW: actualizar seleccionados cuando cambian checks
            UpdateStatsUI();
        }

        // Parallel execution of selected items
        private void RunSelected()
        {
            int started = 0;

            foreach (TreeNode folderNode in tree.Nodes)
            {
                foreach (TreeNode child in folderNode.Nodes)
                {
                    if (child.Checked && child.Tag is string fullPath && File.Exists(fullPath))
                    {
                        string ext = Path.GetExtension(fullPath).ToLowerInvariant();
                        string wd = Path.GetDirectoryName(fullPath)!;

                        try
                        {
                            Process? p = ext switch
                            {
                                ".bat" => StartProcess("cmd.exe", $"/c \"{fullPath}\"", wd),
                                ".ps1" => StartProcess("powershell.exe", $"-ExecutionPolicy Bypass -NoLogo -NoProfile -File \"{fullPath}\"", wd),
                                _ => null
                            };

                            if (p == null)
                            {
                                WriteLog($"Saltado (extensión no soportada): {fullPath}");
                                continue;
                            }

                            p.EnableRaisingEvents = true;
                            p.Exited += (s, e) =>
                            {
                                try
                                {
                                    var proc = (Process)s!;
                                    int pid = -1;
                                    int code = -1;

                                    // Capturamos datos de forma segura
                                    try { pid = proc.Id; } catch { }
                                    try { code = proc.ExitCode; } catch { }

                                    lock (runningProcesses) { if (pid > 0) runningProcesses.Remove(pid); }

                                    // NEW: actualizar contadores de completados/errores
                                    if (code != 0) totalErrors++;
                                    totalCompleted++;

                                    SafeInvoke(() =>
                                    {
                                        WriteLog($"FIN (PID {pid}, exit code {code})");
                                        UpdateStatsUI();
                                    });
                                    proc.Dispose();
                                }
                                catch (Exception ex)
                                {
                                    SafeInvoke(() =>
                                    {
                                        WriteLog($"Error en evento Exited: {ex.Message}");
                                        UpdateStatsUI();
                                    });
                                }
                            };

                            lock (runningProcesses) { runningProcesses[p.Id] = (fullPath, ext); }

                            WriteLog($"Lanzado: {fullPath} (PID {p.Id})");
                            started++;
                            totalLaunched++;

                            // NEW: actualizar estadísticas al lanzar
                            UpdateStatsUI();
                        }
                        catch (Exception ex)
                        {
                            WriteLog($"Excepción al iniciar {fullPath} -> {ex.Message}");
                            totalErrors++;
                            UpdateStatsUI();
                        }
                    }
                }
            }

            if (started == 0)
                WriteLog("No hay scripts seleccionados.");
            else
                WriteLog($"Procesos lanzados en paralelo: {started}");

            // NEW: actualización final
            UpdateStatsUI();
        }

        private Process StartProcess(string fileName, string arguments, string workingDir)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = workingDir,
                UseShellExecute = false,
                CreateNoWindow = false,
                WindowStyle = ProcessWindowStyle.Normal
            };
            return Process.Start(psi)!;
        }

        private void SafeInvoke(Action action)
        {
            if (IsDisposed) return;
            if (InvokeRequired)
            {
                try { BeginInvoke(action); } catch { /* ignore */ }
            }
            else
            {
                try { action(); } catch { /* ignore */ }
            }
        }

        // NEW: cálculo y refresco de estadísticas
        private void UpdateStatsUI()
        {
            int totalScripts = tree.Nodes.Cast<TreeNode>().Sum(folder => folder.Nodes.Count);
            int selectedScripts = tree.Nodes.Cast<TreeNode>()
                                           .SelectMany(folder => folder.Nodes.Cast<TreeNode>())
                                           .Count(n => n.Checked);
            int running = 0;
            lock (runningProcesses) { running = runningProcesses.Count; }

            lblScriptsTotal.Text = $"Scripts cargados: {totalScripts}";
            lblScriptsSelected.Text = $"Seleccionados: {selectedScripts}";
            lblRunning.Text = $"Procesos activos: {running}";
            lblCompleted.Text = $"Completados: {totalCompleted}";
            lblErrors.Text = $"Errores: {totalErrors}";

            // Color semántico rápido
            lblRunning.ForeColor = running > 0 ? Color.FromArgb(41, 128, 185) : Color.FromArgb(50, 60, 70);
            lblErrors.ForeColor = totalErrors > 0 ? Color.FromArgb(192, 57, 43) : Color.FromArgb(50, 60, 70);
        }
    }
}
