#!/bin/bash
# ==============================================================================
#  ASISTENTE NAS & BACKUP EMPRESARIAL • EAD-COL (DEBIAN 13)
# ==============================================================================

# Forzar ejecución con privilegios de root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Este asistente requiere privilegios de administrador."
  echo "    Ejecutando: sudo bash $0"
  exec sudo bash "$0" "$@"
fi

# Restablecer colores nativos estándar y asegurar terminal compatible
unset NEWT_COLORS
if [ -z "$TERM" ] || [ "$TERM" = "dumb" ] || [ "$TERM" = "unknown" ]; then
    export TERM="xterm-256color"
fi

# Colores ANSI para terminal
C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_WHITE="\033[1;37m"
C_GRAY="\033[0;90m"
C_BOLD="\033[1m"
C_RESET="\033[0m"

APP_TITLE="SERVIDOR NAS & BACKUP • EAD-COL"

# Directorio base del script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Función para obtener la IP principal del servidor
obtener_ip_local() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}

# Función para obtener usuario administrador predeterminado del sistema
obtener_usuario_defecto() {
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
    else
        local u
        u=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1; exit}' /etc/passwd)
        echo "${u:-nas}"
    fi
}

# Obtener nombre de servidor / NetBIOS por defecto según entorno y rol
obtener_netbios_defecto() {
    local rol="$1"
    local cur_host
    if command -v testparm &>/dev/null && [ -f /etc/samba/smb.conf ]; then
        local smb_name
        smb_name=$(testparm -s --parameter-name="netbios name" 2>/dev/null || true)
        if [ -n "$smb_name" ] && [ "$smb_name" != "NONE" ]; then
            echo "$smb_name"
            return
        fi
    fi
    cur_host=$(hostname -s 2>/dev/null | tr 'a-z' 'A-Z')
    if [ -n "$cur_host" ]; then
        echo "$cur_host"
    else
        [ "$rol" == "BACKUP" ] && echo "SRV-EAD-BKP" || echo "SRV-EAD-NAS"
    fi
}

# Obtener grupo de trabajo Samba o Dominio por defecto
obtener_workgroup_defecto() {
    local wg=""
    if command -v testparm &>/dev/null && [ -f /etc/samba/smb.conf ]; then
        wg=$(testparm -s --parameter-name=workgroup 2>/dev/null || true)
    fi
    [ -z "$wg" ] && wg="WORKGROUP"
    echo "$wg"
}

SERVER_IP=$(obtener_ip_local)

mkdir -p /etc/backup-credentials /mnt/backup_sources /srv/nas/BACKUPS_HISTORICOS /srv/nas/LOGS_BACKUP /usr/local/bin
chmod 700 /etc/backup-credentials

# ==============================================================================
# 1. FUNCIÓN: ASISTENTE DE DESPLIEGUE GUIADO (ARCHIVOS O BACKUP)
# ==============================================================================
instalar_nas() {
    SERVER_IP=$(obtener_ip_local)

    ROL_SERVER=$(whiptail --title "Paso 1 de 5: Rol del Servidor" \
        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
        --menu "Selecciona la función principal que tendrá este servidor:" 15 72 2 \
        "ARCHIVOS" "Servidor NAS de Archivos (Departamentos y Campañas)" \
        "BACKUP"   "Servidor de Copias de Seguridad (Central de Respaldos)" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$ROL_SERVER" ]; then return; fi

    DEFAULT_NETBIOS=$(obtener_netbios_defecto "$ROL_SERVER")
    DEFAULT_WORKGROUP=$(obtener_workgroup_defecto)
    DEFAULT_USER=$(obtener_usuario_defecto)

    # Detección dinámica de disco raíz (SO)
    ROOT_DISK=""
    ROOT_PART=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [ -n "$ROOT_PART" ]; then
        R_DISK=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null | head -n 1)
        [ -n "$R_DISK" ] && ROOT_DISK="/dev/$R_DISK"
    fi

    # Generar opciones dinámicas para whiptail --radiolist
    mapfile -t DISK_ITEMS < <(python3 -c '
import subprocess, json, sys

def get_mounts(dev):
    mounts = []
    if dev.get("mountpoint"):
        mounts.append(dev["mountpoint"])
    for child in dev.get("children", []):
        mounts.extend(get_mounts(child))
    return mounts

def format_size(bytes_val):
    for unit in ["B", "K", "M", "G", "T"]:
        if bytes_val < 1024:
            return f"{bytes_val:.1f} {unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f} P"

root_disk = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    out = subprocess.check_output(["lsblk", "-J", "-b", "-o", "NAME,PATH,SIZE,TYPE,MOUNTPOINT,MODEL"]).decode()
    data = json.loads(out)
except Exception:
    data = {"blockdevices": []}

disks = []
has_secondary = False

for dev in data.get("blockdevices", []):
    if dev.get("type") == "disk":
        path = dev.get("path", "/dev/" + dev.get("name", ""))
        size_b = dev.get("size", 0)
        size_str = format_size(size_b)
        model = (dev.get("model") or "").strip()
        mounts = get_mounts(dev)

        is_root = (path == root_disk) or ("/" in mounts) or ("/boot" in mounts) or ("/boot/efi" in mounts)
        is_nas = "/srv/nas" in mounts

        if is_root:
            desc = f"{size_str} [SISTEMA OPERATIVO /] (PELIGRO - NO FORMATEAR)"
            status = "OFF"
        elif is_nas:
            desc = f"{size_str} [ACTUAL DATOS NAS /srv/nas]"
            status = "ON"
            has_secondary = True
        elif len(mounts) == 0:
            desc = f"{size_str} [DISCO LIBRE - RECOMENDADO] {model}".strip()
            status = "ON" if not has_secondary else "OFF"
            has_secondary = True
        else:
            m_str = ",".join(mounts)
            desc = f"{size_str} [MONTADO: {m_str}] {model}".strip()
            status = "OFF"

        disks.append((path, desc, status))

local_status = "ON" if not has_secondary else "OFF"
disks.append(("LOCAL", "Usar particion actual (/srv/nas) sin formatear disco", local_status))

on_found = False
final_items = []
for p, d, s in disks:
    if s == "ON" and not on_found:
        on_found = True
        final_items.extend([p, d, "ON"])
    else:
        final_items.extend([p, d, "OFF"])

if not on_found and final_items:
    final_items[2] = "ON"

for item in final_items:
    print(item)
' "$ROOT_DISK")

    NUM_ITEMS=$((${#DISK_ITEMS[@]} / 3))
    [ "$NUM_ITEMS" -lt 1 ] && NUM_ITEMS=1

    DISCO_SELECCIONADO=$(whiptail --title "Paso 2 de 5: Disco de Almacenamiento" \
        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
        --radiolist "Discos detectados en este servidor ($ROL_SERVER):" 18 76 $NUM_ITEMS \
        "${DISK_ITEMS[@]}" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$DISCO_SELECCIONADO" ]; then return; fi

    # Validación de seguridad si se eligió el disco que contiene el SO
    if [ "$DISCO_SELECCIONADO" == "$ROOT_DISK" ] && [ -n "$ROOT_DISK" ]; then
        if (whiptail --title "¡ALERTA CRÍTICA DE SEGURIDAD!" \
            --yes-button "< Volver y Seleccionar Otro >" --no-button "< Continuar de todos modos >" \
            --yesno "⚠ ADVERTENCIA GRAVE:\n\nEl disco seleccionado ($DISCO_SELECCIONADO) contiene el SISTEMA OPERATIVO (/).\n\nSi formateas este disco, Debian quedará DESTRUIDO e INUTILIZABLE.\n\n¿Deseas volver y seleccionar otro disco o partición local?" 15 72); then
            return
        else
            CONFIRM_FORMAT=$(whiptail --title "Confirmación Extrema Requerida" \
                --ok-button "< Confirmar >" --cancel-button "< Cancelar >" \
                --inputbox "Para formatear el disco del sistema operativo, escribe exactamente BORRAR_TODO:" 10 65 3>&1 1>&2 2>&3)
            if [ "$CONFIRM_FORMAT" != "BORRAR_TODO" ]; then
                whiptail --title "Operación Cancelada" --ok-button "< Aceptar >" --msgbox "Acción cancelada por protección del sistema." 8 50
                return
            fi
        fi
    fi

    SMB_NETBIOS=$(whiptail --title "Paso 3 de 5: Nombre del Servidor (NetBIOS)" \
        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
        --inputbox "Ingresa el nombre de red NetBIOS para este servidor:" 10 65 "$DEFAULT_NETBIOS" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$SMB_NETBIOS" ]; then return; fi

    SMB_WORKGROUP=$(whiptail --title "Paso 3 de 5: Grupo de Trabajo / Dominio" \
        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
        --inputbox "Ingresa el Grupo de Trabajo (Workgroup) o Dominio NetBIOS:" 10 68 "$DEFAULT_WORKGROUP" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$SMB_WORKGROUP" ]; then return; fi

    USUARIO_ACTUAL="$DEFAULT_USER"

    OPCION_USER=$(whiptail --title "Paso 4 de 5: Administrador de Cockpit" \
        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
        --menu "Selecciona la cuenta que administrará el panel web Cockpit y el servidor:" 14 70 2 \
        "1" "Usar usuario detectado: [$USUARIO_ACTUAL] (Recomendado)" \
        "2" "Crear o especificar otro usuario administrador" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$OPCION_USER" ]; then return; fi

    ADMIN_USER="$USUARIO_ACTUAL"
    if [ "$OPCION_USER" == "2" ]; then
        ADMIN_USER=$(whiptail --title "Nuevo Administrador" \
            --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
            --inputbox "Ingresa el nombre de usuario para el nuevo administrador:" 10 65 "admin_nas" 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$ADMIN_USER" ]; then return; fi
    fi

    while true; do
        ADMIN_PASS=$(whiptail --title "Contraseña de Red Samba ($ADMIN_USER)" \
            --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
            --passwordbox "Ingresa la contraseña de red para $ADMIN_USER (Requerida por Samba/Windows):" 10 70 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then return; fi
        if [ -n "$ADMIN_PASS" ]; then break; fi
        whiptail --title "Contraseña Requerida" --ok-button "< Aceptar >" \
            --msgbox "Samba requiere una contraseña para que Windows pueda autenticar y conectar a las carpetas compartidas." 9 65
    done

    RESUMEN="PARAMETROS DE CONFIGURACION:
* Funcion Principal    : $ROL_SERVER
* Direccion IP Red     : $SERVER_IP
* Disco Almacenamiento : $DISCO_SELECCIONADO
* Nombre del Servidor  : $SMB_NETBIOS
* Grupo / Dominio      : $SMB_WORKGROUP
* Administrador Web    : $ADMIN_USER (Permisos sudo y Samba)

INCLUYE PARCHES AUTOMATICOS:
- Integracion Cockpit File Sharing y difusion WSDD2 / LLMNR
- Wrappers de compatibilidad en espanol (chage / passwd / lastb)
- Herramientas multiplataforma de Backup (CIFS, Rsync, SSHPass, Cron)

¿Confirmas la configuracion y el despliegue completo?"

    if (whiptail --title "Paso 5 de 5: Confirmación Crítica" \
        --yes-button "< Sí, Iniciar Despliegue >" --no-button "< Cancelar >" \
        --yesno "$RESUMEN" 20 74); then
        
        clear
        echo -e "${C_CYAN}"
        echo "  ╭──────────────────────────────────────────────────────────────────────╮"
        echo "  │        INICIANDO DESPLIEGUE AUTOMATIZADO DEL SERVIDOR ($ROL_SERVER)   │"
        echo "  ╰──────────────────────────────────────────────────────────────────────╯${C_RESET}\n"
        
        bash "$SCRIPT_DIR/ejecutar_configuracion_ead.sh" "$DISCO_SELECCIONADO" "$SMB_WORKGROUP" "$SMB_NETBIOS" "$ADMIN_USER" "$ADMIN_PASS" "$ROL_SERVER"
        local ret_exec=$?
        
        if [ $ret_exec -eq 0 ]; then
            whiptail --title "$APP_TITLE" --ok-button "< Finalizar >" \
                --msgbox "✔ ¡Despliegue del Servidor ($ROL_SERVER) Completado con Éxito!\n\n• Panel Web Cockpit: https://${SERVER_IP}:9090\n• Administrador:     $ADMIN_USER (con permisos sudo y Samba)\n• Grupo Maestro:     grp_sistemas (Permisos totales sobre /srv/nas)\n• Redes Compartidas: 0 (Servidor base 100% limpio)\n\n💡 SIGUIENTE PASO:\nUtiliza las opciones [2] y [3] del menú para crear tus grupos y definir tus carpetas compartidas (visibles u ocultas $) a medida." 17 74
        else
            whiptail --title "Error en el Despliegue" --ok-button "< Aceptar >" \
                --msgbox "✖ Ocurrió un error durante la ejecución del script de despliegue (Código de salida: $ret_exec).\n\nRevisa los mensajes anteriores en la consola." 12 70
        fi
    fi
}

# ==============================================================================
# 2. FUNCIÓN: GESTIÓN DE GRUPOS DE SEGURIDAD
# ==============================================================================
gestionar_grupos() {
    while true; do
        OPC_GRP=$(whiptail --title "$APP_TITLE" \
            --ok-button "< Seleccionar >" --cancel-button "< Volver >" \
            --menu "GESTIÓN DE GRUPOS DE SEGURIDAD:" 16 68 4 \
            "1" "[*] Listar grupos existentes" \
            "2" "[+] Crear un nuevo grupo" \
            "3" "[-] Eliminar un grupo existente" \
            "4" "[<] Volver al Menú Principal" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$OPC_GRP" == "4" ]; then
            break
        fi

        case "$OPC_GRP" in
            1)
                GRUPOS_TXT=$(awk -F: '/^grp_/ {printf "  %-22s | GID: %-5s | Miembros: %s\n", $1, $3, ($4==""?"(Sin miembros)":$4)}' /etc/group)
                [ -z "$GRUPOS_TXT" ] && GRUPOS_TXT="  (No hay grupos con prefijo grp_ creados)"
                HEADER="  GRUPO                  | GID   | MIEMBROS\n  ─────────────────────────────────────────────────────────────────\n"
                whiptail --title "Grupos de Seguridad Registrados" --ok-button "< Aceptar >" --msgbox "${HEADER}${GRUPOS_TXT}" 18 72
                ;;
            2)
                NUEVO_GRP=$(whiptail --title "$APP_TITLE" \
                    --ok-button "< Continuar >" --cancel-button "< Cancelar >" \
                    --inputbox "Ingresa el nombre del nuevo grupo (ej. grp_contabilidad):" 10 60 "grp_" 3>&1 1>&2 2>&3)
                
                if [ $? -eq 0 ] && [ -n "$NUEVO_GRP" ] && [ "$NUEVO_GRP" != "grp_" ]; then
                    if (whiptail --title "Confirmación" \
                        --yes-button "< Sí, Crear Grupo >" --no-button "< Cancelar >" \
                        --yesno "¿Estás seguro de que deseas crear el grupo de seguridad \"$NUEVO_GRP\" en el sistema?" 10 65); then
                        groupadd -f "$NUEVO_GRP"
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" --msgbox "✔ Grupo \"$NUEVO_GRP\" creado correctamente." 8 50
                    fi
                fi
                ;;
            3)
                DEL_GRP=$(whiptail --title "$APP_TITLE" \
                    --ok-button "< Continuar >" --cancel-button "< Cancelar >" \
                    --inputbox "Ingresa el nombre del grupo que deseas eliminar:" 10 60 3>&1 1>&2 2>&3)
                
                if [ $? -eq 0 ] && [ -n "$DEL_GRP" ]; then
                    if (whiptail --title "Confirmación de Eliminación" \
                        --yes-button "< Sí, Eliminar Grupo >" --no-button "< Cancelar >" \
                        --yesno "¿Estás seguro de que deseas eliminar permanentemente el grupo \"$DEL_GRP\"?" 10 65); then
                        if groupdel "$DEL_GRP" 2>/dev/null; then
                            whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" --msgbox "✔ Grupo \"$DEL_GRP\" eliminado exitosamente." 8 50
                        else
                            whiptail --title "Error" --ok-button "< Aceptar >" --msgbox "✖ No se pudo eliminar el grupo \"$DEL_GRP\" (Verifique que exista)." 8 55
                        fi
                    fi
                fi
                ;;
        esac
    done
}

# ==============================================================================
# 3. FUNCIÓN: GESTIÓN DE RECURSOS COMPARTIDOS (CARPETAS EN RED)
# ==============================================================================
gestionar_recursos_compartidos() {
    if [ ! -f /etc/samba/smb.conf ]; then
        whiptail --title "Aviso del Sistema" --ok-button "< Aceptar >" \
            --msgbox "Samba aún no ha sido instalado o configurado en este servidor.\n\nPor favor, ejecuta primero la opción [1] Desplegar Servidor." 10 65
        return
    fi

    while true; do
        OPC_REC=$(whiptail --title "$APP_TITLE" \
            --ok-button "< Seleccionar >" --cancel-button "< Volver >" \
            --menu "GESTIÓN DE RECURSOS COMPARTIDOS (SAMBA):" 16 70 5 \
            "1" "[*] Listar y ver detalles de recursos compartidos" \
            "2" "[+] Crear un nuevo recurso compartido" \
            "3" "[#] Deshabilitar / Habilitar un recurso existente" \
            "4" "[-] Eliminar un recurso compartido de la red" \
            "5" "[<] Volver al Menú Principal" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$OPC_REC" == "5" ]; then
            break
        fi

        case "$OPC_REC" in
            1)
                LISTA_DETALLADA=$(python3 -c '
import re
with open("/etc/samba/smb.conf", "r", encoding="utf-8") as f:
    lines = f.readlines()
shares = {}
current = None
for line in lines:
    m = re.match(r"^\s*\[([^\]]+)\]", line)
    if m:
        sec = m.group(1).strip()
        if sec.lower() != "global":
            current = sec
            shares[current] = {"path": "N/A", "valid_users": "Todos", "available": "yes", "browseable": "yes", "read_only": "no", "write_list": ""}
        else:
            current = None
    elif current and "=" in line:
        k, v = line.split("=", 1)
        k, v = k.strip().lower(), v.strip()
        if k == "path": shares[current]["path"] = v
        elif k == "valid users": shares[current]["valid_users"] = v
        elif k == "write list": shares[current]["write_list"] = v
        elif k == "read only": shares[current]["read_only"] = v
        elif k == "browseable": shares[current]["browseable"] = v
        elif k == "available": shares[current]["available"] = v

for name, d in shares.items():
    st = "[ACTIVO]" if d["available"] != "no" else "[DESHABILITADO]"
    vis = "[OCULTO $]" if d["browseable"] == "no" or name.endswith("$") else "[VISIBLE]"
    perm = "Solo Lectura" if d["read_only"] == "yes" else "Lectura/Escritura"
    p = d["path"]
    w = d["write_list"]
    u = d["valid_users"]
    print(f" {st} {vis} [{name}]")
    print(f"   • Ruta:      {p}")
    print(f"   • Permisos:  {perm}")
    if w:
        print(f"   • Escritura: {w}")
    print(f"   • Acceso:    {u}\n")
')
                [ -z "$LISTA_DETALLADA" ] && LISTA_DETALLADA="No hay recursos compartidos configurados."
                whiptail --title "Recursos Compartidos Activos en el NAS" --ok-button "< Aceptar >" --msgbox "$LISTA_DETALLADA" 22 76
                ;;

            2)
                NOMBRE_SHARE=$(whiptail --title "$APP_TITLE" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --inputbox "Ingresa el nombre del recurso para Windows (ej. VENTAS o BACKUPS):" 10 65 3>&1 1>&2 2>&3)
                if [ $? -ne 0 ] || [ -z "$NOMBRE_SHARE" ]; then continue; fi

                NOMBRE_SHARE=$(echo "$NOMBRE_SHARE" | tr " " "_" | tr -cd "A-Za-z0-9_$-")

                OPC_VIS=$(whiptail --title "Visibilidad en Red (Samba / Windows)" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona la visibilidad del recurso en el entorno de red de Windows:" 15 72 2 \
                    "1" "Recurso OCULTO ($) - No visible en explorador (Recomendado)" \
                    "2" "Recurso VISIBLE - Visible en explorador de red para todos" 3>&1 1>&2 2>&3)
                if [ $? -ne 0 ] || [ -z "$OPC_VIS" ]; then continue; fi

                if [ "$OPC_VIS" == "1" ]; then
                    [[ "$NOMBRE_SHARE" != *\$ ]] && NOMBRE_SHARE="${NOMBRE_SHARE}\$"
                    BROWSEABLE="no"
                    VIS_TXT="Oculto ($) [Invisible en explorador de red]"
                else
                    NOMBRE_SHARE="${NOMBRE_SHARE%\$}"
                    BROWSEABLE="yes"
                    VIS_TXT="Visible en red"
                fi

                NOMBRE_DIR="${NOMBRE_SHARE%\$}"
                RUTA_SHARE=$(whiptail --title "$APP_TITLE" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --inputbox "Ruta física en el disco del servidor:" 10 65 "/srv/nas/$NOMBRE_DIR" 3>&1 1>&2 2>&3)
                if [ $? -ne 0 ] || [ -z "$RUTA_SHARE" ]; then continue; fi

                COMENTARIO=$(whiptail --title "$APP_TITLE" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --inputbox "Descripción o comentario del recurso:" 10 65 "Carpeta compartida $NOMBRE_DIR" 3>&1 1>&2 2>&3)
                [ -z "$COMENTARIO" ] && COMENTARIO="Carpeta compartida $NOMBRE_DIR"

                TIPO_PERM=$(whiptail --title "Esquema de Seguridad y Permisos" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el esquema de permisos para este recurso:" 16 72 4 \
                    "1" "Lectura y Escritura (Todos los grupos autorizados pueden editar)" \
                    "2" "Solo Lectura General + Escritura Exclusiva (write list)" \
                    "3" "Solo Lectura Estricta (Nadie puede modificar desde la red)" \
                    "4" "Acceso Público / Invitados (Sin contraseña)" 3>&1 1>&2 2>&3)
                if [ $? -ne 0 ] || [ -z "$TIPO_PERM" ]; then continue; fi

                GRUPO_DUENO="grp_sistemas"
                VALID_USERS=""
                WRITE_LIST=""
                READ_ONLY="no"
                GUEST_OK="no"
                MASK="0770"
                TIPO_TXT=""

                # Obtener grupos disponibles
                GRUPOS_DISP=$(awk -F: '($3 >= 1000 || $1 ~ /^grp_/) && $1 !~ /^(nogroup|nobody)$/ {print $1}' /etc/group | sort -u)

                case "$TIPO_PERM" in
                    1)
                        # Lectura y Escritura por Grupos
                        TIPO_TXT="Lectura y Escritura para Grupos Seleccionados"
                        READ_ONLY="no"
                        MASK="0770"

                        if [ -z "$GRUPOS_DISP" ]; then
                            whiptail --title "Sin Grupos" --ok-button "< Aceptar >" \
                                --msgbox "No hay grupos de seguridad registrados en el sistema.\nCrea primero un grupo desde la opción [2]." 10 60
                            continue
                        fi

                        LISTA_OPCIONES=""
                        for g in $GRUPOS_DISP; do
                            LISTA_OPCIONES="$LISTA_OPCIONES $g $g OFF"
                        done

                        GRUPOS_SELEC=$(whiptail --title "Grupos con Lectura y Escritura" \
                            --ok-button "< Continuar >" --cancel-button "< Cancelar >" \
                            --checklist "Marca con ESPACIO los grupos autorizados para lectura y escritura:" 18 70 8 \
                            $LISTA_OPCIONES 3>&1 1>&2 2>&3)

                        if [ -z "$GRUPOS_SELEC" ]; then
                            whiptail --ok-button "< Aceptar >" --msgbox "Debes seleccionar al menos un grupo." 8 45
                            continue
                        fi

                        GRUPOS_LIMPIOS=$(echo "$GRUPOS_SELEC" | tr -d '\"')
                        V_LIST=""
                        for g in $GRUPOS_LIMPIOS; do
                            [ -z "$V_LIST" ] && V_LIST="@$g" || V_LIST="$V_LIST, @$g"
                            GRUPO_DUENO="$g"
                        done
                        if grep -q "^grp_sistemas:" /etc/group && [[ "$V_LIST" != *"@grp_sistemas"* ]]; then
                            V_LIST="@grp_sistemas, $V_LIST"
                        fi
                        VALID_USERS="$V_LIST"
                        ;;

                    2)
                        # Solo Lectura General + Escritura Exclusiva (write list)
                        TIPO_TXT="Solo Lectura General con Escritura Exclusiva (write list)"
                        READ_ONLY="yes"
                        MASK="0775"

                        if [ -z "$GRUPOS_DISP" ]; then
                            whiptail --title "Sin Grupos" --ok-button "< Aceptar >" \
                                --msgbox "No hay grupos registrados. Crea un grupo primero en la opción [2]." 10 60
                            continue
                        fi

                        LISTA_OPC_R=""
                        for g in $GRUPOS_DISP; do
                            LISTA_OPC_R="$LISTA_OPC_R $g $g OFF"
                        done

                        # Paso A: Grupos con acceso de lectura
                        GRUPOS_R=$(whiptail --title "Grupos con Acceso de Lectura" \
                            --ok-button "< Continuar >" --cancel-button "< Cancelar >" \
                            --checklist "Marca con ESPACIO los grupos que podrán ver y descargar archivos:" 18 70 8 \
                            $LISTA_OPC_R 3>&1 1>&2 2>&3)

                        if [ -z "$GRUPOS_R" ]; then
                            whiptail --ok-button "< Aceptar >" --msgbox "Debes seleccionar al menos un grupo de lectura." 8 45
                            continue
                        fi

                        # Paso B: Grupo con permiso exclusivo de escritura
                        LISTA_OPC_W=""
                        for g in $GRUPOS_DISP; do
                            LISTA_OPC_W="$LISTA_OPC_W $g Grupo_$g"
                        done

                        GRUPO_W=$(whiptail --title "Grupo con Permiso de ESCRITURA" \
                            --ok-button "< Continuar >" --cancel-button "< Cancelar >" \
                            --menu "Selecciona el grupo único que podrá SUBIR, EDITAR y BORRAR archivos:" 18 70 8 \
                            $LISTA_OPC_W 3>&1 1>&2 2>&3)

                        if [ -z "$GRUPO_W" ]; then continue; fi

                        GRUPOS_R_CLEAN=$(echo "$GRUPOS_R" | tr -d '\"')
                        V_LIST=""
                        for g in $GRUPOS_R_CLEAN; do
                            [ -z "$V_LIST" ] && V_LIST="@$g" || V_LIST="$V_LIST, @$g"
                        done
                        if [[ "$V_LIST" != *"@$GRUPO_W"* ]]; then
                            V_LIST="$V_LIST, @$GRUPO_W"
                        fi

                        VALID_USERS="$V_LIST"
                        WRITE_LIST="@$GRUPO_W"
                        GRUPO_DUENO="$GRUPO_W"
                        ;;

                    3)
                        # Solo Lectura Estricta
                        TIPO_TXT="Solo Lectura Estricta (Nadie puede modificar desde la red)"
                        READ_ONLY="yes"
                        MASK="0755"

                        LISTA_OPCIONES=""
                        for g in $GRUPOS_DISP; do
                            LISTA_OPCIONES="$LISTA_OPCIONES $g $g OFF"
                        done

                        GRUPOS_SELEC=$(whiptail --title "Grupos Autorizados para Lectura" \
                            --ok-button "< Continuar >" --cancel-button "< Cancelar >" \
                            --checklist "Marca los grupos que tendrán acceso de solo lectura:" 18 70 8 \
                            $LISTA_OPCIONES 3>&1 1>&2 2>&3)

                        if [ -z "$GRUPOS_SELEC" ]; then
                            whiptail --ok-button "< Aceptar >" --msgbox "Debes seleccionar al menos un grupo." 8 45
                            continue
                        fi

                        GRUPOS_LIMPIOS=$(echo "$GRUPOS_SELEC" | tr -d '\"')
                        V_LIST=""
                        for g in $GRUPOS_LIMPIOS; do
                            [ -z "$V_LIST" ] && V_LIST="@$g" || V_LIST="$V_LIST, @$g"
                            GRUPO_DUENO="$g"
                        done
                        VALID_USERS="$V_LIST"
                        ;;

                    4)
                        # Acceso Público / Invitados
                        OPC_PUB=$(whiptail --title "Acceso Público (Invitados)" \
                            --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                            --menu "Selecciona el nivel de acceso para usuarios sin credenciales:" 14 68 2 \
                            "1" "Solo Lectura (Invitados solo ven y descargan)" \
                            "2" "Lectura y Escritura Total (Invitados pueden subir y borrar)" 3>&1 1>&2 2>&3)
                        if [ $? -ne 0 ] || [ -z "$OPC_PUB" ]; then continue; fi

                        GUEST_OK="yes"
                        VALID_USERS=""
                        if [ "$OPC_PUB" == "1" ]; then
                            TIPO_TXT="Acceso Público (Solo Lectura)"
                            READ_ONLY="yes"
                            MASK="0755"
                        else
                            TIPO_TXT="Acceso Público (Lectura y Escritura Libre)"
                            READ_ONLY="no"
                            MASK="0777"
                        fi
                        ;;
                esac

                if (whiptail --title "Confirmar Creación de Recurso" \
                    --yes-button "< Sí, Crear Recurso >" --no-button "< Cancelar >" \
                    --yesno "¿Confirmas la creación del recurso con los siguientes parámetros?\n\n• Nombre:      [$NOMBRE_SHARE]\n• Visibilidad: $VIS_TXT\n• Ruta Disco:   $RUTA_SHARE\n• Esquema:     $TIPO_TXT\n• Acceso:      ${VALID_USERS:-Invitados (Público)}\n• Escritura:   ${WRITE_LIST:-Según Permisos Generales}\n\n• Ruta de red: \\\\${SERVER_IP}\\$NOMBRE_SHARE" 17 72); then
                    
                    mkdir -p "$RUTA_SHARE"
                    if [ "$TIPO_PERM" == "1" ]; then
                        chown -R root:"$GRUPO_DUENO" "$RUTA_SHARE"
                        chmod -R 2770 "$RUTA_SHARE"
                    elif [ "$TIPO_PERM" == "2" ]; then
                        chown -R root:"$GRUPO_DUENO" "$RUTA_SHARE"
                        chmod -R 2775 "$RUTA_SHARE"
                    elif [ "$TIPO_PERM" == "3" ]; then
                        chown -R root:"$GRUPO_DUENO" "$RUTA_SHARE"
                        chmod -R 2755 "$RUTA_SHARE"
                    elif [ "$TIPO_PERM" == "4" ]; then
                        if [ "$OPC_PUB" == "1" ]; then
                            chown -R nobody:nogroup "$RUTA_SHARE"
                            chmod -R 0755 "$RUTA_SHARE"
                        else
                            chown -R nobody:nogroup "$RUTA_SHARE"
                            chmod -R 0777 "$RUTA_SHARE"
                        fi
                    fi

                    cat << SMBCONF >> /etc/samba/smb.conf

# ==============================================================================
# RECURSO COMPARTIDO: $NOMBRE_SHARE
# ==============================================================================
[$NOMBRE_SHARE]
   comment = $COMENTARIO
   path = $RUTA_SHARE
   browseable = $BROWSEABLE
   read only = $READ_ONLY
   guest ok = $GUEST_OK
$([ -n "$VALID_USERS" ] && echo "   valid users = $VALID_USERS")
$([ -n "$WRITE_LIST" ] && echo "   write list = $WRITE_LIST")
   create mask = $MASK
   directory mask = $MASK
   force create mode = $MASK
   force directory mode = $MASK
SMBCONF
                    testparm -s &>/dev/null || true
                    smbcontrol all reload-config 2>/dev/null || systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
                    whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                        --msgbox "✔ ¡Recurso \"[$NOMBRE_SHARE]\" creado con éxito!\n\n• Visibilidad: $VIS_TXT\n• Ruta Disco:  $RUTA_SHARE\n• Esquema:    $TIPO_TXT\n\nAccesible desde Windows en: \\\\${SERVER_IP}\\$NOMBRE_SHARE" 14 72
                fi
                ;;

            3)
                LISTA_SHARES=$(python3 -c '
import re
with open("/etc/samba/smb.conf", "r", encoding="utf-8") as f:
    text = f.read()
for m in re.finditer(r"\[([^\]]+)\]", text):
    s = m.group(1).strip()
    if s.lower() != "global":
        sec_start = m.start()
        next_sec = text.find("[", sec_start + 1)
        block = text[sec_start:next_sec] if next_sec != -1 else text[sec_start:]
        st = "[DESHABILITADO]" if "available = no" in block else "[ACTIVO]"
        print(f"{s} {st}")
')
                if [ -z "$LISTA_SHARES" ]; then
                    whiptail --ok-button "< Aceptar >" --msgbox "No hay recursos compartidos disponibles." 8 45
                    continue
                fi

                MENU_ITEMS=""
                while read -r name status; do
                    MENU_ITEMS="$MENU_ITEMS $name $status"
                done <<< "$LISTA_SHARES"

                TARGET_SHARE=$(whiptail --title "Alternar Estado de Recurso" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el recurso para conmutar su estado en la red:" 18 70 8 \
                    $MENU_ITEMS 3>&1 1>&2 2>&3)

                if [ $? -eq 0 ] && [ -n "$TARGET_SHARE" ]; then
                    if (whiptail --title "Confirmar Cambio de Estado" \
                        --yes-button "< Sí, Cambiar Estado >" --no-button "< Cancelar >" \
                        --yesno "¿Estás seguro de que deseas conmutar el estado del recurso \"[$TARGET_SHARE]\" en la red?" 10 68); then
                        
                        NUEVO_ESTADO=$(python3 -c '
import sys, re
target = sys.argv[1]
with open("/etc/samba/smb.conf", "r", encoding="utf-8") as f:
    text = f.read()

pattern = re.compile(rf"(\[{re.escape(target)}\][\s\S]*?)(?=\n\[|\Z)")
m = pattern.search(text)
if m:
    block = m.group(1)
    if "available = no" in block:
        block = block.replace("available = no\n", "").replace("browseable = no", "browseable = yes")
        msg = "HABILITADO (En línea)"
    else:
        block = block.replace("browseable = yes", "browseable = no")
        if "browseable = no" not in block:
            block = block.replace(f"[{target}]\n", f"[{target}]\n   browseable = no\n")
        block = block.replace(f"[{target}]\n", f"[{target}]\n   available = no\n")
        msg = "DESHABILITADO (Fuera de línea)"
    text = text[:m.start()] + block + text[m.end():]
    with open("/etc/samba/smb.conf", "w", encoding="utf-8") as f:
        f.write(text)
    print(msg)
' "$TARGET_SHARE")
                        testparm -s &>/dev/null || true
                        smbcontrol all reload-config 2>/dev/null || systemctl reload smbd 2>/dev/null || true
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" --msgbox "✔ El recurso \"[$TARGET_SHARE]\" ahora está:\n$NUEVO_ESTADO" 9 55
                    fi
                fi
                ;;

            4)
                LISTA_ELIMINAR=$(python3 -c '
import re
with open("/etc/samba/smb.conf", "r", encoding="utf-8") as f:
    lines = f.readlines()
for line in lines:
    m = re.match(r"^\s*\[([^\]]+)\]", line)
    if m and m.group(1).strip().lower() != "global":
        print(m.group(1).strip())
')
                if [ -z "$LISTA_ELIMINAR" ]; then
                    whiptail --ok-button "< Aceptar >" --msgbox "No hay recursos disponibles para eliminar." 8 45
                    continue
                fi

                MENU_DEL=""
                for s in $LISTA_ELIMINAR; do
                    MENU_DEL="$MENU_DEL $s Recurso_Samba"
                done

                SHARE_A_BORRAR=$(whiptail --title "Eliminar Recurso Compartido" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el recurso que deseas eliminar definitivamente:" 18 70 8 \
                    $MENU_DEL 3>&1 1>&2 2>&3)

                if [ $? -eq 0 ] && [ -n "$SHARE_A_BORRAR" ]; then
                    if (whiptail --title "Confirmación de Eliminación" \
                        --yes-button "< Sí, Eliminar Recurso >" --no-button "< Cancelar >" \
                        --yesno "¿Estás 100% seguro de eliminar la definición del recurso \"[$SHARE_A_BORRAR]\" de la red Samba?\n\n(Nota: Los archivos físicos en el disco se mantendrán protegidos)." 11 68); then
                        
                        python3 -c '
import sys, re
target = sys.argv[1]
with open("/etc/samba/smb.conf", "r", encoding="utf-8") as f:
    text = f.read()

text = re.sub(rf"# =+\n# RECURSO COMPARTIDO: {re.escape(target)}\n# =+\n", "", text)
text = re.sub(rf"\[{re.escape(target)}\][\s\S]*?(?=\n\[|\Z)", "", text)

with open("/etc/samba/smb.conf", "w", encoding="utf-8") as f:
    f.write(text.strip() + "\n")
' "$SHARE_A_BORRAR"
                        testparm -s &>/dev/null || true
                        smbcontrol all reload-config 2>/dev/null || systemctl reload smbd 2>/dev/null || true
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" --msgbox "✔ El recurso \"[$SHARE_A_BORRAR]\" ha sido eliminado de la red Samba." 8 60
                    fi
                fi
                ;;
        esac
    done
}

# ==============================================================================
# 4. FUNCIÓN: GESTIÓN DE TAREAS DE BACKUP (CON BUCLE DE EDICIÓN CONTINUA)
# ==============================================================================
gestionar_backups() {
    while true; do
        OPC_BKP=$(whiptail --title "$APP_TITLE" \
            --ok-button "< Seleccionar >" --cancel-button "< Volver >" \
            --menu "GESTIÓN DE TAREAS DE BACKUP (WINDOWS & LINUX):" 16 72 5 \
            "1" "[*] Listar tareas de backup programadas" \
            "2" "[+] Crear nueva tarea de backup automatizada" \
            "3" "[>] Ejecutar una tarea de backup ahora manualmente" \
            "4" "[-] Eliminar una tarea de backup programada" \
            "5" "[<] Volver al Menú Principal" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$OPC_BKP" == "5" ]; then
            break
        fi

        case "$OPC_BKP" in
            1)
                TAREAS_TXT=""
                for f in /etc/cron.d/backup_*; do
                    if [ -f "$f" ]; then
                        NAME=$(basename "$f" | sed "s/backup_//")
                        CRON_LINE=$(grep -v "^#" "$f" | grep -v "^$" | head -n 1)
                        SCRIPT_PATH="/usr/local/bin/backup_${NAME}.sh"
                        ORIGEN_T=$(grep "^# ORIGEN_DESC=" "$SCRIPT_PATH" 2>/dev/null | cut -d= -f2- || echo "N/A")
                        TIPO_T=$(grep "^# TIPO_DESC=" "$SCRIPT_PATH" 2>/dev/null | cut -d= -f2- || echo "Incremental")
                        DEST_T=$(grep "^DESTINO=" "$SCRIPT_PATH" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "N/A")
                        TAREAS_TXT+="* TAREA: [${NAME}] (${TIPO_T})\n  - Origen:  ${ORIGEN_T}\n  - Destino: ${DEST_T}\n  - Horario: ${CRON_LINE}\n\n"
                    fi
                done
                [ -z "$TAREAS_TXT" ] && TAREAS_TXT="No hay tareas de backup automatizadas creadas actualmente."
                whiptail --title "Tareas de Backup Programadas" --ok-button "< Aceptar >" --msgbox "$TAREAS_TXT" 19 75
                ;;

            2)
                # Paso 1: Nombre de la Tarea
                NAME_BKP=$(whiptail --title "Paso 1: Nombre de la Tarea" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --inputbox "Ingresa un nombre identificador para la tarea (ej. bkp_win_srv01 o bkp_linux_nas):" 10 65 3>&1 1>&2 2>&3)
                if [ $? -ne 0 ] || [ -z "$NAME_BKP" ]; then continue; fi
                NAME_BKP=$(echo "$NAME_BKP" | tr " " "_" | tr -cd "A-Za-z0-9_-")

                # Paso 2: Plataforma de Origen
                PLAT_ORIGEN=$(whiptail --title "Paso 2: Plataforma de Origen" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el tipo de servidor o recurso de origen a respaldar:" 15 72 3 \
                    "1" "🖥️ Servidor Windows (Recurso Compartido SMB / CIFS con Clave)" \
                    "2" "🐧 Servidor Linux Remoto (Túnel SSH / Rsync con Clave)" \
                    "3" "💾 Carpeta Local del Servidor" 3>&1 1>&2 2>&3)
                if [ $? -ne 0 ] || [ -z "$PLAT_ORIGEN" ]; then continue; fi

                CRED_FILE="/etc/backup-credentials/${NAME_BKP}.cred"
                MNT_POINT="/mnt/backup_sources/${NAME_BKP}"
                ORIGEN_DESC=""
                PRE_CMD=""
                POST_CMD=""
                ORIGEN_PATH=""
                CANCEL_FLAG=0

                case "$PLAT_ORIGEN" in
                    1)
                        # Servidor Windows con Bucle de Reintento / Edición
                        WIN_IP=$(echo "$SERVER_IP" | awk -F. '{if(NF==4) print $1"."$2"."$3".50"; else print "192.168.1.50"}')
                        WIN_SHARE="Users"
                        WIN_USER="Administrador"
                        WIN_PASS=""
                        WIN_DOM=""

                        while true; do
                            WIN_IP=$(whiptail --title "Servidor Windows (1/5)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --inputbox "Ingresa la Dirección IP del Servidor Windows:" 10 65 "$WIN_IP" 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$WIN_IP" ]; then CANCEL_FLAG=1; break; fi

                            WIN_SHARE=$(whiptail --title "Recurso Windows Compartido (2/5)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --inputbox "Ingresa el nombre del recurso compartido en Windows (ej. Users o Contabilidad):" 10 65 "$WIN_SHARE" 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$WIN_SHARE" ]; then CANCEL_FLAG=1; break; fi

                            WIN_USER=$(whiptail --title "Usuario Windows (3/5)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --inputbox "Ingresa el usuario de Windows con permisos de lectura:" 10 65 "$WIN_USER" 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$WIN_USER" ]; then CANCEL_FLAG=1; break; fi

                            WIN_PASS=$(whiptail --title "Contraseña Windows (4/5)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --passwordbox "Ingresa la contraseña para $WIN_USER:" 10 65 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$WIN_PASS" ]; then CANCEL_FLAG=1; break; fi

                            WIN_DOM=$(whiptail --title "Dominio (5/5) (Opcional)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --inputbox "Ingresa el Dominio Windows (deja en blanco si es grupo de trabajo):" 10 65 "$WIN_DOM" 3>&1 1>&2 2>&3)

                            # Test de Conexión en Vivo
                            mkdir -p "$MNT_POINT"
                            TEST_CRED="/tmp/test_bkp_$$.cred"
                            cat << EOF_TEST > "$TEST_CRED"
username=$WIN_USER
password=$WIN_PASS
$([ -n "$WIN_DOM" ] && echo "domain=$WIN_DOM")
EOF_TEST
                            chmod 600 "$TEST_CRED"

                            whiptail --title "Probando Conexión" --infobox "Verificando acceso a //$WIN_IP/$WIN_SHARE..." 7 55
                            if mount -t cifs "//$WIN_IP/$WIN_SHARE" "$MNT_POINT" -o credentials="$TEST_CRED",ro,iocharset=utf8 2>/tmp/cifs_err.log; then
                                umount "$MNT_POINT" 2>/dev/null || true
                                rm -f "$TEST_CRED" /tmp/cifs_err.log
                                whiptail --title "Conexión Exitosa" --ok-button "< Continuar >" \
                                    --msgbox "✔ ¡Conexión con Windows establecida con éxito!\n\nSe verificó el acceso a //$WIN_IP/$WIN_SHARE y las credenciales." 9 65
                                break
                            else
                                ERR_MSG=$(cat /tmp/cifs_err.log 2>/dev/null || echo "Fallo de conexión")
                                rm -f "$TEST_CRED" /tmp/cifs_err.log
                                
                                if (whiptail --title "Error de Conexión" \
                                    --yes-button "< Corregir Datos >" --no-button "< Cancelar >" \
                                    --yesno "✖ No se pudo conectar a //$WIN_IP/$WIN_SHARE.\n\nDetalle:\n$ERR_MSG\n\n¿Deseas editar y corregir la IP, recurso, usuario o clave ahora?" 16 68); then
                                    continue
                                else
                                    CANCEL_FLAG=1
                                    break
                                fi
                            fi
                        done

                        if [ "$CANCEL_FLAG" -eq 1 ]; then continue; fi

                        # Guardar credencial definitiva protegida 0600
                        cat << EOF_CRED > "$CRED_FILE"
username=$WIN_USER
password=$WIN_PASS
$([ -n "$WIN_DOM" ] && echo "domain=$WIN_DOM")
EOF_CRED
                        chmod 600 "$CRED_FILE"

                        ORIGEN_DESC="Windows: //$WIN_IP/$WIN_SHARE (Usuario: $WIN_USER)"
                        ORIGEN_PATH="$MNT_POINT"
                        PRE_CMD="mount -t cifs \"//$WIN_IP/$WIN_SHARE\" \"$MNT_POINT\" -o credentials=\"$CRED_FILE\",ro,iocharset=utf8,vers=3.0"
                        POST_CMD="umount \"$MNT_POINT\" 2>/dev/null || true"
                        ;;

                    2)
                        # Servidor Linux con Bucle de Reintento / Edición
                        LNX_IP=$(echo "$SERVER_IP" | awk -F. '{if(NF==4) print $1"."$2"."$3".50"; else print "192.168.1.50"}')
                        LNX_PATH="/srv/nas"
                        LNX_USER="root"
                        LNX_PASS=""

                        while true; do
                            LNX_IP=$(whiptail --title "Servidor Linux Remoto (1/4)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --inputbox "Ingresa la Dirección IP del Servidor Linux / NAS Remoto:" 10 65 "$LNX_IP" 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$LNX_IP" ]; then CANCEL_FLAG=1; break; fi

                            LNX_PATH=$(whiptail --title "Ruta Remota en Linux (2/4)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --inputbox "Ingresa la ruta remota a respaldar (ej. /srv/nas o /var/www):" 10 65 "$LNX_PATH" 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$LNX_PATH" ]; then CANCEL_FLAG=1; break; fi

                            LNX_USER=$(whiptail --title "Usuario SSH (3/4)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --inputbox "Ingresa el usuario SSH con permisos:" 10 65 "$LNX_USER" 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$LNX_USER" ]; then CANCEL_FLAG=1; break; fi

                            LNX_PASS=$(whiptail --title "Contraseña SSH (4/4)" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                                --passwordbox "Ingresa la contraseña SSH para $LNX_USER@$LNX_IP:" 10 65 3>&1 1>&2 2>&3)
                            if [ $? -ne 0 ] || [ -z "$LNX_PASS" ]; then CANCEL_FLAG=1; break; fi

                            # Test de Conexión SSH
                            whiptail --title "Probando Conexión" --infobox "Verificando acceso SSH a $LNX_USER@$LNX_IP..." 7 55
                            if sshpass -p "$LNX_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$LNX_USER@$LNX_IP" "test -d $LNX_PATH" 2>/dev/null; then
                                whiptail --title "Conexión Exitosa" --ok-button "< Continuar >" \
                                    --msgbox "✔ ¡Conexión SSH establecida con éxito!\n\nSe verificó el acceso y la ruta remota $LNX_PATH." 9 65
                                break
                            else
                                if (whiptail --title "Error de Conexión SSH" \
                                    --yes-button "< Corregir Datos >" --no-button "< Cancelar >" \
                                    --yesno "✖ No se pudo conectar vía SSH a $LNX_USER@$LNX_IP o la ruta $LNX_PATH no existe.\n\n¿Deseas editar y corregir la IP, usuario, clave o ruta ahora?" 13 68); then
                                    continue
                                else
                                    CANCEL_FLAG=1
                                    break
                                fi
                            fi
                        done

                        if [ "$CANCEL_FLAG" -eq 1 ]; then continue; fi

                        echo "$LNX_PASS" > "$CRED_FILE"
                        chmod 600 "$CRED_FILE"

                        ORIGEN_DESC="Linux: $LNX_USER@$LNX_IP:$LNX_PATH"
                        ORIGEN_PATH="$LNX_USER@$LNX_IP:$LNX_PATH"
                        PRE_CMD=""
                        POST_CMD=""
                        ;;

                    3)
                        # Local
                        LOC_PATH=$(whiptail --title "Carpeta Local" --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                            --inputbox "Ingresa la ruta local de la carpeta a respaldar:" 10 65 "/srv/nas/SISTEMAS" 3>&1 1>&2 2>&3)
                        if [ -z "$LOC_PATH" ]; then continue; fi

                        if [ ! -d "$LOC_PATH" ]; then
                            whiptail --title "Aviso" --ok-button "< Aceptar >" --msgbox "La carpeta $LOC_PATH no existe actualmente. Se creará al respaldar." 8 55
                        fi

                        ORIGEN_DESC="Local: $LOC_PATH"
                        ORIGEN_PATH="$LOC_PATH"
                        PRE_CMD=""
                        POST_CMD=""
                        ;;
                esac

                # Paso 3: Directorio Destino
                DESTINO_BKP=$(whiptail --title "Directorio Destino en el Servidor" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --inputbox "Carpeta donde se almacenarán los respaldos:" 10 65 "/srv/nas/BACKUPS_HISTORICOS/$NAME_BKP" 3>&1 1>&2 2>&3)
                if [ -z "$DESTINO_BKP" ]; then continue; fi

                # Paso 4: Tipo de Respaldo
                TIPO_BKP=$(whiptail --title "Método de Copia de Seguridad" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el método de respaldo:" 15 72 2 \
                    "1" "Incremental con Snapshots y Hardlinks (Recomendado - 85% Ahorro de Espacio)" \
                    "2" "Sincronización Espejo (Clon idéntico del Origen)" 3>&1 1>&2 2>&3)
                if [ -z "$TIPO_BKP" ]; then continue; fi

                TIPO_STR="Incremental_Snapshots"
                [ "$TIPO_BKP" == "2" ] && TIPO_STR="Espejo_Mirror"

                # Paso 5: Frecuencia de Ejecución
                FRECUENCIA=$(whiptail --title "Frecuencia de Ejecución Automática" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el horario programado para ejecutar el backup:" 16 68 4 \
                    "1" "Diario a las 23:00 hrs (Noches)" \
                    "2" "Semanal (Domingos a las 02:00 hrs)" \
                    "3" "Cada 6 Horas" \
                    "4" "Solo Manual (Sin programación cron)" 3>&1 1>&2 2>&3)
                if [ -z "$FRECUENCIA" ]; then continue; fi

                CRON_SCHED=""
                FREQ_TXT="Manual"
                case "$FRECUENCIA" in
                    1) CRON_SCHED="0 23 * * *"; FREQ_TXT="Diario a las 23:00";;
                    2) CRON_SCHED="0 2 * * 0"; FREQ_TXT="Semanal (Domingos 02:00)";;
                    3) CRON_SCHED="0 */6 * * *"; FREQ_TXT="Cada 6 horas";;
                    4) CRON_SCHED=""; FREQ_TXT="Solo Manual";;
                esac

                # Paso 6: Política de Retención
                RETENCION="7"
                if [ "$TIPO_BKP" == "1" ]; then
                    RETENCION=$(whiptail --title "Política de Retención Histórica" \
                        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                        --inputbox "¿Cuántos snapshots históricos diarios deseas conservar?" 10 65 "7" 3>&1 1>&2 2>&3)
                    [ -z "$RETENCION" ] && RETENCION="7"
                fi

                # Paso 7: Confirmación
                RESUMEN_BKP="CONFIGURACION DE LA TAREA:
* Tarea        : $NAME_BKP
* Tipo         : $TIPO_STR
* Origen       : $ORIGEN_DESC
* Destino      : $DESTINO_BKP
* Horario      : $FREQ_TXT"
                [ "$TIPO_BKP" == "1" ] && RESUMEN_BKP="$RESUMEN_BKP
* Retencion    : Conservar ultimas $RETENCION copias (Hardlinks)"

                if (whiptail --title "Confirmar Tarea de Backup" \
                    --yes-button "< Sí, Guardar y Activar >" --no-button "< Cancelar >" \
                    --yesno "$RESUMEN_BKP\n\n¿Confirmas la creación de esta tarea automatizada?" 18 72); then
                    
                    mkdir -p "$DESTINO_BKP" /srv/nas/LOGS_BACKUP

                    SCRIPT_FILE="/usr/local/bin/backup_${NAME_BKP}.sh"
                    cat << BKPEXEC > "$SCRIPT_FILE"
#!/bin/bash
# Script de Respaldo Automatizado: $NAME_BKP
# ORIGEN_DESC=$ORIGEN_DESC
# TIPO_DESC=$TIPO_STR
set -e

DESTINO="$DESTINO_BKP"
RETENCION=$RETENCION
FECHA=\$(date +%Y-%m-%d_%H%M%S)
LOG_FILE="/srv/nas/LOGS_BACKUP/backup_${NAME_BKP}.log"

mkdir -p "\$DESTINO" /srv/nas/LOGS_BACKUP

echo "==============================================================================" >> "\$LOG_FILE"
echo "[\$FECHA] INICIANDO BACKUP: $NAME_BKP ($TIPO_STR)" >> "\$LOG_FILE"
echo "Origen: $ORIGEN_DESC -> Destino: \$DESTINO" >> "\$LOG_FILE"

# 1. Preparar origen (Montaje CIFS si aplica)
$PRE_CMD

cleanup() {
    $POST_CMD
}
trap cleanup EXIT

# 2. Ejecutar Respaldo
if [ "$PLAT_ORIGEN" == "2" ]; then
    # SSH Remoto Linux
    SSH_PASS_OPT="sshpass -f $CRED_FILE ssh -o StrictHostKeyChecking=no"
    if [ "$TIPO_BKP" == "1" ]; then
        ULTIMO_SNAPSHOT=\$(ls -td "\$DESTINO"/snapshot_* 2>/dev/null | head -n 1 || echo "")
        NUEVO_SNAPSHOT="\$DESTINO/snapshot_\$FECHA"
        LINK_DEST_OPT=""
        [ -n "\$ULTIMO_SNAPSHOT" ] && LINK_DEST_OPT="--link-dest=\$ULTIMO_SNAPSHOT"

        rsync -avz --delete \$LINK_DEST_OPT -e "\$SSH_PASS_OPT" "$ORIGEN_PATH/" "\$NUEVO_SNAPSHOT/" >> "\$LOG_FILE" 2>&1
    else
        rsync -avz --delete -e "\$SSH_PASS_OPT" "$ORIGEN_PATH/" "\$DESTINO/" >> "\$LOG_FILE" 2>&1
    fi
else
    # Local o Windows CIFS montado
    if [ "$TIPO_BKP" == "1" ]; then
        ULTIMO_SNAPSHOT=\$(ls -td "\$DESTINO"/snapshot_* 2>/dev/null | head -n 1 || echo "")
        NUEVO_SNAPSHOT="\$DESTINO/snapshot_\$FECHA"
        LINK_DEST_OPT=""
        [ -n "\$ULTIMO_SNAPSHOT" ] && LINK_DEST_OPT="--link-dest=\$ULTIMO_SNAPSHOT"

        rsync -a --delete \$LINK_DEST_OPT "$ORIGEN_PATH/" "\$NUEVO_SNAPSHOT/" >> "\$LOG_FILE" 2>&1
    else
        rsync -av --delete "$ORIGEN_PATH/" "\$DESTINO/" >> "\$LOG_FILE" 2>&1
    fi
fi

# 3. Política de Retención Histórica
if [ "$TIPO_BKP" == "1" ]; then
    cd "\$DESTINO"
    TOTAL_SNAPSHOTS=\$(ls -td snapshot_* 2>/dev/null | wc -l)
    if [ "\$TOTAL_SNAPSHOTS" -gt "\$RETENCION" ]; then
        ls -td snapshot_* | tail -n +"\$((RETENCION + 1))" | while read -r old; do
            echo "Eliminando snapshot caducado: \$old" >> "\$LOG_FILE"
            rm -rf "\$old"
        done
    fi
fi

echo "[\$(date +%Y-%m-%d_%H%M%S)] BACKUP FINALIZADO EXITOSAMENTE." >> "\$LOG_FILE"
echo "==============================================================================" >> "\$LOG_FILE"
BKPEXEC
                    chmod 755 "$SCRIPT_FILE"

                    if [ -n "$CRON_SCHED" ]; then
                        echo "$CRON_SCHED root $SCRIPT_FILE >/dev/null 2>&1" > "/etc/cron.d/backup_${NAME_BKP}"
                        chmod 644 "/etc/cron.d/backup_${NAME_BKP}"
                    else
                        rm -f "/etc/cron.d/backup_${NAME_BKP}"
                    fi

                    whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                        --msgbox "✔ ¡Tarea de Backup [$NAME_BKP] creada con éxito!\n\n• Plataforma: $ORIGEN_DESC\n• Horario:    $FREQ_TXT\n• Script:     $SCRIPT_FILE\n• Registro:   /srv/nas/LOGS_BACKUP/backup_${NAME_BKP}.log" 13 72
                fi
                ;;

            3)
                # Ejecutar ahora
                TAREAS_RUN=$(ls -1 /usr/local/bin/backup_*.sh 2>/dev/null | sed "s|/usr/local/bin/backup_||; s|\.sh||" || echo "")
                if [ -z "$TAREAS_RUN" ]; then
                    whiptail --ok-button "< Aceptar >" --msgbox "No hay tareas de backup creadas actualmente." 8 48
                    continue
                fi

                MENU_RUN=""
                for t in $TAREAS_RUN; do
                    MENU_RUN="$MENU_RUN $t Ejecutar_Respaldo"
                done

                TASK_SELECTED=$(whiptail --title "Ejecutar Backup Manual" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona la tarea que deseas ejecutar ahora mismo:" 16 68 6 \
                    $MENU_RUN 3>&1 1>&2 2>&3)

                if [ $? -eq 0 ] && [ -n "$TASK_SELECTED" ]; then
                    clear
                    echo -e "${C_CYAN}==============================================================================${C_RESET}"
                    echo -e "${C_BOLD}EJECUTANDO TAREA DE RESPALDO: [${TASK_SELECTED}]${C_RESET}"
                    echo -e "${C_CYAN}==============================================================================${C_RESET}\n"
                    
                    bash "/usr/local/bin/backup_${TASK_SELECTED}.sh"
                    
                    echo -e "\n${C_GREEN}✔ ¡Respaldo completado exitosamente!${C_RESET}"
                    echo -e "${C_GRAY}Últimas líneas del registro (/srv/nas/LOGS_BACKUP/backup_${TASK_SELECTED}.log):${C_RESET}"
                    tail -n 8 "/srv/nas/LOGS_BACKUP/backup_${TASK_SELECTED}.log" 2>/dev/null || true
                    echo ""
                    read -n 1 -s -r -p "Presiona cualquier tecla para continuar..."
                fi
                ;;

            4)
                # Eliminar tarea
                TAREAS_DEL=$(ls -1 /usr/local/bin/backup_*.sh 2>/dev/null | sed "s|/usr/local/bin/backup_||; s|\.sh||" || echo "")
                if [ -z "$TAREAS_DEL" ]; then
                    whiptail --ok-button "< Aceptar >" --msgbox "No hay tareas para eliminar." 8 45
                    continue
                fi

                MENU_DEL=""
                for t in $TAREAS_DEL; do
                    MENU_DEL="$MENU_DEL $t Tarea_Programada"
                done

                TASK_DEL_SEL=$(whiptail --title "Eliminar Tarea de Backup" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona la tarea que deseas eliminar:" 16 68 6 \
                    $MENU_DEL 3>&1 1>&2 2>&3)

                if [ $? -eq 0 ] && [ -n "$TASK_DEL_SEL" ]; then
                    if (whiptail --title "Confirmar Eliminación de Tarea" \
                        --yes-button "< Sí, Eliminar Tarea >" --no-button "< Cancelar >" \
                        --yesno "¿Estás seguro de que deseas eliminar la tarea [$TASK_DEL_SEL] y sus credenciales?\n\n(Los respaldos históricos en disco no se borrarán)." 12 70); then
                        
                        rm -f "/usr/local/bin/backup_${TASK_DEL_SEL}.sh" "/etc/cron.d/backup_${TASK_DEL_SEL}" "/etc/backup-credentials/${TASK_DEL_SEL}.cred" "/mnt/backup_sources/${TASK_DEL_SEL}" 2>/dev/null || true
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                            --msgbox "✔ Tarea [$TASK_DEL_SEL] eliminada exitosamente." 8 50
                    fi
                fi
                ;;
        esac
    done
}

# ==============================================================================
# 5. FUNCIÓN: GESTOR DE USUARIOS Y EMPLEADOS
# ==============================================================================
crear_usuario_guiado() {
    USER_NAME=$(whiptail --title "$APP_TITLE" \
        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
        --inputbox "Ingresa el nombre de usuario (ej. carlos_mendoza):" 10 65 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$USER_NAME" ]; then return; fi

    if ! [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        whiptail --title "Error de Formato" --ok-button "< Aceptar >" \
            --msgbox "El nombre de usuario solo puede contener letras minúsculas, números y guión bajo." 10 60
        return
    fi

    # Obtener grupos existentes en el sistema (grupos de seguridad grp_* y GID >= 1000)
    GRUPOS_DISP=$(awk -F: '($3 >= 1000 || $1 ~ /^grp_/) && $1 !~ /^(nogroup|nobody)$/ {print $1}' /etc/group | sort -u)

    if [ -z "$GRUPOS_DISP" ]; then
        whiptail --title "Sin Grupos de Seguridad" --ok-button "< Aceptar >" \
            --msgbox "No hay grupos creados en el sistema.\nPor favor crea un grupo primero desde el menú [2] Gestión de Grupos." 10 65
        return
    fi

    LISTA_OPCIONES=""
    for g in $GRUPOS_DISP; do
        [ "$g" == "$USER_NAME" ] && continue
        LISTA_OPCIONES="$LISTA_OPCIONES $g Grupo_$g OFF"
    done

    if [ -z "$LISTA_OPCIONES" ]; then
        whiptail --title "Sin Grupos" --ok-button "< Aceptar >" \
            --msgbox "Crea primero un grupo departamental desde el menú [2] Gestión de Grupos." 9 65
        return
    fi

    GRUPOS_SELEC=$(whiptail --title "Paso 2 de 3: Asignación de Grupos" \
        --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
        --checklist "Marca con la BARRA ESPACIADORA [X] los grupos a los que pertenecerá '$USER_NAME':" 18 72 8 \
        $LISTA_OPCIONES 3>&1 1>&2 2>&3)

    if [ $? -ne 0 ] || [ -z "$GRUPOS_SELEC" ]; then
        whiptail --title "Aviso" --ok-button "< Aceptar >" --msgbox "Debes seleccionar al menos un grupo para el usuario." 8 50
        return
    fi

    GRUPO_FINAL=$(echo "$GRUPOS_SELEC" | tr -d '\"' | tr ' ' ',')

    while true; do
        USER_PW=$(whiptail --title "Paso 3 de 3: Contraseña de Red Samba" \
            --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
            --passwordbox "Ingresa la contraseña de red Samba para $USER_NAME:" 10 65 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then return; fi
        if [ -n "$USER_PW" ]; then break; fi
        whiptail --title "Error" --ok-button "< Aceptar >" --msgbox "La contraseña no puede estar vacía." 8 45
    done

    if (whiptail --title "Confirmar Registro de Usuario" \
        --yes-button "< Sí, Registrar Usuario >" --no-button "< Cancelar >" \
        --yesno "¿Confirmas el registro del usuario con los siguientes datos?\n\n• Usuario:          $USER_NAME\n• Grupos Asignados: $GRUPO_FINAL" 13 65); then
        
        if ! id "$USER_NAME" &>/dev/null; then
            adduser --disabled-password --gecos "" --no-create-home --shell /usr/sbin/nologin "$USER_NAME"
        fi

        IFS=',' read -ra GRPS <<< "$GRUPO_FINAL"
        for g in "${GRPS[@]}"; do
            groupadd -f "$g"
        done

        usermod -aG "$GRUPO_FINAL" "$USER_NAME"
        echo -e "${USER_PW}\n${USER_PW}" | smbpasswd -a -s "$USER_NAME"

        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
            --msgbox "✔ ¡Usuario Registrado con Éxito!\n\n• Usuario:          $USER_NAME\n• Grupos Asignados: $GRUPO_FINAL\n\nYa puede conectar desde la red a: \\\\${SERVER_IP}" 13 65
    fi
}

gestionar_usuarios() {
    while true; do
        OPC_USR=$(whiptail --title "$APP_TITLE" \
            --ok-button "< Seleccionar >" --cancel-button "< Volver >" \
            --menu "GESTIÓN DE USUARIOS Y EMPLEADOS:" 17 72 5 \
            "1" "[*] Listar usuarios registrados y grupos asignados" \
            "2" "[+] Crear un nuevo usuario (Seleccionar grupos actuales)" \
            "3" "[#] Modificar grupos de un usuario existente" \
            "4" "[*] Cambiar contraseña de Samba a un usuario" \
            "5" "[-] Eliminar un usuario del sistema" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break
        fi

        case "$OPC_USR" in
            1)
                LISTA_USERS=$(pdbedit -L 2>/dev/null | cut -d: -f1)
                if [ -z "$LISTA_USERS" ]; then
                    whiptail --title "Usuarios Registrados" --ok-button "< Aceptar >" \
                        --msgbox "No hay usuarios registrados en Samba actualmente." 8 50
                    continue
                fi

                TXT_USERS="  USUARIO            | GRUPOS ASIGNADOS\n  ─────────────────────────────────────────────────────────────────\n"
                for u in $LISTA_USERS; do
                    grps=$(id -Gn "$u" 2>/dev/null | tr ' ' '\n' | grep -E '^grp_|^[a-z0-9_-]+' | grep -vE '^(cdrom|floppy|audio|dip|video|plugdev|users|netdev|scanner|bluetooth|lpadmin|nobody|nogroup)$' | tr '\n' ',' | sed 's/,$//')
                    TXT_USERS="${TXT_USERS}$(printf "  %-18s | %s\n" "$u" "$grps")"
                done
                whiptail --title "Usuarios Registrados en Samba" --ok-button "< Aceptar >" --msgbox "$TXT_USERS" 18 72
                ;;

            2)
                crear_usuario_guiado
                ;;

            3)
                LISTA_USERS=$(pdbedit -L 2>/dev/null | cut -d: -f1)
                if [ -z "$LISTA_USERS" ]; then
                    whiptail --ok-button "< Aceptar >" --msgbox "No hay usuarios registrados." 8 45
                    continue
                fi
                MENU_USERS=""
                for u in $LISTA_USERS; do
                    MENU_USERS="$MENU_USERS $u Usuario_Samba"
                done
                TARGET_USER=$(whiptail --title "Modificar Grupos de Usuario" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el usuario al que deseas modificar los grupos:" 16 68 6 \
                    $MENU_USERS 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$TARGET_USER" ]; then
                    GRUPOS_DISP=$(awk -F: '($3 >= 1000 || $1 ~ /^grp_/) && $1 !~ /^(nogroup|nobody)$/ {print $1}' /etc/group | sort -u)
                    LISTA_OPC=""
                    GRPS_ACTUALES=$(id -Gn "$TARGET_USER" 2>/dev/null)
                    for g in $GRUPOS_DISP; do
                        [ "$g" == "$TARGET_USER" ] && continue
                        STATUS="OFF"
                        if echo "$GRPS_ACTUALES" | grep -qw "$g"; then STATUS="ON"; fi
                        LISTA_OPC="$LISTA_OPC $g Grupo_$g $STATUS"
                    done
                    NUEVOS_GRPS=$(whiptail --title "Modificar Grupos de $TARGET_USER" \
                        --ok-button "< Guardar >" --cancel-button "< Cancelar >" \
                        --checklist "Marca con ESPACIO los grupos asignados a $TARGET_USER:" 18 72 8 \
                        $LISTA_OPC 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ]; then
                        NUEVOS_GRPS_CSV=$(echo "$NUEVOS_GRPS" | tr -d '\"' | tr ' ' ',')
                        if [ -n "$NUEVOS_GRPS_CSV" ]; then
                            usermod -aG "$NUEVOS_GRPS_CSV" "$TARGET_USER"
                            whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                                --msgbox "✔ Grupos actualizados para $TARGET_USER:\n$NUEVOS_GRPS_CSV" 9 60
                        fi
                    fi
                fi
                ;;

            4)
                LISTA_USERS=$(pdbedit -L 2>/dev/null | cut -d: -f1)
                if [ -z "$LISTA_USERS" ]; then
                    whiptail --ok-button "< Aceptar >" --msgbox "No hay usuarios registrados." 8 45
                    continue
                fi
                MENU_USERS=""
                for u in $LISTA_USERS; do
                    MENU_USERS="$MENU_USERS $u Usuario_Samba"
                done
                USER_PW_SEL=$(whiptail --title "Cambiar Contraseña Samba" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el usuario para cambiar su contraseña:" 16 68 6 \
                    $MENU_USERS 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$USER_PW_SEL" ]; then
                    NUEVA_CLAVE=$(whiptail --title "Nueva Contraseña" \
                        --ok-button "< Cambiar >" --cancel-button "< Cancelar >" \
                        --passwordbox "Ingresa la nueva contraseña de Samba para $USER_PW_SEL:" 10 65 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ] && [ -n "$NUEVA_CLAVE" ]; then
                        echo -e "${NUEVA_CLAVE}\n${NUEVA_CLAVE}" | smbpasswd -s "$USER_PW_SEL"
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                            --msgbox "✔ Contraseña de Samba actualizada con éxito para '$USER_PW_SEL'." 8 60
                    fi
                fi
                ;;

            5)
                LISTA_USERS=$(pdbedit -L 2>/dev/null | cut -d: -f1 | grep -v "^root$")
                if [ -z "$LISTA_USERS" ]; then
                    whiptail --ok-button "< Aceptar >" --msgbox "No hay usuarios disponibles para eliminar." 8 45
                    continue
                fi
                MENU_USERS=""
                for u in $LISTA_USERS; do
                    MENU_USERS="$MENU_USERS $u Usuario_Samba"
                done
                USER_DEL_SEL=$(whiptail --title "Eliminar Usuario" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el usuario que deseas eliminar:" 16 68 6 \
                    $MENU_USERS 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$USER_DEL_SEL" ]; then
                    if (whiptail --title "Confirmación de Eliminación" \
                        --yes-button "< Sí, Eliminar >" --no-button "< Cancelar >" \
                        --yesno "¿Estás seguro de eliminar al usuario '$USER_DEL_SEL' de Samba y Linux?" 10 60); then
                        smbpasswd -x "$USER_DEL_SEL" 2>/dev/null || true
                        deluser "$USER_DEL_SEL" 2>/dev/null || userdel "$USER_DEL_SEL" 2>/dev/null || true
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                            --msgbox "✔ Usuario '$USER_DEL_SEL' eliminado exitosamente." 8 50
                    fi
                fi
                ;;
        esac
    done
}

# ==============================================================================
# 6. FUNCIÓN: DIAGNÓSTICO Y ESTADO
# ==============================================================================
diagnostico_nas() {
    SERVER_IP=$(obtener_ip_local)
    clear
    echo -e "${C_CYAN}"
    echo "  ╭──────────────────────────────────────────────────────────────────────────╮"
    echo "  │               DIAGNÓSTICO EN VIVO • SERVIDOR ($SERVER_IP)                │"
    echo "  ╰──────────────────────────────────────────────────────────────────────────╯${C_RESET}\n"

    echo -e "  ${C_BOLD}${C_WHITE}1. ESTADO DE SERVICIOS EN TIEMPO REAL:${C_RESET}"
    for s in smbd nmbd wsdd2 cockpit.socket cron; do
        if systemctl is-active "$s" &>/dev/null; then
            echo -e "     [${C_GREEN}● ACTIVO${C_RESET}] $s"
        else
            echo -e "     [${C_RED}● INACTIVO${C_RESET}] $s"
        fi
    done

    echo -e "\n  ${C_BOLD}${C_WHITE}2. ALMACENAMIENTO DEL SERVIDOR (/srv/nas):${C_RESET}"
    df -h /srv/nas 2>/dev/null | awk 'NR==2 {printf "     Capacidad Total: %s | Utilizado: %s (%s) | Libre: %s\n", $2, $3, $5, $4}'

    echo -e "\n  ${C_BOLD}${C_WHITE}3. RECURSOS COMPARTIDOS EN SAMBA:${C_RESET}"
    if [ -f /etc/samba/smb.conf ]; then
        local found_share=false
        while read -r r; do
            [ -n "$r" ] && found_share=true && echo -e "     [•] ${C_YELLOW}$r${C_RESET}"
        done < <(grep -E "^\[" /etc/samba/smb.conf | grep -v "global" | tr -d "[]")
        if [ "$found_share" = false ]; then
            echo -e "     ${C_GRAY}(No hay recursos compartidos configurados todavía)${C_RESET}"
        fi
    else
        echo -e "     ${C_GRAY}(Samba aún no ha sido instalado o configurado)${C_RESET}"
    fi

    echo -e "\n  ${C_BOLD}${C_WHITE}4. TAREAS DE BACKUP PROGRAMADAS:${C_RESET}"
    local has_bkp=false
    for b in /etc/cron.d/backup_*; do
        if [ -f "$b" ]; then
            has_bkp=true
            echo -e "     [⏱] ${C_CYAN}$(basename "$b" | sed "s/backup_//"):${C_RESET} ${C_WHITE}$(cat "$b")${C_RESET}"
        fi
    done
    if [ "$has_bkp" = false ]; then
        echo -e "     ${C_GRAY}(No hay tareas de backup programadas)${C_RESET}"
    fi

    echo -e "\n  ${C_GRAY}──────────────────────────────────────────────────────────────────────────${C_RESET}"
    read -n 1 -s -r -p "  Presiona cualquier tecla para regresar al menú principal..."
}

# ==============================================================================
# 7. FUNCIÓN: DESINSTALACIÓN
# ==============================================================================
desinstalar_guiado() {
    if (whiptail --title "ALERTA DE DESINSTALACIÓN CRÍTICA" \
        --yes-button "< Sí, Desinstalar Todo >" --no-button "< Cancelar >" \
        --yesno "¡CUIDADO! Esta acción desinstalará todos los paquetes de Samba, Cockpit, desmontará el disco y limpiará las configuraciones.\n\n¿Confirmas que deseas restablecer el servidor a su estado base limpio?" 12 72); then
        clear
        bash "$SCRIPT_DIR/desinstalar_nas_ead.sh"
        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
            --msgbox "✔ El servidor ha sido desinstalado y el sistema quedó completamente limpio." 8 65
    fi
}

# ==============================================================================
# 8. FUNCIÓN: AUTO-ACTUALIZACIÓN DESDE GITHUB
# ==============================================================================
actualizar_desde_git() {
    clear
    echo -e "${C_CYAN}"
    echo "  ╭──────────────────────────────────────────────────────────────────────────╮"
    echo "  │             BUSCANDO ACTUALIZACIONES DEL PROYECTO EN GITHUB              │"
    echo "  ╰──────────────────────────────────────────────────────────────────────────╯${C_RESET}\n"

    if [ -d "$SCRIPT_DIR/.git" ]; then
        cd "$SCRIPT_DIR"
        echo -e " [•] Conectando con GitHub..."
        git fetch origin main 2>/dev/null || true
        CURRENT_REV=$(git rev-parse HEAD 2>/dev/null || echo "1")
        REMOTE_REV=$(git rev-parse origin/main 2>/dev/null || echo "2")

        if [ "$CURRENT_REV" == "$REMOTE_REV" ]; then
            whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                --msgbox "✔ Tu versión ya está completamente actualizada a la última versión de GitHub.\n\nCommit: $(git log -1 --format='%h - %s (%cd)' --date=short)" 10 70
        else
            if (whiptail --title "Actualización Disponible" \
                --yes-button "< Actualizar Ahora >" --no-button "< Cancelar >" \
                --yesno "Hay una nueva versión disponible en GitHub:\n\n$(git log HEAD..origin/main --oneline -n 5)\n\n¿Deseas descargar e instalar la actualización ahora?" 15 72); then
                git reset --hard origin/main
                chmod +x "$SCRIPT_DIR"/*.sh
                whiptail --title "$APP_TITLE" --ok-button "< Reiniciar Asistente >" \
                    --msgbox "✔ ¡Actualización instalada con éxito!\n\nEl asistente se reiniciará con las nuevas mejoras." 9 65
                exec bash "$SCRIPT_DIR/asistente_nas.sh"
            fi
        fi
    else
        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
            --msgbox "Para actualizar ejecuta:\nsudo nas update" 9 55
    fi
}

# ==============================================================================
# MENÚ PRINCIPAL INTERACTIVO
# ==============================================================================
while true; do
    OPCION=$(whiptail --title "$APP_TITLE" \
        --ok-button "< Seleccionar >" --cancel-button "< Salir >" \
        --menu "Selecciona una opción usando las flechas y presiona Enter:" 21 74 9 \
        "1" "[1]  Desplegar Servidor (NAS de Archivos o Central de Backup)" \
        "2" "[2]  Gestión de Grupos de Seguridad (Crear / Listar / Eliminar)" \
        "3" "[3]  Gestión de Recursos Compartidos (Ver / Crear / Deshabilitar / Borrar)" \
        "4" "[4]  Gestión de Tareas de Backup (Windows / Linux / Local)" \
        "5" "[5]  Gestión de Usuarios y Empleados (Crear, Grupos y Claves)" \
        "6" "[6]  Ver Diagnóstico, Discos y Recursos Compartidos" \
        "7" "[7]  Reiniciar Servicios de Red (Samba / Cockpit)" \
        "8" "[8]  Buscar Actualizaciones desde GitHub (Auto-Update)" \
        "9" "[9]  Desinstalar y Limpiar Servidor" 3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        clear
        break
    fi

    case "$OPCION" in
        1) instalar_nas ;;
        2) gestionar_grupos ;;
        3) gestionar_recursos_compartidos ;;
        4) gestionar_backups ;;
        5) gestionar_usuarios ;;
        6) diagnostico_nas ;;
        7) 
            if (whiptail --title "Confirmar Reinicio" \
                --yes-button "< Sí, Reiniciar >" --no-button "< Cancelar >" \
                --yesno "¿Deseas reiniciar los servicios de red de Samba, WSDD2 y Cockpit ahora?" 9 65); then
                systemctl restart smbd nmbd wsdd2 cockpit.socket cockpit.service
                whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                    --msgbox "✔ Servicios de Samba, WSDD2 y Cockpit reiniciados correctamente." 8 60
            fi
            ;;
        8) actualizar_desde_git ;;
        9) desinstalar_guiado ;;
    esac
done
