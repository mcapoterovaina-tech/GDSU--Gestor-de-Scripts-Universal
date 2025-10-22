using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using GDSU.Models;
using GDSU.Utils;

namespace GDSU.Core
{
    /// <summary>
    /// Responsable de cargar la estructura de carpetas y scripts desde disco.
    /// Devuelve una lista de ScriptNode (carpetas con sus scripts).
    /// No realiza I/O fuera de leer el filesystem y no tiene dependencias UI.
    /// </summary>
    public class ScriptTreeLoader
    {
        private readonly Action<string>? _onLog;
        private readonly string[] _acceptedExtensions = new[] { ".bat", ".ps1" };

        /// <summary>
        /// Crea un loader. Opcionalmente recibe un callback para reportar errores o mensajes.
        /// </summary>
        public ScriptTreeLoader(Action<string>? onLog = null)
        {
            _onLog = onLog;
        }

        /// <summary>
        /// Carga solo las carpetas directas (nivel 1) de la raíz y los scripts aceptados dentro de cada una.
        /// Retorna una colección de ScriptNode representando carpetas; cada carpeta incluye sus scripts como hijos.
        /// Si la ruta raíz no existe, devuelve una secuencia vacía.
        /// </summary>
        public IEnumerable<ScriptNode> LoadRoot(string rootPath)
        {
            if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
            {
                _onLog?.Invoke($"ERROR: Ruta raíz inválida: {rootPath}");
                return Enumerable.Empty<ScriptNode>();
            }

            var result = new List<ScriptNode>();

            foreach (var dir in SafeEnumerateDirectories(rootPath))
            {
                try
                {
                    var dirInfo = new DirectoryInfo(dir);
                    if (!dirInfo.Exists) continue;

                    var folderNode = new ScriptNode
                    {
                        Name = dirInfo.Name,
                        FullPath = dirInfo.FullName,
                        IsFolder = true
                    };

                    var files = SafeEnumerateFiles(dirInfo.FullName)
                                .Select(p => new FileInfo(p))
                                .Where(fi => fi.Exists && _acceptedExtensions.Contains(fi.Extension, StringComparer.OrdinalIgnoreCase))
                                .ToList();

                    foreach (var file in files)
                    {
                        var child = new ScriptNode
                        {
                            Name = file.Name,
                            FullPath = file.FullName,
                            IsFolder = false
                        };
                        // You could add children list on ScriptNode if needed; keep simple
                        result.Add(child); // Note: if you want folder->children tree, adapt below
                    }

                    // If you prefer to return folder nodes with children, build accordingly:
                    // (Below we append folder node only if it has scripts to keep parity with original behavior)
                    if (files.Any())
                    {
                        // attach children on folder node (if ScriptNode later supports a Children collection)
                        result.Add(new ScriptNode
                        {
                            Name = dirInfo.Name,
                            FullPath = dirInfo.FullName,
                            IsFolder = true
                        });
                    }
                }
                catch (Exception ex)
                {
                    _onLog?.Invoke($"Error leyendo carpeta {dir} -> {ex.Message}");
                }
            }

            // The original MainForm expected folder nodes each containing child nodes.
            // For flexibility, return a flat list of folder ScriptNode entries; callers can re-enumerate files if needed.
            return result;
        }

        /// <summary>
        /// Enumerates directories safely using SafeIO; reports errors via _onLog.
        /// </summary>
        private IEnumerable<string> SafeEnumerateDirectories(string path)
        {
            try
            {
                return SafeIO.EnumerateDirectories(path, msg => _onLog?.Invoke(msg));
            }
            catch (Exception ex)
            {
                _onLog?.Invoke($"Error enumerando subcarpetas de {path} -> {ex.Message}");
                return Enumerable.Empty<string>();
            }
        }

        /// <summary>
        /// Enumerates files safely using SafeIO; reports errors via _onLog.
        /// </summary>
        private IEnumerable<string> SafeEnumerateFiles(string path)
        {
            try
            {
                return SafeIO.EnumerateFiles(path, msg => _onLog?.Invoke(msg));
            }
            catch (Exception ex)
            {
                _onLog?.Invoke($"Error enumerando archivos de {path} -> {ex.Message}");
                return Enumerable.Empty<string>();
            }
        }
    }
}
