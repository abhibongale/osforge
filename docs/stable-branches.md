# Testing Stable Branches with OSForge

OSForge allows you to test against specific OpenStack stable branches, not just master.

## Quick Start

### Test Specific Stable Branch

```bash
# Test 2026.1 stable branch
osforge run devstack-platform-rocky-blue-onyx --branch stable/2026.1

# Test 2025.2 stable branch
osforge run devstack-platform-rocky-blue-onyx --branch stable/2025.2

# Test specific Ironic stable branch
osforge run ironic-tempest-bios-ipmi-autodetect --branch stable/2026.1
```

### Test DevStack Stable Branch Specifically

```bash
# Test DevStack stable/2026.1 with master services
osforge run devstack-platform-rocky-blue-onyx --devstack-branch stable/2026.1

# Test custom DevStack with stable branch
osforge run devstack-platform-rocky-blue-onyx \
  --devstack-repo ~/dev/devstack \
  --devstack-branch stable/2026.1
```

---

## Branch Options

### `--branch <branch>`

Checks out the specified branch in **all** OpenStack service repos:
- DevStack
- Nova
- Neutron  
- Glance
- Keystone
- Cinder
- Ironic
- Tempest

```bash
# All repos checkout stable/2026.1
osforge run devstack-platform-rocky-blue-onyx --branch stable/2026.1
```

### `--devstack-branch <branch>`

Checks out the specified branch **only for DevStack**:

```bash
# DevStack uses stable/2026.1, services use master
osforge run devstack-platform-rocky-blue-onyx --devstack-branch stable/2026.1
```

### Combined Usage

```bash
# DevStack on 2026.1, services on 2025.2
osforge run devstack-platform-rocky-blue-onyx \
  --devstack-branch stable/2026.1 \
  --branch stable/2025.2

# Wait, that's weird - probably don't do this!
```

---

## Common Use Cases

### Scenario 1: Test Your Change Against Stable Branch

```bash
# You have changes in ~/dev/nova for stable/2026.1
cd ~/dev/nova
git checkout stable/2026.1
# Make your changes

# Test with all other services on stable/2026.1
osforge run devstack-platform-rocky-blue-onyx \
  --nova-repo ~/dev/nova \
  --branch stable/2026.1
```

**What happens:**
- Your local Nova code (on stable/2026.1 branch) is mounted
- All other services checkout stable/2026.1 inside container
- Tests run against consistent stable branch environment

### Scenario 2: Test Backport

```bash
# You're backporting a fix from master to stable/2026.1
cd ~/dev/ironic
git checkout stable/2026.1
git cherry-pick abc123  # Backport commit

# Test the backport
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/dev/ironic \
  --branch stable/2026.1
```

### Scenario 3: Test DevStack Change on Stable

```bash
# You modified DevStack for stable/2026.1
cd ~/dev/devstack
git checkout stable/2026.1
# Make changes

# Test your DevStack changes with stable services
osforge run devstack-platform-rocky-blue-onyx \
  --devstack-repo ~/dev/devstack \
  --branch stable/2026.1
```

### Scenario 4: Test Specific Commit

```bash
# Test a specific commit (SHA)
osforge run devstack-platform-rocky-blue-onyx \
  --branch a1b2c3d4e5f

# Test a tag
osforge run devstack-platform-rocky-blue-onyx \
  --branch 2026.1.0
```

---

## OpenStack Release Branches

### Supported Branches

OSForge supports any branch that exists in the OpenStack repos:

**Stable Branches:**
- `stable/2026.1` - Latest stable (Dalmatian)
- `stable/2025.2` - Previous (Caracal)
- `stable/2025.1` - (Bobcat)
- `stable/2024.2` - (Antelope)
- Older releases...

**Special Branches:**
- `master` - Current development (default)
- `unmaintained/*` - Old unmaintained branches

**Tags:**
- `2026.1.0`, `2026.1.1` - Point releases
- `milestone-1`, `milestone-2` - Development milestones

### Release Naming

OpenStack uses alphabetical names:
- 2026.1 = Dalmatian
- 2025.2 = Caracal  
- 2025.1 = Bobcat
- 2024.2 = Antelope
- etc.

Branches: `stable/2026.1`, `stable/2025.2`, etc.

---

## How Branch Checkout Works

### Timeline

1. **Container starts** - Has master branch of all repos (from base image)
2. **Services start** - Using master code
3. **Branch checkout** - OSForge checks out specified branches
4. **Services restart** - Pick up new code from branches
5. **Tests run** - Against the stable branch code

### Inside Container

When you run:
```bash
osforge run <job> --branch stable/2026.1
```

OSForge executes:
```bash
# Inside container for each repo:
cd /opt/stack/ironic
git fetch --all --tags
git checkout -B stable/2026.1 origin/stable/2026.1

cd /opt/stack/nova
git checkout -B stable/2026.1 origin/stable/2026.1

# etc for all repos
```

Then restarts services to pick up the new code.

---

## Mixing Branches (Advanced)

### Your Local Code + Stable Services

```bash
# Your code on master, services on stable/2026.1
cd ~/dev/nova
git checkout master
# Make changes

osforge run devstack-platform-rocky-blue-onyx \
  --nova-repo ~/dev/nova \
  --branch stable/2026.1
```

**Result:**
- Nova: Your master branch code (mounted)
- Everything else: stable/2026.1

**Use case:** Testing if your master change works with stable services

### DevStack Stable + Services Master

```bash
# Test new services with old DevStack
osforge run devstack-platform-rocky-blue-onyx \
  --devstack-branch stable/2026.1
```

**Result:**
- DevStack: stable/2026.1
- Services: master

**Use case:** Testing if new services are compatible with stable DevStack

---

## Configuration File

Set default branch in `~/.osforge/config.yaml`:

```yaml
# Default branch for all jobs
default_branch: stable/2026.1

# Job-specific branches
jobs:
  devstack-platform-rocky-blue-onyx:
    branch: stable/2026.1

  ironic-tempest-bios-ipmi-autodetect:
    branch: stable/2025.2  # Test against older stable
```

Then:
```bash
# Uses stable/2026.1 from config
osforge run devstack-platform-rocky-blue-onyx

# Override with CLI
osforge run devstack-platform-rocky-blue-onyx --branch master
```

---

## Troubleshooting

### "Branch not found"

```bash
# Error: Branch/tag/commit not found: stable/2026.1
```

**Cause:** Branch doesn't exist in that repo

**Fix:**
```bash
# Check which branches exist
git clone https://opendev.org/openstack/nova.git
cd nova
git branch -r | grep stable

# Or check online:
# https://opendev.org/openstack/nova/branches
```

### "Services fail to start after checkout"

```bash
# Services were running, then failed after branch checkout
```

**Cause:** Code incompatibility between branches

**Debug:**
```bash
osforge shell
systemctl status nova-compute
journalctl -u nova-compute -n 100
```

**Fix:** Ensure all repos are on compatible branches

### "Tests pass on master, fail on stable"

This is expected! Stable branches have:
- Older code
- Different dependencies
- Different configurations
- Known bugs (that were fixed in master)

**Use case:** This is why testing on stable matters!

---

## Best Practices

### 1. Match Branches

When testing stable, use the same branch everywhere:
```bash
# Good: All on 2026.1
osforge run <job> --branch stable/2026.1

# Bad: Mixed branches (unless you know what you're doing)
osforge run <job> --branch stable/2026.1 \
  --devstack-branch stable/2025.2
```

### 2. Test Your Backports

Always test backports on the target stable branch:
```bash
cd ~/dev/nova
git checkout stable/2026.1
git cherry-pick <commit>

osforge run devstack-platform-rocky-blue-onyx \
  --nova-repo ~/dev/nova \
  --branch stable/2026.1
```

### 3. Keep Base Image Updated

Rebuild base image periodically to get latest master:
```bash
cd images/base
./build.sh
```

Then branch checkouts will be faster (less commits to fetch).

---

## Examples

### Example 1: Test 2026.1 Platform

```bash
osforge run devstack-platform-rocky-blue-onyx --branch stable/2026.1
```

### Example 2: Test Your Nova Patch on 2026.1

```bash
cd ~/dev/nova
git checkout stable/2026.1
# Make changes

osforge run devstack-platform-rocky-blue-onyx \
  --nova-repo ~/dev/nova \
  --branch stable/2026.1
```

### Example 3: Test Ironic Stable Branch

```bash
osforge run ironic-tempest-bios-ipmi-autodetect --branch stable/2026.1
```

### Example 4: Test Specific Tag

```bash
osforge run devstack-platform-rocky-blue-onyx --branch 2026.1.0
```

### Example 5: Test Gerrit Change on Stable

```bash
cd ~/gerrit/openstack/nova
git review -d 12345  # Downloads change on stable/2026.1

osforge run devstack-platform-rocky-blue-onyx \
  --nova-repo ~/gerrit/openstack/nova \
  --branch stable/2026.1
```

---

## See Also

- [[Usage-Workflow]] - Complete usage guide
- [[Repository-Locations]] - Specifying repo locations
- [[Quick-Start]] - Getting started

---

*Last Updated: 2026-04-27*
