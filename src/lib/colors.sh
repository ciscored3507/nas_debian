#!/bin/bash
# ==============================================================================
# Librería: Colores ANSI y Títulos
# ==============================================================================

# Colores ANSI para terminal
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_WHITE="\033[1;37m"
C_GRAY="\033[0;90m"

# Título global de la aplicación
APP_TITLE="SERVIDOR NAS & CENTRAL DE RESPALDOS (DEBIAN 13)"

# Configuración de paleta visual nativa para Whiptail
export NEWT_COLORS="
root=,blue
window=lightgray,black
border=cyan,black
shadow=black,gray
button=black,cyan
actbutton=white,blue
compactbutton=black,lightgray
title=yellow,black
roottext=white,blue
textbox=white,black
acttextbox=white,blue
entry=white,blue
disentry=gray,black
checkbox=cyan,black
actcheckbox=black,cyan
listbox=white,black
actlistbox=black,cyan
actsellistbox=white,blue
"
