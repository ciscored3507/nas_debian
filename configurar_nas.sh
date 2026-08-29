#!/bin/bash
# ==============================================================================
# Script de Configuración del Servidor NAS (Samba + WSDD) para Debian 13
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Por favor, ejecuta este script con permisos de superusuario:"
  echo "    sudo bash $0"
  exit 1
fi

echo "[1/5] Actualizando repositorios e instalando Samba y WSDD..."
apt-get update
apt-get install -y samba wsdd

echo "[2/5] Creando estructura de directorios del NAS en /srv/nas..."
mkdir -p /srv/nas/publico
mkdir -p /srv/nas/privado

# Permisos para la carpeta pública (lectura y escritura para todos)
chmod -R 0777 /srv/nas/publico
chown -R nobody:nogroup /srv/nas/publico

# Permisos para la carpeta privada (asociada al usuario nas)
chown -R nas:nas /srv/nas/privado
chmod -R 0770 /srv/nas/privado

echo "[3/5] Respaldando y configurando /etc/samba/smb.conf..."
if [ -f /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf.bak ]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
fi

cat << 'SMBCONF' > /etc/samba/smb.conf
[global]
   workgroup = WORKGROUP
   server string = Servidor NAS (Debian)
   server role = standalone server
   netbios name = EAD-COL
   security = user
   map to guest = bad user
   server min protocol = SMB2_02
   dns proxy = no

   # Optimización de rendimiento para red local
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
   use sendfile = yes

   # Registro de actividad
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

# ==============================================================================
# CARPETAS COMPARTIDAS
# ==============================================================================

# Carpeta de acceso público (sin contraseña, lectura y escritura)
[Publico]
   path = /srv/nas/publico
   browseable = yes
   writable = yes
   guest ok = yes
   guest only = yes
   read only = no
   create mask = 0777
   directory mask = 0777
   force create mode = 0777
   force directory mode = 0777

# Carpeta privada del usuario 'nas' (requiere usuario y contraseña)
[Privado]
   path = /srv/nas/privado
   browseable = yes
   writable = yes
   guest ok = no
   valid users = nas
   create mask = 0770
   directory mask = 0770
   force create mode = 0770
   force directory mode = 0770
SMBCONF

echo "[4/5] Reiniciando y habilitando servicios Samba y WSDD..."
systemctl restart smbd nmbd wsdd
systemctl enable smbd nmbd wsdd

echo "[5/5] Comprobando sintaxis de configuración..."
testparm -s

echo ""
echo "=============================================================================="
echo " ¡Instalación y configuración completada con éxito!"
echo "=============================================================================="
echo ""
echo "-> Siguiente paso IMPORTANTE:"
echo "   Para acceder a la carpeta [Privado], debes establecer la contraseña de Samba para el usuario 'nas':"
echo "   Ejecuta: sudo smbpasswd -a nas"
echo ""
echo "-> Acceso desde Windows:"
echo "   1. Presiona Win + R y escribe: \\\\10.10.1.2"
echo "   2. Verás las carpetas 'Publico' y 'Privado'."
echo "=============================================================================="
