#!/bin/bash
# ==============================================================================
# Módulo: Gestión de Grupos de Seguridad
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
                LISTA_GRUPOS=$(awk -F: '$1 ~ /^grp_/ {
                    miembros = ($4 != "") ? $4 : "(sin miembros)"
                    printf "  • %-22s (GID: %-4s) | Miembros: %s\n", $1, $3, miembros
                }' /etc/group | sort)
                [ -z "$LISTA_GRUPOS" ] && LISTA_GRUPOS="  (No se encontraron grupos creados)"
                whiptail --title "Grupos de Seguridad Creados" --ok-button "< Aceptar >" \
                    --msgbox "GRUPOS CREADOS EN EL SISTEMA:\n\n$LISTA_GRUPOS" 18 72
                ;;

            2)
                NUEVO_GRP=$(whiptail --title "$APP_TITLE" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --inputbox "Ingresa el nombre del grupo (ej. grp_contabilidad o grp_ventas):" 10 65 "grp_" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$NUEVO_GRP" ]; then
                    NUEVO_GRP=$(echo "$NUEVO_GRP" | tr ' ' '_' | tr -cd 'a-z0-9_-')
                    if [[ "$NUEVO_GRP" != grp_* ]]; then
                        NUEVO_GRP="grp_${NUEVO_GRP}"
                    fi
                    if groupadd "$NUEVO_GRP" 2>/dev/null; then
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                            --msgbox "✔ Grupo \"$NUEVO_GRP\" creado exitosamente." 8 50
                    else
                        whiptail --title "Error" --ok-button "< Aceptar >" \
                            --msgbox "El grupo \"$NUEVO_GRP\" ya existe o el nombre es inválido." 8 55
                    fi
                fi
                ;;

            3)
                GRUPOS_ELIM=$(awk -F: '$1 ~ /^grp_/ && $1 != "grp_sistemas" {print $1}' /etc/group | sort)
                if [ -z "$GRUPOS_ELIM" ]; then
                    whiptail --title "Aviso" --ok-button "< Aceptar >" \
                        --msgbox "No hay grupos personalizados disponibles para eliminar." 8 55
                    continue
                fi

                MENU_ELIM=""
                for g in $GRUPOS_ELIM; do
                    MENU_ELIM="$MENU_ELIM $g Grupo_Personalizado"
                done

                GRP_BORRAR=$(whiptail --title "Eliminar Grupo" \
                    --ok-button "< Siguiente >" --cancel-button "< Cancelar >" \
                    --menu "Selecciona el grupo que deseas eliminar:" 16 68 6 \
                    $MENU_ELIM 3>&1 1>&2 2>&3)

                if [ $? -eq 0 ] && [ -n "$GRP_BORRAR" ]; then
                    if (whiptail --title "Confirmar Eliminación" \
                        --yes-button "< Sí, Eliminar >" --no-button "< Cancelar >" \
                        --yesno "¿Estás seguro de que deseas eliminar el grupo \"$GRP_BORRAR\"?" 8 60); then
                        groupdel "$GRP_BORRAR" 2>/dev/null || true
                        whiptail --title "$APP_TITLE" --ok-button "< Aceptar >" \
                            --msgbox "✔ Grupo \"$GRP_BORRAR\" eliminado correctamente." 8 50
                    fi
                fi
                ;;
        esac
    done
}
