# Development Workflow Guide

This guide explains how to efficiently develop and test OSForge improvements using development mode and other rapid iteration techniques.

## Overview

OSForge provides several features to help you iterate quickly when developing:

- **Development Mode** (`OSFORGE_DEV_MODE`) - Mount local scripts without rebuilding container images
- **Symlink Installation** (`./scripts/install.sh --dev`) - CLI changes take effect immediately
- **Repository Mounting** - Test changes to OpenStack components without rebuilding
- **Container Shell Access** - Debug issues interactively inside running containers

This guide focuses primarily on **Development Mode**, which is the fastest way to test script changes.

## Development Mode (OSFORGE_DEV_MODE)

### What is Development Mode?

Development mode is a feature that allows you to test changes to OSForge scripts (like `setup-vbmc.sh` and `run-tempest.sh`) **without rebuilding the container image**. 

When enabled, your local script files are mounted into the running container, overriding the versions baked into the image. This reduces the development cycle from 45-60 minutes (full image rebuild) to just seconds (edit and re-run).

### How It Works

**Normal Operation (Dev Mode Disabled):**
```
Container Image                    Running Container
┌──────────────────┐              ┌──────────────────┐
│ /usr/local/bin/  │  ────────>   │ /usr/local/bin/  │
│  ├─ setup-vbmc.sh│              │  ├─ setup-vbmc.sh│  <- Uses image version
│  └─ run-tempest.sh              │  └─ run-tempest.sh
└──────────────────┘              └──────────────────┘
```

**Development Mode (OSFORGE_DEV_MODE=true):**
```
Local Filesystem                   Running Container
┌──────────────────┐              ┌──────────────────┐
│ osforge/images/  │              │ /usr/local/bin/  │
│  base/files/     │              │                  │
│   scripts/       │  ──mount──>  │  ├─ setup-vbmc.sh│  <- Uses YOUR version
│    ├─ setup-vbmc.sh│            │  └─ run-tempest.sh
│    └─ run-tempest.sh            │                  │
└──────────────────┘              └──────────────────┘
```

**Implementation Details:**

The mounting happens in `lib/container.sh` when starting the container:

1. Checks if `OSFORGE_DEV_MODE=true` environment variable is set
2. Checks if local scripts directory exists (`images/base/files/scripts/`)
3. For each `.sh` file in the scripts directory:
   - Mounts it to `/usr/local/bin/<script-name>` in the container
   - Uses read-only mount (`:ro`) to prevent accidental modification
4. Container uses your local scripts instead of image scripts

### When to Use Development Mode

**✅ Use Development Mode When:**

- **Debugging script logic** - Add `echo` statements, modify error handling, test fixes
- **Fixing bugs in scripts** - Rapid iteration on script bugs (like we did with 7+ recent fixes)
- **Adding new features to scripts** - Test new functionality before committing to image
- **Testing script changes across multiple jobs** - Verify a script fix works for different job types
- **Prototyping** - Experiment with approaches before finalizing implementation

**Example scenario:** You notice that `setup-vbmc.sh` is failing because it's not waiting long enough for the Ironic API to be ready. With dev mode, you can:
1. Edit the timeout value in your local `setup-vbmc.sh`
2. Run `OSFORGE_DEV_MODE=true osforge run <job>`
3. See results in ~1 minute (not 60 minutes for image rebuild)
4. Iterate until fixed
5. Commit the final version and rebuild the image

### When NOT to Use Development Mode

**❌ Do NOT Use Development Mode When:**

- **Making changes to the base image** - Containerfile, installed packages, DevStack configuration
- **Modifying service configurations** - These are part of the image, not scripts
- **Testing final integration** - Before merging to main, always test with a clean image rebuild
- **Production use** - Dev mode is for development only
- **Scripts that don't exist in images/base/files/scripts/** - Only certain scripts are mounted

**Changes that require image rebuild:**
- Installing new packages in Containerfile
- Modifying DevStack installation steps
- Changing service configurations (tempest.conf templates, ironic.conf)
- Adding new system dependencies
- Updating Python packages in requirements.txt

## Usage Examples

### Example 1: Quick Script Fix

**Scenario:** The `setup-vbmc.sh` script has a timeout that's too short, causing the Ironic API check to fail.

```bash
# 1. Make the change
vim images/base/files/scripts/setup-vbmc.sh
# Change: max_wait=120
# To: max_wait=180

# 2. Test with dev mode (using CLI flag - recommended)
osforge run ironic-tempest-bios-ipmi-autodetect --dev-mode

# Alternative: Use environment variable
OSFORGE_DEV_MODE=true osforge run ironic-tempest-bios-ipmi-autodetect

# 3. Check logs to verify the change worked
osforge logs | grep "Waiting for Ironic API"

# 4. If it works, commit and rebuild image for production
git commit -am "Fix: Increase Ironic API timeout to 180s"
cd images/base
./build.sh
```

**Time savings:** 
- With dev mode: 1-2 minutes per iteration
- Without dev mode: 45-60 minutes per iteration (full image rebuild)

### Example 2: Debugging API Issues

**Scenario:** Need to add detailed logging to understand why flavor creation is failing.

```bash
# 1. Add debug output to setup-vbmc.sh
vim images/base/files/scripts/setup-vbmc.sh

# Add after line 310:
echo "[setup-vbmc] DEBUG: Current auth scope: ${OS_SYSTEM_SCOPE:-unset}"
echo "[setup-vbmc] DEBUG: Project name: ${OS_PROJECT_NAME:-unset}"
openstack flavor list --all -f table  # Show all flavors for debugging

# 2. Run with dev mode and capture detailed logs
osforge run ironic-tempest-bios-ipmi-autodetect --dev-mode 2>&1 | tee debug.log

# 3. Analyze the debug output
grep "DEBUG:" debug.log

# 4. Once you've identified the issue, remove debug output and fix the bug
# Then commit the fix (without the debug lines)
```

### Example 3: Testing Multi-Script Changes

**Scenario:** You need to modify both `setup-vbmc.sh` (to fix flavor creation) and `run-tempest.sh` (to use flavor UUID instead of name).

```bash
# 1. Make changes to both scripts
vim images/base/files/scripts/setup-vbmc.sh   # Fix flavor creation
vim images/base/files/scripts/run-tempest.sh  # Use flavor UUID

# 2. Test both changes together with dev mode
osforge run ironic-tempest-bios-ipmi-autodetect --dev-mode

# 3. Iterate on both scripts until working
# Each iteration is ~1 minute vs ~60 minutes for image rebuild

# 4. Once working, commit all changes
git add images/base/files/scripts/*.sh
git commit -m "Fix: Use flavor UUID and ensure public visibility"

# 5. Rebuild image for production
cd images/base
./build.sh
```

### Example 4: Adding Verbose Logging

**Scenario:** Need to understand the exact flow through `run-tempest.sh` to debug a test discovery issue.

```bash
# 1. Add set -x to enable bash tracing
vim images/base/files/scripts/run-tempest.sh
# Add after line 6:
set -x  # Enable bash tracing for debugging

# 2. Run with dev mode
osforge run ironic-tempest-bios-ipmi-autodetect --dev-mode 2>&1 | tee trace.log

# 3. Analyze the trace to understand execution flow
less trace.log

# 4. Remove set -x before committing the fix
```

## Troubleshooting

### Scripts Not Taking Effect

**Problem:** You enabled dev mode but your script changes aren't being used.

**Checklist:**

1. **Verify dev mode is actually enabled:**
   ```bash
   # Should see: "Development mode enabled - mounting local scripts"
   osforge run <job> --dev-mode 2>&1 | head -20
   ```

2. **Check script location:**
   ```bash
   # Scripts must be in this exact location:
   ls -la images/base/files/scripts/
   # Should show: setup-vbmc.sh, run-tempest.sh, etc.
   ```

3. **Verify script is being mounted:**
   ```bash
   # Start container with dev mode
   osforge run <job> --dev-mode --keep
   
   # In another terminal, check mounts
   osforge shell
   ls -la /usr/local/bin/
   cat /usr/local/bin/setup-vbmc.sh | head -5  # Should show your changes
   ```

4. **Check for syntax errors:**
   ```bash
   # Syntax errors prevent script from executing
   bash -n images/base/files/scripts/setup-vbmc.sh
   shellcheck images/base/files/scripts/setup-vbmc.sh
   ```

### Permission Issues

**Problem:** Scripts fail with permission denied errors.

**Solution:** Scripts are mounted read-only (`:ro`), which is correct. If you're seeing permission issues:

```bash
# 1. Verify local script is executable
chmod +x images/base/files/scripts/*.sh

# 2. Check file ownership
ls -la images/base/files/scripts/

# 3. If container shows permission errors, check SELinux context
# On Fedora/RHEL with SELinux:
ls -laZ images/base/files/scripts/
```

### Container Won't Start

**Problem:** Container fails to start when dev mode is enabled.

**Debugging steps:**

```bash
# 1. Check container logs
podman logs osforge-<job>-<timestamp>

# 2. Try starting without dev mode
osforge run <job>
# If this works, issue is with script mounting

# 3. Check scripts directory exists
ls -la images/base/files/scripts/
# Should show your script files

# 4. Try mounting a single script manually to isolate the issue
podman run --rm -it \
  -v "$(pwd)/images/base/files/scripts/setup-vbmc.sh:/tmp/test.sh:ro" \
  quay.io/osforge/base:latest \
  cat /tmp/test.sh
```

### Scripts Cached from Previous Run

**Problem:** Old version of script is running even with dev mode.

**Solution:** Stop and remove the container completely:

```bash
# Stop current container
osforge stop

# Clean up
osforge clean

# Start fresh
OSFORGE_DEV_MODE=true osforge run <job>
```

## Best Practices

### 1. Always Test Without Dev Mode Before Merging

Development mode is great for iteration, but before merging:

```bash
# 1. Develop with dev mode
osforge run <job> --dev-mode  # Fast iteration

# 2. Once working, rebuild image and test without dev mode
cd images/base
./build.sh dev
cd ../..
osforge run <job>  # Test with clean image (no dev mode)

# 3. Only merge if clean image test passes
```

**Why:** Ensures your changes work in production (where dev mode isn't used).

### 2. Use Version Control Checkpoints

When making multiple script changes:

```bash
# Make checkpoint commits as you go
git add images/base/files/scripts/setup-vbmc.sh
git commit -m "WIP: Add debug logging for API timeout"

# Continue iterating with dev mode
OSFORGE_DEV_MODE=true osforge run <job>

# Easy to revert if you break something
git log --oneline
git reset --hard HEAD^
```

### 3. Document Why You're Using Dev Mode

Add a comment in your script during development:

```bash
# TODO: Remove this debug logging before committing
echo "[DEBUG] Auth scope: ${OS_SYSTEM_SCOPE:-unset}"
echo "[DEBUG] Testing dev mode iteration"
```

### 4. Clean Up Debug Code

Before committing, remove:
- `set -x` tracing
- Extra `echo` debug statements
- Temporary test code
- TODO comments about dev mode

```bash
# Review changes before committing
git diff images/base/files/scripts/

# Only commit production-ready code
git add -p  # Interactive staging
```

### 5. Combine with Other Dev Features

Development mode works great with other OSForge dev features:

```bash
# Symlink installation + dev mode + repository mounting
./scripts/install.sh --dev

osforge run ironic-tempest-bios-ipmi-autodetect \
  --dev-mode \
  --ironic-repo ~/dev/ironic \
  --itp-repo ~/dev/ironic-tempest-plugin
  
# Now you can iterate on:
# - CLI code (symlink installation)
# - Scripts (dev mode)
# - Ironic/plugin code (repo mounting)
```

## Performance Comparison

### Development Cycle Times

| Change Type | Without Dev Mode | With Dev Mode | Speedup |
|-------------|------------------|---------------|---------|
| Script fix (1 line) | 45-60 min | ~1 min | **45-60x faster** |
| Script debug (5 iterations) | 225-300 min (4-5 hours) | ~5 min | **45-60x faster** |
| Multi-script change | 45-60 min | ~1 min | **45-60x faster** |

### Full Development Workflow

**Traditional approach (no dev mode):**
```
Edit script → Rebuild image (60 min) → Test (25 min) → Found bug
Edit script → Rebuild image (60 min) → Test (25 min) → Found bug
Edit script → Rebuild image (60 min) → Test (25 min) → Works!

Total: ~255 minutes (4.25 hours) for 3 iterations
```

**With dev mode:**
```
Edit script → Test (1 min) → Found bug
Edit script → Test (1 min) → Found bug  
Edit script → Test (1 min) → Works!
Rebuild image (60 min) → Test (25 min) → Verify

Total: ~87 minutes (1.5 hours) for 3 iterations + final verification
```

**Savings: ~3 hours** (or more with additional iterations)

## Limitations

### 1. Only Works for Specific Scripts

Dev mode only mounts scripts from `images/base/files/scripts/`. It does not affect:
- Scripts in other locations
- Python code
- Service configurations
- Containerfile changes

**Scripts that work with dev mode:**
- `setup-vbmc.sh` - Virtual baremetal setup
- `run-tempest.sh` - Tempest test execution
- Any other `.sh` files in `images/base/files/scripts/`

### 2. Not for Production

Dev mode is strictly for development. Never use it in CI/CD or production:

```bash
# ❌ Don't do this in CI
OSFORGE_DEV_MODE=true osforge run <job>

# ✅ Only in local development
OSFORGE_DEV_MODE=true osforge run <job>
```

### 3. Doesn't Help with Image Build Issues

If your change requires rebuilding the image (packages, DevStack config), dev mode won't help:

```bash
# These changes require full image rebuild:
vim images/base/Containerfile           # Package installation
vim images/base/files/local.conf        # DevStack configuration
vim images/base/files/ironic.conf.patch # Service configs
```

### 4. Scripts Must Be Executable

Mounted scripts must have executable permissions:

```bash
# Fix if needed
chmod +x images/base/files/scripts/*.sh
```

### 5. May Differ from Production

The final image might behave slightly differently than dev mode due to:
- Different file ownership in image vs mount
- Different timestamps
- Subtle container environment differences

**Always do final testing without dev mode before merging.**

## Summary

Development mode (`--dev-mode`) is a powerful feature for rapid iteration on OSForge scripts. Use it to:

- Fix bugs quickly without waiting for image rebuilds
- Debug issues with detailed logging
- Prototype new features
- Test changes across multiple scripts

**Remember:**
- ✅ Great for development and debugging
- ✅ Saves 45-60 minutes per iteration
- ✅ Works with symlink installation and repo mounting
- ❌ Not for production use
- ❌ Only affects scripts in `images/base/files/scripts/`
- ❌ Always verify with clean image rebuild before merging

**Quick reference:**
```bash
# Enable dev mode (CLI flag - recommended)
osforge run <job> --dev-mode

# Alternative: Use environment variable
OSFORGE_DEV_MODE=true osforge run <job>

# Verify it's active
# Look for: "Development mode enabled - mounting local scripts"

# Test without dev mode before merging
osforge run <job>
```

For more development workflows, see:
- [CONTRIBUTING.md](../CONTRIBUTING.md) - General contribution guidelines
- [docs/building-base-image.md](building-base-image.md) - Image building guide
- [docs/repository-locations.md](repository-locations.md) - Repository mounting options
