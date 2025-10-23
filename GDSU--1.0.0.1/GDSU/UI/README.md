

# UIBuilder class overview

La clase UIBuilder construye y expone la interfaz visual de la aplicación Windows Forms. Su responsabilidad es puramente de composición y estilo: no suscribe eventos, no contiene lógica de interacción, y expone únicamente los controles que otras capas necesitan manipular.

---

## Purpose and responsibilities

- **Único objetivo:** Construir y estilizar la UI (formularios, paneles, layouts y controles).
- **Exposición controlada:** Propiedades públicas con private set para controles que otras capas deben usar.
- **Sin lógica de interacción:** No suscribe eventos ni toma decisiones de negocio o estado.
- **Layouts conmutables:** Métodos para alternar entre el layout de Log y el de Tareas.
- **Utilidades de estilo:** Método para aplicar estilo a nodos de carpeta en el TreeView.

---

## Public API

### Constructor y ciclo de construcción

- **Build(Form form):** Construye toda la interfaz dentro del Form pasado.
  - Configura el Form por defecto.
  - Crea y arma las secciones: Header, Content, Buttons, Status bar.
  - Inicializa el layout por defecto (Log).

### Layouts conmutables

- **ShowLogLayout():** Muestra el panel de registro (TextBox multilinea) bajo el encabezado del panel.
- **ShowTaskLayout(Button btnNewTask):** Muestra el gestor de tareas con el botón “Crear nueva tarea” inyectado por la capa superior.
  - Requiere un Button externo; UIBuilder no crea uno por defecto.

### Utilidades de estilo

- **ApplyFolderNodeStyle(TreeNode node):** Aplica tipografía de carpeta al nodo indicado.
  - Afecta únicamente el estilo visual (NodeFont).

---

## Exposed controls

Estos controles son públicos (solo lectura externa) para permitir integración desde otras capas:

- **Header y título:**  
  - LblTitle

- **Contenedores y splits:**  
  - SplitMain, SplitTop

- **Panel dinámico izquierda (log/tareas):**  
  - LogMenu  
  - TbLog  
  - TaskLayout  
  - BtnLogTitle

- **Estadísticas:**  
  - GbStats  
  - LblScriptsTotal, LblScriptsSelected, LblRunning, LblCompleted, LblErrors, LblLastAction

- **Monitor del sistema:**  
  - GbMonitor  
  - PbCPU, PbRAM

- **Árbol de scripts:**  
  - GbTree  
  - Tree

- **Botonera inferior:**  
  - BtnRun, BtnRefresh, BtnSelectFolder, BtnDocs, BtnClose

- **Status bar:**  
  - SslPath, SslStatus, SslTime

> Nota: Paneles y layouts internos como HeaderPanel, ContentPanel, RightPanel, BtnPanel y Status se mantienen privados para reducir la superficie de acoplamiento.

---

## How it works

### Build sequence

- **ApplyFormDefaults:**  
  - Configura título, tamaño, estilo de borde, tipografía y colores del Form usando Styl.
- **BuildHeader:**  
  - Crea el HeaderPanel y el LblTitle.
- **BuildContent:**  
  - Crea SplitMain (horizontal) y SplitTop (vertical).  
  - Arma el panel izquierdo (log/tareas), el derecho (stats/monitor) y el inferior (árbol).
- **BuildButtons:**  
  - Arma la botonera con layout homogéneo y estilo consistente.
- **BuildStatusBar:**  
  - Crea SslPath, SslStatus, SslTime y los agrega al StatusStrip.
- **ShowLogLayout:**  
  - Establece el layout por defecto en el panel dinámico (registro).

### Dynamic layouts

- **ShowLogLayout:**  
  - Limpia el contenedor, agrega BtnLogTitle y TbLog, y reanuda el layout.
- **ShowTaskLayout:**  
  - Valida que btnNewTask no sea nulo.  
  - Lo configura (Dock Bottom, Height 30), limpia el contenedor, agrega TaskLayout, el botón y BtnLogTitle.

### Styling and theming

- **Tipografías y colores:**  
  - Referenciados desde Styl con fallbacks mínimos locales para fuentes.  
  - Todos los colores (fondo, headers, inputs, botones, status) se toman de Styl para consistencia visual global.
- **NewStatLabel y NewStyledButton:**  
  - Métodos internos de factoría para garantizar estilo uniforme.

---

## Usage patterns

- **Inicialización de la UI:**
  - Crear el Form y pasar la instancia a Build(Form).
  - La UI queda lista con el layout de Log activo.

- **Alternar layouts del panel dinámico:**
  - Para ver el log: llamar ShowLogLayout().
  - Para ver tareas: crear el botón “Crear nueva tarea” desde la capa superior y pasar a ShowTaskLayout(btn).

- **Actualizar estados de estadísticas y monitor:**
  - Actualizar el texto de los labels expuestos: LblScriptsTotal, LblErrors, etc.
  - Ajustar valores de PbCPU, PbRAM desde la capa de monitor.

- **Actualizar status bar:**
  - Asignar textos a SslPath, SslStatus.  
  - Actualizar periódicamente SslTime desde un timer o controlador externo.

- **Estilizar nodos de carpeta en el árbol:**
  - Al crear TreeNode para carpetas, llamar ApplyFolderNodeStyle(node) para un estilo distintivo.

---

## Precautions and best practices

- **Responsabilidad única:**
  - No suscribas eventos dentro de UIBuilder. Maneja clicks, cambios y timers en otra capa (UIX/Controller).

- **Mínimo privilegio:**
  - No hagas públicos nuevos paneles o layouts si no es indispensable. Mantén la superficie de API acotada.

- **Dependencia de Styl:**
  - Asegúrate de que Styl esté inicializado antes de Build(Form).  
  - Si alguna fuente en Styl no está disponible, se usarán fallbacks locales.

- **Layout switching:**
  - Siempre llama SuspendLayout() y ResumeLayout() en el contenedor al reemplazar layouts (ya lo hace UIBuilder).  
  - No insertes controles externos directamente en contenedores privados; usa los métodos públicos.

- **ShowTaskLayout requiere un botón:**
  - Inyecta un Button válido. Si es nulo, se lanzará ArgumentNullException.

- **Status time:**
  - UIBuilder no establece la hora. Usa una capa de monitor con un timer para actualizar SslTime.

- **Thread-safety:**
  - Realiza actualizaciones de controles en el hilo de UI. Si trabajas con tareas asíncronas, invoca al hilo principal (Invoke/BeginInvoke) desde tu controlador.

- **Persistencia de estilos:**
  - No cambies fuentes y colores directamente en los controles expuestos si quieres mantener coherencia. Centraliza cambios en Styl.

---

## Maintenance checklist

- **SRP intacto:**  
  - ¿UIBuilder solo construye y estiliza? ¿Sin eventos ni lógica?

- **Exposición mínima:**  
  - ¿Solo los controles necesarios son públicos? ¿Cualquier nuevo control está privado por defecto?

- **Theming consistente:**  
  - ¿Todos los colores y fuentes vienen de Styl? ¿Se respetan fallbacks?

- **Layouts limpios:**  
  - ¿ShowLogLayout/ShowTaskLayout limpian y reordenan correctamente el contenedor?

- **Status bar sin lógica:**  
  - ¿SslTime no depende de DateTime.Now dentro del builder?

- **Tree styling desacoplado:**  
  - ¿ApplyFolderNodeStyle solo aplica estilo sin crear nodos ni lógica?

---




# UIBuilder integration examples

Esta sección muestra cómo integrar y usar UIBuilder desde una capa superior (UIX/Controller) sin acoplar lógica al builder. Incluye alternar layouts, actualizar estadísticas, refrescar la barra de estado, monitor del sistema y estilizar el árbol.

---

## Inicialización y construcción

- **Crear el formulario y construir la UI:**
```csharp
using System;
using System.Windows.Forms;
using GDSU.UI;

public class MainForm : Form
{
    private readonly UIBuilder ui = new UIBuilder();

    public MainForm()
    {
        // Construir toda la UI dentro de este Form
        ui.Build(this);

        // Ejemplo: texto inicial en status
        ui.SslStatus.Text = "Listo";
        ui.SslPath.Text = $"Ruta: {AppContext.BaseDirectory}";

        // Elegir layout inicial (ya es Log por defecto, pero puedes reafirmarlo)
        ui.ShowLogLayout();

        // Wire-up de eventos EN ESTA CAPA, no en UIBuilder:
        WireEvents();
    }

    private void WireEvents()
    {
        ui.BtnRun.Click += (_, __) => RunSelected();
        ui.BtnRefresh.Click += (_, __) => RefreshScripts();
        ui.BtnSelectFolder.Click += (_, __) => SelectFolder();
        ui.BtnClose.Click += (_, __) => Close();

        // Alternar a layout de tareas cuando corresponda (ej. desde un menú, botón, etc.)
        ui.BtnDocs.Click += (_, __) => ShowTasks();
    }

    private void RunSelected() { /* lógica de ejecución */ }
    private void RefreshScripts() { /* lógica de refresco */ }
    private void SelectFolder() { /* abrir diálogo y cargar */ }
    private void ShowTasks() { /* alternar a tareas */ }
}
```

---

## Alternar layouts del panel dinámico

- **Mostrar el registro (Log):**
```csharp
// Cambia el contenedor izquierdo al TextBox de log
ui.ShowLogLayout();

// Ejemplo de append seguro (hacer en hilo de UI)
ui.TbLog.AppendText("Iniciado...\r\n");
```

- **Mostrar gestor de tareas con botón inyectado:**
```csharp
// Crear el botón en la capa superior (control de interacción)
var btnNewTask = new Button
{
    Text = "Crear nueva tarea"
};

// Suscribir evento en la capa superior
btnNewTask.Click += (_, __) =>
{
    // Abrir modal, crear tarea, etc.
    MessageBox.Show("Crear tarea...");
};

// Cambiar layout al gestor de tareas e inyectar el botón
ui.ShowTaskLayout(btnNewTask);

// Agregar controles a TaskLayout desde esta capa (ejemplo)
ui.TaskLayout.Controls.Add(new Label { Text = "Tarea #1", AutoSize = true }, 0, 0);
ui.TaskLayout.Controls.Add(new TextBox { Width = 200 }, 1, 0);
ui.TaskLayout.Controls.Add(new Button { Text = "Configurar" }, 2, 0);
```

---

## Actualizar estadísticas

- **Refrescar contadores y estado:**
```csharp
void UpdateStats(int total, int selected, int running, int completed, int errors, string lastAction)
{
    ui.LblScriptsTotal.Text = $"Scripts cargados: {total}";
    ui.LblScriptsSelected.Text = $"Seleccionados: {selected}";
    ui.LblRunning.Text = $"Procesos activos: {running}";
    ui.LblCompleted.Text = $"Completados: {completed}";
    ui.LblErrors.Text = $"Errores: {errors}";
    ui.LblLastAction.Text = $"Última acción: {lastAction}";
}

// Ejemplo de uso
UpdateStats(total: 42, selected: 5, running: 2, completed: 37, errors: 3, lastAction: "Refresco de árbol");
```

---

## Monitor del sistema (CPU/RAM) y barra de estado

- **Actualizar barras de progreso:**
```csharp
// Valores típicos de 0 a 100
ui.PbCPU.Value = 67;
ui.PbRAM.Value = 54;
```

- **Actualizar status bar (ruta, estado, hora):**
```csharp
ui.SslPath.Text = $"Ruta: {AppContext.BaseDirectory}";
ui.SslStatus.Text = "Sincronizando...";

// Actualización periódica de hora (Timer en capa superior)
var timer = new Timer { Interval = 1000 };
timer.Tick += (_, __) => ui.SslTime.Text = DateTime.Now.ToString("HH:mm:ss");
timer.Start();
```

---

## Árbol de scripts y estilo de nodos

- **Poblar el árbol y aplicar estilo a carpetas:**
```csharp
ui.Tree.Nodes.Clear();

var root = new TreeNode("Scripts");
ui.ApplyFolderNodeStyle(root); // estilo de carpeta

var folderA = new TreeNode("Mantenimiento");
ui.ApplyFolderNodeStyle(folderA);

var script1 = new TreeNode("clean_temp.ps1") { ToolTipText = "Limpia temporales" };
var script2 = new TreeNode("backup_db.ps1") { ToolTipText = "Respaldo de base de datos" };

folderA.Nodes.Add(script1);
folderA.Nodes.Add(script2);
root.Nodes.Add(folderA);

ui.Tree.Nodes.Add(root);
ui.Tree.ExpandAll();
```

- **Leer selección de scripts (en otra capa):**
```csharp
var selectedScripts = new List<string>();
foreach (TreeNode node in ui.Tree.Nodes)
{
    CollectCheckedLeafs(node, selectedScripts);
}

void CollectCheckedLeafs(TreeNode n, List<string> acc)
{
    if (n.Checked && n.Nodes.Count == 0) acc.Add(n.Text);
    foreach (TreeNode child in n.Nodes) CollectCheckedLeafs(child, acc);
}
```

---

## Precauciones para que todo funcione bien

- **No suscribas eventos en UIBuilder:** Hazlo siempre en la capa superior (UIX/Controller).
- **Inyecta el botón a ShowTaskLayout:** No pases null; si lo haces, se lanzará ArgumentNullException.
- **Mantén la coherencia de tema:** Asegúrate de inicializar Styl antes de llamar a Build(Form).
- **Actualiza controles en el hilo de UI:** Usa Invoke/BeginInvoke si vienes de hilos en background.
- **No agregues controles directamente a contenedores privados:** Usa los métodos públicos (ShowLogLayout/ShowTaskLayout) y los contenedores expuestos (TaskLayout).
- **Evita cambiar estilos ad hoc:** Centraliza fuentes y colores en Styl para no romper la coherencia visual.

---

## Flujo típico de integración

1. **Construir la UI con Build(Form).**
2. **Inicializar textos y estados base (status, labels).**
3. **Wire-up de eventos en la capa superior.**
4. **Cargar árbol y aplicar estilos de carpeta.**
5. **Alternar layouts según interacción (Log/Tareas).**
6. **Actualizar stats, monitor y status en respuesta a acciones o timers.**




# Troubleshooting

Esta sección te ayuda a diagnosticar y resolver problemas típicos al integrar UIBuilder. Incluye síntomas, causas probables y acciones concretas para corregirlos.

---

## Controles nulos o NullReferenceException

- **Síntoma:** Excepciones al acceder a controles como BtnRun, Tree, TbLog, PbCPU, etc.
- **Causas probables:**
  - **Build no fue llamado:** La UI no está construida aún.
  - **Orden incorrecto:** Accedes a controles antes de finalizar el constructor del Form.
- **Cómo corregir:**
  - **Llama Build(this) en el constructor del Form antes de usar cualquier control.**
  - **Evita acceder desde campos inicializados estáticamente**; usa el momento adecuado (constructor o `OnLoad`).
```csharp
public class MainForm : Form
{
    private readonly UIBuilder ui = new UIBuilder();

    public MainForm()
    {
        ui.Build(this); // Construye antes de cualquier acceso
        ui.BtnRun.Click += (_, __) => RunSelected();
    }
}
```

---

## Estilos inconsistentes o colores/fuentes incorrectos

- **Síntoma:** Colores o tipografías no coinciden con el tema esperado.
- **Causas probables:**
  - **Styl no inicializado o con valores nulos.**
  - **Cambios ad hoc en controles expuestos que rompen la coherencia.**
- **Cómo corregir:**
  - **Inicializa Styl antes de Build(Form).**
  - **Centraliza cambios de tema en Styl, no directamente en los controles.**
```csharp
// Antes de construir la UI
Styl.FontDefault = new Font("Segoe UI", 9);
Styl.BgApp = Color.White;
// ...
ui.Build(this);
```

---

## Freeze o parpadeos al alternar layouts

- **Síntoma:** La interfaz se congela brevemente o parpadea al cambiar entre Log y Tareas.
- **Causas probables:**
  - **Actualizaciones pesadas dentro del contenedor sin suspender layout.**
  - **Inserción de controles múltiples sin orden.**
- **Cómo corregir:**
  - **Usa los métodos del builder (ShowLogLayout/ShowTaskLayout),** ya manejan `SuspendLayout/ResumeLayout`.
  - **Evita agregar controles directamente al contenedor privado.** Usa `TaskLayout` para contenido dinámico.

---

## ArgumentNullException en ShowTaskLayout

- **Síntoma:** Excepción al llamar `ShowTaskLayout`.
- **Causa probable:** Se pasó `null` como botón “Crear nueva tarea”.
- **Cómo corregir:**
  - **Crea e inyecta un Button válido** y suscribe sus eventos en la capa superior.
```csharp
var btnNewTask = new Button { Text = "Crear nueva tarea" };
btnNewTask.Click += (_, __) => OpenCreateTaskDialog();
ui.ShowTaskLayout(btnNewTask);
```

---

## Actualizaciones fuera del hilo de UI

- **Síntoma:** Excepciones al actualizar labels, progress bars o `TbLog` desde tareas asíncronas.
- **Causa probable:** Actualizaciones de controles desde hilos en background.
- **Cómo corregir:**
  - **Usa Invoke/BeginInvoke** en el hilo de UI para actualizar controles.
```csharp
void UpdateCpu(int value)
{
    if (ui.PbCPU.InvokeRequired)
        ui.PbCPU.BeginInvoke(new Action(() => ui.PbCPU.Value = value));
    else
        ui.PbCPU.Value = value;
}
```

---

## Hora del status no se actualiza

- **Síntoma:** `SslTime` aparece vacío o no cambia.
- **Causa probable:** UIBuilder no asigna `DateTime.Now` por diseño; requiere actualización externa.
- **Cómo corregir:**
  - **Configura un Timer en la capa superior** que actualice `SslTime`.
```csharp
var timer = new Timer { Interval = 1000 };
timer.Tick += (_, __) => ui.SslTime.Text = DateTime.Now.ToString("HH:mm:ss");
timer.Start();
```

---

## Árbol sin tooltips o estilo de carpeta

- **Síntoma:** Nodos no muestran tooltips o carpetas no resaltadas.
- **Causas probables:**
  - **No se aplicó `ApplyFolderNodeStyle` a los nodos de carpeta.**
  - **Propiedad `ToolTipText` no establecida en nodos hoja.**
- **Cómo corregir:**
  - **Aplica el estilo de carpeta** y configura tooltips al poblar el árbol.
```csharp
var folder = new TreeNode("Operaciones");
ui.ApplyFolderNodeStyle(folder);
var script = new TreeNode("backup_db.ps1") { ToolTipText = "Respaldo de DB" };
folder.Nodes.Add(script);
ui.Tree.Nodes.Add(folder);
```

---

## Botones no responden

- **Síntoma:** Clicks en `BtnRun`, `BtnRefresh`, etc., no ejecutan acciones.
- **Causas probables:**
  - **Eventos no conectados en la capa superior.**
  - **Manejo de eventos agregado en el lugar incorrecto.**
- **Cómo corregir:**
  - **Conecta eventos en tu controlador/UIX, nunca en UIBuilder.**
```csharp
ui.BtnRun.Click += (_, __) => RunSelected();
ui.BtnRefresh.Click += (_, __) => RefreshScripts();
ui.BtnClose.Click += (_, __) => Close();
```

---

## Layouts revertidos accidentalmente

- **Síntoma:** Tras mostrar tareas, el panel regresa a Log sin intención.
- **Causas probables:**
  - **Algún flujo llama `ShowLogLayout()` por defecto después de Build o en un handler global.**
- **Cómo corregir:**
  - **Revisa inicialización y eventos globales** para evitar llamadas no deseadas a `ShowLogLayout()`.
  - **Decide explícitamente cuándo alternar** y mantén la lógica centralizada en tu controlador.

---

## Guía rápida de verificación (QA)

- **Construcción:** ¿Se llamó `Build(Form)` antes de usar controles?
- **Tema:** ¿Styl está inicializado y no se cambian estilos ad hoc?
- **Eventos:** ¿Todos los eventos están conectados en la capa superior?
- **Layouts:** ¿Se usan `ShowLogLayout` y `ShowTaskLayout` para alternar?
- **Hilo de UI:** ¿Actualizaciones de controles se hacen en el hilo de UI?
- **Status:** ¿`SslTime` se actualiza con Timer externo?
- **Árbol:** ¿Se aplicó `ApplyFolderNodeStyle` en carpetas y `ToolTipText` en hojas?












GDSU/
├─ Program.cs
├─ UI/
│  ├─ MainForm.cs              // Composición de alto nivel: arma la UI y conecta controladores
│  ├─ UI.cs                    // Construcción de la interfaz (header, paneles, status bar, etc.)
│  ├─ UIX.cs                   // Interacción: eventos, inputs, navegación
│  └─ Controls/
│     ├─ LogView.cs            // Control encapsulado para el log
│     ├─ TaskManagerView.cs    // Control encapsulado para gestión de tareas
│     └─ ScriptTreeView.cs     // Control encapsulado para el árbol de scripts
├─ Core/
│  ├─ ScriptRunner.cs          // Orquesta la ejecución y seguimiento de procesos
│  ├─ ScriptTreeLoader.cs      // Carga carpetas y scripts desde el sistema de archivos
│  ├─ StatsService.cs          // Lleva los contadores (lanzados, completados, errores)
│  ├─ MonitorService.cs        // Abstracción del timer de CPU/RAM
│  └─ AppController.cs         // Coordina Core y UI, expone acciones de la app
├─ Models/
│  ├─ ScriptProcessInfo.cs     // Modelo con metadatos de ejecución
│  ├─ ScriptNode.cs            // Modelo para nodos del árbol
│  └─ StatsSnapshot.cs         // Snapshot inmutable para refrescar la UI
├─ Services/
│  ├─ ProcessService.cs        // Arranque de procesos y captura de IO
│  ├─ PerformanceService.cs    // Encapsula PerformanceCounter
│  └─ DialogService.cs         // Selección de carpetas, docs, diálogos
├─ Utils/
│  ├─ Logging.cs               // Interfaz de logging + adaptador a UI
│  ├─ SafeIO.cs                // Enumeración segura de archivos/carpetas
│  └─ UIThread.cs              // Helper para SafeInvoke