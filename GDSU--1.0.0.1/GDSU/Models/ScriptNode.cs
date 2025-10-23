using System;
using System.Collections.Generic;

namespace GDSU.Models
{
    /// <summary>
    /// Representa un nodo en el árbol de scripts.
    /// Puede ser una carpeta (IsFolder = true) que contiene Children,
    /// o un archivo (IsFolder = false) que normalmente es una hoja.
    /// Esta clase es un simple DTO sin lógica de IO ni UI.
    /// </summary>
    [Serializable]
    public class ScriptNode
    {
        /// <summary>
        /// Nombre del archivo o carpeta (ej: "mantenimiento" o "backup.ps1").
        /// </summary>
        public string Name { get; set; } = string.Empty;

        /// <summary>
        /// Ruta completa en disco (ej: "C:\proyecto\scripts\mantenimiento").
        /// </summary>
        public string FullPath { get; set; } = string.Empty;

        /// <summary>
        /// True si el nodo representa una carpeta; false si es un archivo/script.
        /// </summary>
        public bool IsFolder { get; set; }

        /// <summary>
        /// Hijos del nodo. Solo tiene elementos cuando IsFolder == true.
        /// Puede ser null para ahorrar memoria si no se usan children.
        /// </summary>
        public List<ScriptNode>? Children { get; set; }

        /// <summary>
        /// Marca de tiempo opcional de última modificación. Nulo si no se conoce.
        /// </summary>
        public DateTime? LastModifiedUtc { get; set; }

        /// <summary>
        /// Tamaño en bytes del archivo si aplica. Nulo si no se conoce o si es carpeta.
        /// </summary>
        public long? SizeBytes { get; set; }

        /// <summary>
        /// Etiquetas arbitrarias para extensiones futuras (metadata ligera).
        /// </summary>
        public Dictionary<string, string>? Tags { get; set; }

        /// <summary>
        /// Devuelve true si es hoja (archivo sin hijos).
        /// </summary>
        public bool IsLeaf => !IsFolder || (Children == null || Children.Count == 0);

        public ScriptNode() { }

        public ScriptNode(string name, string fullPath, bool isFolder)
        {
            Name = name ?? string.Empty;
            FullPath = fullPath ?? string.Empty;
            IsFolder = isFolder;
            if (isFolder) Children = new List<ScriptNode>();
        }

        public override string ToString()
        {
            return IsFolder ? $"[Folder] {Name}" : $"[File] {Name}";
        }
    }
}
