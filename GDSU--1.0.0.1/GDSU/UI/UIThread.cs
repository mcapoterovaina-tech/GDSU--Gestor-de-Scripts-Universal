using System;
using System.Windows.Forms;

namespace GDSU.Utils
{
    /// <summary>
    /// Helper estático responsable únicamente de ejecutar acciones en el hilo de UI de forma segura.
    /// No realiza logging, I/O ni cualquier otra responsabilidad.
    /// </summary>
    public static class UIThread
    {
        /// <summary>
        /// Ejecuta la acción en el hilo de la UI asociado al control.
        /// Si el control está dispuesto o no existe, la acción se ignora.
        /// </summary>
        public static void SafeInvoke(Control? control, Action action)
        {
            if (action == null) return;
            if (control == null) return;
            if (control.IsDisposed || control.Disposing) return;

            if (control.InvokeRequired)
            {
                try { control.BeginInvoke((Action)(() => TryRun(action))); }
                catch { /* ignorar fallos de invocación */ }
            }
            else
            {
                TryRun(action);
            }
        }

        /// <summary>
        /// Intenta ejecutar la acción protegiendo contra excepciones no controladas.
        /// </summary>
        private static void TryRun(Action action)
        {
            try { action(); }
            catch { /* la UI no debe fallar por excepciones aquí; ignorar */ }
        }

        /// <summary>
        /// Ejecuta la acción en el hilo de la UI asociado al formulario.
        /// Comodidad cuando se maneja Form en lugar de Control.
        /// </summary>
        public static void SafeInvoke(Form? form, Action action)
        {
            SafeInvoke(form as Control, action);
        }

        /// <summary>
        /// Intenta ejecutar la función en el hilo de UI y devuelve su resultado.
        /// Si no es posible invocar o ocurre error, devuelve default(T).
        /// </summary>
        public static T? SafeInvoke<T>(Control? control, Func<T> func)
        {
            if (func == null) return default;
            if (control == null) return default;
            if (control.IsDisposed || control.Disposing) return default;

            try
            {
                if (control.InvokeRequired)
                {
                    var result = control.Invoke((Func<T>)(() =>
                    {
                        try { return func(); }
                        catch { return default; }
                    }));
                    return result is T t ? t : default;
                }
                else
                {
                    return func();
                }
            }
            catch
            {
                return default;
            }
        }

        /// <summary>
        /// Ejecuta la función en el hilo de UI asociado al formulario y devuelve su resultado.
        /// </summary>
        public static T? SafeInvoke<T>(Form? form, Func<T> func)
        {
            return SafeInvoke<T>(form as Control, func);
        }
    }
}
