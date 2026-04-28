#!/bin/bash
# OSForge container entrypoint

echo "[osforge] Container starting..."

# If no command specified or init requested, run systemd
if [[ $# -eq 0 ]] || [[ "$1" == "/usr/sbin/init" ]] || [[ "$1" == "init" ]]; then
    exec /usr/sbin/init
fi

# Run health check for non-systemd starts
if command -v health-check.sh >/dev/null 2>&1; then
    health-check.sh || true
fi

# Execute command
exec "$@"
