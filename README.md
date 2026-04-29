# OSForge - Local OpenStack CI Runner

Tired of waiting 3 hours for OpenStack CI? Run Zuul jobs locally in containers against your changes in ~20 minutes!

> **Status (2026-04-29)**: ✅ Phase 1 Complete | 🚧 Phase 2 In Progress
> - Base image built and working
> - CLI fully functional
> - Service startup tested (~60 seconds)
> - VirtualBMC and Tempest runners need implementation

## What is OSForge?

OSForge allows OpenStack developers to run specific Zuul CI jobs locally in containers before pushing to Gerrit. Test your changes fast, iterate quickly, and push with confidence.

**Before OSForge:** 
```
Make change → Push to Gerrit → Wait 3 hours → Test fails → Repeat
```

**With OSForge:**
```
Make change → osforge run <job> → Wait 20 min → See result → Fix locally → Repeat
```

## Quick Start

```bash
# 1. Clone OSForge
git clone https://github.com/abhibongale/osforge.git
cd osforge

# 2. Build base image (one-time, 45-60 minutes)
cd images/base
./build-with-devstack.sh
cd ../..

# 3. Install OSForge CLI
./scripts/install.sh --dev

# 4. Verify installation
osforge --version
osforge list-jobs

# 5. Go to your Ironic code
cd ~/dev/ironic

# 6. Make your changes
vim ironic/drivers/modules/ipmitool.py

# 7. Run the test!
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/dev/ironic \
  --no-pull

# 8. Watch it work (~1 min startup + test time)
```

**Note**: Base image is not yet pushed to Quay.io. You must build it locally first.

## Features

- ✅ Run Zuul jobs locally
- ✅ Mount your local code changes
- ✅ Fast iteration (no commit needed!)
- ✅ Full Ironic + Swift + VirtualBMC environment
- ✅ Detailed logs and debugging
- ⏱️ 20-30 minute feedback loop vs 3+ hours in CI

## Supported Jobs

Currently supports:
- `ironic-tempest-bios-ipmi-autodetect` - BIOS + IPMI + auto-detect deployment

Coming soon:
- More Ironic jobs (UEFI, Redfish, etc.)
- Other OpenStack projects (Nova, Tempest, Neutron)

## Requirements

- **OS**: Linux with KVM support
- **RAM**: 8GB minimum (16GB recommended)
- **CPU**: 4+ cores
- **Disk**: 30GB free space
- **Software**: Podman 4.0+

## Installation

### Prerequisites

```bash
# Install Podman
sudo dnf install podman podman-compose  # Fedora/RHEL
# or
sudo apt install podman podman-compose  # Ubuntu/Debian

# Setup KVM access
sudo usermod -a -G kvm $USER
newgrp kvm

# Verify
ls -l /dev/kvm
podman --version
```

### Install OSForge

```bash
git clone https://github.com/abhibongale/osforge.git
cd osforge
./scripts/install.sh

# Add to PATH (if not already)
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## Usage

### Basic Usage

```bash
# Run job from Ironic directory (auto-detects repo)
cd ~/dev/ironic
osforge run ironic-tempest-bios-ipmi-autodetect

# Or specify repo explicitly
osforge run ironic-tempest-bios-ipmi-autodetect --ironic-repo ~/dev/ironic
```

### Viewing Logs

```bash
# View summary
osforge logs

# View specific service logs
osforge logs ironic-conductor
osforge logs tempest
```

### Debugging

```bash
# Open shell in container
osforge shell

# Keep container running after test
osforge run <job> --keep
osforge shell
```

### Cleanup

```bash
# Stop all containers and clean up
osforge clean

# Keep last 5 log runs
osforge clean 5
```

## Configuration

User configuration at `~/.osforge/config.yaml`:

```yaml
runtime: podman
base_image: quay.io/osforge/base:latest

repos:
  ironic: ~/dev/ironic

logging:
  level: INFO
  keep_logs: 10

resources:
  memory: 8G
  cpus: 4
```

## Building the Base Image

**Critical first step:** Build the base container image before using OSForge.

```bash
cd images/base

# 1. Uncomment DevStack installation in Containerfile
vim Containerfile
# Find: # RUN cd /opt/stack/devstack && ./stack.sh
# Uncomment it (remove the #)

# 2. Build (takes 45-60 minutes!)
./build.sh

# 3. Test
podman run --rm -it --privileged --device /dev/kvm \
  quay.io/osforge/base:latest /bin/bash

# 4. Push to Quay.io (optional)
podman login quay.io
podman push quay.io/osforge/base:latest
```

**Full guide:** See `docs/building-base-image.md` for complete instructions, troubleshooting, and optimization tips.

## Project Status

**Current:** 🚧 **Alpha / In Development**

- ✅ Project structure complete
- ✅ CLI framework implemented
- ✅ Container orchestration designed
- 🚧 Base image (needs DevStack installation tested)
- 🚧 VirtualBMC setup scripts (placeholder)
- 🚧 Tempest execution logic (placeholder)
- ❌ Production-ready base image
- ❌ Comprehensive testing

**Next Steps:**
1. Build and test base image with DevStack
2. Implement VirtualBMC setup
3. Implement tempest test execution
4. Test end-to-end with real Ironic changes
5. Push base image to Quay.io
6. Add more job definitions

## Development

```bash
# Install in dev mode (symlink)
./scripts/install.sh --dev

# Build base image
cd images/base
./build.sh dev

# Test CLI
osforge --help
osforge list-jobs
```

## Architecture

OSForge uses pre-built container images with DevStack + Ironic installed. Your local code is mounted as a volume, services are restarted, and tests run - all in ~20 minutes.

```
Host Machine                    Container
~/dev/ironic/     ──mount──>   /opt/stack/ironic/
                                    ↓
                               Ironic services use your code
                                    ↓
                               Run Tempest tests
                                    ↓
                               Results + logs
```

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

See [LICENSE](LICENSE) file.

## Links

- **GitHub**: https://github.com/abhibongale/osforge
- **Documentation**: [docs/](docs/)
- **Issues**: https://github.com/abhibongale/osforge/issues

## Credits

Created by [Abhi Bongale](https://github.com/abhibongale) to solve the "3-hour feedback loop" problem in OpenStack Ironic development.

Inspired by the need to iterate faster on Ironic changes without waiting for CI.

---

**Note:** This is an independent tool, not officially part of OpenStack. It replicates Zuul CI jobs locally for development purposes.

---

## Current Status (2026-04-29)

### ✅ What's Working

**Infrastructure:**
- ✅ Base image build complete (25.3 GB, two-stage with systemd)
- ✅ Container launch with proper systemd support
- ✅ Service startup (MySQL, RabbitMQ, all 28 DevStack services)
- ✅ Code mounting infrastructure ready
- ✅ Option A architecture implemented (services stopped in base image)

**CLI:**
- ✅ Full command framework (`run`, `logs`, `shell`, `status`, `stop`, `clean`)
- ✅ Installation script (dev mode with symlinks)
- ✅ Job configuration system
- ✅ Logging and output formatting

**Testing:**
- ✅ Automated build validation (`tests/images/base/test-build.sh`)
- ✅ 8 test phases with colored output
- ✅ Service verification

**Documentation:**
- ✅ Comprehensive Obsidian documentation (15 files, ~60,000 words)
- ✅ Container Build Implementation guide
- ✅ Line-by-Line Changes reference
- ✅ Architecture Plan
- ✅ Usage Workflow examples

### 🚧 In Progress

**Need Implementation:**
- ⚠️ VirtualBMC setup (placeholder exists in `images/base/files/scripts/setup-vbmc.sh`)
- ⚠️ Tempest test execution (placeholder exists in `images/base/files/scripts/run-tempest.sh`)
- ⚠️ Testing with real Ironic code changes (mounting ready, needs end-to-end test)

**Not Started:**
- ❌ Base image push to Quay.io
- ❌ Additional job definitions (UEFI, Redfish, etc.)
- ❌ Stable branch support
- ❌ Performance optimization

### 📊 Performance Metrics

**Current:**
- Base image build: 45-60 minutes (one-time)
- Container startup: ~60 seconds
- Service startup: ~45 seconds
- Expected total: ~25 minutes per test

**Target:**
- CI time: 3+ hours
- OSForge time: ~25 minutes
- **Speedup: ~7x faster**

---

## Architecture

OSForge uses a **two-stage build** approach:

**Stage 1: Build Intermediate Image**
```dockerfile
FROM ubuntu:noble
# Install dependencies
# Clone repos
# Apply container-specific patches
# Result: quay.io/osforge/base-intermediate:latest
```

**Stage 2: Run DevStack in Live Container**
```bash
podman run --systemd=always intermediate:latest
# Inside container: execute stack.sh
# Commit running container to final image
# Result: quay.io/osforge/base:latest
```

**Why Two-Stage?**
- DevStack requires running systemd (not available during `podman build`)
- Services need to start/stop during installation
- Final image has services **configured but stopped** (Option A architecture)

**Runtime Flow:**
```
1. Start container from base image (services stopped)
2. Mount user code at /opt/stack/ironic
3. Start all services (~60 seconds)
4. Run tests
5. Collect results
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

**Current Priority Areas:**
1. Implement real VirtualBMC setup
2. Implement real Tempest test execution
3. Test with actual Ironic code changes
4. Push base image to Quay.io
5. Add more job definitions

---

## Related Documentation

**Obsidian Documentation** (if you have access):
- Quick Start: `/home/abongale/Dropbox/Obsidian/RESOURCE/OSFORGE/1-Getting-Started/Quick-Start.md`
- Architecture Plan: `.../4-Development/Architecture-Plan.md`
- Container Build Implementation: `.../4-Development/Container-Build-Implementation.md`
- Usage Workflow: `.../2-Usage-Guides/Usage-Workflow.md`

**GitHub Issues:**
- [#4](https://github.com/abhibongale/osforge/issues/4) - Architecture deviation discussion (resolved with Option A)
- [#5](https://github.com/abhibongale/osforge/issues/5) - OSForge CLI integration implementation

---

*Last Updated: 2026-04-29*
