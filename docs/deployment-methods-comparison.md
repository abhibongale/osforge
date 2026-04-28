# OpenStack Deployment Methods Comparison

This document compares three main deployment methods used in OpenStack CI and production: **DevStack**, **Kolla-Ansible**, and **Bifrost**.

## Quick Comparison Table

| Feature | DevStack | Kolla-Ansible | Bifrost |
|---------|----------|---------------|---------|
| **Purpose** | Development & CI Testing | Production Deployments & CI | Standalone Ironic |
| **Installation** | Shell scripts | Ansible playbooks | Ansible playbooks |
| **Services** | All OpenStack | All OpenStack | Ironic only |
| **Containerization** | No (systemd services) | Yes (Docker/Podman) | No (systemd services) |
| **Setup Time** | 30-45 min | 60-90 min | 15-20 min |
| **Iteration Speed** | Fast (restart services) | Slow (rebuild containers) | Fast (restart services) |
| **Complexity** | Low | High | Medium |
| **Production Ready** | No | Yes | Limited |
| **CI Usage** | ~90% of jobs | ~5% of jobs | ~5% of jobs |
| **Best For** | Development, testing | Production-like testing, upgrades | Ironic-only testing |

---

## DevStack

### What is DevStack?

Shell scripts that install OpenStack services from source code, managed by systemd. This is the **most common** deployment method in OpenStack CI.

### Architecture

```
Host OS (Ubuntu/CentOS/Fedora)
├── MySQL (systemd service)
├── RabbitMQ (systemd service)  
├── Keystone (systemd service)
├── Nova (systemd services: nova-api, nova-compute, nova-conductor...)
├── Neutron (systemd services: neutron-server, neutron-dhcp-agent...)
├── Ironic (systemd services: ironic-api, ironic-conductor)
├── Glance (systemd service)
└── Swift (systemd services)
```

### Pros

✅ **Fast iteration**: Edit code → restart service → test (< 1 minute)  
✅ **Simple**: One `stack.sh` command installs everything  
✅ **Well documented**: Used by thousands of developers  
✅ **Easy debugging**: Direct access to logs, processes, code  
✅ **Standard CI**: 90% of OpenStack CI jobs use DevStack  
✅ **Lightweight**: No container overhead

### Cons

❌ **Not production-ready**: Only for development/testing  
❌ **No isolation**: All services share the same filesystem  
❌ **Less realistic**: Production deployments use containers  
❌ **Upgrades not tested**: Can't test upgrade scenarios

### Common CI Jobs Using DevStack

```yaml
# From openstack/ironic/zuul.d/ironic-jobs.yaml
- ironic-tempest-bios-ipmi-autodetect
- ironic-tempest-uefi-redfish-vmedia
- ironic-tempest-ovn-uefi-ipmi-pxe
- ironic-grenade (upgrade testing with DevStack)
```

### When to Use DevStack

- **Daily development**: Testing code changes quickly
- **Feature development**: Iterating on new features
- **Bug fixes**: Reproducing and fixing issues
- **Tempest testing**: Running integration tests
- **Learning OpenStack**: Understanding service interactions

### OSForge Support

✅ **Fully supported** - Current implementation uses DevStack

---

## Kolla-Ansible

### What is Kolla-Ansible?

Ansible playbooks that deploy OpenStack services in containers using pre-built container images from the Kolla project.

### Architecture

```
Host OS (Ubuntu/CentOS/Rocky)
├── Docker/Podman Runtime
│   ├── mariadb container
│   ├── rabbitmq container
│   ├── keystone container
│   ├── nova-api container
│   ├── nova-compute container
│   ├── nova-conductor container
│   ├── neutron-server container
│   ├── ironic-api container
│   ├── ironic-conductor container
│   ├── glance-api container
│   └── swift containers
```

### Pros

✅ **Production-like**: Matches real deployment architecture  
✅ **Isolated services**: Each service in its own container  
✅ **Upgrade testing**: Can test minor/major upgrades  
✅ **Multi-node**: Easy to deploy across multiple nodes  
✅ **Reproducible**: Container images ensure consistency  
✅ **Configuration management**: Ansible-based, version controlled

### Cons

❌ **Slower iteration**: Code change → rebuild image → redeploy (~10-20 min)  
❌ **More complex**: Requires understanding Ansible + containers  
❌ **Resource heavy**: Container overhead + Ansible control node  
❌ **Debugging harder**: Logs scattered across containers  
❌ **Less common in CI**: Only ~5% of jobs use kolla-ansible

### Common CI Jobs Using Kolla-Ansible

Based on research, kolla-ansible CI jobs focus on:

- **Deployment testing**: Verify kolla-ansible can deploy Ironic
- **Upgrade testing**: Test upgrade paths (e.g., 2024.2 → 2025.1)
- **Multi-node scenarios**: Test distributed deployments
- **Production scenario testing**: Validate production configurations

Example from kolla-ansible repository:
```yaml
# Jobs in openstack/kolla-ansible/zuul.d/
- kolla-ansible-ironic-base
- kolla-ansible-centos9s-source-ironic
- kolla-ansible-ubuntu-binary-ironic
```

### When to Use Kolla-Ansible

- **Production validation**: Testing deployment configurations
- **Upgrade testing**: Validating upgrade procedures
- **Container issues**: Debugging containerization problems
- **Multi-node testing**: Testing distributed deployments
- **Security testing**: Testing isolated service deployment

### OSForge Support

🔄 **Planned** - Will be added as separate deployment type

---

## Bifrost

### What is Bifrost?

Ansible playbooks that deploy Ironic in **standalone mode** (without other OpenStack services). Lightweight alternative for bare metal provisioning only.

### Architecture

```
Host OS (Ubuntu/CentOS/Fedora)
├── MySQL (systemd service)
├── RabbitMQ (systemd service) [optional]
├── Ironic API (systemd service)
├── Ironic Conductor (systemd service)
├── Ironic Inspector (systemd service) [optional]
├── Dnsmasq (DHCP/TFTP for PXE)
├── Nginx (HTTP server for images)
└── No Nova, No Neutron, No Keystone
```

### Pros

✅ **Lightweight**: Only Ironic, no other OpenStack services  
✅ **Fast setup**: 15-20 minutes to deploy  
✅ **Focused testing**: Test Ironic in isolation  
✅ **Production use case**: Used for standalone Ironic deployments  
✅ **Simple networking**: No Neutron complexity  
✅ **Good for bare metal**: Direct bare metal provisioning

### Cons

❌ **Limited scope**: Can't test Ironic + Nova integration  
❌ **Less CI coverage**: Only ~5% of Ironic CI jobs  
❌ **No multi-tenancy**: No Keystone authentication  
❌ **Missing features**: Some Ironic features require Nova integration  
❌ **Different workflow**: Not representative of full OpenStack

### Common CI Jobs Using Bifrost

From research and Ironic CI:

```yaml
# Bifrost-specific testing (in openstack/bifrost repo)
- bifrost-integration-tinyipa-ubuntu-jammy
- bifrost-integration-redfish-ubuntu-jammy

# Note: Many "ironic-standalone" jobs use DevStack, not Bifrost
# True Bifrost jobs are in the bifrost repository, not ironic repository
```

### When to Use Bifrost

- **Ironic-only development**: Testing Ironic without Nova
- **Bare metal focus**: Testing deployment interfaces, drivers
- **Lightweight testing**: Quick feedback on Ironic changes
- **Edge deployments**: Testing standalone Ironic scenarios
- **Metal3 integration**: Kubernetes bare metal provisioning

### OSForge Support

📋 **Future consideration** - Lower priority than kolla-ansible

---

## Deployment Method Selection Guide

### I want to test Ironic code changes quickly

→ **Use DevStack**

Fast iteration, most common CI method, easy debugging.

**OSForge command:**
```bash
osforge run ironic-tempest-bios-ipmi-autodetect
```

---

### I want to test Ironic deployment/configuration

→ **Use Kolla-Ansible** (when supported)

Production-like deployment, tests containerization, configuration management.

**OSForge command (planned):**
```bash
osforge run ironic-kolla-deploy --deployment kolla-ansible
```

---

### I want to test Ironic upgrade procedures

→ **Use Kolla-Ansible** (when supported)

Can deploy old version → upgrade → test.

**OSForge command (planned):**
```bash
osforge run ironic-upgrade-2024.2-to-2025.1 --deployment kolla-ansible
```

---

### I want to test Ironic without Nova

→ **Use Bifrost** or **DevStack standalone mode**

Lightweight, focused on bare metal provisioning only.

**OSForge command:**
```bash
# DevStack standalone (currently supported)
osforge run ironic-standalone

# Bifrost (future)
osforge run ironic-bifrost --deployment bifrost
```

---

### I want to test multi-node Ironic deployment

→ **Use Kolla-Ansible** (when supported)

Supports multi-node configurations easily.

---

### I want to test Ironic + Nova integration

→ **Use DevStack**

Standard multi-service deployment, most CI coverage.

**OSForge command:**
```bash
osforge run ironic-tempest-bios-ipmi-autodetect
```

---

## CI Job Statistics (Approximate)

Based on analysis of openstack/ironic zuul.d configurations:

| Deployment Method | % of Ironic CI Jobs | Example Count |
|-------------------|---------------------|---------------|
| DevStack | ~90% | ~25 jobs |
| Kolla-Ansible | ~5% | ~2 jobs |
| Bifrost | ~5% | ~2 jobs |

**Note**: The majority of Ironic testing uses DevStack because it provides fast feedback for code changes.

---

## Implementation in OSForge

### Current Status

✅ **DevStack**: Fully supported  
🔄 **Kolla-Ansible**: In planning  
📋 **Bifrost**: Future consideration

### Planned Architecture

```
osforge/
├── images/
│   ├── devstack/          # DevStack base image (current)
│   ├── kolla-ansible/     # Kolla-Ansible base image (planned)
│   └── bifrost/           # Bifrost base image (future)
├── jobs/
│   ├── devstack/          # DevStack job definitions
│   ├── kolla/             # Kolla-Ansible job definitions (planned)
│   └── bifrost/           # Bifrost job definitions (future)
```

### CLI Design (Planned)

```bash
# Explicit deployment type selection
osforge run <job-name> --deployment devstack
osforge run <job-name> --deployment kolla-ansible
osforge run <job-name> --deployment bifrost

# Auto-detect from job name
osforge run ironic-tempest-bios-ipmi-autodetect  # → uses devstack
osforge run kolla-ansible-ironic-deploy           # → uses kolla-ansible
osforge run bifrost-integration-tinyipa           # → uses bifrost
```

---

## References

### DevStack
- [DevStack Documentation](https://docs.openstack.org/devstack/latest/)
- [Ironic DevStack Plugin](https://opendev.org/openstack/ironic/src/branch/master/devstack)
- [Zuul Jobs - DevStack](https://opendev.org/openstack/openstack-zuul-jobs/src/branch/master/roles/run-devstack)

### Kolla-Ansible
- [Kolla-Ansible Documentation](https://docs.openstack.org/kolla-ansible/latest/)
- [Ironic in Kolla](https://docs.openstack.org/kolla-ansible/latest/reference/bare-metal/ironic-guide.html)
- [Kolla-Ansible GitHub](https://github.com/openstack/kolla-ansible)
- [Kolla-Ansible Release Notes](https://docs.openstack.org/releasenotes/kolla-ansible/2025.1.html)

### Bifrost
- [Bifrost Documentation](https://docs.openstack.org/bifrost/latest/)
- [Bifrost Installation Guide](https://docs.openstack.org/bifrost/latest/install/index.html)
- [Bifrost GitHub](https://github.com/openstack/bifrost)
- [Testing Environment](https://docs.openstack.org/bifrost/latest/contributor/testenv.html)

### Articles & Tutorials
- [Getting Started with Standalone OpenStack Ironic - Superuser](https://superuser.openinfra.org/articles/openstack-ironic-standalone/)
- [Getting Hands-On with Bifrost - Medium](https://medium.com/@edwinkayodeayo/%EF%B8%8F-part-2-getting-hands-on-with-bifrost-lightweight-bare-metal-provisioning-with-openstack-799957ae3e28)

---

*Last Updated: 2026-04-28*
