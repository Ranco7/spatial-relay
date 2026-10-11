#!/bin/bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PACKAGE_DIR/Scripts/paths.sh"
"$RELAY_EXECUTABLE" --status
