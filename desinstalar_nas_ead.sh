#!/bin/bash
# ==============================================================================
# Lanzador de Desinstalación (Redirige a src/core/uninstall.sh)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/src/core/uninstall.sh" "$@"
