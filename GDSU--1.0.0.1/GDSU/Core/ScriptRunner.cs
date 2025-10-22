using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using GDSU.Models;

namespace GDSU.Core
{
    /// <summary>
    /// Orquesta el arranque de procesos (scripts), captura stdout/stderr y emite eventos.
    /// Responsabilidad única: gestión y observación de procesos en ejecución.
    /// </summary>
    public class ScriptRunner : IDisposable
    {
        private readonly ConcurrentDictionary<int, ScriptProcessInfo> _running = new ConcurrentDictionary<int, ScriptProcessInfo>();
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private bool _disposed;

        /// <summary>
        /// Evento: una línea de salida estándar o de error del proceso.
        /// </summary>
        public event Action<int, string, bool>? OnOutput; // pid, text, isError

        /// <summary>
        /// Evento: proceso arrancado (pid, path).
        /// </summary>
        public event Action<int, string>? OnStarted;

        /// <summary>
        /// Evento: proceso finalizado (pid, exitCode).
        /// </summary>
        public event Action<int, int?>? OnExited;

        /// <summary>
        /// Inicia múltiples scripts en paralelo. Devuelve cuando todos los inicios han sido solicitados.
        /// </summary>
        /// <param name="scriptFiles">Rutas completas a scripts</param>
        /// <param name="getStartInfo">Opcional: función para construir ProcessStartInfo por archivo.
        /// Si es null, se usa un StartInfo por extensión (.bat → cmd /c, .ps1 → powershell -File)</param>
        public Task StartManyAsync(IEnumerable<string> scriptFiles, Func<string, ProcessStartInfo?>? getStartInfo = null)
        {
            if (scriptFiles == null) throw new ArgumentNullException(nameof(scriptFiles));
            return Task.Run(() => StartManyInternal(scriptFiles, getStartInfo, _cts.Token), _cts.Token);
        }

        private void StartManyInternal(IEnumerable<string> scriptFiles, Func<string, ProcessStartInfo?>? getStartInfo, CancellationToken token)
        {
            foreach (var path in scriptFiles)
            {
                if (token.IsCancellationRequested) break;
                if (string.IsNullOrWhiteSpace(path)) continue;
                if (!File.Exists(path)) continue;

                var startInfo = getStartInfo?.Invoke(path) ?? DefaultStartInfoFor(path);
                if (startInfo == null) continue;

                try
                {
                    var proc = Process.Start(startInfo);
                    if (proc == null) continue;

                    // Prepare process info and register
                    var info = new ScriptProcessInfo
                    {
                        Path = path,
                        Ext = Path.GetExtension(path),
                        StartTime = DateTime.Now,
                        Pid = TryGetPid(proc)
                    };
                    if (info.Pid.HasValue)
                        _running[info.Pid.Value] = info;

                    // Begin capture output
                    try
                    {
                        proc.EnableRaisingEvents = true;

                        proc.OutputDataReceived += (s, e) =>
                        {
                            if (e?.Data != null)
                                OnOutput?.Invoke(TryGetPidSafe(proc), e.Data, false);
                        };
                        proc.ErrorDataReceived += (s, e) =>
                        {
                            if (e?.Data != null)
                                OnOutput?.Invoke(TryGetPidSafe(proc), e.Data, true);
                        };

                        try { proc.BeginOutputReadLine(); } catch { /* ignore */ }
                        try { proc.BeginErrorReadLine(); } catch { /* ignore */ }

                        proc.Exited += (s, e) =>
                        {
                            var exitedProc = s as Process;
                            var pid = TryGetPidSafe(exitedProc);
                            int? code = null;
                            try { if (exitedProc != null && !exitedProc.HasExited) exitedProc.WaitForExit(100); } catch { }
                            try { if (exitedProc != null && exitedProc.HasExited) code = exitedProc.ExitCode; } catch { }
                            // update info
                            if (pid > 0 && _running.TryRemove(pid, out var pi))
                            {
                                pi.EndTime = DateTime.Now;
                                pi.ExitCode = code;
                            }
                            OnExited?.Invoke(pid, code);
                            try { exitedProc?.Dispose(); } catch { /* ignore */ }
                        };
                    }
                    catch
                    {
                        // If hooking fails, still notify started and continue
                    }

                    OnStarted?.Invoke(info.Pid ?? -1, path);
                }
                catch (Exception)
                {
                    // Swallow to keep runner robust; external caller may handle logging via events
                }
            }
        }

        /// <summary>
        /// Intenta cancelar todos los procesos iniciados por este runner enviando Kill.
        /// No garantiza que procesos externos no hayan sido creados por los scripts.
        /// </summary>
        public void CancelAll()
        {
            foreach (var kv in _running)
            {
                try
                {
                    var pid = kv.Key;
                    // Try to find process and kill
                    try
                    {
                        var p = Process.GetProcessById(pid);
                        if (!p.HasExited)
                        {
                            try { p.Kill(); } catch { /* ignore */ }
                        }
                        try { p.Dispose(); } catch { }
                    }
                    catch { /* process may have exited or not accessible */ }
                }
                catch { /* ignore */ }
            }
            _running.Clear();
            _cts.Cancel();
        }

        /// <summary>
        /// Attempts to get a current snapshot of running processes tracked by this runner.
        /// </summary>
        public IReadOnlyCollection<ScriptProcessInfo> GetRunningProcessesSnapshot()
        {
            return _running.Values;
        }

        private static int TryGetPidSafe(Process? p)
        {
            try { return TryGetPid(p) ?? -1; }
            catch { return -1; }
        }

        private static int? TryGetPid(Process? p)
        {
            try
            {
                if (p == null) return null;
                return p.Id;
            }
            catch
            {
                return null;
            }
        }

        private static ProcessStartInfo? DefaultStartInfoFor(string path)
        {
            var ext = Path.GetExtension(path)?.ToLowerInvariant();
            if (string.IsNullOrEmpty(ext)) return null;

            switch (ext)
            {
                case ".bat":
                    return new ProcessStartInfo
                    {
                        FileName = "cmd.exe",
                        Arguments = $"/c \"{path}\"",
                        WorkingDirectory = Path.GetDirectoryName(path) ?? Environment.CurrentDirectory,
                        UseShellExecute = false,
                        CreateNoWindow = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        WindowStyle = ProcessWindowStyle.Normal
                    };
                case ".ps1":
                    return new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = $"-ExecutionPolicy Bypass -NoLogo -NoProfile -File \"{path}\"",
                        WorkingDirectory = Path.GetDirectoryName(path) ?? Environment.CurrentDirectory,
                        UseShellExecute = false,
                        CreateNoWindow = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        WindowStyle = ProcessWindowStyle.Normal
                    };
                default:
                    return null;
            }
        }

        /// <summary>
        /// Dispose pattern to free resources.
        /// </summary>
        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try { _cts.Cancel(); } catch { }
            try { CancelAll(); } catch { }
            try { _cts.Dispose(); } catch { }
        }
    }
}
