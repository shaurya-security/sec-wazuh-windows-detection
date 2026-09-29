#!/bin/bash
#
# Terraform-rendered bootstrap shim. Keep this file thin: its only jobs are to
# fetch payloads from S3 and hand configuration to them via the environment.
# All real logic belongs in the fetched scripts so they stay plain S3 files.
#
# Payload fingerprints (changing any of these re-renders user_data and, with
# user_data_replace_on_change, rebuilds this instance):
%{ for key, hash in payloads ~}
#   ${key} = ${hash}
%{ endfor ~}

set -euxo pipefail

exec > >(tee /var/log/wazuh_bootstrap.log | logger -t wazuh_bootstrap -s 2>/dev/console) 2>&1

# --------------------------------------------------
# Configuration injected by Terraform
# --------------------------------------------------
export BUCKET="${s3_bucket}"
export TIMEZONE="${timezone}"
export WAZUH_VERSION="${wazuh_version}"   # e.g. 4.14.0  -> agent MSI + version checks
export WAZUH_BRANCH="${wazuh_branch}"     # e.g. 4.14    -> installer URL path
export BOOTSTRAP_DIR="/opt/bootstrap"

mkdir -p "$BOOTSTRAP_DIR"

# --------------------------------------------------
# AWS CLI
# --------------------------------------------------
if ! command -v aws &>/dev/null; then
    echo "Installing AWS CLI..."
    dnf install -y awscli2 || dnf install -y aws-cli
fi

# --------------------------------------------------
# Fetch payloads
# --------------------------------------------------
fetch() {
    local key="$1"
    local dest="$BOOTSTRAP_DIR/$key"
    mkdir -p "$(dirname "$dest")"

    for i in {1..5}; do
        if aws s3 cp "s3://$BUCKET/$key" "$dest"; then
            echo "Fetched $key"
            return 0
        fi
        echo "Fetch of $key failed, retry $i/5 in 5s..."
        sleep 5
    done

    echo "FATAL: could not fetch $key from s3://$BUCKET" >&2
    return 1
}

%{ for key, hash in payloads ~}
fetch "${key}"
%{ endfor ~}

# --------------------------------------------------
# Execute (order matters: linux-setup.sh sets up the user/env wazuh-setup.sh relies on)
# --------------------------------------------------
chmod +x "$BOOTSTRAP_DIR"/*.sh

echo "Running common bootstrap..."
"$BOOTSTRAP_DIR/linux-setup.sh"

echo "Running Wazuh installation (version $WAZUH_VERSION)..."
"$BOOTSTRAP_DIR/wazuh-setup.sh"

# Bootstrap payloads are left in $BOOTSTRAP_DIR deliberately: on a disposable
# lab box they are useful for debugging a failed run.

echo "===== Bootstrap Complete ====="
date
