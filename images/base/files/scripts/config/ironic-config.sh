#!/bin/bash
# Ironic (baremetal service) configuration for Tempest tests

get_ironic_config() {
    # Ironic-specific settings
    # Future: Could query node information, driver details, etc.
    echo "[ironic-config] Baremetal configuration loaded"
}

generate_ironic_tempest_config() {
    # Support both IPMI and Redfish drivers via environment variables
    # Default to IPMI for backwards compatibility
    local driver="${IRONIC_TEMPEST_DRIVER:-ipmi}"
    local enabled_drivers="${IRONIC_TEMPEST_ENABLED_DRIVERS:-ipmi,redfish}"

    cat <<EOF
[baremetal]
driver = ${driver}
enabled_drivers = ${enabled_drivers}
min_microversion = 1.1
max_microversion = latest
deployment_timeout = 900

[baremetal-feature-enabled]
adoption = false
EOF
}
