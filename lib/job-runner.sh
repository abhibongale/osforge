#!/bin/bash
# Job execution logic for OSForge

# Run a Zuul job
run_job() {
    local job_name="$1"
    local ironic_repo="$2"
    local ipa_repo="$3"
    local itp_repo="$4"
    local tempest_repo="$5"
    local devstack_repo="$6"
    local nova_repo="$7"
    local neutron_repo="$8"
    local branch="$9"
    local devstack_branch="${10}"
    local tag="${11}"
    local verbose="${12}"
    local keep="${13}"
    local no_pull="${14}"

    # Set BASE_IMAGE if custom tag specified
    if [[ -n "$tag" ]]; then
        BASE_IMAGE="quay.io/osforge/base:$tag"
        log_info "Using custom image tag: $tag"
    fi

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
    if ! container_start "$job_name" "$ironic_repo" "$ipa_repo" "$itp_repo" "$tempest_repo" "$devstack_repo" "$nova_repo" "$neutron_repo" "$CURRENT_LOG_DIR" "$no_pull"; then
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

    # Reinstall mounted repos if provided
    if ! reinstall_mounted_repos "$itp_repo" "$tempest_repo"; then
        log_error "Failed to reinstall mounted repositories"
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
    # Start database and message queue first
    log_info "Starting MySQL..."
    if ! container_exec bash -c "systemctl start mysql && sleep 3 && systemctl is-active --quiet mysql"; then
        log_error "MySQL failed to start"
        container_exec systemctl status mysql --no-pager || true
        return 1
    fi
    log_success "MySQL started"

    log_info "Starting RabbitMQ..."
    if ! container_exec bash -c "systemctl start rabbitmq-server && sleep 5 && systemctl is-active --quiet rabbitmq-server"; then
        log_error "RabbitMQ failed to start"
        container_exec systemctl status rabbitmq-server --no-pager || true
        return 1
    fi

    # Create stackrabbit user for OpenStack services
    log_info "Configuring RabbitMQ users..."
    container_exec bash -c "rabbitmqctl add_user stackrabbit secret 2>/dev/null || rabbitmqctl change_password stackrabbit secret"
    container_exec bash -c "rabbitmqctl set_permissions -p / stackrabbit '.*' '.*' '.*'"
    log_success "RabbitMQ started"

    # Start Apache (HTTP proxy for Keystone and other OpenStack APIs)
    log_info "Starting Apache..."
    if ! container_exec bash -c "systemctl start apache2 && sleep 3 && systemctl is-active --quiet apache2"; then
        log_error "Apache failed to start"
        container_exec systemctl status apache2 --no-pager || true
        return 1
    fi
    log_success "Apache started"

    # Start OVN (Open Virtual Network) services
    log_info "Starting OVN services..."
    if ! container_exec bash -c "systemctl start ovn-ovsdb-server-nb.service ovn-ovsdb-server-sb.service ovn-northd.service && sleep 3"; then
        log_warn "Some OVN services may not have started"
    else
        log_success "OVN services started"
    fi

    # Start all DevStack services
    log_info "Starting DevStack services (this may take 30-60 seconds)..."
    if ! container_exec systemctl start --all 'devstack@*'; then
        log_warn "Some DevStack services may not have started"
    fi
    sleep 15

    # Verify key services are running
    log_info "Verifying key services..."
    local services_ok=true

    if ! container_exec systemctl is-active --quiet devstack@ir-api.service; then
        log_error "Ironic API not running"
        services_ok=false
    fi

    if ! container_exec systemctl is-active --quiet devstack@ir-cond.service; then
        log_error "Ironic Conductor not running"
        services_ok=false
    fi

    if ! container_exec systemctl is-active --quiet devstack@keystone.service; then
        log_error "Keystone not running"
        services_ok=false
    fi

    if ! container_exec systemctl is-active --quiet apache2; then
        log_error "Apache not running"
        services_ok=false
    fi

    if [[ "$services_ok" != "true" ]]; then
        log_error "Some services failed to start"
        return 1
    fi

    log_success "All services started successfully"
    return 0
}

# Reinstall mounted repositories in the virtualenv
reinstall_mounted_repos() {
    local itp_repo="$1"
    local tempest_repo="$2"

    # If no repos to reinstall, return early
    if [[ -z "$itp_repo" ]] && [[ -z "$tempest_repo" ]]; then
        return 0
    fi

    log_info "Reinstalling mounted repositories in virtualenv..."

    # Fix git safe.directory for mounted repos
    if [[ -n "$itp_repo" ]]; then
        log_info "  Reinstalling ironic-tempest-plugin from local mount..."
        container_exec bash -c "git config --global --add safe.directory /opt/stack/ironic-tempest-plugin"
        if ! container_exec bash -c "source /opt/stack/data/venv/bin/activate && cd /opt/stack/ironic-tempest-plugin && pip install -e . -q"; then
            log_error "Failed to reinstall ironic-tempest-plugin"
            return 1
        fi
        log_success "  ironic-tempest-plugin reinstalled"
    fi

    if [[ -n "$tempest_repo" ]]; then
        log_info "  Reinstalling tempest from local mount..."
        container_exec bash -c "git config --global --add safe.directory /opt/stack/tempest"
        if ! container_exec bash -c "source /opt/stack/data/venv/bin/activate && cd /opt/stack/tempest && pip install -e . -q"; then
            log_error "Failed to reinstall tempest"
            return 1
        fi
        log_success "  tempest reinstalled"
    fi

    log_success "Mounted repositories reinstalled"
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
    log_info "Setting up virtual baremetal node..."

    # Load job configuration and set environment variables
    local job_file="$OSFORGE_CONFIG/jobs/${job_name}.yaml"

    # Extract environment variables from job config
    local env_vars=""
    if grep -q "^env:" "$job_file"; then
        # Read env section from YAML and convert to bash exports
        while IFS=: read -r key value; do
            # Skip the 'env:' line and empty lines
            if [[ "$key" == "env" ]] || [[ -z "$key" ]]; then
                continue
            fi
            # Trim whitespace and quotes
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs | sed 's/"//g' | sed "s/'//g")
            if [[ -n "$key" ]] && [[ -n "$value" ]]; then
                env_vars="$env_vars -e ${key}=${value}"
            fi
        done < <(sed -n '/^env:/,/^[a-z]/p' "$job_file" | grep -v "^#" | head -n -1)
    fi

    # Call setup-vbmc.sh script in container with environment variables
    container_exec bash -c "export IRONIC_VM_COUNT=${IRONIC_VM_COUNT:-1} && /usr/local/bin/setup-vbmc.sh" || return 1

    log_success "VirtualBMC setup complete"
    return 0
}

# Run tempest test
run_tempest_test() {
    local job_name="$1"

    log_info "Running tempest tests (this may take 20-30 minutes)..."

    # Load job configuration
    local job_file="$OSFORGE_CONFIG/jobs/${job_name}.yaml"

    # Extract test configuration from job config
    local test_regex=$(yaml_get "$job_file" "test.regex")
    local test_concurrency=$(yaml_get "$job_file" "test.concurrency")
    local test_timeout=$(yaml_get "$job_file" "test.timeout")

    # Set defaults if not found
    test_regex=${test_regex:-"ironic_tempest_plugin.tests.scenario"}
    test_concurrency=${test_concurrency:-1}
    test_timeout=${test_timeout:-2600}

    log_debug "Test regex: $test_regex"
    log_debug "Test concurrency: $test_concurrency"
    log_debug "Test timeout: $test_timeout"

    # TEMPORARY FIX: Patch run-tempest.sh to activate virtualenv and fix stestr (for testing only)
    container_exec bash -c "sed -i '/echo \"\[run-tempest\] Using SERVICE_HOST:/a source /opt/stack/data/venv/bin/activate' /usr/local/bin/run-tempest.sh"
    container_exec bash -c "sed -i 's/if stestr last --exists; then/if stestr last \&>\\/dev\\/null; then/' /usr/local/bin/run-tempest.sh"

    # Call run-tempest.sh script in container with configuration
    if container_exec bash -c "export TEST_REGEX='${test_regex}' TEST_CONCURRENCY='${test_concurrency}' TEST_TIMEOUT='${test_timeout}' && /usr/local/bin/run-tempest.sh '$job_name' /opt/stack/logs"; then
        return 0
    else
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
