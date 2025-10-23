using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using GDSU.Core;
using GDSU.Models;
using GDSU.Services;
using GDSU.Utils;

namespace GDSU.UI
{
    // UIX: wiring entre UIBuilder y servicios. SRP: solo orquestación UI ↔ servicios.
    public class UIX : IDisposable
    {
        private readonly UIBuilder ui;
        private readonly IScriptTreeLoader treeLoader;
        private readonly ScriptRunner scriptRunner;
        private readonly IMonitorService monitorService;
        private readonly IStatsService statsService;
        private readonly IDialogService dialogService;
        private readonly ILogger logger;

        private string rootPath;

        public UIX(
            UIBuilder builder,
            IScriptTreeLoader treeLoader,
            ScriptRunner scriptRunner,
            IMonitorService monitorService,
            IStatsService statsService,
            IDialogService dialogService,
            ILogger logger,
            string initialRoot = null)
        {
            ui = builder ?? throw new ArgumentNullException(nameof(builder));
            this.treeLoader = treeLoader ?? throw new ArgumentNullException(nameof(treeLoader));
            this.scriptRunner = scriptRunner ?? throw new ArgumentNullException(nameof(scriptRunner));
            this.monitorService = monitorService ?? throw new ArgumentNullException(nameof(monitorService));
            this.statsService = statsService ?? throw new ArgumentNullException(nameof(statsService));
            this.dialogService = dialogService ?? throw new ArgumentNullException(nameof(dialogService));
            this.logger = logger ?? throw new ArgumentNullException(nameof(logger));

            rootPath = string.IsNullOrWhiteSpace(initialRoot) ? AppContext.BaseDirectory : initialRoot;

            WireUiEvents();
            WireServiceEvents();

            monitorService.Start();
            LoadTree();
            RefreshStatsFromServices();
        }

        public void Dispose()
        {
            try { monitorService.Stop(); } catch { }

            // Unsubscribe ScriptRunner events
            try
            {
                scriptRunner.OnStarted -= ScriptRunner_OnStarted;
                scriptRunner.OnOutput -= ScriptRunner_OnOutput;
                scriptRunner.OnExited -= ScriptRunner_OnExited;
            }
            catch { }

            // Unsubscribe service events
            try { monitorService.OnSample -= Monitor_OnSample; } catch { }
            try { statsService.OnStatsChanged -= StatsService_OnStatsChanged; } catch { }
            try { logger.OnLogged -= Logger_OnLogged; } catch { }

            // Unsubscribe process service if it was used elsewhere (defensive)
            try
            {
                if (ui.BtnRun != null) ui.BtnRun.Click -= BtnRun_Click;
                if (ui.BtnRefresh != null) ui.BtnRefresh.Click -= BtnRefresh_Click;
                if (ui.BtnSelectFolder != null) ui.BtnSelectFolder.Click -= BtnSelectFolder_Click;
                if (ui.BtnClose != null) ui.BtnClose.Click -= BtnClose_Click;
                if (ui.Tree != null) ui.Tree.AfterCheck -= Tree_AfterCheck;
                if (ui.BtnLogTitle != null) ui.BtnLogTitle.Click -= BtnLogTitle_Click;
                if (ui.LogMenu != null)
                {
                    if (ui.LogMenu.Items.Count >= 1) ui.LogMenu.Items[0].Click -= LogMenu_VerLog;
                    if (ui.LogMenu.Items.Count >= 2) ui.LogMenu.Items[1].Click -= LogMenu_GestionTareas;
                }
            }
            catch { }
        }

        private void WireUiEvents()
        {
            if (ui.BtnRun != null) ui.BtnRun.Click += BtnRun_Click;
            if (ui.BtnRefresh != null) ui.BtnRefresh.Click += BtnRefresh_Click;
            if (ui.BtnSelectFolder != null) ui.BtnSelectFolder.Click += BtnSelectFolder_Click;
            if (ui.BtnClose != null) ui.BtnClose.Click += BtnClose_Click;

            if (ui.BtnLogTitle != null && ui.LogMenu != null)
            {
                ui.BtnLogTitle.Click += BtnLogTitle_Click;

                if (ui.LogMenu.Items.Count >= 1)
                {
                    ui.LogMenu.Items[0].Click -= LogMenu_VerLog;
                    ui.LogMenu.Items[0].Click += LogMenu_VerLog;
                }
                if (ui.LogMenu.Items.Count >= 2)
                {
                    ui.LogMenu.Items[1].Click -= LogMenu_GestionTareas;
                    ui.LogMenu.Items[1].Click += LogMenu_GestionTareas;
                }
            }

            if (ui.Tree != null) ui.Tree.AfterCheck += Tree_AfterCheck;
        }

        private void WireServiceEvents()
        {
            // Subscribe to ScriptRunner events to update UI and stats
            scriptRunner.OnStarted += ScriptRunner_OnStarted;
            scriptRunner.OnOutput += ScriptRunner_OnOutput;
            scriptRunner.OnExited += ScriptRunner_OnExited;

            monitorService.OnSample += Monitor_OnSample;
            statsService.OnStatsChanged += StatsService_OnStatsChanged;
            logger.OnLogged += Logger_OnLogged;
        }

        // UI event handlers (named so we can unsubscribe cleanly)
        private void BtnRun_Click(object? s, EventArgs e) => RunSelected();
        private void BtnRefresh_Click(object? s, EventArgs e) { LoadTree(); RefreshStatsFromServices(); }
        private void BtnSelectFolder_Click(object? s, EventArgs e) => SelectFolder();
        private void BtnClose_Click(object? s, EventArgs e) => UIThread.SafeInvoke(ui.Form, () => ui.Form?.Close());
        private void BtnLogTitle_Click(object? s, EventArgs e)
        {
            if (ui.LogMenu != null)
                ui.LogMenu.Show(ui.BtnLogTitle, new System.Drawing.Point(0, ui.BtnLogTitle.Height));
        }

        private void LogMenu_VerLog(object? s, EventArgs e) => ShowLogLayout();
        private void LogMenu_GestionTareas(object? s, EventArgs e) => ShowTaskLayout();

        private void Logger_OnLogged(string msg) => AppendLog(msg);
        private void StatsService_OnStatsChanged(StatsSnapshot s) => UIThread.SafeInvoke(ui.Form, () => ApplySnapshotToUI(s));
        private void Monitor_OnSample(int cpu, int ram)
        {
            UIThread.SafeInvoke(ui.Form, () =>
            {
                if (ui.PbCPU != null) ui.PbCPU.Value = Math.Max(0, Math.Min(100, cpu));
                if (ui.PbRAM != null) ui.PbRAM.Value = Math.Max(0, Math.Min(100, ram));
            });
        }

        private void ScriptRunner_OnStarted(int pid, string path)
        {
            statsService.IncrementLaunched();
            AppendLog($"Lanzado: {path} (PID {pid})");
            RefreshStatsFromServices();
        }

        private void ScriptRunner_OnOutput(int pid, string line, bool isError)
        {
            AppendLog(isError ? $"[ERR] {line}" : $"[OUT] {line}");
        }

        private void ScriptRunner_OnExited(int pid, int? code)
        {
            if (code != 0) statsService.IncrementErrors();
            statsService.IncrementCompleted();
            AppendLog($"FIN (PID {pid}, exit code {code})");
            RefreshStatsFromServices();
        }

        private void ApplySnapshotToUI(StatsSnapshot s)
        {
            if (ui.LblScriptsTotal != null) ui.LblScriptsTotal.Text = $"Scripts cargados: {s.Total}";
            if (ui.LblScriptsSelected != null) ui.LblScriptsSelected.Text = $"Seleccionados: {s.Selected}";
            if (ui.LblRunning != null) ui.LblRunning.Text = $"Procesos activos: {s.Running}";
            if (ui.LblCompleted != null) ui.LblCompleted.Text = $"Completados: {s.Completed}";
            if (ui.LblErrors != null) ui.LblErrors.Text = $"Errores: {s.Errors}";
            if (ui.LblRunning != null) ui.LblRunning.ForeColor = s.Running > 0 ? Styl.BtnPrimaryHover : Styl.TextDefault;
            if (ui.LblErrors != null) ui.LblErrors.ForeColor = s.Errors > 0 ? System.Drawing.Color.FromArgb(192,57,43) : Styl.TextDefault;
        }

        private void AppendLog(string text)
        {
            var timestamp = DateTime.Now.ToString("HH:mm:ss");
            UIThread.SafeInvoke(ui.Form, () =>
            {
                if (ui.TbLog != null) ui.TbLog.AppendText($"[{timestamp}] {text}{Environment.NewLine}");
                if (ui.SslStatus != null) ui.SslStatus.Text = text;
                if (ui.SslTime != null) ui.SslTime.Text = DateTime.Now.ToString("HH:mm");
                if (ui.LblLastAction != null) ui.LblLastAction.Text = $"Última acción: {text}";
            });
        }

        private void SelectFolder()
        {
            if (dialogService.TryPickFolder(rootPath, out var picked) && !string.IsNullOrWhiteSpace(picked))
            {
                rootPath = picked;
                AppendLog($"Carpeta raíz cambiada a: {rootPath}");
                UIThread.SafeInvoke(ui.Form, () => { if (ui.SslPath != null) ui.SslPath.Text = $"Ruta: {rootPath}"; });
                LoadTree();
                RefreshStatsFromServices();
            }
        }

        public void ShowLogLayout() => UIThread.SafeInvoke(ui.Form, () => ui.ShowLogLayout());
        public void ShowTaskLayout()
        {
            var btnNewTask = new Button { Text = "Crear nueva tarea", Dock = DockStyle.Bottom, Height = 30 };
            btnNewTask.Click += (_,__) => AddNewTaskRow();
            UIThread.SafeInvoke(ui.Form, () => ui.ShowTaskLayout(btnNewTask));
        }

        private void AddNewTaskRow()
        {
            UIThread.SafeInvoke(ui.Form, () =>
            {
                var layout = ui.TaskLayout;
                if (layout == null) return;
                int row = layout.RowCount++;
                layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.Controls.Add(new Label { Text = $"Tarea {row}", AutoSize = true, Anchor = AnchorStyles.Left }, 0, row);
                layout.Controls.Add(new TextBox { Dock = DockStyle.Fill }, 1, row);
                layout.Controls.Add(new CheckBox { Text = "Hecho", Anchor = AnchorStyles.Left }, 2, row);
            });
        }

        private void Tree_AfterCheck(object? sender, TreeViewEventArgs e)
        {
            if (e.Action == TreeViewAction.ByMouse || e.Action == TreeViewAction.ByKeyboard)
            {
                var node = e.Node;
                if (node.Tag is string tag && Directory.Exists(tag) && node.Nodes.Count > 0)
                    foreach (TreeNode child in node.Nodes) child.Checked = node.Checked;
            }
            RefreshStatsFromServices();
        }

        private void RefreshStatsFromServices()
        {
            var snapshot = statsService.GetSnapshot(
                scriptsTotal: ui.Tree?.Nodes.Cast<TreeNode>().Sum(f => f.Nodes.Count) ?? 0,
                scriptsSelected: ui.Tree?.Nodes.Cast<TreeNode>().SelectMany(f => f.Nodes.Cast<TreeNode>()).Count(n => n.Checked) ?? 0,
                running: scriptRunner.GetRunningProcessesSnapshot()?.Count ?? 0
            );
            ApplySnapshotToUI(snapshot);
        }

        public void LoadTree()
        {
            IEnumerable<ScriptNode> folders;
            try { folders = treeLoader.LoadRoot(rootPath) ?? Enumerable.Empty<ScriptNode>(); }
            catch (Exception ex) { AppendLog($"Error cargando árbol: {ex.Message}"); folders = Enumerable.Empty<ScriptNode>(); }

            UIThread.SafeInvoke(ui.Form, () =>
            {
                var tree = ui.Tree;
                if (tree == null) return;
                tree.BeginUpdate();
                tree.Nodes.Clear();
                foreach (var folder in folders.Where(f => f.IsFolder))
                {
                    var folderNode = new TreeNode(folder.Name) { Tag = folder.FullPath, ToolTipText = folder.FullPath };
                    ui.ApplyFolderNodeStyle(folderNode);
                    if (folder.Children != null)
                        foreach (var child in folder.Children.Where(c => !c.IsFolder))
                            folderNode.Nodes.Add(new TreeNode(child.Name) { Tag = child.FullPath, ToolTipText = child.FullPath });
                    tree.Nodes.Add(folderNode);
                }
                tree.ExpandAll();
                tree.EndUpdate();
                if (ui.SslPath != null) ui.SslPath.Text = $"Ruta: {rootPath}";
                AppendLog($"Árbol cargado desde: {rootPath}");
            });
        }

        public async void RunSelected()
        {
            var toRun = new List<string>();
            UIThread.SafeInvoke(ui.Form, () =>
            {
                if (ui.Tree == null) return;
                foreach (TreeNode folder in ui.Tree.Nodes)
                    foreach (TreeNode child in folder.Nodes)
                        if (child.Checked && child.Tag is string p && File.Exists(p)) toRun.Add(p);
            });

            if (!toRun.Any()) { AppendLog("No hay scripts seleccionados."); return; }

            try
            {
                await scriptRunner.StartManyAsync(toRun);
            }
            catch (Exception ex)
            {
                AppendLog($"Error iniciando scripts: {ex.Message}");
            }
        }

        private ProcessStartInfo DefaultStartInfoFor(string path)
        {
            var ext = Path.GetExtension(path)?.ToLowerInvariant();
            if (ext == ".bat") return new ProcessStartInfo("cmd.exe", $"/c \"{path}\"") { WorkingDirectory = Path.GetDirectoryName(path) ?? AppContext.BaseDirectory, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            if (ext == ".ps1") return new ProcessStartInfo("powershell.exe", $"-ExecutionPolicy Bypass -NoLogo -NoProfile -File \"{path}\"") { WorkingDirectory = Path.GetDirectoryName(path) ?? AppContext.BaseDirectory, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            return null;
        }
    }
}
