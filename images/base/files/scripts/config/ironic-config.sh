#!/bin/bash
# Ironic (baremetal service) configuration for Tempest tests

get_ironic_config() {
    # Ironic-specific settings
    # Future: Could query node information, driver details, etc.
    echo "[ironic-config] Baremetal configuration loaded"
}

generate_ironic_tempest_config() {
    cat <<EOF
[baremetal]
driver = ipmi
enabled_drivers = ipmi
min_microversion = 1.1
max_microversion = latest
deployment_timeout = 900

[baremetal-feature-enabled]
adoption = false
EOF
}
