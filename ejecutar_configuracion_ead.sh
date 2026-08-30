#!/bin/bash
# ==============================================================================
# Lanzador de Despliegue Base (Redirige a src/core/deploy.sh)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/src/core/deploy.sh" "$@"
