using System;
using System.Windows.Forms;
using GDSU.UI;

namespace GDSU
{
    public class MainForm : Form
    {
        private readonly UIBuilder ui;
        private readonly UIX uix;

        public MainForm()
        {
            // Construir UI (UIBuilder crea y añade los controles al Form)
            ui = new UIBuilder();
            ui.Build(this);

            // Conectar la lógica e interacción (UIX suscribe eventos sobre los controles creados)
            uix = new UIX(ui, AppContext.BaseDirectory);

            // Mantener comportamiento de teclas rápidas
            if (ui.BtnRun != null) AcceptButton = ui.BtnRun;
            if (ui.BtnClose != null) CancelButton = ui.BtnClose;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { uix?.Dispose(); } catch { /* ignorar errores de limpieza */ }
            }
            base.Dispose(disposing);
        }
    }
}
