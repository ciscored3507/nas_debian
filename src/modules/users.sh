#!/bin/bash
# ==============================================================================
# Módulo: Gestión de Usuarios y Credenciales Samba
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

    # Obtener grupos de seguridad creados (grp_*)
    GRUPOS_DISP=$(awk -F: '$1 ~ /^grp_/ {print $1}' /etc/group | sort -u)

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
                TABLA_USERS=$(python3 -c '
import subprocess

out = subprocess.run(["pdbedit", "-L"], capture_output=True, text=True)
users = [line.split(":")[0] for line in out.stdout.strip().split("\n") if line.strip()]

rows = []
for u in users:
    grp_out = subprocess.run(["id", "-Gn", u], capture_output=True, text=True)
    all_grps = grp_out.stdout.strip().split()
    sec_grps = [g for g in all_grps if g.startswith("grp_")]
    is_admin = "Admin (sudo)" if "sudo" in all_grps or "adm" in all_grps else "Usuario Samba"
    grps_str = ", ".join(sec_grps) if sec_grps else "(sin grupos grp_*)"
    rows.append((u, is_admin, grps_str))

if not rows:
    print("  (No hay usuarios registrados en Samba actualmente)")
    exit(0)

w_user = max(max(len(r[0]) for r in rows), 16)
w_role = max(max(len(r[1]) for r in rows), 14)
w_grps = max(max(len(r[2]) for r in rows), 30)

print(f"┌─{"─"*w_user}─┬─{"─"*w_role}─┬─{"─"*w_grps}─┐")
print(f"│ {"USUARIO SAMBA".ljust(w_user)} │ {"ROL / TIPO".ljust(w_role)} │ {"GRUPOS ASIGNADOS (grp_*)".ljust(w_grps)} │")
print(f"├─{"─"*w_user}─┼─{"─"*w_role}─┼─{"─"*w_grps}─┤")
for r in rows:
    print(f"│ {r[0].ljust(w_user)} │ {r[1].ljust(w_role)} │ {r[2].ljust(w_grps)} │")
print(f"└─{"─"*w_user}─┴─{"─"*w_role}─┴─{"─"*w_grps}─┘")
')
                whiptail --title "CRUD: Usuarios Registrados en Samba" --ok-button "< Aceptar >" --msgbox "$TABLA_USERS" 18 78
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
                    GRUPOS_DISP=$(awk -F: '$1 ~ /^grp_/ {print $1}' /etc/group | sort -u)
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
