#!/bin/bash
# Script Hash: ${script_hash}
# Common Hash: ${common_hash}

set -euxo pipefail

exec > >(tee /var/log/wazuh_bootstrap.log | logger -t wazuh_bootstrap -s 2>/dev/console) 2>&1

BUCKET="shaurya-terraform-userdata-2026"

# --------------------------------------------------
# AWS CLI Installation
# --------------------------------------------------

if ! command -v aws &> /dev/null; then
    echo "📦 Installing AWS CLI..."
    dnf install -y awscli2 || dnf install -y aws-cli
fi

# --------------------------------------------------
# Step 1: Download and run common.sh from S3
# --------------------------------------------------

echo "📦 Running common bootstrap..."

for i in {1..5}; do
    aws s3 cp s3://"$BUCKET"/common.sh /tmp/common.sh && break
    echo "S3 copy failed, retrying in 5 seconds... ($i/5)"
    sleep 5
done

chmod +x /tmp/common.sh
/tmp/common.sh

# --------------------------------------------------
# Step 2: Download and run wazuh.sh from S3
# --------------------------------------------------

echo "🔐 Running Wazuh installation..."

for i in {1..5}; do
    aws s3 cp s3://"$BUCKET"/wazuh.sh /tmp/wazuh.sh && break
    echo "S3 copy failed, retrying in 5 seconds... ($i/5)"
    sleep 5
done

chmod +x /tmp/wazuh.sh
/tmp/wazuh.sh

# --------------------------------------------------
# Step 3: Cleanup
# --------------------------------------------------

rm -f /tmp/common.sh /tmp/wazuh.sh

echo "===== Bootstrap Complete ====="
date
