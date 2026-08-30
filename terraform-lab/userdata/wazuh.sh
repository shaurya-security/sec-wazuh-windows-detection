#!/bin/bash

set -euxo pipefail

exec > >(tee /var/log/wazuh-install.log | logger -t wazuh-userdata -s 2>/dev/console) 2>&1

echo "===== Wazuh installation started ====="
date

# --------------------------------------------------
# Set working user and home directory
# --------------------------------------------------
WORK_USER="ssm-user"
WORK_HOME="/home/${WORK_USER}"

# Ensure ssm-user exists
if ! id "${WORK_USER}" &>/dev/null; then
    echo "Creating ${WORK_USER} user..."
    useradd -m -s /bin/bash "${WORK_USER}"
fi

# --------------------------------------------------
# System preparation
# --------------------------------------------------

dnf update -y
dnf install -y tar gzip unzip net-tools

# Make sure hostname is sensible
hostnamectl set-hostname wazuh-server


# --------------------------------------------------
# Wazuh all-in-one installation
# --------------------------------------------------

cd /tmp

curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh
chmod +x wazuh-install.sh

# Run Wazuh installer (this takes time - be patient)
echo "Running Wazuh installer (this may take 5-10 minutes)..."
bash ./wazuh-install.sh -a

# --------------------------------------------------
# Save generated credentials to ssm-user's home
# --------------------------------------------------
echo "Processing Wazuh credentials and installation files..."

# Extract full archive for reference if available
if [ -f /root/wazuh-install-files.tar ]; then
    echo "✅ Found /root/wazuh-install-files.tar. Extracting archive..."
    mkdir -p "${WORK_HOME}/wazuh-install-files"
    tar -xvf /root/wazuh-install-files.tar \
        -C "${WORK_HOME}/wazuh-install-files" || true
    chown -R "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/wazuh-install-files"
fi


# Fetch IMDSv2 token and retrieve public IP (falls back to hostname if no public IP)
TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
PUBLIC_IP=$(curl -s -S -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/public-ipv4" || true)
DASHBOARD_HOST="${PUBLIC_IP:-$(hostname)}"


# Fetch ONLY the password string (ignoring shell debug traces starting with '+')
PASS_VAL=$(grep -a "Password:" /var/log/wazuh-install.log | grep -v '^+ ' | head -n 1 | sed 's/.*Password: //' | xargs)

# Write formatted credential card
cat > "${WORK_HOME}/wazuh-passwords.txt" <<EOF
=================================================================
                  WAZUH ADMIN CREDENTIALS
=================================================================

  🌐 Web Dashboard : https://${DASHBOARD_HOST}:443
  👤 Username      : admin
  🔑 Password      : ${PASS_VAL:-"Check /var/log/wazuh-install.log"}

=================================================================
EOF


# Set proper permissions on the final passwords file
if [ -f "${WORK_HOME}/wazuh-passwords.txt" ]; then
    chmod 600 "${WORK_HOME}/wazuh-passwords.txt"
    chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/wazuh-passwords.txt"
    echo "✅ Credentials saved to ${WORK_HOME}/wazuh-passwords.txt"
else
    echo "❌ Failed to retrieve credentials."
fi


# --------------------------------------------------
# Configure Wazuh Dashboard Timezone (Asia/Kolkata)
# --------------------------------------------------
echo "Setting Wazuh Dashboard timezone to Asia/Kolkata..."

# Extract admin password for API authentication
PASS_VAL=$(grep -a "Password:" /var/log/wazuh-install.log | grep -v '^+ ' | head -n 1 | sed 's/.*Password: //' | xargs)

# Execute API call in background loop once Dashboard API is up
(
    until curl -s -k -u "admin:${PASS_VAL}" https://localhost:443/api/status | grep -q '"state":"green"\|"state":"yellow"'; do
        sleep 5
    done

    # Update global timezone setting in OpenSearch Dashboards
    curl -s -k -X POST "https://localhost:443/api/opensearch-dashboards/settings" \
      -H "osd-xsrf: true" \
      -H "Content-Type: application/json" \
      -u "admin:${PASS_VAL}" \
      -d '{"changes":{"dateFormat:tz":"Asia/Kolkata"}}' > /dev/null && \
    echo "✅ Successfully updated Wazuh Dashboard timezone to Asia/Kolkata (IST)"
) &

# --------------------------------------------------
# Service Enablement and Health Wait Loop
# --------------------------------------------------
echo "Enabling and verifying Wazuh services..."

# Reload systemd to pick up new service files
systemctl daemon-reload

# Enable services to start on boot
systemctl enable wazuh-indexer wazuh-manager wazuh-dashboard

# Wait for wazuh-dashboard service unit to exist
echo "Waiting for wazuh-dashboard service to be registered..."
for i in {1..30}; do
    if systemctl list-unit-files | grep -q wazuh-dashboard.service; then
        echo "✅ wazuh-dashboard service registered after $((i * 2)) seconds"
        break
    fi
    echo "Waiting for wazuh-dashboard.service... ($((i * 2))s)"
    sleep 2
done

# Start services if not already running
systemctl start wazuh-indexer 2>/dev/null || true
systemctl start wazuh-manager 2>/dev/null || true
systemctl start wazuh-dashboard 2>/dev/null || true

# Wait for wazuh-dashboard to become active (up to 120 seconds)
echo "Waiting for Wazuh Dashboard to be healthy..."
for i in {1..24}; do
    if systemctl is-active --quiet wazuh-dashboard; then
        echo "✅ wazuh-dashboard is active!"
        break
    fi
    echo "Waiting for wazuh-dashboard... ($((i * 5))s)"
    sleep 5
done

# Additional health check - check if port 443 is listening
echo "Checking if Wazuh Dashboard is listening on port 443..."
for i in {1..12}; do
    if ss -tlnp | grep -q ":443"; then
        echo "✅ wazuh-dashboard is listening on port 443"
        break
    fi
    echo "Waiting for port 443... ($((i * 10))s)"
    sleep 10
done

# Restart dashboard once to ensure the timezone setting takes effect cleanly
echo "Restarting wazuh-dashboard to apply timezone changes..."
systemctl restart wazuh-dashboard

# Wait for restart to complete
sleep 10

# Verify all services are running
echo "===== Verifying Wazuh services ====="

# Check services with proper output
SERVICES=("wazuh-indexer" "wazuh-manager" "wazuh-dashboard")
SERVICE_NAMES=("Indexer" "Manager" "Dashboard")
ALL_OK=true

for i in "${!SERVICES[@]}"; do
    if systemctl is-active --quiet "${SERVICES[$i]}"; then
        echo "✅ Wazuh ${SERVICE_NAMES[$i]}: OK"
    else
        echo "❌ Wazuh ${SERVICE_NAMES[$i]}: FAILED"
        ALL_OK=false
    fi
done

# --------------------------------------------------
# Create marker file for successful installation
# --------------------------------------------------
cat > "${WORK_HOME}/.wazuh-provisioned" <<EOF
Wazuh provisioned on: $(date)
Version: 4.14
Timezone: ${timezone:-Asia/Kolkata}
Dashboard configured: $( [ -f "$DASHBOARD_CONF" ] && echo "Yes" || echo "No" )
EOF

chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/.wazuh-provisioned"

# Also create a marker file for root
cat > /root/.wazuh-provisioned <<EOF
Wazuh provisioned on: $(date)
Version: 4.14
Timezone: ${timezone:-Asia/Kolkata}
EOF


# --------------------------------------------------
# Create summary file and display final status
# --------------------------------------------------
INFO_FILE="${WORK_HOME}/wazuh-info.txt"

{
echo "================================================================="
echo "                 Wazuh Installation Information"
echo "================================================================="
echo ""
echo "📅 Install Date: $(date)"
echo "🌐 Hostname: $(hostname)"
echo "👤 User: ${WORK_USER}"
echo ""
echo "📋 Important files for ${WORK_USER}:"
echo "   📁 Credentials: ${WORK_HOME}/wazuh-passwords.txt"
echo "   📁 Summary File: ${INFO_FILE}"
echo "   📁 Full Install Files: ${WORK_HOME}/wazuh-install-files/"
echo ""
echo "🔐 To view passwords:"
echo "   cat ${WORK_HOME}/wazuh-passwords.txt"
echo "   sudo grep 'admin' ${WORK_HOME}/wazuh-passwords.txt"
echo ""
echo "📊 Service Status:"
if [ "$ALL_OK" = true ]; then
    echo "   ✅ All services are running"
else
    echo "   ⚠️  Some services may not be ready yet"
    echo "   Check logs: journalctl -u wazuh-dashboard -f"
fi
echo ""
echo "📝 Logs:"
echo "   /var/log/wazuh-install.log"
echo "   journalctl -u wazuh-dashboard"
echo ""
echo "================================================================="
} | tee "$INFO_FILE"

# Set proper ownership for the summary file
chmod 644 "$INFO_FILE"
chown "${WORK_USER}:${WORK_USER}" "$INFO_FILE"
