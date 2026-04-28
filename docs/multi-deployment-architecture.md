# Multi-Deployment Architecture Design

This document describes how OSForge will support multiple OpenStack deployment methods (DevStack, Kolla-Ansible, Bifrost).

## Goals

1. **Support multiple deployment types** while maintaining simple user experience
2. **Reuse existing infrastructure** (container runtime, job definitions, CLI)
3. **Allow easy addition** of new deployment methods in the future
4. **Maintain backwards compatibility** with existing DevStack-based jobs

---

## Architecture Overview

### Current Architecture (DevStack Only)

```
osforge/
├── images/
│   └── base/                    # DevStack base image
│       ├── Containerfile
│       ├── build.sh
│       └── devstack-local.conf
├── jobs/
│   └── ironic-tempest-*.yaml    # Job definitions
└── cli/
    └── osforge                  # CLI tool
```

**Limitation**: Only supports DevStack deployment

### Proposed Architecture (Multi-Deployment)

```
osforge/
├── images/
│   ├── devstack/                # DevStack base image
│   │   ├── Containerfile
│   │   ├── build-with-devstack.sh
│   │   └── devstack-local.conf
│   ├── kolla-ansible/           # Kolla-Ansible base image (NEW)
│   │   ├── Containerfile
│   │   ├── build-with-kolla.sh
│   │   └── globals.yml
│   └── bifrost/                 # Bifrost base image (FUTURE)
│       ├── Containerfile
│       ├── build-with-bifrost.sh
│       └── bifrost.yml
├── jobs/
│   ├── devstack/                # DevStack job definitions
│   │   ├── ironic-tempest-bios-ipmi-autodetect.yaml
│   │   ├── ironic-tempest-uefi-redfish-vmedia.yaml
│   │   └── ...
│   ├── kolla/                   # Kolla-Ansible job definitions (NEW)
│   │   ├── kolla-ansible-ironic-deploy.yaml
│   │   ├── kolla-ansible-ironic-upgrade.yaml
│   │   └── ...
│   └── bifrost/                 # Bifrost job definitions (FUTURE)
│       └── bifrost-integration-tinyipa.yaml
└── cli/
    └── osforge                  # CLI tool (enhanced for multi-deployment)
```

---

## Component Design

### 1. Base Images

Each deployment method has its own base image directory with:

#### DevStack Base Image (`images/devstack/`)

**Purpose**: Fast development iteration with systemd services

**Key Files**:
- `Containerfile` - Multi-stage build (dependencies + DevStack)
- `build-with-devstack.sh` - Two-stage build script
- `devstack-local.conf` - DevStack configuration
- `entrypoint.sh` - Container entrypoint

**Image Tag**: `quay.io/osforge/devstack:latest`

**Build Command**:
```bash
cd images/devstack
./build-with-devstack.sh
```

---

#### Kolla-Ansible Base Image (`images/kolla-ansible/`)

**Purpose**: Production-like deployment with containerized services

**Key Files**:
- `Containerfile` - Ansible + Kolla-Ansible + tools
- `build-with-kolla.sh` - Build and deploy script
- `globals.yml` - Kolla global configuration
- `passwords.yml` - Generated passwords
- `inventory/all-in-one` - Single-node inventory

**Image Tag**: `quay.io/osforge/kolla-ansible:latest`

**Build Strategy**:
```
Stage 1: Build base image with Ansible + Kolla-Ansible
Stage 2: Run kolla-ansible deploy in container
Stage 3: Commit deployed container as final image
```

**Build Command**:
```bash
cd images/kolla-ansible
./build-with-kolla.sh
```

---

#### Bifrost Base Image (`images/bifrost/`) - FUTURE

**Purpose**: Lightweight Ironic-only deployment

**Key Files**:
- `Containerfile` - Ansible + Bifrost
- `build-with-bifrost.sh` - Build and deploy script
- `bifrost.yml` - Bifrost configuration
- `inventory/bifrost-inventory.yml` - Bifrost inventory

**Image Tag**: `quay.io/osforge/bifrost:latest`

---

### 2. Job Definitions

Each job specifies which deployment method to use.

#### Job YAML Structure

```yaml
# jobs/devstack/ironic-tempest-bios-ipmi-autodetect.yaml
---
job:
  name: ironic-tempest-bios-ipmi-autodetect
  deployment: devstack                    # Deployment method
  base_image: quay.io/osforge/devstack:latest
  
  resources:
    memory: 8GB
    cpus: 4
    
  environment:
    IRONIC_DEFAULT_DEPLOY_INTERFACE: direct
    
  repositories:
    ironic: /opt/stack/ironic
    
  test_command: |
    cd /opt/stack/tempest
    tox -e all -- ironic_tempest_plugin.tests.scenario.test_baremetal_basic_ops
```

```yaml
# jobs/kolla/kolla-ansible-ironic-deploy.yaml
---
job:
  name: kolla-ansible-ironic-deploy
  deployment: kolla-ansible                # Deployment method
  base_image: quay.io/osforge/kolla-ansible:latest
  
  resources:
    memory: 10GB
    cpus: 4
    
  kolla_config:
    enable_ironic: "yes"
    enable_nova: "yes"
    enable_neutron: "yes"
    
  repositories:
    ironic: /var/lib/kolla/venv/lib/python3.11/site-packages/ironic
    
  test_command: |
    # Verify deployment
    source /etc/kolla/admin-openrc.sh
    openstack baremetal driver list
```

---

### 3. CLI Enhancement

The `osforge` CLI needs to handle multiple deployment types.

#### Current CLI

```bash
osforge run ironic-tempest-bios-ipmi-autodetect
```

**Problem**: Assumes DevStack deployment

#### Enhanced CLI

```bash
# Auto-detect deployment from job definition
osforge run ironic-tempest-bios-ipmi-autodetect

# Explicit deployment type
osforge run ironic-tempest-bios-ipmi-autodetect --deployment devstack
osforge run kolla-ansible-ironic-deploy --deployment kolla-ansible

# List available jobs by deployment type
osforge list --deployment devstack
osforge list --deployment kolla-ansible

# List all jobs
osforge list
```

#### CLI Implementation

```bash
#!/bin/bash
# osforge CLI (simplified)

JOB_NAME="$1"
DEPLOYMENT_TYPE="${2:-auto}"  # auto, devstack, kolla-ansible, bifrost

# Auto-detect deployment from job file
if [[ "$DEPLOYMENT_TYPE" == "auto" ]]; then
    if [[ -f "jobs/devstack/${JOB_NAME}.yaml" ]]; then
        DEPLOYMENT_TYPE="devstack"
    elif [[ -f "jobs/kolla/${JOB_NAME}.yaml" ]]; then
        DEPLOYMENT_TYPE="kolla-ansible"
    elif [[ -f "jobs/bifrost/${JOB_NAME}.yaml" ]]; then
        DEPLOYMENT_TYPE="bifrost"
    else
        echo "Error: Job not found"
        exit 1
    fi
fi

# Load job configuration
JOB_FILE="jobs/${DEPLOYMENT_TYPE}/${JOB_NAME}.yaml"
BASE_IMAGE=$(yq '.job.base_image' "$JOB_FILE")

# Run container with appropriate base image
podman run --rm -it \
    --privileged \
    --device /dev/kvm \
    -v "$PWD:/workspace" \
    "$BASE_IMAGE" \
    /usr/local/bin/run-job.sh "$JOB_NAME"
```

---

### 4. Container Runtime Environment

Each deployment type provides different environments.

#### DevStack Container

```
Container: quay.io/osforge/devstack:latest
├── DevStack installed (/opt/stack/devstack)
├── All OpenStack services running (systemd)
├── Tempest installed (/opt/stack/tempest)
├── User code mounted at /opt/stack/ironic
└── Entrypoint: osforge-entrypoint.sh
```

**Service management**:
```bash
# Inside container
systemctl restart devstack@ir-api
systemctl restart devstack@ir-cond
```

---

#### Kolla-Ansible Container

```
Container: quay.io/osforge/kolla-ansible:latest
├── Kolla-Ansible installed (/usr/local/share/kolla-ansible)
├── Nested containers for each service:
│   ├── mariadb (docker container)
│   ├── rabbitmq (docker container)
│   ├── keystone (docker container)
│   ├── ironic_api (docker container)
│   └── ironic_conductor (docker container)
├── Tempest installed (pip install)
├── User code mounted and copied into ironic containers
└── Entrypoint: osforge-kolla-entrypoint.sh
```

**Service management**:
```bash
# Inside container
docker restart ironic_api
docker restart ironic_conductor

# Or via kolla-ansible
kolla-ansible -i /etc/kolla/inventory reconfigure --tags ironic
```

---

### 5. Code Mounting Strategy

Different deployment types require different code mounting approaches.

#### DevStack: Direct Mount

```bash
podman run \
    -v ~/dev/ironic:/opt/stack/ironic:z \
    quay.io/osforge/devstack:latest

# Inside container:
# User code is directly at /opt/stack/ironic
# Restart service to pick up changes
systemctl restart devstack@ir-api
```

---

#### Kolla-Ansible: Mount + Copy

```bash
podman run \
    -v ~/dev/ironic:/workspace/ironic:z \
    quay.io/osforge/kolla-ansible:latest

# Inside container entrypoint:
# 1. Copy user code into Kolla venv
cp -r /workspace/ironic/* /var/lib/kolla/venv/lib/python3.11/site-packages/ironic/

# 2. Restart Ironic containers
docker restart ironic_api ironic_conductor

# OR rebuild Ironic containers with custom code
kolla-ansible -i /etc/kolla/inventory reconfigure --tags ironic
```

**Challenge**: Slower iteration (need to copy/rebuild containers)

**Mitigation**: 
- Pre-install Ironic in editable mode: `pip install -e /workspace/ironic`
- Restart containers instead of rebuilding when possible

---

## Migration Path

### Phase 1: DevStack (Current)

✅ DevStack base image  
✅ DevStack jobs  
✅ Basic CLI

**Status**: Complete

---

### Phase 2: Kolla-Ansible (Next)

**Tasks**:
1. Create `images/kolla-ansible/` directory
2. Create `Containerfile` for Kolla-Ansible base image
3. Create `build-with-kolla.sh` build script
4. Test Kolla-Ansible deployment in container
5. Create Kolla-Ansible job definitions
6. Update CLI to support `--deployment` flag
7. Update documentation

**Timeline**: 2-3 weeks

**Priority**: High (production-like testing is valuable)

---

### Phase 3: Bifrost (Future)

**Tasks**:
1. Create `images/bifrost/` directory
2. Create Bifrost Containerfile
3. Create Bifrost job definitions
4. Test Bifrost standalone deployment

**Timeline**: 1-2 weeks

**Priority**: Medium (lower CI usage, but useful for standalone Ironic)

---

## Backwards Compatibility

### Existing Users

Users with existing DevStack workflows should continue to work:

```bash
# This still works
osforge run ironic-tempest-bios-ipmi-autodetect

# CLI auto-detects it's a DevStack job
# Uses quay.io/osforge/devstack:latest
```

### Migration Strategy

```bash
# Old way (implicit DevStack)
osforge run ironic-tempest-bios-ipmi-autodetect

# New way (explicit, but optional)
osforge run ironic-tempest-bios-ipmi-autodetect --deployment devstack

# Both work identically
```

---

## Configuration Management

### Global Configuration (`~/.osforge/config.yaml`)

```yaml
# User preferences
default_deployment: devstack

# Repository locations
repos:
  ironic: ~/dev/ironic
  
# Per-deployment settings
devstack:
  base_image: quay.io/osforge/devstack:latest
  
kolla_ansible:
  base_image: quay.io/osforge/kolla-ansible:latest
  kolla_base_distro: ubuntu
  kolla_install_type: source
  
bifrost:
  base_image: quay.io/osforge/bifrost:latest
```

---

## Testing Strategy

### Test Matrix

| Deployment | Job Type | Test Coverage |
|------------|----------|---------------|
| DevStack | Tempest tests | High (current) |
| DevStack | Grenade (upgrades) | Medium (planned) |
| Kolla-Ansible | Deployment tests | Medium (planned) |
| Kolla-Ansible | Upgrade tests | Medium (planned) |
| Bifrost | Integration tests | Low (future) |

---

## Resource Requirements

### DevStack Container

- **RAM**: 8-12 GB
- **CPUs**: 4
- **Disk**: 30 GB
- **Build Time**: 60-80 minutes

### Kolla-Ansible Container

- **RAM**: 10-16 GB (nested containers)
- **CPUs**: 4-6
- **Disk**: 40 GB (container images)
- **Build Time**: 90-120 minutes

### Bifrost Container

- **RAM**: 6-8 GB
- **CPUs**: 4
- **Disk**: 20 GB
- **Build Time**: 20-30 minutes

---

## Implementation Checklist

### Kolla-Ansible Support

- [ ] Create `images/kolla-ansible/` directory structure
- [ ] Write `Containerfile` for Kolla base image
- [ ] Write `build-with-kolla.sh` script
- [ ] Test Kolla deployment in privileged container
- [ ] Create `globals.yml` configuration
- [ ] Test nested Docker-in-Podman
- [ ] Create sample job definitions
- [ ] Update CLI to support multiple deployments
- [ ] Write documentation
- [ ] Test end-to-end workflow

---

## Open Questions

1. **Nested containers**: Podman-in-Podman or Docker-in-Podman for Kolla?
   - **Recommendation**: Docker-in-Podman (Kolla officially supports Docker)

2. **Code mounting**: How to efficiently update code in Kolla containers?
   - **Recommendation**: Editable pip install + container restart

3. **Image size**: Kolla images are large (~40GB), acceptable?
   - **Recommendation**: Yes, one-time build cost, reusable

4. **CI/CD**: Build all deployment types or on-demand?
   - **Recommendation**: Build all, push to Quay.io with tags

5. **Upgrade testing**: How to support multi-version Kolla images?
   - **Future**: Tag images by OpenStack version (2024.2, 2025.1, etc.)

---

## Next Steps

1. **Finalize DevStack build issues** (current blocker with systemd)
2. **Create Kolla-Ansible Containerfile** (prototype)
3. **Test Kolla deployment** in container
4. **Update CLI** for multi-deployment support
5. **Document user workflows**

---

*Last Updated: 2026-04-28*
