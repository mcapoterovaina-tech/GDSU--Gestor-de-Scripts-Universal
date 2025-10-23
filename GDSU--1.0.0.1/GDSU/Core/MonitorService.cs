using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using GDSU.Services;

namespace GDSU.Core
{
    /// <summary>
    /// Servicio responsable únicamente de medir CPU y RAM periódicamente y publicar muestras.
    /// SRP: no escribe en UI ni en logs, no conoce consumidores; expone Start/Stop y evento OnSample.
    /// Implementa IMonitorService (contrato pequeño en Services/Contracts.cs).
    /// </summary>
    public class MonitorService : IMonitorService, IDisposable
    {
        private readonly int _intervalMs;
        private CancellationTokenSource? _cts;
        private Task? _loop;
        private volatile bool _disposed;

        // PerformanceCounter fields created lazily; can be null on unsupported platforms or failure.
        private PerformanceCounter? _cpuCounter;
        private PerformanceCounter? _ramCounter;

        /// <summary>
        /// Evento que publica muestras periódicas: cpu% (0-100), ram% (0-100).
        /// </summary>
        public event Action<int, int>? OnSample;

        /// <summary>
        /// Crea un MonitorService.
        /// intervalMs: periodo de muestreo en milisegundos (por defecto 2000).
        /// </summary>
        public MonitorService(int intervalMs = 2000)
        {
            _intervalMs = Math.Max(200, intervalMs);
            TryCreateCounters();
        }

        private void TryCreateCounters()
        {
            try
            {
                // Crear PerformanceCounter solo si la plataforma lo soporta.
                _cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total", readOnly: true);
                _ramCounter = new PerformanceCounter("Memory", "% Committed Bytes In Use", readOnly: true);

                // Primer NextValue para inicializar; puede lanzar en entornos con permisos distintos.
                try { _cpuCounter.NextValue(); } catch { /* ignore initial read errors */ }
                try { _ramCounter.NextValue(); } catch { /* ignore initial read errors */ }
            }
            catch
            {
                // Falla la creación de contadores: dejamos null y el servicio seguirá emitiendo 0s.
                _cpuCounter = null;
                _ramCounter = null;
            }
        }

        /// <summary>
        /// Inicia el loop de muestreo. Llamadas redundantes son ignoradas.
        /// </summary>
        public void Start()
        {
            if (_disposed) throw new ObjectDisposedException(nameof(MonitorService));
            if (_loop != null && !_loop.IsCompleted) return;

            _cts = new CancellationTokenSource();
            var token = _cts.Token;
            _loop = Task.Run(async () =>
            {
                while (!token.IsCancellationRequested)
                {
                    try
                    {
                        int cpu = ReadPercentSafe(_cpuCounter);
                        int ram = ReadPercentSafe(_ramCounter);

                        try { OnSample?.Invoke(cpu, ram); } catch { /* do not let subscribers break loop */ }
                    }
                    catch
                    {
                        // swallow any transient errors inside loop to keep it running
                    }

                    try { await Task.Delay(_intervalMs, token).ConfigureAwait(false); } catch (TaskCanceledException) { break; }
                }
            }, token);
        }

        /// <summary>
        /// Detiene el loop de muestreo y libera el token. Puede volver a Start() después de Stop().
        /// </summary>
        public void Stop()
        {
            try
            {
                if (_cts != null && !_cts.IsCancellationRequested)
                {
                    _cts.Cancel();
                }
            }
            catch { /* ignore */ }

            try
            {
                _loop?.Wait(500);
            }
            catch { /* ignore */ }

            try
            {
                _cts?.Dispose();
            }
            catch { /* ignore */ }

            _cts = null;
            _loop = null;
        }

        private static int ReadPercentSafe(PerformanceCounter? counter)
        {
            if (counter == null) return 0;
            try
            {
                // NextValue can return floats; clamp to 0..100 and cast to int
                var val = counter.NextValue();
                if (float.IsNaN(val) || float.IsInfinity(val)) return 0;
                var i = (int)Math.Round(val);
                if (i < 0) i = 0;
                if (i > 100) i = 100;
                return i;
            }
            catch
            {
                return 0;
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            Stop();
            try { _cpuCounter?.Dispose(); } catch { }
            try { _ramCounter?.Dispose(); } catch { }
        }
    }
}
