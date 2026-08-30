#!/bin/bash
# ==============================================================================
# Lanzador del Asistente NAS (Debian 13)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/src/asistente.sh" ]; then
    exec bash "$SCRIPT_DIR/src/asistente.sh" "$@"
else
    echo "[-] Error: No se encontró el módulo principal en $SCRIPT_DIR/src/asistente.sh"
    exit 1
fi
