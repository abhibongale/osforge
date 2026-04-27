#!/bin/bash
# OSForge container entrypoint

set -euo pipefail

echo "[osforge] Container starting..."

# Initialize systemd
if [[ "$1" == "/usr/sbin/init" ]]; then
    exec /usr/sbin/init
fi

# Run health check
if command -v health-check.sh >/dev/null 2>&1; then
    health-check.sh || true
fi

# Execute command
exec "$@"
