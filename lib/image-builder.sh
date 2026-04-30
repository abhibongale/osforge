#!/bin/bash
# Image building utilities for OSForge

# Check build requirements
check_build_requirements() {
    local errors=0

    log_info "Checking build requirements..."

    # Check Podman
    if ! command_exists podman; then
        log_error "Podman not found. Install with: sudo dnf install podman"
        ((errors++))
    else
        local podman_version
        podman_version=$(podman --version | grep -oP '\d+\.\d+' | head -1)
        local min_version="4.0"
        if ! awk -v ver="$podman_version" -v min="$min_version" 'BEGIN{exit(ver<min)}'; then
            log_error "Podman version $podman_version is too old (need 4.0+)"
            ((errors++))
        else
            log_success "Podman version $podman_version ✓"
        fi
    fi

    # Check disk space (need at least 50GB free)
    local free_space
    free_space=$(df -BG "$OSFORGE_ROOT" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ "$free_space" -lt 50 ]]; then
        log_error "Insufficient disk space: ${free_space}GB free (need 50GB+)"
        ((errors++))
    else
        log_success "Disk space: ${free_space}GB available ✓"
    fi

    # Check KVM access
    if [[ ! -e /dev/kvm ]]; then
        log_error "/dev/kvm not found. Enable KVM virtualization."
        ((errors++))
    elif [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
        log_error "No access to /dev/kvm. Run: sudo usermod -a -G kvm \$USER && newgrp kvm"
        ((errors++))
    else
        log_success "KVM access ✓"
    fi

    # Check memory (recommend at least 8GB, warn if less than 16GB)
    local total_mem
    total_mem=$(free -g | awk 'NR==2 {print $2}')
    if [[ "$total_mem" -lt 8 ]]; then
        log_error "Insufficient RAM: ${total_mem}GB (need 8GB minimum, 16GB recommended)"
        ((errors++))
    elif [[ "$total_mem" -lt 16 ]]; then
        log_warn "RAM: ${total_mem}GB (16GB+ recommended for faster builds)"
    else
        log_success "RAM: ${total_mem}GB ✓"
    fi

    # Check if build directory exists
    if [[ ! -d "$OSFORGE_ROOT/images/base" ]]; then
        log_error "Build directory not found: $OSFORGE_ROOT/images/base"
        ((errors++))
    fi

    return $errors
}

# Build base image (dependencies only, no DevStack)
build_base_image() {
    local tag="${1:-latest}"
    local no_cache="${2:-false}"

    log_info "Building base image (dependencies only): quay.io/osforge/base:$tag"
    log_warn "This build does NOT include DevStack. Use --full for complete image."
    echo ""

    # Build command
    local build_args="-t quay.io/osforge/base:$tag -f Containerfile ."
    if [[ "$no_cache" == "true" ]]; then
        build_args="--no-cache $build_args"
    fi

    # Change to build directory and build
    (
        cd "$OSFORGE_ROOT/images/base" || exit 1

        log_info "Starting build (this may take 10-15 minutes)..."
        if podman build $build_args; then
            echo ""
            log_success "Base image built successfully: quay.io/osforge/base:$tag"
            return 0
        else
            echo ""
            log_error "Build failed!"
            return 1
        fi
    )
}

# Build full image with DevStack
build_full_image() {
    local tag="${1:-latest}"
    local no_cache="${2:-false}"

    log_info "Building full image with DevStack: quay.io/osforge/base:$tag"
    log_warn "This will take 45-60 minutes. Go get coffee! ☕"
    echo ""

    # Estimate time
    log_info "Build stages:"
    echo "  [1/10] Ubuntu base          ~5 min"
    echo "  [2/10] System packages     ~10 min"
    echo "  [3/10] Stack user           ~1 min"
    echo "  [4/10] Clone DevStack       ~2 min"
    echo "  [5/10] Clone OpenStack      ~5 min"
    echo "  [6/10] Run DevStack        ~30-45 min ☕☕☕"
    echo "  [7/10] Install Tempest      ~5 min"
    echo "  [8/10] Helper scripts       ~1 min"
    echo "  [9/10] Configure systemd    ~2 min"
    echo "  [10/10] Finalize            ~1 min"
    echo "  ────────────────────────────────────"
    echo "  Total: ~60-75 minutes"
    echo ""

    # Build using the two-stage script
    local build_script="$OSFORGE_ROOT/images/base/build-with-devstack.sh"

    if [[ ! -f "$build_script" ]]; then
        log_error "Build script not found: $build_script"
        return 1
    fi

    # Export no-cache flag if needed
    if [[ "$no_cache" == "true" ]]; then
        export OSFORGE_BUILD_NO_CACHE="true"
        log_info "Using --no-cache flag for clean build"
        echo ""
    fi

    # Run build script from the images/base directory
    (
        cd "$OSFORGE_ROOT/images/base" || exit 1

        log_info "Running build script from: $OSFORGE_ROOT/images/base"
        if bash ./build-with-devstack.sh "$tag"; then
            echo ""
            log_success "Full image built successfully: quay.io/osforge/base:$tag"
            return 0
        else
            echo ""
            log_error "Build failed! Check logs above for details."
            return 1
        fi
    )
}

# Push image to Quay.io
push_image() {
    local tag="${1:-latest}"
    local image="quay.io/osforge/base:$tag"

    log_info "Pushing image to Quay.io: $image"
    echo ""

    # Check if logged in to Quay.io
    if ! podman login --get-login quay.io >/dev/null 2>&1; then
        log_warn "Not logged in to Quay.io. Attempting login..."
        if ! podman login quay.io; then
            log_error "Login to Quay.io failed"
            return 1
        fi
    fi

    # Check if image exists locally
    if ! podman image exists "$image"; then
        log_error "Image not found locally: $image"
        log_error "Build it first with: osforge build --full"
        return 1
    fi

    # Push image
    log_info "Pushing image (this may take 10-20 minutes for 5-7GB image)..."
    if podman push "$image"; then
        echo ""
        log_success "Image pushed successfully: $image"

        # Also tag and push with date
        local date_tag="noble-$(date +%Y%m%d)"
        log_info "Tagging with date: $date_tag"
        podman tag "$image" "quay.io/osforge/base:$date_tag"

        log_info "Pushing dated tag..."
        if podman push "quay.io/osforge/base:$date_tag"; then
            log_success "Dated image pushed: quay.io/osforge/base:$date_tag"
        fi

        return 0
    else
        echo ""
        log_error "Push failed!"
        return 1
    fi
}

# Show build status
show_build_status() {
    log_info "Checking build status..."
    echo ""

    # Check for running build containers
    local building_containers
    building_containers=$(podman ps -a --filter "name=osforge-devstack-build" --format "{{.ID}} {{.Status}} {{.Names}}")

    if [[ -n "$building_containers" ]]; then
        log_info "Active build containers:"
        echo "$building_containers"
        echo ""

        # Get container ID
        local container_id
        container_id=$(echo "$building_containers" | head -1 | awk '{print $1}')

        log_info "To view build logs:"
        echo "  podman logs -f $container_id"
        echo ""
        log_info "To check DevStack progress inside container:"
        echo "  podman exec $container_id tail -f /opt/stack/logs/stack.sh.log"
    else
        log_info "No active builds found"
        echo ""
    fi

    # List local base images
    log_info "Local OSForge images:"
    podman images --filter "reference=quay.io/osforge/base" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.Created}}"
    echo ""

    # Check disk usage
    log_info "Container storage usage:"
    podman system df
}

# Validate image after build
validate_image() {
    local tag="${1:-latest}"
    local image="quay.io/osforge/base:$tag"

    log_info "Validating image: $image"
    echo ""

    # Check if image exists
    if ! podman image exists "$image"; then
        log_error "Image not found: $image"
        return 1
    fi

    log_success "Image exists: $image"

    # Get image size
    local size
    size=$(podman image inspect "$image" --format '{{.Size}}' | awk '{print $1/1024/1024/1024 " GB"}')
    log_info "Image size: $size"

    # Quick validation - check if key directories exist
    log_info "Checking image contents..."

    local validation_checks=(
        "/opt/stack/devstack:DevStack directory"
        "/opt/stack/ironic:Ironic directory"
        "/opt/stack/tempest:Tempest directory"
        "/usr/bin/systemctl:Systemd"
    )

    local errors=0
    for check in "${validation_checks[@]}"; do
        local path="${check%%:*}"
        local name="${check##*:}"

        if podman run --rm "$image" test -e "$path"; then
            log_success "$name ✓"
        else
            log_error "$name not found at $path"
            ((errors++))
        fi
    done

    echo ""
    if [[ $errors -eq 0 ]]; then
        log_success "Image validation passed"
        return 0
    else
        log_error "Image validation failed with $errors errors"
        return 1
    fi
}
