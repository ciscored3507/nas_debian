# Servidor NAS & Central de Respaldos Multiplataforma (Debian 13)

Este repositorio contiene la suite de scripts interactivos y automatizados para desplegar y administrar servidores de almacenamiento en red (**NAS Departamental**) y **Centrales de Copias de Seguridad** inmunes a ransomware bajo **Debian 13 (Trixie)**.

---

## 📋 Guía de Puesta a Punto del Servidor (Paso a Paso)

Sigue estos pasos antes de ejecutar el asistente para garantizar que el sistema operativo base esté actualizado, seguro y con todas las dependencias necesarias.

---

### Paso 1: Cambiar a usuario `root`

Para realizar configuraciones administrativas a nivel de sistema:

```bash
su -
```
> **IMPORTANTE:** Es fundamental incluir el espacio y el guion (`su -`). Esto asegura que Debian cargue el entorno completo de `root`, incluyendo el directorio de utilidades del sistema (`/usr/sbin/`) en tu `$PATH`.

---

### Paso 2: Configurar los Repositorios APT (Debian 13 Trixie)

Asegúrate de contar con los componentes oficiales (`main`, `contrib`, `non-free`, `non-free-firmware`) y los repositorios de seguridad.

Edita el archivo de repositorios:
```bash
cat << 'SOURCES' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
SOURCES
```

---

### Paso 3: Actualizar el Sistema

Actualiza la lista de paquetes e instala las últimas actualizaciones disponibles:

```bash
apt update && apt upgrade -y
```

---

### Paso 4: Instalar Paquetes Base Esenciales

Instala utilidades clave de diagnóstico, descarga y firewall:

```bash
apt install -y curl wget htop ufw
```

---

### Paso 5: Verificar el Estado de Red

Comprueba las interfaces y direcciones IP asignadas:

```bash
ip a
```

Para verificar la puerta de enlace predeterminada:
```bash
ip r
```

---

### Paso 6: Comprobar Conectividad a Internet y DNS

Prueba de conexión directa por IP:
```bash
ping -c 4 8.8.8.8
```

Prueba de resolución DNS:
```bash
ping -c 4 google.com
```

---

### Paso 7: Listar Usuarios y Otorgar Permisos de Administrador (`sudo`)

1. **Listar usuarios con shell interactivo:**
   ```bash
   grep -E '/bin/bash|/bin/sh' /etc/passwd
   ```

2. **Instalar `sudo` y conceder permisos directos e inmediatos:**
   ```bash
   apt install -y sudo
   usermod -aG sudo <nombre_usuario>
   echo "<nombre_usuario> ALL=(ALL:ALL) ALL" > /etc/sudoers.d/<nombre_usuario>
   chmod 0440 /etc/sudoers.d/<nombre_usuario>
   ```
   *Ejemplo para el usuario `jose`:*
   ```bash
   usermod -aG sudo jose
   echo "jose ALL=(ALL:ALL) ALL" > /etc/sudoers.d/jose
   chmod 0440 /etc/sudoers.d/jose
   ```
   > **Nota:** La creación del archivo en `/etc/sudoers.d/` garantiza que los permisos de `sudo` surtan efecto **inmediatamente** en todas las terminales activas sin necesidad de cerrar sesión o reiniciar.

3. **Salir de root:**
   ```bash
   exit
   ```

---

### Paso 8: Desactivar el Acceso de `root` por SSH

Por seguridad, restringe el acceso directo de root vía SSH para obligar a usar un usuario estándar con escalado de privilegios:

```bash
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
```

---

### Paso 9: Activar Actualizaciones de Seguridad Automáticas

Mantén el servidor protegido contra vulnerabilidades instalando `unattended-upgrades`:

```bash
apt install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
```

---

### Paso 10: Configurar el Firewall (`ufw`)

Configura la política base restrictiva y habilita los puertos necesarios para administración (SSH, Cockpit) y servicios de red (Samba, WSDD2):

```bash
# Políticas base: bloquear entrante, permitir saliente
ufw default deny incoming
ufw default allow outgoing

# SSH (Acceso remoto)
ufw allow 22/tcp comment 'SSH'

# Panel Web Cockpit
ufw allow 9090/tcp comment 'Cockpit Web Admin'

# Samba (Compartición de Archivos)
ufw allow 137,138/udp comment 'Samba NetBIOS'
ufw allow 139,445/tcp comment 'Samba SMB'

# WSDD2 (Detección de equipos en red Windows)
ufw allow 3702/udp comment 'WSDD2 WSD Discovery'
ufw allow 5357/tcp comment 'WSDD2 LLMNR'

# Activar firewall
ufw --force enable

# Verificar estado
ufw status verbose
```

---

### Paso 11: Instalar y Configurar `fail2ban`

Protege el servidor contra ataques de fuerza bruta en SSH:

```bash
apt install -y fail2ban
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
systemctl enable --now fail2ban
systemctl status fail2ban
```

---

### Paso 12: Ejecución del Asistente NAS (`asistente_nas.sh`)

Una vez preparado el servidor, ejecuta el asistente visual interactivo:

```bash
cd /home/jose/ead_nas_debian
sudo bash asistente_nas.sh
```

#### Funcionalidades del Asistente:
* **[1] Desplegar Servidor:** Configuración en 5 pasos para **Servidor de Archivos (NAS)** o **Central de Backup (Inmune a Ransomware)**.
* **[2] Gestión de Grupos:** Creación y asignación de grupos departamentales o técnicos.
* **[3] Gestión de Recursos Compartidos:** Creación, edición, deshabilitación y permisos de carpetas SMB.
* **[4] Gestión de Tareas de Backup:** Programación de copias incrementales deduplicadas (con *hardlinks*) para servidores Windows (CIFS), Linux (SSH) o carpetas locales.
* **[5] Gestión de Usuarios:** Creación y control de acceso a empleados y cuentas técnicas.
* **[6] Diagnóstico y Discos:** Monitoreo de espacio, servicios activos y tareas cron.
* **[7] Reiniciar Servicios:** Recarga limpia de Samba, WSDD2 y Cockpit.
* **[8] Desinstalar y Limpiar:** Restablecimiento total del sistema a su estado original.

---

## 🛠 Documentación Adicional

* [AGENTS.md](AGENTS.md) — Especificación técnica de arquitectura, parches de Debian 13 y notas de diseño.
* [SMB_DEBIAN.md](SMB_DEBIAN.md) — Manual de replicación y procedimientos de restauración de copias de seguridad.
