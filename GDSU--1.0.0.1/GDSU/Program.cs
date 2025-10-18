namespace GDSU;

static class Program
{
    /// <summary>
    ///  The main entry point for the application.
    /// </summary>
    [STAThread]
    static void Main()
    {
        // Inicializa configuración de la app (DPI, fuentes, etc.)
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}
