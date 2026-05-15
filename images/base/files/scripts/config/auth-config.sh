#!/bin/bash
# Authentication configuration for OpenStack Tempest tests
# Sets up credentials and generates Tempest auth/identity sections

set_auth_credentials() {
    export OS_AUTH_URL=http://${SERVICE_HOST:-127.0.0.1}/identity
    export OS_PROJECT_NAME=admin
    export OS_USERNAME=admin
    export OS_PASSWORD=secret
    export OS_REGION_NAME=RegionOne
    export OS_IDENTITY_API_VERSION=3
    export OS_USER_DOMAIN_NAME=Default
    export OS_PROJECT_DOMAIN_NAME=Default

    echo "[auth-config] OpenStack credentials configured"
}

# Generate [auth] and [identity] sections for tempest.conf
generate_auth_tempest_config() {
    cat <<EOF
[auth]
use_dynamic_credentials = true
admin_username = admin
admin_password = secret
admin_project_name = admin
admin_domain_name = Default

[identity]
uri = http://${SERVICE_HOST}/identity
uri_v3 = http://${SERVICE_HOST}/identity/v3
auth_version = v3
region = RegionOne
v3_endpoint_type = public

[identity-feature-enabled]
api_v2 = false
api_v3 = true
EOF
}
