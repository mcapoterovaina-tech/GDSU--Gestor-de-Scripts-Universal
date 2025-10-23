using System;
using System.Diagnostics;
using GDSU.Services;

namespace GDSU.Services
{
    /// <summary>
    /// Servicio responsable únicamente de iniciar procesos y publicar sus salidas y salida final.
    /// Cumple SRP: no toma decisiones de negocio ni actualiza UI, solo encapsula Process lifecycle y eventos.
    /// </summary>
    public class ProcessService : IProcessService, IDisposable
    {
        public event Action<int, string, bool>? OnOutput;
        public event Action<int, int?>? OnExited;

        private bool _disposed;

        public ProcessService() { }

        /// <summary>
        /// Inicia un proceso con el ProcessStartInfo proporcionado. Devuelve Process o null si no pudo iniciarse.
        /// El proceso queda manejado por el caller; this service subscribe a sus eventos y reenvía información.
        /// </summary>
        public Process? Start(ProcessStartInfo psi)
        {
            if (psi == null) throw new ArgumentNullException(nameof(psi));

            // Asegurar redirección cuando se desee captura
            var copy = CopyStartInfo(psi);

            Process? proc = null;
            try
            {
                proc = Process.Start(copy);
                if (proc == null) return null;

                // Hook events early
                try
                {
                    proc.EnableRaisingEvents = true;

                    proc.OutputDataReceived += (s, e) =>
                    {
                        if (e?.Data != null)
                        {
                            try { OnOutput?.Invoke(proc.Id, e.Data, false); } catch { }
                        }
                    };

                    proc.ErrorDataReceived += (s, e) =>
                    {
                        if (e?.Data != null)
                        {
                            try { OnOutput?.Invoke(proc.Id, e.Data, true); } catch { }
                        }
                    };

                    proc.Exited += (s, e) =>
                    {
                        int pid = -1;
                        int? code = null;
                        try { pid = proc.Id; } catch { }
                        try { if (proc.HasExited) code = proc.ExitCode; } catch { }
                        try { OnExited?.Invoke(pid, code); } catch { }
                    };

                    // Begin async reads only if redirected
                    try { if (copy.RedirectStandardOutput) proc.BeginOutputReadLine(); } catch { }
                    try { if (copy.RedirectStandardError) proc.BeginErrorReadLine(); } catch { }
                }
                catch
                {
                    // If hooking fails, still return the process, caller may dispose/handle it.
                }

                return proc;
            }
            catch
            {
                try { proc?.Dispose(); } catch { }
                return null;
            }
        }

        private static ProcessStartInfo CopyStartInfo(ProcessStartInfo src)
        {
            // Create a shallow copy to avoid modifying caller's object
            var dst = new ProcessStartInfo
            {
                FileName = src.FileName,
                Arguments = src.Arguments,
                WorkingDirectory = src.WorkingDirectory,
                UseShellExecute = src.UseShellExecute,
                CreateNoWindow = src.CreateNoWindow,
                RedirectStandardOutput = src.RedirectStandardOutput,
                RedirectStandardError = src.RedirectStandardError,
                WindowStyle = src.WindowStyle,
                Verb = src.Verb,
            };

            // Preserve environment only if explicitly set
            try
            {
                foreach (var k in src.EnvironmentVariables.Keys)
                {
                    var key = k as string;
                    if (key != null && src.EnvironmentVariables[key] is string v)
                        dst.EnvironmentVariables[key] = v;
                }
            }
            catch { /* ignore environment copy failures */ }

            return dst;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            // No global resources to free for now
        }
    }
}
