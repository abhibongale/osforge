#!/bin/bash
# Install OSForge CLI

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"
DEV_MODE="${1:-}"

echo "===> Installing OSForge"

# Determine source directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSFORGE_ROOT="$(dirname "$SCRIPT_DIR")"

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found"
    echo "Install with: sudo dnf install podman"
    exit 1
fi

if [[ ! -r /dev/kvm ]]; then
    echo "WARNING: Cannot read /dev/kvm"
    echo "Add yourself to kvm group: sudo usermod -a -G kvm \$USER"
fi

echo "✓ Prerequisites OK"

# Create installation directory
mkdir -p "$INSTALL_DIR"

# Install CLI
if [[ "$DEV_MODE" == "--dev" ]]; then
    echo "Installing in development mode..."
    echo "Creating symlink: $INSTALL_DIR/osforge -> $OSFORGE_ROOT/bin/osforge"
    ln -sf "$OSFORGE_ROOT/bin/osforge" "$INSTALL_DIR/osforge"
else
    echo "Installing to: $INSTALL_DIR"
    cp "$OSFORGE_ROOT/bin/osforge" "$INSTALL_DIR/osforge"
    chmod +x "$INSTALL_DIR/osforge"
fi

# Create user directory
OSFORGE_USER_DIR="${OSFORGE_USER_DIR:-$HOME/.osforge}"
mkdir -p "$OSFORGE_USER_DIR"/{logs,cache/{images,pip},volumes}

# Create default config if it doesn't exist
if [[ ! -f "$OSFORGE_USER_DIR/config.yaml" ]]; then
    cat > "$OSFORGE_USER_DIR/config.yaml" << 'EOF'
# OSForge User Configuration

# Container runtime (podman or docker)
runtime: podman

# Base image
base_image: quay.io/osforge/base:latest

# Default repositories (override with --ironic-repo, etc.)
repos:
  ironic: ~/dev/ironic
  ironic-python-agent: ~/dev/ironic-python-agent

# Logging
logging:
  level: INFO  # DEBUG, INFO, WARN, ERROR
  keep_logs: 10  # Keep last N runs

# Resources
resources:
  memory: 8G
  cpus: 4

# Advanced
advanced:
  pull_before_run: false
  cleanup_after_run: false
EOF
    echo "Created default config: $OSFORGE_USER_DIR/config.yaml"
fi

# Check if in PATH
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    echo ""
    echo "WARNING: $INSTALL_DIR is not in your PATH"
    echo "Add to your ~/.bashrc:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
fi

echo "✓ Installation complete!"
echo ""
echo "Usage:"
echo "  osforge run <job-name>"
echo "  osforge --help"
echo ""
echo "To get started:"
echo "  1. Pull base image: podman pull quay.io/osforge/base:latest"
echo "  2. Go to your Ironic repo: cd ~/dev/ironic"
echo "  3. Run a job: osforge run ironic-tempest-bios-ipmi-autodetect"
