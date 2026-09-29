#!/bin/bash
#
# Wazuh manager installation.
#
# Plain S3 payload - NO Terraform interpolation. All configuration arrives via
# environment variables exported by bootstrap.sh.tpl:
#   BUCKET, TIMEZONE, WAZUH_VERSION, WAZUH_BRANCH, BOOTSTRAP_DIR

set -euxo pipefail

exec > >(tee /var/log/wazuh-install.log | logger -t wazuh-userdata -s 2>/dev/console) 2>&1

echo "===== Wazuh manager installation started ====="
date

# --------------------------------------------------
# Validate injected configuration
# --------------------------------------------------
: "${WAZUH_VERSION:?WAZUH_VERSION not set by bootstrap}"
: "${WAZUH_BRANCH:?WAZUH_BRANCH not set by bootstrap}"
: "${BOOTSTRAP_DIR:?BOOTSTRAP_DIR not set by bootstrap}"
TIMEZONE="${TIMEZONE:-Asia/Kolkata}"

WORK_USER="ssm-user"
WORK_HOME="/home/${WORK_USER}"

if ! id "${WORK_USER}" &>/dev/null; then
    useradd -m -s /bin/bash "${WORK_USER}"
fi

# --------------------------------------------------
# System preparation
# --------------------------------------------------
dnf update -y
dnf install -y tar gzip unzip net-tools

hostnamectl set-hostname wazuh-server

# --------------------------------------------------
# Wazuh all-in-one installation (version pinned)
# --------------------------------------------------
cd /tmp

echo "Installing Wazuh ${WAZUH_VERSION} (branch ${WAZUH_BRANCH})..."
curl -sO "https://packages.wazuh.com/${WAZUH_BRANCH}/wazuh-install.sh"
chmod +x wazuh-install.sh

bash ./wazuh-install.sh -a -i

# Fail loudly if the installed manager is not the version we asked for.
INSTALLED_VERSION="$(/var/ossec/bin/wazuh-control info 2>/dev/null \
    | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"

if [ "$INSTALLED_VERSION" != "$WAZUH_VERSION" ]; then
    echo "WARNING: requested ${WAZUH_VERSION} but manager reports ${INSTALLED_VERSION}."
    echo "The Windows agent is pinned to ${WAZUH_VERSION} - verify compatibility."
fi

# --------------------------------------------------
# Custom ruleset (fetched from S3, not embedded)
# --------------------------------------------------
echo "Installing custom SOC simulation rules..."

install -o wazuh -g wazuh -m 0640 \
    "${BOOTSTRAP_DIR}/wazuh-local-rules.xml" \
    /var/ossec/etc/rules/wazuh-local-rules.xml

# Validate ruleset before restarting the manager.
if ! /var/ossec/bin/wazuh-logtest -t >/dev/null 2>&1; then
    echo "ERROR: ossec.conf or ruleset failed validation. Review with:"
    echo "  /var/ossec/bin/wazuh-logtest -t"
fi

# --------------------------------------------------
# Credentials
# --------------------------------------------------
if [ -f /root/wazuh-install-files.tar ]; then
    mkdir -p "${WORK_HOME}/wazuh-install-files"
    tar -xvf /root/wazuh-install-files.tar -C "${WORK_HOME}/wazuh-install-files" || true
    chown -R "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/wazuh-install-files"
fi

TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)

PUBLIC_IP=$(curl -s -S \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/public-ipv4" || true)

DASHBOARD_HOST="${PUBLIC_IP:-$(hostname)}"

PASS_VAL=$(grep -a "Password:" /var/log/wazuh-install.log \
    | grep -v '^+ ' \
    | head -n 1 \
    | sed 's/.*Password: //' \
    | xargs || true)

if [ -z "$PASS_VAL" ]; then
    echo "WARNING: admin password could not be parsed from the install log."
    echo "Format may have changed in ${WAZUH_VERSION}; check the log manually."
fi

cat > "${WORK_HOME}/wazuh-passwords.txt" <<EOF
=================================================================
                  WAZUH ADMIN CREDENTIALS
=================================================================

  Version        : ${WAZUH_VERSION}
  Web Dashboard  : https://${DASHBOARD_HOST}:443
  Username       : admin
  Password       : ${PASS_VAL:-"PARSE FAILED - see /var/log/wazuh-install.log"}

=================================================================
EOF

chmod 600 "${WORK_HOME}/wazuh-passwords.txt"
chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/wazuh-passwords.txt"

# --------------------------------------------------
# Dashboard timezone
# --------------------------------------------------
if [ -n "$PASS_VAL" ]; then
(
    for _ in {1..60}; do
        if curl -s -k -u "admin:${PASS_VAL}" https://localhost:443/api/status \
            | grep -q '"state":"green"\|"state":"yellow"'; then
            break
        fi
        sleep 5
    done

    curl -s -k -X POST \
        "https://localhost:443/api/opensearch-dashboards/settings" \
        -H "osd-xsrf: true" \
        -H "Content-Type: application/json" \
        -u "admin:${PASS_VAL}" \
        -d "{\"changes\":{\"dateFormat:tz\":\"${TIMEZONE}\"}}" \
        > /dev/null \
        && echo "Dashboard timezone set to ${TIMEZONE}"
) &
fi

# --------------------------------------------------
# Services
# --------------------------------------------------
systemctl daemon-reload

systemctl enable \
    wazuh-indexer \
    wazuh-manager \
    wazuh-dashboard

for svc in wazuh-indexer wazuh-manager wazuh-dashboard; do
    systemctl start "$svc" 2>/dev/null || true
done

# Restart manager so the custom ruleset takes effect.
echo "Restarting wazuh-manager to load custom rules..."
systemctl restart wazuh-manager

for i in {1..24}; do
    systemctl is-active --quiet wazuh-dashboard && break
    sleep 5
done

systemctl restart wazuh-dashboard
sleep 10

ALL_OK=true

for svc in wazuh-indexer wazuh-manager wazuh-dashboard; do
    if systemctl is-active --quiet "$svc"; then
        echo "OK      : $svc"
    else
        echo "FAILED  : $svc"
        ALL_OK=false
    fi
done

# --------------------------------------------------
# Summary
# --------------------------------------------------
cat > "${WORK_HOME}/.wazuh-provisioned" <<EOF
Wazuh provisioned on : $(date)
Requested version     : ${WAZUH_VERSION}
Installed version     : ${INSTALLED_VERSION}
Log format contract   : eventchannel / Security channel
Timezone              : ${TIMEZONE}
Custom rules          : /var/ossec/etc/rules/wazuh-local-rules.xml
Detection focus       : Windows RDP brute force
EOF

chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/.wazuh-provisioned"
cp "${WORK_HOME}/.wazuh-provisioned" /root/.wazuh-provisioned

INFO_FILE="${WORK_HOME}/wazuh-info.txt"

{
    echo "================================================================="
    echo "                 Wazuh Installation Information"
    echo "================================================================="
    echo
    echo "Install date : $(date)"
    echo "Hostname     : $(hostname)"
    echo "Version      : ${INSTALLED_VERSION} (requested ${WAZUH_VERSION})"
    echo
    echo "Credentials  : ${WORK_HOME}/wazuh-passwords.txt"
    echo "Install files: ${WORK_HOME}/wazuh-install-files/"
    echo
    echo "Detection scenario:"
    echo "  115200  Failed RDP authentication       4625"
    echo "  115210  RDP brute-force correlation      4625 x4/60s"
    echo "  115220  Successful login after failures  4624"
    echo
    echo "Simulation script: simulation/soc-sim-brute-force.sh (run from the operator workstation)."
    echo
    if [ "$ALL_OK" = true ]; then
        echo "Services     : all running"
    else
        echo "Services     : degraded - journalctl -u wazuh-manager -f"
    fi
    echo "================================================================="
} | tee "$INFO_FILE"

chmod 644 "$INFO_FILE"
chown "${WORK_USER}:${WORK_USER}" "$INFO_FILE"
