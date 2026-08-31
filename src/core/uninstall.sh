#!/bin/bash
# ==============================================================================
# Motor de Desinstalación y Limpieza Base (Debian 13)
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Este script debe ejecutarse con privilegios de root (sudo bash $0)"
  exit 1
fi

echo "=============================================================================="
echo " [!] INICIANDO DESINSTALACIÓN Y LIMPIEZA TOTAL DEL SERVIDOR"
echo "=============================================================================="

echo "[1/6] Deteniendo y deshabilitando servicios..."
systemctl stop smbd nmbd wsdd2 cockpit.socket cockpit.service 2>/dev/null || true
systemctl disable smbd nmbd wsdd2 cockpit.socket 2>/dev/null || true

echo "[2/6] Desinstalando paquetes de Samba, Cockpit y dependencias..."
DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    samba samba-common samba-common-bin wsdd2 smbclient \
    cockpit cockpit-storaged cockpit-networkmanager cockpit-packagekit \
    cockpit-file-sharing cockpit-identities cockpit-navigator 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

echo "[3/6] Desmontando almacenamiento y limpiando /etc/fstab..."
umount /srv/nas 2>/dev/null || true
sed -i '\|/srv/nas|d' /etc/fstab
systemctl daemon-reload

echo "[4/6] Eliminando archivos de configuración y wrappers..."
rm -rf /etc/samba
rm -f /usr/local/sbin/chage /usr/local/sbin/passwd /usr/local/bin/lastb /usr/bin/lastb
rm -rf /usr/share/cockpit/file-sharing /usr/share/cockpit/identities /usr/share/cockpit/navigator /usr/share/cockpit/backups
rm -f /etc/udev/rules.d/80-udisks2-hide-os.rules

echo "[5/6] Eliminando grupos creados..."
grep -E '^grp_' /etc/group | cut -d: -f1 | while read -r grp; do
    groupdel "$grp" 2>/dev/null || true
done

echo "[6/6] Restaurando /etc/motd..."
> /etc/motd
> /etc/issue.net

echo ""
echo "=============================================================================="
echo " ✔ ¡DESINSTALACIÓN COMPLETADA CON ÉXITO!"
echo " El servidor ha vuelto a su estado base limpio."
echo "=============================================================================="
