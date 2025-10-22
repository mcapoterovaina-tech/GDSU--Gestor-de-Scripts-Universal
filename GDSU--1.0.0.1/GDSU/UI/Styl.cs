using System.Drawing;

namespace GDSU.UI
{
    /// <summary>
    /// Clase responsable únicamente de exponer paleta de colores y tipografías usadas por la UI.
    /// No contiene lógica, I/O ni dependencias externas.
    /// </summary>
    public static class Styl
    {
        // Colores de la aplicación
        public static readonly Color BgApp = Color.FromArgb(245, 248, 250);
        public static readonly Color BgPanel = Color.FromArgb(252, 253, 254);
        public static readonly Color BgHeader = Color.FromArgb(28, 42, 66);
        public static readonly Color BgInput = Color.FromArgb(248, 250, 252);

        // Botones
        public static readonly Color BtnPrimary = Color.FromArgb(52, 152, 219);
        public static readonly Color BtnPrimaryHover = Color.FromArgb(41, 128, 185);

        // Texto / estado
        public static readonly Color TextDefault = Color.FromArgb(50, 60, 70);
        public static readonly Color StatusBg = Color.FromArgb(236, 240, 244);
        public static readonly Color StatusText = Color.FromArgb(60, 70, 80);

        // Tipografías (expuestas para reutilización; creación ligera aquí)
        public static readonly Font FontDefault = new Font("Segoe UI", 9f);
        public static readonly Font FontHeader = new Font("Segoe UI Semibold", 12.5f);
        public static readonly Font FontMono = new Font("Consolas", 9f);
        public static readonly Font FontNodeFolder = new Font("Segoe UI Semibold", 9f);

        // Valores comunes de layout (opcional, facilitar consistencia)
        public const int HeaderHeight = 52;
        public const int ButtonHeight = 30;
        public const int BottomPanelHeight = 44;
    }
}
