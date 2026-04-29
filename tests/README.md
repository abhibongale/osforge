# OSForge Tests

This directory contains test scripts and validation tools for OSForge components.

## Structure

```
tests/
├── images/
│   └── base/
│       └── test-build.sh    # Base image build validation
└── README.md                # This file
```

## Running Tests

### Base Image Tests

Test the containerized DevStack build for functionality:

```bash
cd tests/images/base

# Quick test (~2 minutes)
./test-build.sh

# Full test with Tempest (~10 minutes)
./test-build.sh --full
```

**Prerequisites:**
- Base image must be built first: `cd images/base && ./build-with-devstack.sh`
- Podman installed
- `/dev/kvm` device available
- Image `quay.io/osforge/base:latest` exists locally

### Test Phases

The base image test script validates:

1. **Pre-flight checks** - Podman, KVM, image existence
2. **Container startup** - Systemd initialization
3. **Systemd services** - DevStack service status
4. **OpenStack CLI** - Keystone, Glance, Nova, Ironic
5. **VirtualBMC** - IPMI simulation
6. **OVS/OVN** - Networking configuration
7. **Tempest** - Quick API test (full mode only)
8. **Summary** - Test results and next steps

### Output

- Colored terminal output with status indicators
- Container left running for manual inspection
- Detailed summary with image size, node count, network info

### Manual Testing

After automated tests, you can manually inspect:

```bash
# Get container ID from test output
podman exec -it <container-id> /bin/bash

# Inside container
export OS_CLOUD=devstack-admin
openstack baremetal node list
openstack server list
openstack image list

# Run full Tempest suite
cd /opt/stack/tempest
tox -e all -- ironic_tempest_plugin.tests.scenario.test_baremetal_basic_ops
```

### Cleanup

```bash
# Stop and remove test container
podman stop <container-id>
podman rm <container-id>
```

## Adding New Tests

When adding new test scripts:

1. Follow the directory structure matching `images/` or `jobs/`
2. Use descriptive names: `test-<component>.sh`
3. Include usage information in script header
4. Add colored output for better visibility
5. Leave artifacts for manual inspection when possible
6. Update this README with test documentation
