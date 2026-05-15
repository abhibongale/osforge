#!/bin/bash
# Setup IPA (Ironic Python Agent) deploy images
# Downloads TinyIPA kernel and ramdisk if not present

set -eo pipefail

echo "[setup-ipa] Setting up IPA deploy images..."

# Configuration
HTTPBOOT_DIR="/opt/stack/data/ironic/httpboot"
IPA_KERNEL="${HTTPBOOT_DIR}/ipa-kernel"
IPA_RAMDISK="${HTTPBOOT_DIR}/ipa-ramdisk"
TinyIPA_VERSION="stable-2024.1"
TinyIPA_BASE_URL="https://tarballs.opendev.org/openstack/ironic-python-agent/tinyipa/files"

# Ensure httpboot directory exists
mkdir -p "$HTTPBOOT_DIR"

# Download IPA kernel if not present
if [[ ! -f "$IPA_KERNEL" ]]; then
    echo "[setup-ipa] Downloading TinyIPA kernel..."
    wget -q --show-progress \
        "${TinyIPA_BASE_URL}/tinyipa-${TinyIPA_VERSION}.vmlinuz" \
        -O "$IPA_KERNEL"
    chown stack:stack "$IPA_KERNEL"
    echo "[setup-ipa]   Kernel downloaded: $(du -h "$IPA_KERNEL" | cut -f1)"
else
    echo "[setup-ipa] IPA kernel already exists: $(du -h "$IPA_KERNEL" | cut -f1)"
fi

# Download IPA ramdisk if not present
if [[ ! -f "$IPA_RAMDISK" ]]; then
    echo "[setup-ipa] Downloading TinyIPA ramdisk..."
    wget -q --show-progress \
        "${TinyIPA_BASE_URL}/tinyipa-${TinyIPA_VERSION}.gz" \
        -O "$IPA_RAMDISK"
    chown stack:stack "$IPA_RAMDISK"
    echo "[setup-ipa]   Ramdisk downloaded: $(du -h "$IPA_RAMDISK" | cut -f1)"
else
    echo "[setup-ipa] IPA ramdisk already exists: $(du -h "$IPA_RAMDISK" | cut -f1)"
fi

# Fix Apache permissions on the path
# Apache needs execute permission on all parent directories to access httpboot
echo "[setup-ipa] Fixing Apache permissions..."
chmod +x /opt/stack
chmod +x /opt/stack/data
chmod +x /opt/stack/data/ironic
chmod +x /opt/stack/data/ironic/httpboot
chmod +r "$IPA_KERNEL" "$IPA_RAMDISK"

# Verify Apache can access the files
HTTP_URL="http://127.0.0.1:3928"
echo "[setup-ipa] Verifying HTTP access..."
if curl -sI "${HTTP_URL}/ipa-kernel" | grep -q "200 OK"; then
    echo "[setup-ipa]   ✓ IPA kernel accessible via HTTP"
else
    echo "[setup-ipa]   ✗ WARNING: IPA kernel not accessible via HTTP"
    echo "[setup-ipa]   Check Apache configuration and permissions"
fi

if curl -sI "${HTTP_URL}/ipa-ramdisk" | grep -q "200 OK"; then
    echo "[setup-ipa]   ✓ IPA ramdisk accessible via HTTP"
else
    echo "[setup-ipa]   ✗ WARNING: IPA ramdisk not accessible via HTTP"
fi

echo "[setup-ipa] IPA images setup complete"
