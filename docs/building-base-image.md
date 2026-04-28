# Building the OSForge Base Image

This guide walks you through building the OSForge base container image from scratch.

## Overview

The base image contains:
- Ubuntu 24.04 (Noble)
- DevStack pre-installed
- All OpenStack services (Nova, Neutron, Glance, Keystone, Cinder, Ironic, etc.)
- Tempest + plugins
- VirtualBMC
- Helper scripts

**Build time**: 45-60 minutes (one-time investment)

**Result**: An image you can reuse for all OSForge jobs

---

## Prerequisites

### System Requirements

**Minimum:**
- 16GB RAM (12GB for build, 4GB for system)
- 8 CPU cores (can work with 4, but slower)
- 50GB free disk space
- Fast internet connection (downloads ~5GB)

**Recommended:**
- 32GB RAM
- 8+ CPU cores
- 100GB free disk space
- SSD storage

### Software Requirements

```bash
# Check you have these installed:
podman --version     # Should be 4.0+
git --version        # For cloning repos
ls -l /dev/kvm      # Should be accessible
```

If missing, install:
```bash
# Fedora/RHEL
sudo dnf install podman git

# Ubuntu/Debian
sudo apt install podman git
```

### KVM Access

The build process needs KVM for testing VirtualBMC:

```bash
# Check KVM access
ls -l /dev/kvm

# If not accessible, add yourself to kvm group
sudo usermod -a -G kvm $USER
newgrp kvm
```

### Disk Space Check

```bash
# Check available space (need 50GB+)
df -h /var/lib/containers  # Podman storage
df -h /tmp                 # Build temp files
```

---

## Build Process

### Step 1: Navigate to Base Image Directory

```bash
cd ~/osforge/images/base
```

### Step 2: Review the Containerfile

Before building, review what will be built:

```bash
cat Containerfile
```

**Key layers:**
1. Base OS (Ubuntu Noble)
2. System packages
3. DevStack user
4. DevStack clone
5. **DevStack installation** ← Most time-consuming
6. OpenStack repos
7. Helper scripts

### Step 3: Run the Two-Stage Build

DevStack requires running services (MySQL, RabbitMQ, etc.) which can't start during a normal container build. We use a two-stage approach:

**Stage 1**: Build base image with all dependencies
**Stage 2**: Run DevStack in a privileged container, then commit it

```bash
# Two-stage build (recommended)
./build-with-devstack.sh

# Or for testing just the base layer:
./build.sh
```

The `build-with-devstack.sh` script will:
1. Build intermediate image with dependencies (~10 min)
2. Start container with systemd (~10 sec)
3. Run DevStack inside container (~45-60 min)
4. Commit container to final image (~2 min)
5. Clean up intermediate artifacts

**What happens:**

```
Stage 1: Building intermediate image
  [1/8] Building base layer (Ubuntu)... (~3 min)
  [2/8] Installing system packages... (~8 min)
  [3/8] Creating stack user... (~10 sec)
  [4/8] Cloning DevStack... (~2 min)
  [5/8] Cloning OpenStack repos... (~5 min)
  [6/8] Copying helper scripts... (~10 sec)
  [7/8] Configuring systemd... (~20 sec)
  [8/8] Finalizing intermediate image... (~10 sec)
  
Stage 2: Running DevStack in container
  [1/4] Starting container with systemd... (~10 sec)
  [2/4] Running stack.sh (THIS IS LONG!)... (~45-60 min)
  [3/4] Committing container to image... (~2 min)
  [4/4] Cleaning up... (~10 sec)

Total: ~65-80 minutes
```

### Step 4: Monitor the Build

The build will show progress. Watch for:

**Expected output:**
```
STEP 1/15: FROM ubuntu:noble
STEP 2/15: RUN apt-get update && apt-get install -y...
...
STEP 10/15: RUN cd /opt/stack/devstack && ./stack.sh
This is your host IP address: 10.0.2.15
This is your host IPv6 address: ::1
Horizon is now available at http://10.0.2.15/dashboard
...
stack.sh completed in 2145 seconds.
```

**Warning signs:**
- `ERROR`: Something failed
- `killed`: Out of memory
- Network timeouts: Retry build

### Step 6: Verify Build Success

```bash
# Check image exists
podman images | grep osforge

# Should see:
# quay.io/osforge/base  latest  abc123  5 minutes ago  5.2 GB
```

---

## Testing the Image

Before pushing to Quay.io, test the image locally.

### Quick Test: Shell Access

```bash
# Start container and open shell
podman run --rm -it \
  --privileged \
  --device /dev/kvm \
  quay.io/osforge/base:latest /bin/bash

# Inside container, verify:
ls /opt/stack/           # Should see devstack, ironic, nova, etc.
which tempest            # Should find tempest
systemctl list-units     # Should show systemd running

# Exit
exit
```

### Thorough Test: Start Services

```bash
# Start container with systemd
podman run -d \
  --name osforge-test \
  --privileged \
  --device /dev/kvm \
  quay.io/osforge/base:latest /usr/sbin/init

# Wait for systemd to be ready
sleep 10

# Check systemd status
podman exec osforge-test systemctl is-system-running
# Should output: running or degraded

# Try starting a service
podman exec osforge-test systemctl start mysql
podman exec osforge-test systemctl status mysql
# Should show: active (running)

# Clean up
podman stop osforge-test
podman rm osforge-test
```

### Full Test: Run DevStack Services

```bash
# Start container
podman run -d \
  --name osforge-full-test \
  --privileged \
  --device /dev/kvm \
  --tmpfs /run \
  --tmpfs /tmp \
  quay.io/osforge/base:latest /usr/sbin/init

# Start core services
podman exec osforge-full-test systemctl start mysql
podman exec osforge-full-test systemctl start rabbitmq-server

# Check they're running
podman exec osforge-full-test systemctl status mysql
podman exec osforge-full-test systemctl status rabbitmq-server

# Try starting Nova
podman exec osforge-full-test systemctl start nova-api
podman exec osforge-full-test systemctl status nova-api

# If all running successfully, image is good!

# Clean up
podman stop osforge-full-test
podman rm osforge-full-test
```

---

## Pushing to Quay.io

Once tested, push the image to Quay.io so others can use it.

### Step 1: Setup Quay.io Repository

If you haven't already:

1. Visit https://quay.io
2. Create organization "osforge" (or use your username)
3. Create public repository "base"
4. Your image will be: `quay.io/osforge/base`

### Step 2: Login to Quay.io

```bash
podman login quay.io
# Enter username and password
```

### Step 3: Tag the Image

```bash
# Tag with latest
podman tag quay.io/osforge/base:latest quay.io/osforge/base:latest

# Also tag with date for versioning
podman tag quay.io/osforge/base:latest \
  quay.io/osforge/base:noble-$(date +%Y%m%d)

# Optional: tag with git commit
cd ~/osforge
GIT_SHA=$(git rev-parse --short HEAD)
podman tag quay.io/osforge/base:latest \
  quay.io/osforge/base:noble-${GIT_SHA}
```

### Step 4: Push the Image

```bash
# Push latest
podman push quay.io/osforge/base:latest

# Push dated version
podman push quay.io/osforge/base:noble-$(date +%Y%m%d)
```

**This will take 10-20 minutes** depending on your upload speed (image is ~5GB).

### Step 5: Verify on Quay.io

Visit: https://quay.io/repository/osforge/base

You should see:
- Repository is public
- Tags: `latest`, `noble-20260427`, etc.
- Size: ~5-7GB
- Security scan results (if enabled)

---

## Using the Built Image

### From Quay.io (Recommended)

```bash
# Pull the image
podman pull quay.io/osforge/base:latest

# Run OSForge
osforge run ironic-tempest-bios-ipmi-autodetect
```

### From Local Build

```bash
# Use local image (don't pull)
osforge run ironic-tempest-bios-ipmi-autodetect --no-pull
```

---

## Rebuilding the Image

You should rebuild periodically to get latest OpenStack code:

**When to rebuild:**
- Weekly (recommended for active development)
- After major OpenStack releases
- When DevStack configuration changes
- When dependencies are updated

**How to rebuild:**

```bash
cd ~/osforge/images/base

# Full rebuild with DevStack
./build-with-devstack.sh

# Or just rebuild the base layer for testing
./build.sh
```

Then push to Quay.io again.

---

## Optimizing Build Time

### Use Build Cache

On subsequent builds, Podman will cache layers:

```bash
# First build: 60 minutes
podman build -t quay.io/osforge/base:latest -f Containerfile .

# Second build (if only last layers changed): 5-10 minutes
podman build -t quay.io/osforge/base:latest -f Containerfile .
```

### Multi-stage Strategy

For development, you can build in stages:

```bash
# Stage 1: Base OS + packages (fast to rebuild)
podman build --target base-packages -t osforge-base-packages .

# Stage 2: DevStack (only rebuild when needed)
podman build --target devstack-installed -t osforge-devstack .

# Stage 3: Final image
podman build -t quay.io/osforge/base:latest .
```

(Requires modifying Containerfile for multi-stage builds)

---

## Troubleshooting

### Build Fails: Out of Memory

**Symptom:**
```
Killed
Error: error building at STEP "RUN cd /opt/stack/devstack && ./stack.sh"
```

**Solution:**
- Increase system RAM (need 16GB+)
- Close other applications
- Add swap space:
  ```bash
  sudo dd if=/dev/zero of=/swapfile bs=1G count=8
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  ```

### Build Fails: DevStack Installation Error

**Symptom:**
```
+ die 'Failed to install package xyz'
```

**Solutions:**

1. **Check DevStack logs:**
   ```bash
   # Build with shell on failure
   podman build --debug -t quay.io/osforge/base:latest .
   ```

2. **Network issues:** Retry build
   ```bash
   ./build.sh
   ```

3. **Repository issues:** Check `devstack-local.conf` settings

4. **Known issues:** Check DevStack mailing list

### Build Fails: Permission Denied

**Symptom:**
```
Permission denied: /dev/kvm
```

**Solution:**
```bash
# Add yourself to kvm group
sudo usermod -a -G kvm $USER
newgrp kvm

# Verify
ls -l /dev/kvm
```

### Build is Extremely Slow

**Causes:**
- Not enough CPU cores
- Slow disk (HDD instead of SSD)
- Limited RAM (swapping)
- Slow network

**Solutions:**
- Use a machine with more resources
- Build overnight
- Use build cache on subsequent builds

### Push to Quay.io Fails

**Symptom:**
```
Error: authentication required
```

**Solution:**
```bash
# Re-login
podman login quay.io

# Check credentials
podman login --get-login quay.io
```

---

## Advanced: Customizing the Image

### Change Python Version

Edit `devstack-local.conf`:
```ini
PYTHON3_VERSION: 3.12  # Instead of 3.11
```

Rebuild.

### Add More Services

Edit `devstack-local.conf`:
```ini
# Enable Swift
enable_service s-proxy s-object s-container s-account

# Enable Heat
enable_plugin heat https://opendev.org/openstack/heat
```

Rebuild.

### Change DevStack Branch

Edit `Containerfile`:
```dockerfile
RUN git clone https://opendev.org/openstack/devstack.git /opt/stack/devstack && \
    cd /opt/stack/devstack && \
    git checkout stable/2026.1
```

Rebuild.

---

## Image Maintenance

### Tagging Strategy

```bash
# Latest (always the newest build)
quay.io/osforge/base:latest

# Date tagged (for versioning)
quay.io/osforge/base:noble-20260427

# Git commit tagged (for reproducibility)
quay.io/osforge/base:noble-a1b2c3d

# Stable branch tagged
quay.io/osforge/base:noble-stable-2026.1
```

### Cleaning Old Images

```bash
# List local images
podman images | grep osforge

# Remove old local images
podman rmi quay.io/osforge/base:noble-20260420

# Clean up build cache
podman system prune -a
```

### Security Scanning

Quay.io automatically scans for vulnerabilities:

1. Visit: https://quay.io/repository/osforge/base?tab=tags
2. Click on a tag
3. View "Security Scan" results
4. Fix critical/high vulnerabilities and rebuild

---

## CI/CD: Automated Builds

You can automate image builds with GitHub Actions:

```yaml
# .github/workflows/build-base-image.yml
name: Build Base Image

on:
  schedule:
    - cron: '0 0 * * 0'  # Weekly on Sunday
  workflow_dispatch:     # Manual trigger

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build image
        run: |
          cd images/base
          podman build -t quay.io/osforge/base:latest .
          
      - name: Login to Quay.io
        run: |
          podman login -u ${{ secrets.QUAY_USERNAME }} \
            -p ${{ secrets.QUAY_TOKEN }} quay.io
          
      - name: Push image
        run: |
          podman push quay.io/osforge/base:latest
          podman tag quay.io/osforge/base:latest \
            quay.io/osforge/base:noble-$(date +%Y%m%d)
          podman push quay.io/osforge/base:noble-$(date +%Y%m%d)
```

---

## Quick Reference

### Build Commands

```bash
# Basic build
cd images/base && ./build.sh

# Build without cache
podman build --no-cache -t quay.io/osforge/base:latest .

# Build and tag
./build.sh && \
podman tag quay.io/osforge/base:latest \
  quay.io/osforge/base:noble-$(date +%Y%m%d)
```

### Test Commands

```bash
# Quick test
podman run --rm -it --privileged --device /dev/kvm \
  quay.io/osforge/base:latest /bin/bash

# Full test
podman run -d --name test --privileged --device /dev/kvm \
  quay.io/osforge/base:latest /usr/sbin/init
podman exec test systemctl start mysql
podman exec test systemctl status mysql
podman stop test && podman rm test
```

### Push Commands

```bash
# Login
podman login quay.io

# Tag and push
podman push quay.io/osforge/base:latest
podman tag quay.io/osforge/base:latest \
  quay.io/osforge/base:noble-$(date +%Y%m%d)
podman push quay.io/osforge/base:noble-$(date +%Y%m%d)
```

---

## Next Steps

After building and pushing the image:

1. **Test with OSForge:**
   ```bash
   osforge run ironic-tempest-bios-ipmi-autodetect
   ```

2. **Document your build:**
   - Note any customizations
   - Record build time
   - Document issues encountered

3. **Share with team:**
   - Update README with Quay.io URL
   - Document image versions
   - Share build logs if issues

4. **Schedule rebuilds:**
   - Weekly or bi-weekly
   - After OpenStack releases
   - When DevStack changes

---

*Last Updated: 2026-04-27*
