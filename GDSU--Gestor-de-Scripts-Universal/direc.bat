@echo off
REM === Organizador completo de .ps1 (100 items) ===
setlocal enabledelayedexpansion

REM Carpeta base (donde está este .bat)
set "BASE=%~dp0"

echo === Base: %BASE% ===

REM Crear categorias si faltan (ASCII sin acentos para compatibilidad)
if not exist "%BASE%01_Instalacion_y_Actualizacion" mkdir "%BASE%01_Instalacion_y_Actualizacion"
if not exist "%BASE%02_Sistema_y_Seguridad" mkdir "%BASE%02_Sistema_y_Seguridad"
if not exist "%BASE%03_Usuarios_y_Perfiles" mkdir "%BASE%03_Usuarios_y_Perfiles"
if not exist "%BASE%04_Red_y_Conectividad" mkdir "%BASE%04_Red_y_Conectividad"
if not exist "%BASE%05_Almacenamiento_y_Backup" mkdir "%BASE%05_Almacenamiento_y_Backup"
if not exist "%BASE%06_Mantenimiento_y_Optimizacion" mkdir "%BASE%06_Mantenimiento_y_Optimizacion"
if not exist "%BASE%07_Archivos_y_Formatos" mkdir "%BASE%07_Archivos_y_Formatos"
if not exist "%BASE%08_UI_y_Experiencia" mkdir "%BASE%08_UI_y_Experiencia"
if not exist "%BASE%09_Integraciones_y_Comunicacion" mkdir "%BASE%09_Integraciones_y_Comunicacion"
if not exist "%BASE%10_DevOps_y_Automatizacion" mkdir "%BASE%10_DevOps_y_Automatizacion"
if not exist "%BASE%11_Documentacion_y_Reportes" mkdir "%BASE%11_Documentacion_y_Reportes"
if not exist "%BASE%12_Utilidades_Comunes" mkdir "%BASE%12_Utilidades_Comunes"

echo === Moviendo scripts existentes ===

REM --- 01 Instalacion y Actualizacion ---
if exist "%BASE%Instalacion silenciosa de apps.ps1" move "%BASE%Instalacion silenciosa de apps.ps1" "%BASE%01_Instalacion_y_Actualizacion\"
if exist "%BASE%Actualizacion de software.ps1" move "%BASE%Actualizacion de software.ps1" "%BASE%01_Instalacion_y_Actualizacion\"
if exist "%BASE%Instalador portable.ps1" move "%BASE%Instalador portable.ps1" "%BASE%01_Instalacion_y_Actualizacion\"
if exist "%BASE%Desinstalacion limpia.ps1" move "%BASE%Desinstalacion limpia.ps1" "%BASE%01_Instalacion_y_Actualizacion\"
if exist "%BASE%Distribucion por lotes.ps1" move "%BASE%Distribucion por lotes.ps1" "%BASE%01_Instalacion_y_Actualizacion\"
if exist "%BASE%Distribucion con branding.ps1" move "%BASE%Distribucion con branding.ps1" "%BASE%01_Instalacion_y_Actualizacion\"
if exist "%BASE%Auto-actualizacion de scripts.ps1" move "%BASE%Auto-actualizacion de scripts.ps1" "%BASE%01_Instalacion_y_Actualizacion\"
if exist "%BASE%Provisioning de maquina nueva.ps1" move "%BASE%Provisioning de maquina nueva.ps1" "%BASE%01_Instalacion_y_Actualizacion\"

REM --- 02 Sistema y Seguridad ---
if exist "%BASE%Gestion de servicios.ps1" move "%BASE%Gestion de servicios.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Creacion de usuarios locales.ps1" move "%BASE%Creacion de usuarios locales.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Politicas de firewall.ps1" move "%BASE%Politicas de firewall.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Hardening de Windows.ps1" move "%BASE%Hardening de Windows.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Control de ExecutionPolicy.ps1" move "%BASE%Control de ExecutionPolicy.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Firma de scripts.ps1" move "%BASE%Firma de scripts.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Gestion de certificados.ps1" move "%BASE%Gestion de certificados.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Auditoria de permisos.ps1" move "%BASE%Auditoria de permisos.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Correccion de ACL.ps1" move "%BASE%Correccion de ACL.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Bloqueo de dispositivos USB.ps1" move "%BASE%Bloqueo de dispositivos USB.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Monitoreo de eventos.ps1" move "%BASE%Monitoreo de eventos.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Health check de apps.ps1" move "%BASE%Health check de apps.ps1" "%BASE%02_Sistema_y_Seguridad\"
if exist "%BASE%Remoting seguro.ps1" move "%BASE%Remoting seguro.ps1" "%BASE%02_Sistema_y_Seguridad\"

REM --- 03 Usuarios y Perfiles ---
if exist "%BASE%Gestion de perfiles PowerShell.ps1" move "%BASE%Gestion de perfiles PowerShell.ps1" "%BASE%03_Usuarios_y_Perfiles\"
if exist "%BASE%Gestion de perfiles de Git.ps1" move "%BASE%Gestion de perfiles de Git.ps1" "%BASE%03_Usuarios_y_Perfiles\"
if exist "%BASE%Gestion de sesiones RDP.ps1" move "%BASE%Gestion de sesiones RDP.ps1" "%BASE%03_Usuarios_y_Perfiles\"

REM --- 04 Red y Conectividad ---
if exist "%BASE%Configuracion de proxy.ps1" move "%BASE%Configuracion de proxy.ps1" "%BASE%04_Red_y_Conectividad\"
if exist "%BASE%DNS flush y pruebas.ps1" move "%BASE%DNS flush y pruebas.ps1" "%BASE%04_Red_y_Conectividad\"
if exist "%BASE%Ping y conectividad.ps1" move "%BASE%Ping y conectividad.ps1" "%BASE%04_Red_y_Conectividad\"
if exist "%BASE%Pruebas de puertos.ps1" move "%BASE%Pruebas de puertos.ps1" "%BASE%04_Red_y_Conectividad\"
if exist "%BASE%Configuracion de NTP.ps1" move "%BASE%Configuracion de NTP.ps1" "%BASE%04_Red_y_Conectividad\"
if exist "%BASE%Reset de red.ps1" move "%BASE%Reset de red.ps1" "%BASE%04_Red_y_Conectividad\"

REM --- 05 Almacenamiento y Backup ---
if exist "%BASE%Inventario de hardware.ps1" move "%BASE%Inventario de hardware.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Inventario de software.ps1" move "%BASE%Inventario de software.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Mapeo de unidades.ps1" move "%BASE%Mapeo de unidades.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Sincronizacion de carpetas.ps1" move "%BASE%Sincronizacion de carpetas.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Backup incremental.ps1" move "%BASE%Backup incremental.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Restauracion rapida.ps1" move "%BASE%Restauracion rapida.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Rotacion de logs.ps1" move "%BASE%Rotacion de logs.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Parsing de logs.ps1" move "%BASE%Parsing de logs.ps1" "%BASE%05_Almacenamiento_y_Backup\"
if exist "%BASE%Gestion de cache de build.ps1" move "%BASE%Gestion de cache de build.ps1" "%BASE%05_Almacenamiento_y_Backup\"

REM --- 06 Mantenimiento y Optimizacion ---
if exist "%BASE%Limpieza de caches.ps1" move "%BASE%Limpieza de caches.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"
if exist "%BASE%Rotacion de logs.ps1" move "%BASE%Rotacion de logs.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"
if exist "%BASE%Gestion de procesos.ps1" move "%BASE%Gestion de procesos.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"
if exist "%BASE%Monitor de rendimiento.ps1" move "%BASE%Monitor de rendimiento.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"
if exist "%BASE%Optimizacion de arranque.ps1" move "%BASE%Optimizacion de arranque.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"
if exist "%BASE%Politica de energia.ps1" move "%BASE%Politica de energia.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"
if exist "%BASE%Politica de actualizaciones.ps1" move "%BASE%Politica de actualizaciones.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"
if exist "%BASE%Telemetria local.ps1" move "%BASE%Telemetria local.ps1" "%BASE%06_Mantenimiento_y_Optimizacion\"

REM --- 07 Archivos y Formatos ---
if exist "%BASE%Comparacion de archivos.ps1" move "%BASE%Comparacion de archivos.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Ordenar biblioteca.ps1" move "%BASE%Ordenar biblioteca.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Extraccion de metadatos.ps1" move "%BASE%Extraccion de metadatos.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Compresion inteligente.ps1" move "%BASE%Compresion inteligente.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Descompresion masiva.ps1" move "%BASE%Descompresion masiva.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Renombrado masivo.ps1" move "%BASE%Renombrado masivo.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Conversion de formatos.ps1" move "%BASE%Conversion de formatos.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Calculo de hashes.ps1" move "%BASE%Calculo de hashes.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Control de versiones de archivos.ps1" move "%BASE%Control de versiones de archivos.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Normalizacion de nombres.ps1" move "%BASE%Normalizacion de nombres.ps1" "%BASE%07_Archivos_y_Formatos\"
if exist "%BASE%Gestion de SQLite.ps1" move "%BASE%Gestion de SQLite.ps1" "%BASE%07_Archivos_y_Formatos\"

REM --- 08 UI y Experiencia ---
if exist "%BASE%UI de instalacion.ps1" move "%BASE%UI de instalacion.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Selector de iconos.ps1" move "%BASE%Selector de iconos.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Menu de acciones rapidas.ps1" move "%BASE%Menu de acciones rapidas.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Plantillas de UI.ps1" move "%BASE%Plantillas de UI.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Tema claro-oscuro.ps1" move "%BASE%Tema claro-oscuro.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Notificaciones toast.ps1" move "%BASE%Notificaciones toast.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Wizard de configuracion.ps1" move "%BASE%Wizard de configuracion.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Plantillas de accesos directos.ps1" move "%BASE%Plantillas de accesos directos.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Catalogo de iconos.ps1" move "%BASE%Catalogo de iconos.ps1" "%BASE%08_UI_y_Experiencia\"
if exist "%BASE%Plantillas de documentacion UI.ps1" move "%BASE%Plantillas de documentacion UI.ps1" "%BASE%08_UI_y_Experiencia\"

REM --- 09 Integraciones y Comunicacion ---
if exist "%BASE%Email automatizado.ps1" move "%BASE%Email automatizado.ps1" "%BASE%09_Integraciones_y_Comunicacion\"
if exist "%BASE%Webhook dispatcher.ps1" move "%BASE%Webhook dispatcher.ps1" "%BASE%09_Integraciones_y_Comunicacion\"
if exist "%BASE%REST API client.ps1" move "%BASE%REST API client.ps1" "%BASE%09_Integraciones_y_Comunicacion\"
if exist "%BASE%Scraping liviano.ps1" move "%BASE%Scraping liviano.ps1" "%BASE%09_Integraciones_y_Comunicacion\"
if exist "%BASE%Validador de enlaces.ps1" move "%BASE%Validador de enlaces.ps1" "%BASE%09_Integraciones_y_Comunicacion\"
if exist "%BASE%Generacion de QR.ps1" move "%BASE%Generacion de QR.ps1" "%BASE%09_Integraciones_y_Comunicacion\"
if exist "%BASE%Buscador universal.ps1" move "%BASE%Buscador universal.ps1" "%BASE%09_Integraciones_y_Comunicacion\"
if exist "%BASE%Generacion de reportes ejecutivos.ps1" move "%BASE%Generacion de reportes ejecutivos.ps1" "%BASE%09_Integraciones_y_Comunicacion\"

REM --- 10 DevOps y Automatizacion ---
if exist "%BASE%Instalacion de modulos.ps1" move "%BASE%Instalacion de modulos.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Pruebas Pester.ps1" move "%BASE%Pruebas Pester.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Linting de codigo.ps1" move "%BASE%Linting de codigo.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Build pipeline local.ps1" move "%BASE%Build pipeline local.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Control de versiones semanticas.ps1" move "%BASE%Control de versiones semanticas.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Feature flags.ps1" move "%BASE%Feature flags.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Simulacion de fallos.ps1" move "%BASE%Simulacion de fallos.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Orquestacion paralela segura.ps1" move "%BASE%Orquestacion paralela segura.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Colas y paralelismo.ps1" move "%BASE%Colas y paralelismo.ps1" "%BASE%10_DevOps_y_Automatizacion\"
if exist "%BASE%Gestion de cache de build.ps1" move "%BASE%Gestion de cache de build.ps1" "%BASE%10_DevOps_y_Automatizacion\"

REM --- 11 Documentacion y Reportes ---
if exist "%BASE%Generacion de documentacion.ps1" move "%BASE%Generacion de documentacion.ps1" "%BASE%11_Documentacion_y_Reportes\"
if exist "%BASE%Changelog automatico.ps1" move "%BASE%Changelog automatico.ps1" "%BASE%11_Documentacion_y_Reportes\"
if exist "%BASE%Logs estructurados.ps1" move "%BASE%Logs estructurados.ps1" "%BASE%11_Documentacion_y_Reportes\"

REM --- 12 Utilidades Comunes ---
if exist "%BASE%Perfilado de rendimiento.ps1" move "%BASE%Perfilado de rendimiento.ps1" "%BASE%12_Utilidades_Comunes\"
if exist "%BASE%Gestion de errores.ps1" move "%BASE%Gestion de errores.ps1" "%BASE%12_Utilidades_Comunes\"
if exist "%BASE%Modulo de utilidades comunes.ps1" move "%BASE%Modulo de utilidades comunes.ps1" "%BASE%12_Utilidades_Comunes\"
if exist "%BASE%Plantillas de proyectos.ps1" move "%BASE%Plantillas de proyectos.ps1" "%BASE%12_Utilidades_Comunes\"

echo.
echo ✅ Terminado. Se movieron todos los .ps1 existentes a sus carpetas.
pause
