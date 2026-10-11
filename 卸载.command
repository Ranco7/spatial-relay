#!/bin/bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$PACKAGE_DIR/Scripts/uninstall.sh"
