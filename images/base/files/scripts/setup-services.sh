#!/bin/bash
# Setup and start services for Ironic testing
# This script runs inside the container

set -euo pipefail

echo "[setup-services] Starting OpenStack services..."

# TODO: Implement service startup logic
# This will be called by the job-runner

# Start database
systemctl start mysql
sleep 2

# Start message queue
systemctl start rabbitmq-server
sleep 2

# Start networking
systemctl start openvswitch-switch
sleep 2

# Start Ironic
systemctl start ironic-api
systemctl start ironic-conductor
sleep 5

# Start Swift
systemctl start swift-proxy
systemctl start swift-account
systemctl start swift-container
systemctl start swift-object
sleep 3

echo "[setup-services] All services started successfully"
