# OSForge - Local OpenStack CI Runner

Tired of waiting 3 hours for OpenStack CI? Run Zuul jobs locally in containers against your changes in ~20 minutes!

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
# 1. Install OSForge
git clone https://github.com/abhibongale/osforge.git
cd osforge
./scripts/install.sh

# 2. Pull base image (TODO: Build and push to Quay.io first!)
podman pull quay.io/osforge/base:latest

# 3. Go to your Ironic code
cd ~/dev/ironic

# 4. Make your changes
vim ironic/drivers/modules/ipmitool.py

# 5. Run the test!
osforge run ironic-tempest-bios-ipmi-autodetect

# 6. Wait ~20 minutes and see results
```

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
