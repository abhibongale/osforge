#!/bin/bash
# Setup and start services for Ironic testing
# This script runs inside the container

set -euo pipefail

echo "[setup-services] Starting OpenStack services..."

# Start database
systemctl start mysql
sleep 2

# Start message queue
systemctl start rabbitmq-server
sleep 2

# Create stackrabbit user for OpenStack services
# DevStack expects this user to exist for AMQP messaging
rabbitmqctl add_user stackrabbit secret 2>/dev/null || rabbitmqctl change_password stackrabbit secret
rabbitmqctl set_permissions -p / stackrabbit '.*' '.*' '.*'
echo "[setup-services] RabbitMQ stackrabbit user configured"

# Create Nova cells vhost (required for Nova compute service)
# Nova cells use a separate RabbitMQ vhost for message isolation
rabbitmqctl add_vhost nova_cell1 2>/dev/null || true
rabbitmqctl set_permissions -p nova_cell1 stackrabbit '.*' '.*' '.*'
echo "[setup-services] RabbitMQ nova_cell1 vhost configured"

# Start Apache (HTTP proxy for Keystone and other services)
systemctl start apache2
sleep 2

# Start networking
systemctl start openvswitch-switch
sleep 2

# Start OVN (Open Virtual Network) databases and northd daemon
# Required for Neutron ML2/OVN networking
systemctl start ovn-ovsdb-server-nb.service
systemctl start ovn-ovsdb-server-sb.service
systemctl start ovn-northd.service
sleep 3
echo "[setup-services] OVN services started"

# Start all DevStack services (Keystone, Nova, Neutron, Glance, Placement, Ironic, Swift, etc.)
# This starts all devstack@* services which are the main OpenStack components
systemctl start 'devstack@*'
sleep 10

# Explicitly check and start Nova compute service (critical for Ironic + Placement)
# Without Nova compute running, baremetal nodes won't be registered in Placement
echo "[setup-services] Checking Nova compute service..."
if systemctl list-unit-files | grep -q "devstack@n-cpu.service"; then
    echo "[setup-services]   Nova compute service file found"

    # Enable if not enabled
    if ! systemctl is-enabled devstack@n-cpu.service >/dev/null 2>&1; then
        echo "[setup-services]   Enabling Nova compute service..."
        systemctl enable devstack@n-cpu.service
    fi

    # Start if not active
    if ! systemctl is-active devstack@n-cpu.service >/dev/null 2>&1; then
        echo "[setup-services]   Nova compute not running, starting it..."
        systemctl start devstack@n-cpu.service || {
            echo "[setup-services]   ERROR: Nova compute failed to start!"
            echo "[setup-services]   Checking logs:"
            journalctl -u devstack@n-cpu.service -n 50 --no-pager
            exit 1
        }
        sleep 5
    fi

    if systemctl is-active devstack@n-cpu.service >/dev/null 2>&1; then
        echo "[setup-services]   ✓ Nova compute is running"
    else
        echo "[setup-services]   ERROR: Nova compute failed to start!"
        exit 1
    fi
else
    echo "[setup-services]   ERROR: Nova compute service file not found!"
    echo "[setup-services]   DevStack may not have been installed with VIRT_DRIVER=ironic"
    exit 1
fi

echo "[setup-services] All services started successfully"
