# Repository Locations - Flexible Configuration

OSForge needs to know where your OpenStack repositories are located so it can mount them into the container. It supports multiple ways to specify this.

## Priority Order

OSForge looks for repository locations in this order:

1. **Command-line flag** (highest priority)
2. **Current directory auto-detection**
3. **User config file** (`~/.osforge/config.yaml`)
4. **No mount** (uses code from base image)

---

## Method 1: Command-Line Flag (Explicit)

**Best for**: One-off tests, multiple checkouts, CI/CD scripts

```bash
# Specify exact path
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo /path/to/your/ironic

# Multiple repos
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/work/ironic \
  --ipa-repo ~/work/ironic-python-agent
```

**Examples:**

```bash
# Work directory
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/work/openstack/ironic

# Gerrit checkout
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/gerrit/openstack/ironic

# Multiple branches
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/ironic-feature-branch

# Absolute path
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/Projects/ironic-custom
```

---

## Method 2: Auto-Detection (Convenient)

**Best for**: Daily development workflow

OSForge automatically detects if you're in an Ironic repository:

```bash
# Just cd into your ironic repo
cd /wherever/your/ironic/checkout/is
osforge run ironic-tempest-bios-ipmi-autodetect
```

**How it works:**
1. Checks if `.git` directory exists
2. Checks if `setup.py` contains `"name.*ironic"`
3. If both true, uses current directory

**Example workflow:**
```bash
# Multiple feature branches
cd ~/ironic-bugfix-123
osforge run ironic-tempest-bios-ipmi-autodetect

cd ~/ironic-feature-xyz
osforge run ironic-tempest-bios-ipmi-autodetect
```

---

## Method 3: Config File (Default)

**Best for**: Consistent development environment

Set your default paths in `~/.osforge/config.yaml`:

```yaml
repos:
  ironic: ~/dev/ironic
  ironic-python-agent: ~/dev/ironic-python-agent
```

Then run from anywhere:
```bash
# No need to specify path
osforge run ironic-tempest-bios-ipmi-autodetect
```

**Setup:**
```bash
# Create config
vim ~/.osforge/config.yaml

# Add your paths
repos:
  ironic: /your/custom/path/to/ironic

# Now it works from anywhere
cd ~
osforge run ironic-tempest-bios-ipmi-autodetect
```

---

## Method 4: No Mount (Base Image Code)

If you don't specify a repo, OSForge uses the Ironic code from the base image:

```bash
# Uses base image's Ironic code
osforge run ironic-tempest-bios-ipmi-autodetect
```

**Useful for:**
- Testing base image
- Baseline comparison
- Debugging OSForge itself

---

## Common Scenarios

### Scenario 1: Multiple Gerrit Changes

```bash
# Testing different patches
cd ~/gerrit/openstack/ironic
git review -d 12345  # Download change
osforge run ironic-tempest-bios-ipmi-autodetect

git review -d 12346  # Different change
osforge run ironic-tempest-bios-ipmi-autodetect
```

### Scenario 2: Multiple Feature Branches

```bash
# Branch 1
cd ~/ironic-bugfix-deployment
osforge run ironic-tempest-bios-ipmi-autodetect

# Branch 2  
cd ~/ironic-feature-redfish
osforge run ironic-tempest-bios-ipmi-autodetect
```

### Scenario 3: Testing Upstream vs Fork

```bash
# Upstream
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/upstream/ironic

# Your fork
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/fork/ironic
```

### Scenario 4: Different Projects

```bash
# Different OpenStack repos in different locations
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo ~/work/ironic

osforge run nova-tempest-test \
  --nova-repo ~/other-location/nova
```

### Scenario 5: CI/CD Script

```bash
#!/bin/bash
# test-ironic-patch.sh

GERRIT_CHANGE="$1"
CHECKOUT_DIR="/tmp/ironic-test-$$"

git clone https://opendev.org/openstack/ironic.git "$CHECKOUT_DIR"
cd "$CHECKOUT_DIR"
git review -d "$GERRIT_CHANGE"

osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo "$CHECKOUT_DIR"
```

---

## Environment Variables

You can also use environment variables:

```bash
# Set in shell
export OSFORGE_IRONIC_REPO=~/my-ironic

# Run
osforge run ironic-tempest-bios-ipmi-autodetect
```

Or in your `~/.bashrc`:
```bash
export OSFORGE_IRONIC_REPO=~/dev/ironic
export OSFORGE_IPA_REPO=~/dev/ironic-python-agent
```

---

## Troubleshooting

### "Repository not found"

```bash
# Check path
ls -la /path/to/ironic

# Try absolute path
osforge run ironic-tempest-bios-ipmi-autodetect \
  --ironic-repo /absolute/path/to/ironic

# Check auto-detection
cd /path/to/ironic
ls -la .git setup.py
grep name setup.py
```

### "Auto-detection not working"

Auto-detection requires:
1. `.git` directory exists
2. `setup.py` exists
3. `setup.py` contains `"name.*ironic"`

Check:
```bash
cd /your/ironic/repo
ls -la .git
cat setup.py | grep name
```

### "Wrong code is being used"

Check priority:
```bash
# Explicit flag wins
osforge run <job> --ironic-repo ~/correct-path

# Check what's mounted
osforge run <job> --keep --verbose
osforge shell
ls -la /opt/stack/ironic
```

---

## Best Practices

1. **Daily development**: Use auto-detection (cd into repo and run)
2. **Multiple checkouts**: Use explicit `--ironic-repo` flag
3. **Stable setup**: Set default in `~/.osforge/config.yaml`
4. **Scripts**: Always use explicit flag for clarity

---

## Path Expansion

OSForge expands paths:
- `~/dev/ironic` → `/home/username/dev/ironic`
- `$HOME/ironic` → `/home/username/ironic`
- Relative paths are made absolute based on current directory

---

## See Also

- [[Usage-Workflow]] - Full usage guide
- [[Quick-Start]] - Getting started
- `config/settings.yaml.example` - Example config file

---

*Last Updated: 2026-04-27*
