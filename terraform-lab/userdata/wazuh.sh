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
# Local Rules - Wazuh Manager
# --------------------------------------------------

sudo tee /var/ossec/etc/rules/local_rules.xml << 'EOF'
<group name="windows,soc_simulation,">

  <!-- ============================================================
       SCENARIO 1: SUSPICIOUS POWERSHELL EXECUTION (T1059.001)
       ============================================================ -->
  <rule id="115100" level="8">
    <if_sid>67027</if_sid>
    <field name="win.eventdata.newProcessName" type="pcre2">(?i)\\powershell\.exe$</field>
    <field name="win.eventdata.commandLine" type="pcre2">(?i)(-enc|-encodedcommand|-nop|-noprofile|-w[[:space:]]+hidden|-windowstyle[[:space:]]+hidden)</field>
    <description>SOC-SIM [Scenario 1]: Suspicious PowerShell execution detected</description>
    <mitre><id>T1059.001</id></mitre>
    <group>powershell,execution</group>
  </rule>


  <!-- ============================================================
       SCENARIO 2: FAILED LOGON BRUTE FORCE (T1110)
       Base Rule: Windows Logon Failure (Event ID 4625)
       ============================================================ -->
  <rule id="115200" level="5">
    <if_sid>60110</if_sid>
    <field name="win.system.eventID">^4625$</field>
    <description>SOC-SIM [Scenario 2]: Single failed logon attempt (Event 4625)</description>
    <mitre><id>T1110</id></mitre>
    <group>authentication_failed</group>
  </rule>

  <!-- Correlation: 5+ failed logons within 60 seconds -->
  <rule id="115210" level="12" frequency="5" timeframe="60">
    <if_matched_sid>115200</if_matched_sid>
    <same_source_ip />
    <description>SOC-SIM [Scenario 2]: Multiple failed logon attempts detected (Potential Brute-Force)</description>
    <mitre><id>T1110</id></mitre>
    <group>high_confidence,correlation,brute_force</group>
  </rule>


  <!-- ============================================================
       SCENARIO 3: SCHEDULED TASK PERSISTENCE (T1053.005)
       ============================================================ -->

  <!-- Base Event A: schtasks.exe process execution (Event 4688) -->
  <rule id="115300" level="8">
    <if_sid>67027</if_sid>
    <field name="win.eventdata.newProcessName" type="pcre2">(?i)\\schtasks\.exe$</field>
    <field name="win.eventdata.commandLine" type="pcre2">(?i)/create</field>
    <description>SOC-SIM [Scenario 3]: schtasks.exe used to create a scheduled task</description>
    <mitre><id>T1053.005</id></mitre>
    <group>persistence,scheduled_task</group>
  </rule>

  <!-- Base Event B: Security Audit Scheduled Task Created (Event 4698) -->
  <rule id="115301" level="8">
    <field name="win.system.eventID">^4698$</field>
    <description>SOC-SIM [Scenario 3]: Windows Security Audit logged scheduled task creation</description>
    <mitre><id>T1053.005</id></mitre>
    <group>persistence,scheduled_task</group>
  </rule>

  <!-- Correlation: schtasks.exe (115300) + Audit Creation (115301) within 60s -->
  <rule id="115310" level="13" timeframe="60">
    <if_sid>115300</if_sid>
    <if_matched_sid>115301</if_matched_sid>
    <description>HIGH CORRELATION: Scheduled Task persistence created via command line</description>
    <mitre><id>T1053.005</id></mitre>
    <group>high_confidence,correlation,persistence,scheduled_task</group>
  </rule>

</group>
EOF


cat > "${WORK_HOME}/active_response_config.sh" <<'ACTIVE'
#!/bin/bash
sudo tee -a /var/ossec/etc/ossec.conf << 'EOF'

<!-- Active Response: Scenario 1 - Terminate Malicious Process -->
<command>
  <name>task-kill</name>
  <executable>task-kill.exe</executable>
  <timeout_allowed>no</timeout_allowed>
</command>

<active-response>
  <command>task-kill</command>
  <location>local</location>
  <rules_id>115100</rules_id>
</active-response>
EOF
ACTIVE

chmod +x "${WORK_HOME}/active_response_config.sh"
chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/active_response_config.sh"


cat > "${WORK_HOME}/alert_gen_commands.txt" <<'EOF'
### Scenario 1 — Encoded PowerShell & Active Response Termination

# Prepares a simple Encoded PowerShell command that sleeps for 30 seconds
$cmd = "Start-Sleep -Seconds 30"
$bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
$encodedCmd = [Convert]::ToBase64String($bytes)

Write-Host "Launching Encoded PowerShell Process..." -ForegroundColor Yellow

# Launch process with -EncodedCommand and -NoProfile
$proc = Start-Process powershell.exe -ArgumentList "-NoProfile -EncodedCommand $encodedCmd" -PassThru

Write-Host "Process Started with PID: $($proc.Id)" -ForegroundColor Cyan
Start-Sleep -Seconds 3

# Verify if Active Response terminated the process
if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
    Write-Host "Process is still running." -ForegroundColor Red
} else {
    Write-Host "SUCCESS: Process (PID: $($proc.Id)) was terminated by Active Response!" -ForegroundColor Green
}

=================================================================================================================
=================================================================================================================

### Scenario 2 — Failed Logons Brute-Force

Write-Host "Simulating Brute-Force Logon Attempt (6 Failed Logons)..." -ForegroundColor Yellow

1..6 | ForEach-Object {
    Write-Host "Attempt $_..." -NoNewline
    # Attempts network authentication using an invalid username/password
    cmd.exe /c "net use \\localhost\C$ /user:FakeSOCUser InvalidPass123! 2>&1" | Out-Null
    Write-Host " Failed." -ForegroundColor Red
    Start-Sleep -Milliseconds 500
}

Write-Host "`nCheck Wazuh Dashboard for Rule 115210 (Brute-Force Correlation Alert)." -ForegroundColor Green

=================================================================================================================
=================================================================================================================

### Scenario 3 — Scheduled Task Persistence Creation

Write-Host "Simulating Scheduled Task Persistence Creation..." -ForegroundColor Yellow

# Create persistent task named "SOC_Persistence_Task"
schtasks /create /tn "SOC_Persistence_Task" /tr "C:\Windows\System32\notepad.exe" /sc daily /st 09:00 /f

Write-Host "`nTask Created successfully." -ForegroundColor Green
Write-Host "Check Wazuh Dashboard for Rule 115310 (Scheduled Task Persistence Correlation Alert)." -ForegroundColor Cyan

# Remove the test task
schtasks /delete /tn "SOC_Persistence_Task" /f | Out-Null
Write-Host "Test Scheduled Task 'SOC_Persistence_Task' deleted." -ForegroundColor Green

EOF

chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/alert_gen_commands.txt"

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
DASHBOARD_CONF="/etc/wazuh-dashboard/opensearch_dashboards.yml"

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
