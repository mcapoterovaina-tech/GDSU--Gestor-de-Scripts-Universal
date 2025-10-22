using System;
using System.Windows.Forms;

namespace GDSU.Services
{
    /// <summary>
    /// Abstracción responsable únicamente de mostrar diálogos al usuario.
    /// No contiene lógica de negocio ni accede a ficheros directamente.
    /// Provee una interfaz para facilitar pruebas y desacoplar UIX/AppController.
    /// </summary>
    public interface IDialogService
    {
        bool TryPickFolder(string? initialPath, out string? selectedPath);
        void ShowDocument(Form? owner, Form docForm);
        void ShowInfo(string title, string message);
        bool Confirm(string title, string message);
    }

    /// <summary>
    /// Implementación concreta basada en los diálogos de WinForms.
    /// Mantiene la responsabilidad única de interacción modal básica.
    /// </summary>
    public class DialogService : IDialogService
    {
        public bool TryPickFolder(string? initialPath, out string? selectedPath)
        {
            selectedPath = null;
            try
            {
                using var dlg = new FolderBrowserDialog
                {
                    Description = "Selecciona la carpeta raíz de scripts",
                    SelectedPath = string.IsNullOrWhiteSpace(initialPath) ? Environment.CurrentDirectory : initialPath,
                    ShowNewFolderButton = true
                };

                var res = dlg.ShowDialog();
                if (res == DialogResult.OK || res == DialogResult.Yes)
                {
                    selectedPath = dlg.SelectedPath;
                    return true;
                }
                return false;
            }
            catch
            {
                selectedPath = null;
                return false;
            }
        }

        public void ShowDocument(Form? owner, Form docForm)
        {
            if (docForm == null) return;
            try
            {
                if (owner == null || owner.IsDisposed)
                    docForm.ShowDialog();
                else
                    docForm.ShowDialog(owner);
            }
            catch
            {
                try { docForm.ShowDialog(); } catch { /* ignore */ }
            }
        }

        public void ShowInfo(string title, string message)
        {
            try
            {
                MessageBox.Show(message, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch { /* ignore UI failures */ }
        }

        public bool Confirm(string title, string message)
        {
            try
            {
                var res = MessageBox.Show(message, title, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                return res == DialogResult.Yes;
            }
            catch { return false; }
        }
    }
}
