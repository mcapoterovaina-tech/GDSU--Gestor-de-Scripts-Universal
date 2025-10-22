using System;
using System.Drawing;
using System.Windows.Forms;

namespace GDSU.UI
{
    // Responsable ÚNICO: construir y exponer la interfaz visual.
    // No suscribe eventos ni contiene lógica de interacción.
    public class UIBuilder
    {
        // Tipografías (referenciadas desde Styl; fallback local mínimo)
        private static readonly Font FontDefault = Styl.FontDefault ?? new Font("Segoe UI", 9);
        private static readonly Font FontHeader = Styl.FontHeader ?? new Font("Segoe UI Semibold", 12.5f);
        private static readonly Font FontMono = Styl.FontMono ?? new Font("Consolas", 9);
        private static readonly Font FontNodeFolder = Styl.FontNodeFolder ?? new Font("Segoe UI Semibold", 9);

        // Form y contenedor raíz
        public Form Form { get; private set; }

        // Header (visibilidad pública innecesaria restringida)
        private Panel HeaderPanel { get; set; }
        public Label LblTitle { get; private set; }

        // Contenido principal
        private Panel ContentPanel { get; set; }
        public SplitContainer SplitMain { get; private set; }
        public SplitContainer SplitTop { get; private set; }

        // Panel izquierdo superior (log / tareas)
        private Panel LogPanelContainer { get; set; }
        public ContextMenuStrip LogMenu { get; private set; }
        public TextBox TbLog { get; private set; }
        public TableLayoutPanel TaskLayout { get; private set; }
        public Button BtnLogTitle { get; private set; } // botón-encabezado del panel

        // Panel derecho superior (stats + monitor)
        private TableLayoutPanel RightPanel { get; set; }

        // Stats (exponer sólo los labels necesarios)
        public GroupBox GbStats { get; private set; }
        public Label LblScriptsTotal { get; private set; }
        public Label LblScriptsSelected { get; private set; }
        public Label LblRunning { get; private set; }
        public Label LblCompleted { get; private set; }
        public Label LblErrors { get; private set; }
        public Label LblLastAction { get; private set; }

        // Monitor
        public GroupBox GbMonitor { get; private set; }
        public ProgressBar PbCPU { get; private set; }
        public ProgressBar PbRAM { get; private set; }

        // Árbol
        public GroupBox GbTree { get; private set; }
        public TreeView Tree { get; private set; }

        // Botonera inferior (exponer sólo los botones que se usan externamente)
        private Panel BtnPanel { get; set; }
        public Button BtnRun { get; private set; }
        public Button BtnRefresh { get; private set; }
        public Button BtnSelectFolder { get; private set; }
        public Button BtnDocs { get; private set; }
        public Button BtnClose { get; private set; }

        // Status bar (exponer solo las etiquetas que UIX actualiza)
        private StatusStrip Status { get; set; }
        public ToolStripStatusLabel SslPath { get; private set; }
        public ToolStripStatusLabel SslStatus { get; private set; }
        public ToolStripStatusLabel SslTime { get; private set; }

        // Construye toda la interfaz visual
        public void Build(Form form)
        {
            Form = form ?? throw new ArgumentNullException(nameof(form));
            ApplyFormDefaults();

            BuildHeader();
            BuildContent();
            BuildButtons();
            BuildStatusBar();

            // Por defecto, mostrar layout de Log en el panel dinámico (UIX cambiará entre Log/Tareas)
            ShowLogLayout();
        }

        private void ApplyFormDefaults()
        {
            Form.Text = "Gestor de Scripts Universal";
            Form.StartPosition = FormStartPosition.CenterScreen;
            Form.Size = new Size(1140, 640);
            Form.MinimumSize = new Size(900, 560);
            Form.FormBorderStyle = FormBorderStyle.Sizable;
            Form.MaximizeBox = true;
            Form.BackColor = Styl.BgApp;
            Form.Font = FontDefault;
        }

        // === Header ===
        private void BuildHeader()
        {
            HeaderPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 52,
                BackColor = Styl.BgHeader
            };
            Form.Controls.Add(HeaderPanel);

            LblTitle = new Label
            {
                Text = "Gestor de Scripts Universal",
                ForeColor = Color.White,
                Font = FontHeader,
                Location = new Point(20, 14),
                AutoSize = true
            };
            HeaderPanel.Controls.Add(LblTitle);
        }

        // === Contenido principal ===
        private void BuildContent()
        {
            ContentPanel = new Panel
            {
                Location = new Point(16, 60),
                Size = new Size(Form.ClientSize.Width - 32, Form.ClientSize.Height - 120),
                BackColor = Styl.BgPanel,
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom,
                Padding = new Padding(0)
            };
            Form.Controls.Add(ContentPanel);

            // Split superior/inferior
            SplitMain = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Horizontal,
                SplitterDistance = 260,
                IsSplitterFixed = false
            };
            ContentPanel.Controls.Add(SplitMain);

            // Split izquierdo/derecho (Panel superior)
            SplitTop = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Vertical,
                SplitterDistance = 600,
                IsSplitterFixed = false
            };
            SplitMain.Panel1.Controls.Add(SplitTop);

            // Panel dinámico: Log/Tareas (lado izquierdo)
            BuildLogPanel();

            // Panel derecho: Stats + Monitor
            BuildRightPanel();

            // Panel inferior: Árbol
            BuildTreePanel();
        }

        // === Panel dinámico: Log/Tareas ===
        private void BuildLogPanel()
        {
            LogPanelContainer = new Panel { Dock = DockStyle.Fill };

            BtnLogTitle = new Button
            {
                Text = "Registro ▼",
                Dock = DockStyle.Top,
                Height = 28,
                FlatStyle = FlatStyle.Flat
            };
            BtnLogTitle.FlatAppearance.BorderSize = 0;

            LogMenu = new ContextMenuStrip();
            // Sin handlers aquí; UIX se encargará de .Click para alternar layouts.
            LogMenu.Items.Add("Ver Log");
            LogMenu.Items.Add("Gestión de Tareas");

            // Controles de Log (se agregan por ShowLogLayout)
            TbLog = new TextBox
            {
                Dock = DockStyle.Fill,
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                ReadOnly = true,
                BorderStyle = BorderStyle.FixedSingle,
                BackColor = Styl.BgInput,
                Font = FontMono
            };

            // Controles de Tareas (se agregan por ShowTaskLayout)
            TaskLayout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 3,
                AutoScroll = true
            };
            TaskLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20F));
            TaskLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 60F));
            TaskLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20F));

            LogPanelContainer.Controls.Add(BtnLogTitle);
            SplitTop.Panel1.Controls.Add(LogPanelContainer);
        }

        // Layout por defecto: muestra el TextBox de log
        public void ShowLogLayout()
        {
            LogPanelContainer.SuspendLayout();
            LogPanelContainer.Controls.Clear();

            // Header button + log textbox
            LogPanelContainer.Controls.Add(BtnLogTitle);
            LogPanelContainer.Controls.Add(TbLog);

            LogPanelContainer.ResumeLayout();
        }

        // Layout alternativo: muestra el gestor de tareas
        // Nota: NO crea un botón de 'Crear nueva tarea' por defecto; el llamador debe inyectarlo.
        public void ShowTaskLayout(Button btnNewTask)
        {
            if (btnNewTask == null) throw new ArgumentNullException(nameof(btnNewTask));

            LogPanelContainer.SuspendLayout();
            LogPanelContainer.Controls.Clear();

            // Botón “Crear nueva tarea” será el suministrado por la capa superior (UIX)
            var bottomButton = btnNewTask;
            bottomButton.Dock = DockStyle.Bottom;
            bottomButton.Height = 30;

            LogPanelContainer.Controls.Add(TaskLayout);
            LogPanelContainer.Controls.Add(bottomButton);
            LogPanelContainer.Controls.Add(BtnLogTitle);

            LogPanelContainer.ResumeLayout();
        }

        // === Panel derecho: Stats + Monitor ===
        private void BuildRightPanel()
        {
            RightPanel = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 2
            };
            RightPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 60F));
            RightPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 40F));
            SplitTop.Panel2.Controls.Add(RightPanel);

            BuildStats();
            BuildMonitor();
        }

        private void BuildStats()
        {
            GbStats = new GroupBox
            {
                Text = " Estadísticas ",
                Dock = DockStyle.Fill,
                Font = FontDefault,
                ForeColor = Styl.TextDefault
            };

            var statsLayout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 6,
                AutoSize = true
            };
            statsLayout.RowStyles.Clear();
            for (int i = 0; i < 6; i++)
                statsLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            LblScriptsTotal = NewStatLabel("Scripts cargados: 0");
            LblScriptsSelected = NewStatLabel("Seleccionados: 0");
            LblRunning = NewStatLabel("Procesos activos: 0");
            LblCompleted = NewStatLabel("Completados: 0");
            LblErrors = NewStatLabel("Errores: 0");
            LblLastAction = NewStatLabel("Última acción: —");

            statsLayout.Controls.Add(LblScriptsTotal, 0, 0);
            statsLayout.Controls.Add(LblScriptsSelected, 0, 1);
            statsLayout.Controls.Add(LblRunning, 0, 2);
            statsLayout.Controls.Add(LblCompleted, 0, 3);
            statsLayout.Controls.Add(LblErrors, 0, 4);
            statsLayout.Controls.Add(LblLastAction, 0, 5);

            GbStats.Controls.Add(statsLayout);
            RightPanel.Controls.Add(GbStats, 0, 0);
        }

        private Label NewStatLabel(string text)
        {
            return new Label
            {
                Text = text,
                AutoSize = true,
                ForeColor = Styl.TextDefault
            };
        }

        private void BuildMonitor()
        {
            GbMonitor = new GroupBox
            {
                Text = " Monitor del sistema ",
                Dock = DockStyle.Fill,
                Font = FontDefault,
                ForeColor = Styl.TextDefault
            };

            var monitorLayout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 2,
                AutoSize = true
            };
            monitorLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            monitorLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            monitorLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            monitorLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            var lblCPU = new Label { Text = "CPU", AutoSize = true, Anchor = AnchorStyles.Left };
            PbCPU = new ProgressBar { Dock = DockStyle.Fill };

            var lblRAM = new Label { Text = "RAM", AutoSize = true, Anchor = AnchorStyles.Left };
            PbRAM = new ProgressBar { Dock = DockStyle.Fill };

            monitorLayout.Controls.Add(lblCPU, 0, 0);
            monitorLayout.Controls.Add(PbCPU, 1, 0);
            monitorLayout.Controls.Add(lblRAM, 0, 1);
            monitorLayout.Controls.Add(PbRAM, 1, 1);

            GbMonitor.Controls.Add(monitorLayout);
            RightPanel.Controls.Add(GbMonitor, 0, 1);
        }

        // === Panel inferior: Árbol ===
        private void BuildTreePanel()
        {
            GbTree = new GroupBox
            {
                Text = " Scripts disponibles ",
                Dock = DockStyle.Fill,
                Font = FontDefault,
                ForeColor = Styl.TextDefault
            };
            SplitMain.Panel2.Controls.Add(GbTree);

            Tree = new TreeView
            {
                Dock = DockStyle.Fill,
                CheckBoxes = true,
                HideSelection = false,
                BorderStyle = BorderStyle.FixedSingle,
                BackColor = Styl.BgInput,
                Font = FontDefault,
                ShowLines = true,
                ShowRootLines = true
            };
            Tree.ShowNodeToolTips = true;
            GbTree.Controls.Add(Tree);
        }

        // === Botonera inferior ===
        private void BuildButtons()
        {
            BtnPanel = new Panel
            {
                Dock = DockStyle.Bottom,
                Height = 44,
                BackColor = Styl.BgPanel
            };
            ContentPanel.Controls.Add(BtnPanel);

            var tlp = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 5,
                RowCount = 1,
                Padding = new Padding(6)
            };
            tlp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            tlp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20F));
            tlp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            tlp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 15F));
            tlp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 15F));
            BtnPanel.Controls.Add(tlp);

            BtnRun = NewStyledButton("Ejecutar seleccionados");
            BtnRefresh = NewStyledButton("Refrescar");
            BtnSelectFolder = NewStyledButton("Seleccionar carpeta");
            BtnDocs = NewStyledButton("Documentación");
            BtnDocs.Size = new Size(100, 30);
            BtnClose = NewStyledButton("Cerrar");

            tlp.Controls.Add(BtnRun, 0, 0);
            tlp.Controls.Add(BtnRefresh, 1, 0);
            tlp.Controls.Add(BtnSelectFolder, 2, 0);
            tlp.Controls.Add(BtnDocs, 3, 0);
            tlp.Controls.Add(BtnClose, 4, 0);
        }

        private Button NewStyledButton(string text)
        {
            var btn = new Button
            {
                Text = text,
                Size = new Size(190, 30),
                FlatStyle = FlatStyle.Flat,
                BackColor = Styl.BtnPrimary,
                ForeColor = Color.White
            };
            btn.FlatAppearance.BorderSize = 0;
            btn.FlatAppearance.MouseOverBackColor = Styl.BtnPrimaryHover;
            return btn;
        }

        // === Status bar ===
        private void BuildStatusBar()
        {
            Status = new StatusStrip
            {
                SizingGrip = false,
                BackColor = Styl.StatusBg,
                ForeColor = Styl.StatusText
            };

            SslPath = new ToolStripStatusLabel
            {
                Text = $"Ruta: {AppContext.BaseDirectory}",
                Spring = true
            };

            SslStatus = new ToolStripStatusLabel
            {
                Text = "Listo"
            };

            // No asignamos DateTime.Now aquí; la capa de monitor/Control actualizará SslTime periódicamente
            SslTime = new ToolStripStatusLabel
            {
                Text = string.Empty,
                BorderSides = ToolStripStatusLabelBorderSides.Left,
                BorderStyle = Border3DStyle.Raised
            };

            Status.Items.Add(SslPath);
            Status.Items.Add(SslStatus);
            Status.Items.Add(SslTime);
            Form.Controls.Add(Status);
        }

        // Utilidad de estilo para nodos de carpeta (UIX puede usarla al crear nodos)
        public void ApplyFolderNodeStyle(TreeNode node)
        {
            if (node == null) return;
            node.NodeFont = FontNodeFolder;
        }
    }
}
