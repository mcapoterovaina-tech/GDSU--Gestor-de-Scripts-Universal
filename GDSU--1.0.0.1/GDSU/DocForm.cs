using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows.Forms;

namespace GDSU
{
    public class DocForm : Form
    {
        // UI
        private Panel topBar;
        private TextBox tbSearch;
        private Button btnAddTxt;

        private SplitContainer split;
        private TreeView tvCategories;

        private Panel rightPanel;
        private Label lblTitle;
        private RichTextBox rtbContent;

        private StatusStrip status;
        private ToolStripStatusLabel sslCount;
        private ToolStripStatusLabel sslInfo;

        // Data
        private List<DocItem> docs = new();
        private string jsonPath;
        private string docsFolder;

        // Visual palette
        private readonly Color cBg = Color.White;
        private readonly Color cPanel = Color.FromArgb(248, 250, 252);
        private readonly Color cBar = Color.FromArgb(236, 240, 244);
        private readonly Color cAccent = Color.FromArgb(52, 152, 219);
        private readonly Color cAccentDark = Color.FromArgb(41, 128, 185);
        private readonly Color cText = Color.FromArgb(50, 60, 70);

        public DocForm()
        {
            Text = "Documentación - GDSU";
            Size = new Size(980, 640);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = cBg;

            jsonPath = Path.Combine(AppContext.BaseDirectory, "docs.json");
            docsFolder = Path.Combine(AppContext.BaseDirectory, "docs");

            BuildUI();
            LoadDocs();
            PopulateTree();
            UpdateStatus();
        }

        // ===== UI =====

        private void BuildUI()
        {
            // Top bar: búsqueda + agregar TXT
            topBar = new Panel
            {
                Dock = DockStyle.Top,
                Height = 48,
                BackColor = cBar,
                Padding = new Padding(10, 8, 10, 8)
            };
            Controls.Add(topBar);

            tbSearch = new TextBox
            {
                PlaceholderText = "Buscar en el documento actual...",
                Font = new Font("Segoe UI", 10),
                ForeColor = cText,
                Width = 640,
                Location = new Point(10, 10)
            };
            tbSearch.TextChanged += (s, e) => ApplySearch();
            topBar.Controls.Add(tbSearch);

            btnAddTxt = new Button
            {
                Text = "Agregar TXT",
                Font = new Font("Segoe UI", 9),
                BackColor = cAccent,
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat,
                Size = new Size(120, 30),
                Location = new Point(tbSearch.Right + 12, 9)
            };
            btnAddTxt.FlatAppearance.BorderSize = 0;
            btnAddTxt.FlatAppearance.MouseOverBackColor = cAccentDark;
            btnAddTxt.Click += (s, e) => LoadTxtFile();
            topBar.Controls.Add(btnAddTxt);

            // Split: izquierda categorías, derecha contenido
            split = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Vertical,
                SplitterDistance = 280,
                BackColor = cBg
            };
            Controls.Add(split);

            // TreeView (categorías)
            tvCategories = new TreeView
            {
                Dock = DockStyle.Fill,
                Font = new Font("Segoe UI", 9),
                HideSelection = false,
                BackColor = cPanel,
                BorderStyle = BorderStyle.None
            };
            tvCategories.AfterSelect += (s, e) =>
            {
                if (e.Node?.Tag is DocItem doc) LoadSelectedDoc(doc);
            };
            split.Panel1.Padding = new Padding(8);
            split.Panel1.BackColor = cBg;
            split.Panel1.Controls.Add(tvCategories);

            // Panel derecho: título + contenido
            rightPanel = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = cPanel,
                Padding = new Padding(16)
            };
            split.Panel2.Controls.Add(rightPanel);

            lblTitle = new Label
            {
                Text = "—",
                Font = new Font("Segoe UI Semibold", 14),
                ForeColor = cText,
                AutoSize = true,
                Location = new Point(8, 8)
            };
            rightPanel.Controls.Add(lblTitle);

            rtbContent = new RichTextBox
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                Font = new Font("Segoe UI", 10),
                BackColor = cPanel,
                BorderStyle = BorderStyle.None,
                Location = new Point(8, 40)
            };
            rightPanel.Controls.Add(rtbContent);

            // Status bar
            status = new StatusStrip
            {
                SizingGrip = false,
                BackColor = cBar
            };
            sslCount = new ToolStripStatusLabel { Text = "0 documentos" };
            sslInfo = new ToolStripStatusLabel { Text = "Listo" };
            status.Items.Add(sslCount);
            status.Items.Add(sslInfo);
            Controls.Add(status);
        }

        // ===== Data & Persistence =====

        private void LoadDocs()
        {
            // Si existe docs.json, cargarlo. Si no, importar TXT iniciales y crear JSON.
            if (File.Exists(jsonPath))
            {
                try
                {
                    var json = File.ReadAllText(jsonPath);
                    docs = JsonSerializer.Deserialize<List<DocItem>>(json) ?? new List<DocItem>();
                }
                catch
                {
                    docs = new List<DocItem>();
                }
            }
            else
            {
                ImportTxtFolderToJson(); // crea docs.json si hay .txt
            }

            // Si no hay docs, crear ejemplos
            if (docs.Count == 0)
            {
                docs = new List<DocItem>
                {
                    new DocItem { Title = "Introducción", Content = "Bienvenido a la documentación de GDSU." },
                    new DocItem { Title = "Uso Básico", Content = "Aquí van las instrucciones básicas..." },
                    new DocItem { Title = "Avanzado", Content = "Aquí van las funciones avanzadas..." }
                };
                SaveDocs();
            }
        }

        private void SaveDocs()
        {
            try
            {
                var json = JsonSerializer.Serialize(docs, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(jsonPath, json);
                sslInfo.Text = "Cambios guardados en docs.json";
            }
            catch (Exception ex)
            {
                MessageBox.Show($"No se pudo guardar docs.json:\n{ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ImportTxtFolderToJson()
        {
            try
            {
                Directory.CreateDirectory(docsFolder);
                var txtFiles = Directory.EnumerateFiles(docsFolder, "*.txt").ToList();

                if (txtFiles.Count == 0)
                {
                    // Si la carpeta está vacía, dejar que LoadDocs() cree ejemplos
                    return;
                }

                docs = new List<DocItem>();
                foreach (var f in txtFiles)
                {
                    var title = Path.GetFileNameWithoutExtension(f);
                    var content = File.ReadAllText(f);
                    docs.Add(new DocItem { Title = title, Content = content });
                }

                SaveDocs();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error importando TXT desde /docs:\n{ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // ===== Tree & Content =====

        private void PopulateTree()
        {
            tvCategories.BeginUpdate();
            tvCategories.Nodes.Clear();

            foreach (var doc in docs.OrderBy(d => d.Title))
            {
                var node = new TreeNode(doc.Title) { Tag = doc };
                tvCategories.Nodes.Add(node);
            }

            tvCategories.EndUpdate();

            if (tvCategories.Nodes.Count > 0)
            {
                tvCategories.SelectedNode = tvCategories.Nodes[0];
                LoadSelectedDoc(tvCategories.Nodes[0].Tag as DocItem);
            }

            UpdateStatus();
        }

        private void LoadSelectedDoc(DocItem? doc)
        {
            if (doc == null)
            {
                lblTitle.Text = "—";
                rtbContent.Clear();
                return;
            }

            lblTitle.Text = doc.Title;
            rtbContent.Clear();

            // Formato básico: título destacado y separación
            rtbContent.SelectionColor = cText;
            rtbContent.SelectionFont = new Font("Segoe UI", 11, FontStyle.Regular);
            rtbContent.AppendText(doc.Content);
            rtbContent.Select(0, 0);

            sslInfo.Text = $"Viendo: {doc.Title}";
        }

        // ===== Actions =====

        private void LoadTxtFile()
        {
            using var ofd = new OpenFileDialog
            {
                Filter = "Archivos de texto|*.txt",
                Title = "Selecciona un archivo TXT"
            };

            if (ofd.ShowDialog() == DialogResult.OK)
            {
                try
                {
                    string content = File.ReadAllText(ofd.FileName);
                    string title = Path.GetFileNameWithoutExtension(ofd.FileName);

                    // Evitar duplicados por título
                    var existing = docs.FirstOrDefault(d => d.Title.Equals(title, StringComparison.OrdinalIgnoreCase));
                    if (existing != null)
                    {
                        var overwrite = MessageBox.Show($"Ya existe '{title}'. ¿Deseas reemplazar su contenido?",
                                                        "Duplicado", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                        if (overwrite == DialogResult.Yes)
                        {
                            existing.Content = content;
                            SaveDocs();
                            PopulateTree();
                            SelectNodeByTitle(title);
                            MessageBox.Show("Documento actualizado en docs.json.", "OK", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        return;
                    }

                    // Agregar nuevo doc
                    docs.Add(new DocItem { Title = title, Content = content });
                    SaveDocs();
                    PopulateTree();
                    SelectNodeByTitle(title);
                    MessageBox.Show("Documento agregado y guardado en docs.json.", "OK", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"No se pudo cargar el TXT:\n{ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void SelectNodeByTitle(string title)
        {
            foreach (TreeNode node in tvCategories.Nodes)
            {
                if (string.Equals(node.Text, title, StringComparison.OrdinalIgnoreCase))
                {
                    tvCategories.SelectedNode = node;
                    tvCategories.Focus();
                    return;
                }
            }
        }

        private void ApplySearch()
        {
            // Limpiar resaltado previo
            rtbContent.Select(0, rtbContent.TextLength);
            rtbContent.SelectionBackColor = cPanel;
            rtbContent.Select(0, 0);

            string query = tbSearch.Text.Trim();
            if (string.IsNullOrEmpty(query)) return;

            // Resaltar primera coincidencia (simple, rápido)
            int index = rtbContent.Text.IndexOf(query, StringComparison.OrdinalIgnoreCase);
            if (index >= 0)
            {
                rtbContent.Select(index, query.Length);
                rtbContent.SelectionBackColor = Color.Yellow;
                rtbContent.ScrollToCaret();
                sslInfo.Text = "Coincidencia resaltada";
            }
            else
            {
                sslInfo.Text = "Sin coincidencias";
            }
        }

        private void UpdateStatus()
        {
            sslCount.Text = $"{docs.Count} documento(s)";
        }
    }

    public class DocItem
    {
        public string Title { get; set; } = "";
        public string Content { get; set; } = "";
    }
}
