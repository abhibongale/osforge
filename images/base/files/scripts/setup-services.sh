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

# Start Apache (HTTP proxy for Keystone and other services)
systemctl start apache2
sleep 2

# Start networking
systemctl start openvswitch-switch
sleep 2

# Start all DevStack services (Keystone, Nova, Neutron, Glance, Placement, Ironic, Swift, etc.)
# This starts all devstack@* services which are the main OpenStack components
systemctl start 'devstack@*'
sleep 10

echo "[setup-services] All services started successfully"
