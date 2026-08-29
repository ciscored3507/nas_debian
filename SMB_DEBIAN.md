# Guía de Implementación y Replicación: Servidor NAS & Central de Backup Multiplataforma (Debian Linux)

Esta guía documenta el procedimiento completo, probado y 100% replicable para desplegar servidores empresariales bajo Debian 13 para dos funciones principales:
1. **Servidor de Archivos (NAS Principal):** Almacenamiento en red departamental para clientes Windows con Samba, WSDD2 y Cockpit.
2. **Servidor de Copias de Seguridad (Backup Centralizado):** Repositorio dedicado e inmune a ransomware para respaldar servidores Windows, servidores Linux y estaciones de trabajo mediante snapshots incrementales y deduplicación.

---

## 1. Arquitectura y Métodos de Respaldo

### A. Tipos de Copias de Seguridad y Deduplicación:
* **Incremental Versionada con Snapshots y Hardlinks (Recomendada):**
  * Cada ejecución genera una carpeta con fecha y hora (`snapshot_YYYY-MM-DD_HHMMSS`).
  * Los archivos que no han sido modificados **comparten el mismo bloque físico en el disco** (*hardlinks*).
  * **Ahorro de espacio:** Más del **85% de ahorro de disco** en comparación con copias completas repetitivas.
  * **Retención histórica:** Tus archivos actuales nunca se borran; solo se depuran las carpetas históricas de hace más de $N$ días automáticamente.
* **Sincronización Espejo (Mirror / Sync):**
  * Mantiene una réplica idéntica y exacta del origen en el destino en tiempo real (`rsync -a --delete`).

---

### B. Respaldo de Servidores Windows (Active Directory, SQL, File Server):
* **Protocolo:** SMB / CIFS con montaje en modo **Solo Lectura (`ro`)**.
* **Seguridad de Credenciales:** El usuario y contraseña de Windows se almacenan en `/etc/backup-credentials/<tarea>.cred` con permisos estrictos `0600 root:root` (inaccesible para usuarios normales).
* **Flujo de Ejecución:**
  1. El servidor de backup monta temporalmente la carpeta de Windows en `/mnt/backup_sources/<tarea>`.
  2. Ejecuta el snapshot incremental con deduplicación.
  3. Desmonta el recurso inmediatamente (`umount`).
  4. Genera el registro detallado en `/srv/nas/LOGS_BACKUP/`.

---

### C. Respaldo de Servidores Linux / NAS Principal:
* **Protocolo:** Túnel SSH cifrado con `rsync` y `sshpass` (o llaves SSH).
* **Flujo de Ejecución:**
  1. Conexión segura por SSH con usuario autorizado (`root` o `nas`).
  2. Preservación exacta de permisos POSIX, propietarios, grupos y fechas de modificación.

---

## 2. Métodos de Gestión y Despliegue

### Método 1: Asistente Gráfico Interactivo en Terminal (Recomendado)
```bash
sudo bash /home/nas/asistente_nas.sh
```
* **Opciones del Menú Principal:**
  * `[1] Desplegar Servidor`: Asistente en 5 pasos que permite elegir entre **Servidor de Archivos** o **Central de Backup**, disco, nombre de red y administrador de Cockpit.
  * `[2] Gestión de Grupos de Seguridad`: Crear, listar y eliminar grupos de red (`grp_*` y `grp_backups`).
  * `[3] Gestión de Recursos Compartidos`: Submenú para listar, crear, deshabilitar (`available = no`) o eliminar carpetas en red Samba.
  * `[4] Gestión de Tareas de Backup (Windows / Linux / Local)`:
    * 📋 *Listar tareas programadas* con origen, destino y horario cron.
    * ➕ *Crear nueva tarea automatizada* para Servidores Windows (CIFS con clave), Servidores Linux (SSH) o Carpetas Locales, con **test de conexión en vivo y ciclo de reintento/edición inmediata** en caso de error en IP, recurso o clave.
    * ▶ *Ejecutar tarea manualmente en caliente* con visualización de logs en tiempo real.
    * 🗑 *Eliminar tarea programada* y limpiar credenciales.
  * `[5] Gestión de Usuarios / Empleados`: Crear cuentas con roles departamentales o cuenta técnica de backup.
  * `[6] Ver Diagnóstico, Discos y Recursos`: Estado de servicios, almacenamiento y tareas cron activas.
  * `[7] Reiniciar Servicios de Red`: Reinicio limpio de Samba, WSDD2 y Cockpit.
  * `[8] Desinstalar y Limpiar Servidor`: Restablecimiento completo del equipo.

---

### Método 2: Despliegue Automatizado por Línea de Comandos
```bash
# Sintaxis:
sudo bash /home/nas/ejecutar_configuracion_ead.sh [DISCO] [WORKGROUP] [NETBIOS] [ADMIN_USER] [ADMIN_PASS] [ROL]

# Ejemplo para Servidor NAS de Archivos:
sudo bash /home/nas/ejecutar_configuracion_ead.sh /dev/sdb EAD-COL SRV-EAD-NAS nas DE0puFvp85# ARCHIVOS

# Ejemplo para Servidor de Backup:
sudo bash /home/nas/ejecutar_configuracion_ead.sh /dev/sdb EAD-COL SRV-EAD-BKP nas DE0puFvp85# BACKUP
```

### Método 3: Desinstalación y Limpieza Rápida
```bash
sudo bash /home/nas/desinstalar_nas_ead.sh
```

---

## 3. ¿Cómo Restaurar Archivos desde un Backup?

Para restaurar archivos o carpetas de cualquier fecha histórica:

1. **Ingresar a la carpeta de snapshots:**
   ```bash
   cd /srv/nas/BACKUPS_HISTORICOS/<nombre_tarea>/
   ls -la
   ```
2. **Seleccionar el snapshot deseado:**
   * Cada carpeta corresponde a un punto exacto en el tiempo (ej. `snapshot_2026-08-28_230000`).
3. **Copiar el archivo hacia el servidor de destino:**
   ```bash
   # Ejemplo restaurando un archivo hacia Windows o NAS:
   cp snapshot_2026-08-28_230000/Contabilidad/Reporte.xlsx /srv/nas/CAMPANA_UNO/Administrativo/
   ```

---


---

## 4. Diferencias de Arquitectura: Servidor NAS vs Servidor de Backup

### Rol ARCHIVOS (NAS Departamental):
* **Grupos:** `grp_sistemas`, `grp_c1_admin`, `grp_c1_analista`, `grp_c1_asesor`, `grp_c2_admin`, etc.
* **Carpetas Visibles:** `[SISTEMAS]`, `[C1_*]`, `[C2_*]` accesibles según matriz de permisos.

### Rol BACKUP (100% Oculto e Inmune a Ransomware):
* **Grupos Exclusivos:** Solo existen `grp_sistemas` (TI) y `grp_backups` (Servicio técnico). Ningún usuario común existe en este servidor.
* **Recursos Ocultos:** Todos los recursos terminan en `$` y tienen `browseable = no` (**completamente invisibles en la red de Windows**):
  * `[BACKUPS_WINDOWS$]`: Destino oculto para agentes Windows (Veeam / Windows Backup).
  * `[BACKUPS_LINUX$]`: Destino oculto para servidores Linux.
  * `[BACKUPS_SERVIDORES$]`: Repositorio de imágenes y snapshots.
* **Acceso Estricto:** Solo accesible por credenciales de `@grp_sistemas` y `@grp_backups` escribiendo la ruta UNC directa (ej. `\\10.10.1.2\BACKUPS_WINDOWS$`).

## 5. Acceso Web y Conexión de Red

* **Panel Web Cockpit:** `https://10.10.1.2:9090`
* **Red Windows:** `\\10.10.1.2` (o `\\SRV-EAD-NAS` / `\\SRV-EAD-BKP`)
