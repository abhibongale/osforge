#!/bin/bash
# Job execution logic for OSForge

# Run a Zuul job
run_job() {
    local job_name="$1"
    local ironic_repo="$2"
    local ipa_repo="$3"
    local devstack_repo="$4"
    local nova_repo="$5"
    local neutron_repo="$6"
    local branch="$7"
    local devstack_branch="$8"
    local verbose="$9"
    local keep="${10}"
    local no_pull="${11}"

    # Enable verbose logging if requested
    if [[ "$verbose" == "true" ]]; then
        CURRENT_LOG_LEVEL=$LOG_LEVEL_DEBUG
    fi

    log_step "OSForge - Running job: $job_name"

    # Check prerequisites
    check_prereqs || exit 1

    # Load job configuration
    local job_file="$OSFORGE_CONFIG/jobs/${job_name}.yaml"
    if [[ ! -f "$job_file" ]]; then
        log_error "Job definition not found: $job_file"
        log_info "Available jobs:"
        list_available_jobs
        exit 1
    fi

    log_debug "Loaded job config: $job_file"

    # Create log directory
    CURRENT_LOG_DIR=$(create_log_dir)
    log_info "Logs will be saved to: $CURRENT_LOG_DIR"

    # Save run metadata
    save_run_metadata "$CURRENT_LOG_DIR" "$job_name" "$ironic_repo"

    # Start container
    if ! container_start "$job_name" "$ironic_repo" "$CURRENT_LOG_DIR" "$no_pull"; then
        log_error "Failed to start container"
        exit 1
    fi

    # Run the test
    local start_time
    start_time=$(date +%s)

    log_step "Setting up services..."
    if ! setup_services; then
        log_error "Failed to setup services"
        container_stop
        exit 1
    fi

    # Checkout branches if specified
    if ! checkout_branches "$branch" "$devstack_branch"; then
        log_error "Failed to checkout branches"
        container_stop
        exit 1
    fi

    log_step "Setting up virtual baremetal..."
    if ! setup_vbmc; then
        log_error "Failed to setup VirtualBMC"
        container_stop
        exit 1
    fi

    log_step "Running tempest test..."
    if ! run_tempest_test "$job_name"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_error "Test FAILED"
        log_info "Runtime: $((duration / 60)) minutes $((duration % 60)) seconds"

        log_info ""
        log_info "To debug:"
        log_info "  osforge logs          # View logs"
        log_info "  osforge shell         # Open shell in container"

        if [[ "$keep" != "true" ]]; then
            container_stop
        fi

        exit 1
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Test PASSED!"
    log_info "Runtime: $((duration / 60)) minutes $((duration % 60)) seconds"
    log_info "Logs: $CURRENT_LOG_DIR"

    # Stop container unless --keep
    if [[ "$keep" != "true" ]]; then
        container_stop
    else
        log_info "Container kept running (--keep). Use 'osforge shell' to access."
    fi
}

# Setup services in container
setup_services() {
    # For our DevStack base image, services are already running
    # Just verify they're active instead of trying to start them
    log_info "Verifying services are running..."

    # Check key DevStack services
    log_info "Checking Ironic API..."
    if ! container_exec systemctl is-active --quiet devstack@ir-api.service; then
        log_warn "Ironic API not running, attempting to start..."
        container_exec systemctl start devstack@ir-api.service || return 1
    fi

    log_info "Checking Ironic Conductor..."
    if ! container_exec systemctl is-active --quiet devstack@ir-cond.service; then
        log_warn "Ironic Conductor not running, attempting to start..."
        container_exec systemctl start devstack@ir-cond.service || return 1
    fi

    log_info "Checking Keystone..."
    if ! container_exec systemctl is-active --quiet devstack@keystone.service; then
        log_warn "Keystone not running, attempting to start..."
        container_exec systemctl start devstack@keystone.service || return 1
    fi

    log_success "All required services are running"
    return 0
}

# Checkout specific branches in container
checkout_branches() {
    local branch="$1"
    local devstack_branch="$2"

    # If no branches specified, nothing to do
    if [[ -z "$branch" ]] && [[ -z "$devstack_branch" ]]; then
        return 0
    fi

    log_info "Checking out branches..."

    # Checkout DevStack branch (takes precedence over global branch)
    local ds_branch="${devstack_branch:-$branch}"
    if [[ -n "$ds_branch" ]]; then
        log_info "Checking out DevStack branch: $ds_branch"
        if ! container_exec /usr/local/bin/checkout-branch.sh /opt/stack/devstack "$ds_branch"; then
            log_error "Failed to checkout DevStack branch: $ds_branch"
            return 1
        fi
    fi

    # Checkout global branch for all other repos
    if [[ -n "$branch" ]]; then
        # List of repos to checkout (skip devstack if we already did it)
        local repos=(
            "ironic"
            "ironic-python-agent"
            "nova"
            "neutron"
            "glance"
            "keystone"
            "cinder"
            "tempest"
        )

        for repo in "${repos[@]}"; do
            local repo_path="/opt/stack/$repo"

            # Check if repo exists in container
            if container_exec test -d "$repo_path/.git" 2>/dev/null; then
                log_info "Checking out $repo branch: $branch"
                if ! container_exec /usr/local/bin/checkout-branch.sh "$repo_path" "$branch"; then
                    log_warn "Failed to checkout $repo branch (may not exist): $branch"
                    # Don't fail the whole job, just warn
                fi
            fi
        done
    fi

    log_success "Branch checkout complete"
    return 0
}

# Setup VirtualBMC
setup_vbmc() {
    log_info "Setting up VirtualBMC..."

    # Start vbmcd daemon (remove stale PID file if exists)
    container_exec bash -c 'rm -f /root/.vbmc/master.pid && vbmcd' || return 1
    sleep 2

    # Verify VirtualBMC nodes are configured
    log_info "Checking VirtualBMC nodes..."
    if ! container_exec vbmc list | grep -q "node-"; then
        log_error "VirtualBMC nodes not found"
        return 1
    fi

    log_success "VirtualBMC setup complete"
    return 0
}

# Run tempest test
run_tempest_test() {
    local job_name="$1"

    log_info "Running tempest tests (this may take 20-30 minutes)..."

    # Install ironic-tempest-plugin in the tempest tox environment
    log_info "Installing ironic-tempest-plugin..."
    if ! container_exec bash -c "cd /opt/stack/ironic-tempest-plugin && /opt/stack/tempest/.tox/tempest/bin/pip install -e ."; then
        log_error "Failed to install ironic-tempest-plugin"
        return 1
    fi

    # Set OS_CLOUD environment and run the specific Tempest test
    # For ironic-tempest-bios-ipmi-autodetect, the test is test_baremetal_server_ops_wholedisk_image
    local test_regex="test_baremetal_server_ops_wholedisk_image"

    log_info "Test regex: $test_regex"
    log_info "This will test deploying a baremetal instance with whole-disk image..."

    # Run tempest test
    if container_exec bash -c "cd /opt/stack/tempest && export OS_CLOUD=devstack-admin && .tox/tempest/bin/tempest run --regex ironic_tempest_plugin.tests.scenario.${test_regex}"; then
        log_success "Tempest test passed!"
        return 0
    else
        log_error "Tempest test failed!"
        return 1
    fi
}

# Show logs from last run
show_logs() {
    local service="$1"

    local log_dir
    log_dir=$(get_latest_log_dir)

    if [[ -z "$log_dir" ]]; then
        log_error "No logs found"
        return 1
    fi

    case "$service" in
        all|"")
            log_info "Summary:"
            cat "$log_dir/summary.txt" 2>/dev/null || echo "No summary available"
            ;;
        ironic-api|ironic-conductor|swift|tempest|container)
            if [[ -f "$log_dir/${service}.log" ]]; then
                less "$log_dir/${service}.log"
            else
                log_error "Log file not found: ${service}.log"
            fi
            ;;
        *)
            log_error "Unknown service: $service"
            log_info "Available services: ironic-api, ironic-conductor, swift, tempest, container"
            return 1
            ;;
    esac
}

# Open shell in container
open_shell() {
    if [[ -z "$CURRENT_CONTAINER" ]]; then
        # Try to find a running container
        local containers
        containers=$(find_running_containers)

        if [[ -z "$containers" ]]; then
            log_error "No running containers found"
            log_info "Start a job first: osforge run <job-name> --keep"
            return 1
        fi

        # Use the first container
        CURRENT_CONTAINER=$(echo "$containers" | head -1)
        log_info "Attaching to container: $CURRENT_CONTAINER"
    fi

    log_info "Opening shell in container..."
    log_info "You are now user 'stack' in /opt/stack"
    log_info "Type 'exit' to return"

    container_exec_interactive /bin/bash
}

# Show status
show_status() {
    local containers
    containers=$(find_running_containers)

    if [[ -z "$containers" ]]; then
        log_info "No jobs running"
        return 0
    fi

    log_info "Running containers:"
    echo "$containers" | while read -r container; do
        echo "  - $container"
    done
}

# Stop job
stop_job() {
    if [[ -z "$CURRENT_CONTAINER" ]]; then
        # Try to find and stop all
        kill_all_containers
    else
        container_stop
    fi
}

# Cleanup
cleanup() {
    local keep_logs="$1"

    log_step "Cleaning up OSForge..."

    # Stop all containers
    kill_all_containers

    # Cleanup container images/volumes
    cleanup_containers

    # Cleanup old logs
    if [[ -n "$keep_logs" ]] && [[ "$keep_logs" =~ ^[0-9]+$ ]]; then
        log_info "Removing old logs (keeping last $keep_logs)..."

        local logs_to_delete
        logs_to_delete=$(find "$OSFORGE_USER_DIR/logs" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r | tail -n +$((keep_logs + 1)))

        if [[ -n "$logs_to_delete" ]]; then
            echo "$logs_to_delete" | while read -r log_dir; do
                log_info "  Removing: $(basename "$log_dir")"
                rm -rf "$log_dir"
            done
        fi
    fi

    log_success "Cleanup complete"
}

# List available jobs
list_available_jobs() {
    log_info "Available jobs:"

    if [[ ! -d "$OSFORGE_CONFIG/jobs" ]]; then
        log_warn "No job definitions found"
        return 0
    fi

    find "$OSFORGE_CONFIG/jobs" -name "*.yaml" -type f | while read -r job_file; do
        local job_name
        job_name=$(basename "$job_file" .yaml)

        local description
        description=$(yaml_get "$job_file" "description")

        if [[ -n "$description" ]]; then
            echo "  - $job_name: $description"
        else
            echo "  - $job_name"
        fi
    done
}
