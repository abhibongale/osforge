#!/bin/bash
# Swift (object storage service) configuration for Tempest tests

generate_swift_tempest_config() {
    cat <<EOF
[object-storage]
operator_role = Member
reseller_admin_role = ResellerAdmin

[object-storage-feature-enabled]
discoverability = true
container_sync = false
object_versioning = true
bulk_upload = true
EOF
}
