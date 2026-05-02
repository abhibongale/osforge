#!/bin/bash
# Container management for OSForge

# Global container variables
CURRENT_CONTAINER=""
CURRENT_LOG_DIR=""

# Helper function to mount a repository
mount_repo() {
    local repo_path="$1"
    local mount_point="$2"
    local repo_name="$3"
    local mount_args_var="$4"

    if [[ -n "$repo_path" ]]; then
        local resolved_repo
        resolved_repo=$(resolve_path "$repo_path")

        if [[ ! -d "$resolved_repo" ]]; then
            log_error "$repo_name repository not found: $resolved_repo"
            return 1
        fi

        log_info "Mounting $repo_name repo: $resolved_repo"
        eval "$mount_args_var+=(-v \"$resolved_repo:$mount_point:rw\")"
    fi
    return 0
}

# Start container for job
container_start() {
    local job_name="$1"
    local ironic_repo="$2"
    local ipa_repo="$3"
    local itp_repo="$4"
    local tempest_repo="$5"
    local devstack_repo="$6"
    local nova_repo="$7"
    local neutron_repo="$8"
    local log_dir="$9"
    local no_pull="${10}"

    log_step "Starting container for job: $job_name"

    # Pull base image unless --no-pull
    if [[ "$no_pull" != "true" ]]; then
        log_info "Pulling base image: $BASE_IMAGE"
        if ! $RUNTIME pull "$BASE_IMAGE"; then
            log_error "Failed to pull base image"
            return 1
        fi
    else
        log_info "Skipping image pull (--no-pull specified)"
    fi

    # Generate container name
    local container_name
    container_name=$(get_container_name "$job_name")
    CURRENT_CONTAINER="$container_name"

    # Build mount arguments
    local mount_args=()

    # Mount repositories if provided
    mount_repo "$ironic_repo" "/opt/stack/ironic" "Ironic" "mount_args" || return 1
    mount_repo "$ipa_repo" "/opt/stack/ironic-python-agent" "Ironic Python Agent" "mount_args" || return 1
    mount_repo "$itp_repo" "/opt/stack/ironic-tempest-plugin" "Ironic Tempest Plugin" "mount_args" || return 1
    mount_repo "$tempest_repo" "/opt/stack/tempest" "Tempest" "mount_args" || return 1
    mount_repo "$devstack_repo" "/opt/stack/devstack" "DevStack" "mount_args" || return 1
    mount_repo "$nova_repo" "/opt/stack/nova" "Nova" "mount_args" || return 1
    mount_repo "$neutron_repo" "/opt/stack/neutron" "Neutron" "mount_args" || return 1

    # Mount log directory
    mount_args+=(-v "$log_dir:/opt/stack/logs:rw")

    # Mount cache
    mount_args+=(-v "$OSFORGE_USER_DIR/cache:/opt/stack/cache:rw")

    # Start container
    log_info "Starting container: $container_name"

    $RUNTIME run -d \
        --name "$container_name" \
        --privileged \
        --systemd=always \
        --device /dev/kvm \
        --cgroupns=host \
        --cap-add SYS_ADMIN \
        --memory "$MEMORY" \
        --cpus "$CPUS" \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "${mount_args[@]}" \
        -e "OSFORGE_JOB=$job_name" \
        -e "OSFORGE_LOG_DIR=/opt/stack/logs" \
        "$BASE_IMAGE" \
        /usr/sbin/init

    if [[ $? -ne 0 ]]; then
        log_error "Failed to start container"
        return 1
    fi

    log_success "Container started: $container_name"

    # Wait for systemd to be ready
    log_info "Waiting for systemd to initialize..."
    local timeout=60
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        # Check if systemd is operational (can list units)
        if container_exec systemctl list-units --no-pager &>/dev/null; then
            log_success "Container is ready (systemd operational)"
            return 0
        fi
        sleep 2
        ((elapsed+=2))
    done

    log_error "Container failed to become ready"
    return 1
}

# Execute command in container
container_exec() {
    if [[ -z "$CURRENT_CONTAINER" ]]; then
        log_error "No container running"
        return 1
    fi

    $RUNTIME exec "$CURRENT_CONTAINER" "$@"
}

# Execute command in container interactively
container_exec_interactive() {
    if [[ -z "$CURRENT_CONTAINER" ]]; then
        log_error "No container running"
        return 1
    fi

    $RUNTIME exec -it "$CURRENT_CONTAINER" "$@"
}

# Get container logs
container_logs() {
    if [[ -z "$CURRENT_CONTAINER" ]]; then
        log_error "No container running"
        return 1
    fi

    $RUNTIME logs "$CURRENT_CONTAINER"
}

# Stop container
container_stop() {
    if [[ -z "$CURRENT_CONTAINER" ]]; then
        log_warn "No container running"
        return 0
    fi

    log_info "Stopping container: $CURRENT_CONTAINER"
    $RUNTIME stop "$CURRENT_CONTAINER" || true

    log_info "Removing container: $CURRENT_CONTAINER"
    $RUNTIME rm "$CURRENT_CONTAINER" || true

    CURRENT_CONTAINER=""
}

# Find running osforge containers
find_running_containers() {
    $RUNTIME ps --filter "name=osforge-" --format "{{.Names}}"
}

# Kill all running osforge containers
kill_all_containers() {
    local containers
    containers=$(find_running_containers)

    if [[ -z "$containers" ]]; then
        log_info "No running containers found"
        return 0
    fi

    log_info "Stopping containers..."
    echo "$containers" | while read -r container; do
        log_info "  Stopping: $container"
        $RUNTIME stop "$container" || true
        $RUNTIME rm "$container" || true
    done

    log_success "All containers stopped"
}

# Cleanup old containers
cleanup_containers() {
    log_info "Cleaning up stopped containers..."
    $RUNTIME container prune -f
}

# Check if container is running
is_container_running() {
    if [[ -z "$CURRENT_CONTAINER" ]]; then
        return 1
    fi

    $RUNTIME inspect "$CURRENT_CONTAINER" >/dev/null 2>&1
}
