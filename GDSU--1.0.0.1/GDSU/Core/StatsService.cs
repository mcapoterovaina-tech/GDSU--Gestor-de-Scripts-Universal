using System;
using System.Threading;
using GDSU.Models;

namespace GDSU.Core
{
    /// <summary>
    /// Servicio responsable únicamente de llevar contadores atómicos
    /// y producir snapshots inmutables de estado (StatsSnapshot).
    /// </summary>
    public class StatsService
    {
        private int _launched;
        private int _completed;
        private int _errors;

        /// <summary>
        /// Evento disparado cuando los contadores cambian.
        /// Provee el snapshot nuevo como argumento.
        /// </summary>
        public event Action<StatsSnapshot>? OnStatsChanged;

        /// <summary>
        /// Incrementa el contador de scripts lanzados.
        /// </summary>
        public void IncrementLaunched(int amount = 1)
        {
            if (amount <= 0) return;
            Interlocked.Add(ref _launched, amount);
            Publish();
        }

        /// <summary>
        /// Incrementa el contador de scripts completados.
        /// </summary>
        public void IncrementCompleted(int amount = 1)
        {
            if (amount <= 0) return;
            Interlocked.Add(ref _completed, amount);
            Publish();
        }

        /// <summary>
        /// Incrementa el contador de errores.
        /// </summary>
        public void IncrementErrors(int amount = 1)
        {
            if (amount <= 0) return;
            Interlocked.Add(ref _errors, amount);
            Publish();
        }

        /// <summary>
        /// Devuelve un snapshot inmutable con los valores actuales.
        /// </summary>
        public StatsSnapshot GetSnapshot(int scriptsTotal = 0, int scriptsSelected = 0, int running = 0)
        {
            // StatsSnapshot fields: total, selected, running, completed, errors
            var launched = Volatile.Read(ref _launched);
            var completed = Volatile.Read(ref _completed);
            var errors = Volatile.Read(ref _errors);

            return new StatsSnapshot(scriptsTotal, scriptsSelected, running, completed, errors);
        }

        /// <summary>
        /// Resetea los contadores a cero.
        /// </summary>
        public void Reset()
        {
            Interlocked.Exchange(ref _launched, 0);
            Interlocked.Exchange(ref _completed, 0);
            Interlocked.Exchange(ref _errors, 0);
            Publish();
        }

        /// <summary>
        /// Publica el snapshot actual a los suscriptores.
        /// ScriptsTotal / Selected / Running se deben obtener por el caller y pueden pasarse si se desea.
        /// Aquí publicamos un snapshot con zeros en campos derivados; caller puede pedir GetSnapshot con reales.
        /// </summary>
        private void Publish()
        {
            var snapshot = GetSnapshot();
            try
            {
                OnStatsChanged?.Invoke(snapshot);
            }
            catch
            {
                // no lanzar excepciones desde el servicio de estadísticas
            }
        }
    }
}
