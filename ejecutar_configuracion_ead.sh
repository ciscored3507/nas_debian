#!/bin/bash
# ==============================================================================
# Script de Despliegue Automatizado: Servidor NAS / Backup EAD-COL (Debian 13)
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Este script debe ejecutarse como root o con sudo:"
  echo "    sudo bash $0 [DISCO] [WORKGROUP] [NETBIOS] [ADMIN_USER] [ADMIN_PASS] [ROL]"
  exit 1
fi

# Detección automática del entorno del servidor
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}')
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="127.0.0.1"

# Detección del usuario administrador por defecto
detect_default_user() {
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
    else
        local u
        u=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1; exit}' /etc/passwd)
        echo "${u:-nas}"
    fi
}

SERVER_ROLE="${6:-ARCHIVOS}" # ARCHIVOS o BACKUP
TARGET_DISK="${1:-LOCAL}"
SMB_WORKGROUP="${2:-EAD-COL}"

# Detección dinámica de NetBIOS si no se especificó
if [ -n "$3" ]; then
    SMB_NETBIOS="$3"
else
    CUR_HOST=$(hostname -s 2>/dev/null | tr 'a-z' 'A-Z')
    if [ -n "$CUR_HOST" ] && [ "$CUR_HOST" != "DEBIAN" ] && [ "$CUR_HOST" != "LOCALHOST" ]; then
        SMB_NETBIOS="$CUR_HOST"
    else
        [ "$SERVER_ROLE" == "BACKUP" ] && SMB_NETBIOS="SRV-EAD-BKP" || SMB_NETBIOS="SRV-EAD-NAS"
    fi
fi

# Detección del usuario admin
if [ -n "$4" ]; then
    ADMIN_USER="$4"
else
    ADMIN_USER=$(detect_default_user)
fi

ADMIN_PASS="${5:-}"
HOST_NAME_LOWER=$(echo "$SMB_NETBIOS" | tr 'A-Z' 'a-z')

echo "=============================================================================="
echo " CONFIGURACIÓN DE DESPLIEGUE: SERVIDOR EAD-COL ($SERVER_ROLE)"
echo "=============================================================================="
echo " • Rol del Servidor        : $SERVER_ROLE"
echo " • Dirección IP del Servidor: $SERVER_IP"
echo " • Almacenamiento          : $TARGET_DISK"
echo " • Grupo de Trabajo        : $SMB_WORKGROUP"
echo " • Nombre NetBIOS / Host   : $SMB_NETBIOS ($HOST_NAME_LOWER)"
echo " • Administrador Cockpit   : $ADMIN_USER"
echo "=============================================================================="

echo " [1/9] Configurando Hostname y repositorios oficiales (Debian 13 Trixie)..."
hostnamectl set-hostname "$HOST_NAME_LOWER"
sed -i "s/127.0.1.1.*/127.0.1.1\t$HOST_NAME_LOWER $SMB_NETBIOS ead-col/" /etc/hosts 2>/dev/null || echo "127.0.1.1 $HOST_NAME_LOWER $SMB_NETBIOS" >> /etc/hosts

cat << "SOURCES" > /etc/apt/sources.list
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
SOURCES
apt-get update

echo " [2/9] Preparando almacenamiento en /srv/nas..."
ROOT_PART=$(findmnt -n -o SOURCE / 2>/dev/null || true)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null | head -n 1 || true)

if [ "$TARGET_DISK" == "LOCAL" ] || [ "$TARGET_DISK" == "local" ] || [ "$TARGET_DISK" == "none" ]; then
    echo " [i] Modo de almacenamiento local: Usando directorio /srv/nas en partición existente."
    mkdir -p /srv/nas
elif [ -n "$ROOT_DISK" ] && [ "$TARGET_DISK" == "/dev/$ROOT_DISK" ]; then
    echo " [!] ADVERTENCIA: $TARGET_DISK contiene el Sistema Operativo raíz (/)."
    echo "     Se preserva el disco y se utiliza /srv/nas localmente para evitar pérdida del SO."
    mkdir -p /srv/nas
elif [ -b "$TARGET_DISK" ]; then
    echo " [i] Formateando disco secundario dedicado: $TARGET_DISK"
    swapoff ${TARGET_DISK}* 2>/dev/null || true
    umount ${TARGET_DISK}* 2>/dev/null || true

    parted "$TARGET_DISK" --script mklabel gpt
    parted "$TARGET_DISK" --script mkpart primary ext4 0% 100%
    partprobe "$TARGET_DISK" 2>/dev/null || sleep 2

    PART_NAS="${TARGET_DISK}1"
    [ ! -b "$PART_NAS" ] && PART_NAS="${TARGET_DISK}p1"

    LABEL_NAME="DATOS_NAS"
    [ "$SERVER_ROLE" == "BACKUP" ] && LABEL_NAME="DATOS_BACKUP"

    mkfs.ext4 -F -L "$LABEL_NAME" "$PART_NAS"

    mkdir -p /srv/nas
    UUID_NAS=$(blkid -s UUID -o value "$PART_NAS" 2>/dev/null || lsblk -no UUID "$PART_NAS" 2>/dev/null || true)
    sed -i '\|/srv/nas|d' /etc/fstab
    if [ -n "$UUID_NAS" ]; then
        echo "UUID=${UUID_NAS}  /srv/nas  ext4  defaults,noatime  0  2" >> /etc/fstab
    else
        echo "${PART_NAS}  /srv/nas  ext4  defaults,noatime  0  2" >> /etc/fstab
    fi

    systemctl daemon-reload
    mount -a || mount "$PART_NAS" /srv/nas || true
else
    echo "[!] Advertencia: $TARGET_DISK no detectado como disco válido. Usando directorio /srv/nas en disco local."
    mkdir -p /srv/nas
fi

echo " [3/9] Instalando Samba, WSDD2, Cockpit y utilidades de Backup..."
mkdir -p /run/samba /var/log/samba /var/lib/samba/printers
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    samba wsdd2 smbclient rsync cifs-utils cron wget curl \
    cockpit cockpit-storaged cockpit-networkmanager cockpit-packagekit

rm -f /tmp/cockpit-*.deb
wget -q -O /tmp/cockpit-file-sharing.deb https://github.com/45Drives/cockpit-file-sharing/releases/download/v4.6.1-2/cockpit-file-sharing_4.6.1-2trixie_all.deb 2>/dev/null || true
wget -q -O /tmp/cockpit-identities.deb https://github.com/45Drives/cockpit-identities/releases/download/v0.1.14-1/cockpit-identities_0.1.14-1trixie_all.deb 2>/dev/null || true
wget -q -O /tmp/cockpit-navigator.deb https://github.com/45Drives/cockpit-navigator/releases/download/v0.5.10/cockpit-navigator_0.5.10-1focal_all.deb 2>/dev/null || true

for deb_pkg in /tmp/cockpit-file-sharing.deb /tmp/cockpit-identities.deb /tmp/cockpit-navigator.deb; do
    if [ -s "$deb_pkg" ]; then
        apt-get install -y "$deb_pkg" 2>/dev/null || dpkg -i "$deb_pkg" 2>/dev/null || true
    fi
done
rm -f /tmp/cockpit-*.deb

# Configurar WSDD2
cat << WSDDCFG > /etc/default/wsdd2
WSDD2_OPTS="-N $SMB_NETBIOS -G $SMB_WORKGROUP -H $SMB_NETBIOS"
WSDDCFG

mkdir -p /etc/systemd/system/wsdd2.service.d
cat << WSDDOVERRIDE > /etc/systemd/system/wsdd2.service.d/override.conf
[Service]
EnvironmentFile=-/etc/default/wsdd2
ExecStart=
ExecStart=/usr/sbin/wsdd2 \$WSDD2_OPTS
WSDDOVERRIDE

echo " [4/9] Creando grupos y configurando Administrador ($ADMIN_USER)..."
if [ "$SERVER_ROLE" == "BACKUP" ]; then
    # El servidor de backup SOLO contiene grupos técnicos de administración
    groupadd -f grp_sistemas
    groupadd -f grp_backups
else
    # El servidor NAS contiene grupos departamentales
    groupadd -f grp_empleados_ead
    groupadd -f grp_sistemas
    groupadd -f grp_c1_admin
    groupadd -f grp_c1_analista
    groupadd -f grp_c1_asesor
    groupadd -f grp_c2_admin
    groupadd -f grp_c2_analista
    groupadd -f grp_c2_asesor
    groupadd -f grp_backups
fi

if ! id "$ADMIN_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$ADMIN_USER"
fi

if [ "$SERVER_ROLE" == "BACKUP" ]; then
    usermod -aG sudo,adm,grp_sistemas,grp_backups "$ADMIN_USER"
else
    usermod -aG sudo,adm,grp_empleados_ead,grp_sistemas,grp_backups "$ADMIN_USER"
fi

echo "$ADMIN_USER ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$ADMIN_USER"
chmod 0440 "/etc/sudoers.d/$ADMIN_USER"

if [ -n "$ADMIN_PASS" ]; then
    echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
    echo -e "${ADMIN_PASS}\n${ADMIN_PASS}" | smbpasswd -a -s "$ADMIN_USER" 2>/dev/null || true
fi

echo " [5/9] Creando estructura de directorios y permisos según el rol ($SERVER_ROLE)..."
if [ "$SERVER_ROLE" == "BACKUP" ]; then
    mkdir -p /srv/nas/BACKUPS_WINDOWS
    mkdir -p /srv/nas/BACKUPS_LINUX
    mkdir -p /srv/nas/BACKUPS_SERVIDORES
    mkdir -p /srv/nas/SNAPSHOTS_NAS
    mkdir -p /srv/nas/LOGS_BACKUP

    chown -R root:grp_backups /srv/nas/BACKUPS_WINDOWS && chmod -R 2770 /srv/nas/BACKUPS_WINDOWS
    chown -R root:grp_backups /srv/nas/BACKUPS_LINUX && chmod -R 2770 /srv/nas/BACKUPS_LINUX
    chown -R root:grp_backups /srv/nas/BACKUPS_SERVIDORES && chmod -R 2770 /srv/nas/BACKUPS_SERVIDORES
    chown -R root:grp_sistemas /srv/nas/SNAPSHOTS_NAS && chmod -R 2770 /srv/nas/SNAPSHOTS_NAS
    chown -R root:grp_sistemas /srv/nas/LOGS_BACKUP && chmod -R 2775 /srv/nas/LOGS_BACKUP
else
    mkdir -p /srv/nas/SISTEMAS
    mkdir -p /srv/nas/CAMPANA_UNO/Administrativo
    mkdir -p /srv/nas/CAMPANA_UNO/Analistas
    mkdir -p /srv/nas/CAMPANA_UNO/Asesores
    mkdir -p /srv/nas/CAMPANA_DOS/Administrativo
    mkdir -p /srv/nas/CAMPANA_DOS/Analistas
    mkdir -p /srv/nas/CAMPANA_DOS/Asesores

    chown -R root:grp_sistemas /srv/nas/SISTEMAS && chmod -R 2775 /srv/nas/SISTEMAS
    chown -R root:grp_c1_admin /srv/nas/CAMPANA_UNO/Administrativo && chmod -R 2770 /srv/nas/CAMPANA_UNO/Administrativo
    chown -R root:grp_c1_analista /srv/nas/CAMPANA_UNO/Analistas && chmod -R 2770 /srv/nas/CAMPANA_UNO/Analistas
    chown -R root:grp_c1_asesor /srv/nas/CAMPANA_UNO/Asesores && chmod -R 2770 /srv/nas/CAMPANA_UNO/Asesores
    chown -R root:grp_c2_admin /srv/nas/CAMPANA_DOS/Administrativo && chmod -R 2770 /srv/nas/CAMPANA_DOS/Administrativo
    chown -R root:grp_c2_analista /srv/nas/CAMPANA_DOS/Analistas && chmod -R 2770 /srv/nas/CAMPANA_DOS/Analistas
    chown -R root:grp_c2_asesor /srv/nas/CAMPANA_DOS/Asesores && chmod -R 2770 /srv/nas/CAMPANA_DOS/Asesores
fi

echo " [6/9] Configurando /etc/samba/smb.conf para rol $SERVER_ROLE..."
if [ "$SERVER_ROLE" == "BACKUP" ]; then
cat << SMBCONF > /etc/samba/smb.conf
[global]
   workgroup = $SMB_WORKGROUP
   server string = Servidor Central de Respaldos (Backup) EAD-COL
   server role = standalone server
   netbios name = $SMB_NETBIOS
   security = user
   map to guest = Never
   server min protocol = SMB2_02
   server smb encrypt = desired
   dns proxy = no
   include = registry

   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

# Recursos de Backup Ocultos (Invisible para la red publica)
[BACKUPS_WINDOWS$]
   comment = Repositorio Oculto de Backups para Windows
   path = /srv/nas/BACKUPS_WINDOWS
   browseable = no
   read only = no
   valid users = @grp_sistemas, @grp_backups
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770

[BACKUPS_LINUX$]
   comment = Repositorio Oculto de Backups para Linux
   path = /srv/nas/BACKUPS_LINUX
   browseable = no
   read only = no
   valid users = @grp_sistemas, @grp_backups
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770

[BACKUPS_SERVIDORES$]
   comment = Repositorio Oculto de Imagenes y Servidores
   path = /srv/nas/BACKUPS_SERVIDORES
   browseable = no
   read only = no
   valid users = @grp_sistemas, @grp_backups
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770
SMBCONF
else
cat << SMBCONF > /etc/samba/smb.conf
[global]
   workgroup = $SMB_WORKGROUP
   server string = Servidor NAS $SMB_WORKGROUP
   server role = standalone server
   netbios name = $SMB_NETBIOS
   security = user
   map to guest = Never
   server min protocol = SMB2_02
   server smb encrypt = desired
   dns proxy = no
   include = registry

   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

[SISTEMAS]
   comment = Software y Herramientas de Sistemas
   path = /srv/nas/SISTEMAS
   browseable = yes
   read only = yes
   write list = @grp_sistemas
   valid users = @grp_empleados_ead, @grp_sistemas
   create mask = 0775
   directory mask = 0775
   force create mode = 0775
   force directory mode = 0775

[C1_ADMINISTRATIVO]
   comment = Campaña 1 - Area Administrativa
   path = /srv/nas/CAMPANA_UNO/Administrativo
   browseable = yes
   read only = no
   valid users = @grp_sistemas, @grp_c1_admin, @grp_c1_analista
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770

[C1_ANALISTAS]
   comment = Campaña 1 - Area de Analistas
   path = /srv/nas/CAMPANA_UNO/Analistas
   browseable = yes
   read only = no
   valid users = @grp_sistemas, @grp_c1_admin, @grp_c1_analista
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770

[C1_ASESORES]
   comment = Campaña 1 - Area de Asesores
   path = /srv/nas/CAMPANA_UNO/Asesores
   browseable = yes
   read only = no
   valid users = @grp_sistemas, @grp_c1_admin, @grp_c1_asesor
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770

[C2_ADMINISTRATIVO]
   comment = Campaña 2 - Area Administrativa
   path = /srv/nas/CAMPANA_DOS/Administrativo
   browseable = yes
   read only = no
   valid users = @grp_sistemas, @grp_c2_admin, @grp_c2_analista
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770

[C2_ANALISTAS]
   comment = Campaña 2 - Area de Analistas
   path = /srv/nas/CAMPANA_DOS/Analistas
   browseable = yes
   read only = no
   valid users = @grp_sistemas, @grp_c2_admin, @grp_c2_analista
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770

[C2_ASESORES]
   comment = Campaña 2 - Area de Asesores
   path = /srv/nas/CAMPANA_DOS/Asesores
   browseable = yes
   read only = no
   valid users = @grp_sistemas, @grp_c2_admin, @grp_c2_asesor
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770
SMBCONF
fi

echo " [7/9] Aplicando correcciones y compatibilidad total para Cockpit..."
mkdir -p /root/.ssh "/home/$ADMIN_USER/.ssh" /etc/skel/.ssh /nonexistent/.ssh
touch /root/.ssh/authorized_keys "/home/$ADMIN_USER/.ssh/authorized_keys" /etc/skel/.ssh/authorized_keys /nonexistent/.ssh/authorized_keys
chmod 700 /root/.ssh "/home/$ADMIN_USER/.ssh" /etc/skel/.ssh
chmod 600 /root/.ssh/authorized_keys "/home/$ADMIN_USER/.ssh/authorized_keys" /etc/skel/.ssh/authorized_keys
chown -R root:root /root/.ssh
[ -d "/home/$ADMIN_USER" ] && chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"

grep -qxF "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells
grep -qxF "/sbin/nologin" /etc/shells || echo "/sbin/nologin" >> /etc/shells
mkdir -p /nonexistent && chmod 555 /nonexistent

cat << "CHAGE" > /usr/local/bin/chage
#!/bin/sh
exec env LC_ALL=C /usr/bin/chage "$@"
CHAGE
chmod 755 /usr/local/bin/chage

cat << "PASSWD" > /usr/local/bin/passwd
#!/bin/sh
exec env LC_ALL=C /usr/bin/passwd "$@"
PASSWD
chmod 755 /usr/local/bin/passwd

cat << "LASTB" > /usr/local/bin/lastb
#!/bin/bash
if [ -f /var/log/btmp ] && [ -s /var/log/btmp ]; then
    /usr/bin/last -f /var/log/btmp "$@" 2>/dev/null || echo "btmp begins $(date -Iseconds)"
else
    echo "btmp begins $(date -Iseconds)"
fi
LASTB
chmod 755 /usr/local/bin/lastb
ln -sf /usr/local/bin/lastb /usr/bin/lastb 2>/dev/null || true

cat << MOTD > /etc/motd

======================================================
  SERVIDOR EAD-COL ($SERVER_ROLE) - IP: $SERVER_IP
  * Panel Web   : https://${SERVER_IP}:9090
  * Red Windows : \\${SERVER_IP} ($SMB_NETBIOS)
======================================================

MOTD
cp /etc/motd /etc/issue.net

echo " [8/9] Recargando systemd y reiniciando servicios..."
testparm -s
systemctl daemon-reload
systemctl restart smbd nmbd wsdd2 cockpit.socket cockpit.service
systemctl enable smbd nmbd wsdd2 cockpit.socket

echo ""
echo "=============================================================================="
echo " ✔ ¡DESPLIEGUE DEL SERVIDOR $SERVER_ROLE COMPLETADO CON ÉXITO!"
echo "=============================================================================="
echo " Rol del Servidor: $SERVER_ROLE"
echo " Almacenamiento  : /srv/nas ($TARGET_DISK)"
echo " Administrador   : $ADMIN_USER (con permisos sudo totales para Cockpit)"
echo " Panel Web       : https://${SERVER_IP}:9090"
echo " Red Windows     : \\\\${SERVER_IP} (o \\\\$SMB_NETBIOS)"
echo "=============================================================================="
