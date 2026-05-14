# Contributing to OSForge

Thank you for your interest in contributing to OSForge!

## How to Contribute

### Reporting Issues

- Check if the issue already exists
- Include OSForge version (`osforge version`)
- Include Podman version (`podman --version`)
- Provide steps to reproduce
- Include relevant logs from `~/.osforge/logs/`

### Submitting Changes

1. **Fork the repository**
   ```bash
   git clone https://github.com/abhibongale/osforge.git
   cd osforge
   ```

2. **Create a branch**
   ```bash
   git checkout -b fix/my-bug-fix
   # or
   git checkout -b feature/my-new-feature
   ```

3. **Make your changes**
   - Follow existing code style (bash best practices)
   - Add comments for complex logic
   - Test your changes locally

4. **Test**
   ```bash
   # Install in dev mode
   ./scripts/install.sh --dev

   # Test your changes
   osforge run ironic-tempest-bios-ipmi-autodetect
   ```

5. **Commit**
   ```bash
   git add -p
   git commit -m "Fix: Description of your fix"

   # Or for features
   git commit -m "Add: Description of your feature"
   ```

6. **Push and create PR**
   ```bash
   git push origin fix/my-bug-fix
   ```
   Then create a Pull Request on GitHub.

## Development Setup

```bash
# Clone repo
git clone https://github.com/abhibongale/osforge.git
cd osforge

# Install in dev mode (creates symlink)
./scripts/install.sh --dev

# Build base image locally
cd images/base
./build.sh dev

# Make changes
vim bin/osforge
vim lib/container.sh

# Test
osforge run ironic-tempest-bios-ipmi-autodetect
```

### Development Mode (Rapid Iteration)

When working on scripts in `images/base/files/scripts/`, use development mode to test changes without rebuilding the container image:

```bash
# Enable development mode (recommended)
osforge run <job> --dev-mode

# Alternative: Use environment variable
OSFORGE_DEV_MODE=true osforge run <job>

# Your local scripts will be mounted and used instead of image scripts
```

**What gets mounted:**
- `setup-vbmc.sh` - Virtual baremetal node setup
- `run-tempest.sh` - Tempest test execution
- Other scripts in `images/base/files/scripts/`

**Example workflow:**
```bash
# 1. Make changes to a script
vim images/base/files/scripts/setup-vbmc.sh

# 2. Test immediately with dev mode (no image rebuild needed)
osforge run ironic-tempest-bios-ipmi-autodetect --dev-mode

# 3. Iterate until working
# 4. Rebuild image for production testing
cd images/base && ./build.sh
```

**See:** [docs/development-workflow.md](docs/development-workflow.md) for complete guide, examples, and troubleshooting.

## Project Structure

```
bin/osforge           - Main CLI tool
lib/                  - Helper libraries
images/base/          - Base container image
config/jobs/          - Job definitions
scripts/              - Utility scripts
docs/                 - Documentation
```

## Coding Guidelines

### Bash Scripts

- Use `set -euo pipefail` at the top
- Quote variables: `"$variable"`
- Use functions for reusable code
- Add comments for non-obvious logic
- Use shellcheck for linting

### Commits

- Use conventional commit format
- `Fix:` for bug fixes
- `Add:` for new features
- `Update:` for changes to existing features
- `Docs:` for documentation only

### Testing

Before submitting:
- ✓ shellcheck passes on bash scripts
- ✓ CLI commands work as expected
- ✓ Base image builds successfully
- ✓ At least one job runs end-to-end

## Adding New Jobs

1. Create job definition in `config/jobs/`
2. Follow existing YAML format
3. Test with `osforge run <new-job>`
4. Document in README

## Building Base Image

```bash
cd images/base
./build.sh dev
podman run --rm -it quay.io/osforge/base:dev /bin/bash
```

## Questions?

- Open an issue for discussion
- Tag with `question` label

## Code of Conduct

- Be respectful
- Be constructive
- Help others learn

Thank you for contributing!
