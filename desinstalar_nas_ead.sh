#!/bin/bash
# ==============================================================================
# Script de Desinstalación y Limpieza: Servidor NAS EAD-COL (Debian 13)
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Este script debe ejecutarse como root o con sudo:"
  echo "    sudo bash $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================================================="
echo " [!] ADVERTENCIA: Este script desinstalará Samba, Cockpit, WSDD2 y los grupos."
echo "=============================================================================="

echo "[1/6] Deteniendo y deshabilitando servicios..."
systemctl stop smbd nmbd wsdd2 cockpit.socket cockpit.service 2>/dev/null || true
systemctl disable smbd nmbd wsdd2 cockpit.socket 2>/dev/null || true

echo "[2/6] Desinstalando paquetes de Samba, Cockpit y plugins..."
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
rm -f /usr/local/bin/chage /usr/local/bin/passwd /usr/local/bin/lastb /usr/bin/lastb
rm -rf /usr/share/cockpit/file-sharing /usr/share/cockpit/identities /usr/share/cockpit/navigator

echo "[5/6] Eliminando grupos creados..."
for grp in grp_empleados_ead grp_sistemas grp_c1_admin grp_c1_analista grp_c1_asesor grp_c2_admin grp_c2_analista grp_c2_asesor grp_backups; do
    groupdel "$grp" 2>/dev/null || true
done

echo "[6/6] Restaurando /etc/motd..."
> /etc/motd
> /etc/issue.net

echo ""
echo "=============================================================================="
echo " ✔ ¡DESINSTALACIÓN Y LIMPIEZA COMPLETADAS CON ÉXITO!"
echo " El servidor ha vuelto a su estado base limpio."
echo " Para reinstalar todo desde cero en cualquier momento, ejecuta:"
echo " sudo bash \"$SCRIPT_DIR/asistente_nas.sh\""
echo "=============================================================================="
