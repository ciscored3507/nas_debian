# AGENTS.md • Servidor NAS & Central de Respaldos Multiplataforma EAD-COL (Debian 13)

Este documento contiene la **especificación técnica completa, inventario de scripts, arquitectura de seguridad, soluciones a peculiaridades del sistema y estado del proyecto** para que cualquier agente de IA o ingeniero pueda retomar y continuar este trabajo en cualquier equipo.

---

## 1. Identidad y Propósito del Proyecto

* **Sistema Operativo Base:** Debian 13 (Trixie) GNU/Linux x86_64.
* **Organización / Grupo de Trabajo:** `EAD-COL`.
* **Identificadores NetBIOS por Defecto:**
  * Servidor NAS de Archivos: `SRV-EAD-NAS`
  * Servidor Central de Backup: `SRV-EAD-BKP`
* **Dirección IP de Red Local de Prueba:** `10.10.1.2` (Subred `10.10.1.0/24`).
* **Credenciales Administrativas de Entorno:**
  * Usuario: `nas` / `root`
  * Contraseña predeterminada: `DE0puFvp85#`

---

## 2. Inventario de Archivos del Proyecto

Todos los archivos del proyecto residen en el directorio principal `/home/nas/`:

| Archivo / Ruta | Tipo | Descripción |
| :--- | :--- | :--- |
| `/home/nas/asistente_nas.sh` | Script Bash (TUI `whiptail`) | **Asistente Visual Interactivo** con colores nativos, validación en vivo, ciclo de edición y 8 módulos de gestión. |
| `/home/nas/ejecutar_configuracion_ead.sh` | Script Bash CLI | **Motor de Despliegue Automatizado** parametrizado con soporte de roles (`ARCHIVOS` o `BACKUP`), formateo, Samba, Cockpit y parches. |
| `/home/nas/desinstalar_nas_ead.sh` | Script Bash CLI | **Desinstalador y Limpiador Total** para restablecer el servidor a su estado base limpio. |
| `/home/nas/SMB_DEBIAN.md` | Markdown | **Manual Técnico y Guía de Replicación** para usuarios y administradores. |
| `/home/nas/AGENTS.md` | Markdown | **Este documento maestro de contexto para agentes de IA**. |

---

## 3. Roles del Servidor y Matriz de Seguridad

El sistema está diseñado para operar bajo dos roles mutuamente excluyentes:

```text
                               ┌─────────────────────────┐
                               │    Servidor Debian 13   │
                               └────────────┬────────────┘
                     ┌──────────────────────┴──────────────────────┐
                     ▼                                             ▼
        ┌─────────────────────────┐                   ┌─────────────────────────┐
        │      Rol: ARCHIVOS      │                   │       Rol: BACKUP       │
        │    (NAS Departamental)  │                   │  (Central de Respaldos) │
        └────────────┬────────────┘                   └────────────┬────────────┘
                     │                                             │
      ┌──────────────┴──────────────┐               ┌──────────────┴──────────────┐
      ▼                             ▼               ▼                             ▼
Carpetas Visibles:            Grupos:         Carpetas Ocultas ($):         Grupos:
[SISTEMAS]                    grp_sistemas    [BACKUPS_WINDOWS$]            SOLO grp_sistemas
[CAMPANA_UNO_*]               grp_empleados   [BACKUPS_LINUX$]              SOLO grp_backups
[CAMPANA_DOS_*]               grp_c1_*, c2_*  [BACKUPS_SERVIDORES$]         (Cero empleados)
```

### A. Rol `ARCHIVOS` (NAS Departamental):
* **Grupos Creados:** `grp_sistemas`, `grp_empleados_ead`, `grp_c1_admin`, `grp_c1_analista`, `grp_c1_asesor`, `grp_c2_admin`, `grp_c2_analista`, `grp_c2_asesor`.
* **Permisos:**
  * `[SISTEMAS]`: TI tiene lectura/escritura (`2770`), resto solo lectura (`2775`).
  * `[CAMPANA_UNO_ADMINISTRATIVO]`: TI + Administrativos.
  * `[CAMPANA_UNO_ANALISTAS]`: TI + Administrativos + Analistas (Asesores bloqueados).
  * `[CAMPANA_UNO_ASESORES]`: TI + Administrativos + Analistas + Asesores.

### B. Rol `BACKUP` (Central de Respaldos 100% Oculto e Inmune a Ransomware):
* **Grupos Creados:** Únicamente `grp_sistemas` y `grp_backups`.
* **Recursos Samba:** Ocultos con sufijo `$` y `browseable = no`. Invisibles en la red de Windows:
  * `[BACKUPS_WINDOWS$]` ➜ `/srv/nas/BACKUPS_WINDOWS`
  * `[BACKUPS_LINUX$]` ➜ `/srv/nas/BACKUPS_LINUX`
  * `[BACKUPS_SERVIDORES$]` ➜ `/srv/nas/BACKUPS_SERVIDORES`

---

## 4. Motor de Copias de Seguridad Multiplataforma

### A. Respaldo de Servidores Windows:
* **Protocolo:** CIFS / SMB.
* **Seguridad:** Credenciales en `/etc/backup-credentials/<tarea>.cred` con permisos `0600 root:root`.
* **Mecanismo:** Montaje temporal en `/mnt/backup_sources/<tarea>` con flag `ro` (Solo Lectura) ➜ Ejecución de Snapshot ➜ Desmontaje inmediato.

### B. Respaldo de Servidores Linux Remotos:
* **Protocolo:** SSH túnel con `rsync` y `sshpass` (o llaves SSH).
* **Mecanismo:** Preserva propietarios, fechas y permisos POSIX exactos.

### C. Deduplicación por Enlaces Duros (*Hardlinks*):
* **Estructura en disco:** `/srv/nas/BACKUPS_HISTORICOS/<tarea>/snapshot_YYYY-MM-DD_HHMMSS/`.
* **Cómo funciona:** `rsync --link-dest=<ultimo_snapshot>`. Los archivos que no cambiaron apuntan al mismo inodo físico en disco (0% espacio extra duplicado). Ahorro superior al 85% de disco.
* **Política de Retención:** Al crearse un snapshot, el script cuenta los existentes; si superan $N$, elimina el más antiguo. Los archivos vigentes **nunca se borran** gracias al contador de referencias de inodos de Linux.

### D. Test de Conexión en Vivo y Ciclo de Edición:
* Antes de crear una tarea, el asistente prueba la IP, recurso compartido y contraseña en 1 segundo.
* Si falla (ej. error tipográfico o nombre NetBIOS sin DNS), muestra el error detallado y permite **corregir los datos sin perder lo escrito**.

---

## 5. Parches Críticos y Soluciones de Debian 13 Integradas

Si se reinstala el servidor desde cero o en otra máquina, estos parches están incluidos en `ejecutar_configuracion_ead.sh`:

1. **Visibilidad en Red Windows (WSDD2):**
   * *Problema:* `wsdd2` en Debian 13 usa `DynamicUser=true` y falla al ejecutar `testparm` para leer `smb.conf`.
   * *Solución:* Override en `/etc/default/wsdd2` y `/etc/systemd/system/wsdd2.service.d/override.conf` con `WSDD2_OPTS="-N <NETBIOS> -G <WORKGROUP> -H <NETBIOS>"`.
2. **Permisos de Base de Datos Samba:**
   * `/var/lib/samba/registry.tdb` configurado con `chmod 644`.
3. **Compatibilidad de Cockpit en Servidores en Español:**
   * *Problema:* Cockpit espera salida en inglés de herramientas del sistema (`chage`, `passwd -S`, `lastb`).
   * *Solución:* Wrappers en `/usr/local/sbin/` que fuerzan `LANG=C.UTF-8` y regla en `/etc/sudoers.d/99-cockpit-spanish-fix`.

---

## 6. Comandos de Operación Rápida

### Lanzar el Asistente Interactivo:
```bash
sudo bash /home/nas/asistente_nas.sh
```

### Despliegue Manual por Consola:
```bash
# Servidor NAS:
sudo bash /home/nas/ejecutar_configuracion_ead.sh /dev/sdb EAD-COL SRV-EAD-NAS nas DE0puFvp85# ARCHIVOS

# Servidor de Backup:
sudo bash /home/nas/ejecutar_configuracion_ead.sh /dev/sdb EAD-COL SRV-EAD-BKP nas DE0puFvp85# BACKUP
```

### Limpieza y Desinstalación Total:
```bash
sudo bash /home/nas/desinstalar_nas_ead.sh
```

### Verificar Tareas y Logs de Backup:
```bash
ls -la /etc/cron.d/backup_*
tail -f /srv/nas/LOGS_BACKUP/backup_*.log
```
