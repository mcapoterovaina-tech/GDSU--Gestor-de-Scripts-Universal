using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using GDSU.Models;
using GDSU.Services;

namespace GDSU.Core
{
    /// <summary>
    /// Orquesta el arranque de procesos (scripts) delegando el inicio y la captura de I/O a IProcessService.
    /// Responsabilidad única: coordinar ejecuciones, mantener metadatos mínimos por proceso y reenviar eventos.
    /// </summary>
    public class ScriptRunner : IDisposable
    {
        private readonly IProcessService _processService;
        private readonly ConcurrentDictionary<int, ScriptProcessInfo> _running = new ConcurrentDictionary<int, ScriptProcessInfo>();
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private bool _disposed;

        public event Action<int, string, bool>? OnOutput; // pid, text, isError
        public event Action<int, string>? OnStarted; // pid, path
        public event Action<int, int?>? OnExited; // pid, exitCode

        public ScriptRunner(IProcessService processService)
        {
            _processService = processService ?? throw new ArgumentNullException(nameof(processService));
            _processService.OnOutput += ProcessService_OnOutput;
            _processService.OnExited += ProcessService_OnExited;
        }

        private void ProcessService_OnOutput(int pid, string line, bool isError)
        {
            try { OnOutput?.Invoke(pid, line, isError); } catch { }
        }

        private void ProcessService_OnExited(int pid, int? code)
        {
            if (pid > 0 && _running.TryRemove(pid, out var info))
            {
                info.EndTime = DateTime.UtcNow;
                info.ExitCode = code;
            }

            try { OnExited?.Invoke(pid, code); } catch { }
        }

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

                Process? proc = null;
                try
                {
                    proc = _processService.Start(startInfo);
                    if (proc == null) continue;

                    var pid = TryGetPid(proc) ?? -1;

                    var info = new ScriptProcessInfo
                    {
                        Path = path,
                        Ext = Path.GetExtension(path),
                        StartTime = DateTime.UtcNow,
                        Pid = pid
                    };

                    if (pid > 0) _running[pid] = info;

                    try { OnStarted?.Invoke(pid, path); } catch { }
                }
                catch
                {
                    try { proc?.Dispose(); } catch { }
                }
            }
        }

        public void CancelAll(bool kill = true)
        {
            _cts.Cancel();

            if (kill)
            {
                foreach (var kv in _running)
                {
                    try
                    {
                        var pid = kv.Key;
                        try
                        {
                            var p = Process.GetProcessById(pid);
                            if (!p.HasExited)
                            {
                                try { p.Kill(); } catch { }
                            }
                            try { p.Dispose(); } catch { }
                        }
                        catch { /* may have exited or not accessible */ }
                    }
                    catch { }
                }
            }

            _running.Clear();
        }

        public IReadOnlyCollection<ScriptProcessInfo> GetRunningProcessesSnapshot() => _running.Values;

        private static int? TryGetPid(Process? p)
        {
            try { return p?.Id; } catch { return null; }
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

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try { _cts.Cancel(); } catch { }
            try { CancelAll(kill: false); } catch { }
            try { _processService.OnOutput -= ProcessService_OnOutput; _processService.OnExited -= ProcessService_OnExited; } catch { }
            try { _cts.Dispose(); } catch { }
            _running.Clear();
        }
    }

    public class ScriptProcessInfo
    {
        public int Pid { get; set; } = -1;
        public string Path { get; set; } = string.Empty;
        public string? Ext { get; set; }
        public DateTime StartTime { get; set; }
        public DateTime? EndTime { get; set; }
        public int? ExitCode { get; set; }
    }
}
