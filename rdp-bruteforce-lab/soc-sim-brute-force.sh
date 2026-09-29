#!/usr/bin/env bash
set -u

# ============================================================
# SOC-SIM Scenario 1 - RDP Brute Force
#
# 4 failed RDP authentications followed by 1 successful login.
# Generates:
#   4625 x4
#   4624 x1
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$(cd "${SCRIPT_DIR}/../terraform-lab" && pwd)}"

TARGET_USER="FakeSOCUser"
TARGET_PASS_GOOD="ValidPass123!"
TARGET_PASS_BAD="InvalidPass123!"

if [[ ! -d "${TF_DIR}" ]]; then
    echo "ERROR: Terraform directory not found: ${TF_DIR}" >&2
    exit 1
fi

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RESET='\033[0m'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'

BOLD='\033[1m'

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

info() {
    echo -e "${GREEN}[+]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[!]${RESET} $*"
}

step() {
    echo -e "${CYAN}[*]${RESET} $*"
}

error() {
    echo -e "${RED}[!]${RESET} $*" >&2
}

success() {
    echo -e "${GREEN}[✓]${RESET} $*"
}

die() {
    error "$*"
    exit 1
}

banner() {
    echo
    echo -e "${MAGENTA}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║        SOC-SIM SCENARIO 1 - RDP BF           ║"
    echo "║        Windows RDP Brute-Force Lab           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ------------------------------------------------------------
# Banner
# ------------------------------------------------------------

banner

# ------------------------------------------------------------
# Check / install FreeRDP
# ------------------------------------------------------------

step "Checking for FreeRDP..."

if ! command -v xfreerdp >/dev/null 2>&1; then

    warn "xfreerdp is not installed."

    if ! command -v dnf >/dev/null 2>&1; then
        die "dnf is not available. Install FreeRDP manually."
    fi

    echo -e "${BLUE}[*]${RESET} Installing FreeRDP..."

    if [[ "${EUID}" -eq 0 ]]; then
        dnf install -y freerdp
    elif command -v sudo >/dev/null 2>&1; then
        sudo dnf install -y freerdp
    else
        die "sudo is not available. Install FreeRDP with: dnf install freerdp"
    fi

    if ! command -v xfreerdp >/dev/null 2>&1; then
        die "FreeRDP installation completed, but xfreerdp was not found."
    fi

    success "FreeRDP installed successfully."

else

    FREERDP_VERSION="$(xfreerdp /version 2>/dev/null | head -n 1)"
    success "FreeRDP detected: ${FREERDP_VERSION}"

fi

echo

# ------------------------------------------------------------
# Terraform check
# ------------------------------------------------------------

step "Checking Terraform..."

if ! command -v terraform >/dev/null 2>&1; then
    die "Terraform is not installed or not in PATH."
fi

success "Terraform detected."

# ------------------------------------------------------------
# Resolve target IP
# ------------------------------------------------------------

step "Resolving Windows EC2 public IP..."

TARGET_IP="$(
    cd "$TF_DIR" &&
    terraform output -raw windows_public_ip 2>/dev/null
)"

if [[ -z "${TARGET_IP}" || "${TARGET_IP}" == "null" ]]; then
    die "Could not resolve windows_public_ip from Terraform."
fi

success "Target IP: ${TARGET_IP}"

# ------------------------------------------------------------
# RDP configuration
# ------------------------------------------------------------

RDP_COMMON=(
    "/v:${TARGET_IP}"
    "/u:.\\${TARGET_USER}"
    "/cert:ignore"
    "/sec:nla"
    "+auth-only"
    "/log-level:ERROR"
)

echo
echo -e "${WHITE}${BOLD}┌──────────────────────────────────────────────┐${RESET}"
echo -e "${WHITE}${BOLD}│              ATTACK PARAMETERS               │${RESET}"
echo -e "${WHITE}${BOLD}├──────────────────────────────────────────────┤${RESET}"
echo -e "${WHITE}│ Target : ${CYAN}${TARGET_IP}:3389${RESET}"
echo -e "${WHITE}│ User   : ${CYAN}.\\${TARGET_USER}${RESET}"
echo -e "${WHITE}│ Attack : ${YELLOW}4 failed + 1 successful${RESET}"
echo -e "${WHITE}${BOLD}└──────────────────────────────────────────────┘${RESET}"
echo

# ------------------------------------------------------------
# Check TCP 3389
# ------------------------------------------------------------

step "Checking RDP connectivity on TCP/3389..."

if ! timeout 5 bash -c \
    "cat < /dev/null > /dev/tcp/${TARGET_IP}/3389" \
    2>/dev/null; then

    die "TCP 3389 is not reachable."
fi

success "TCP 3389 is reachable."
echo

# ------------------------------------------------------------
# Four failed authentications
# ------------------------------------------------------------

echo -e "${RED}${BOLD}━━━ PHASE 1: BRUTE-FORCE ATTEMPTS ━━━${RESET}"
echo

for i in 1 2 3 4; do

    printf "  ${RED}[✗]${RESET} Attempt %d/4 ... " "$i"

    timeout 15 xfreerdp \
        "${RDP_COMMON[@]}" \
        "/p:${TARGET_PASS_BAD}" \
        >/dev/null 2>&1

    # FreeRDP exit status is not treated as authoritative.
    # Windows Security events are the source of truth.
    echo -e "${GREEN}sent${RESET}"

    sleep 2
done

echo
success "4 failed authentication attempts sent."
echo -e "  ${BLUE}Expected:${RESET} ${YELLOW}Windows Event ID 4625 × 4${RESET}"
echo -e "  ${BLUE}Expected:${RESET} ${MAGENTA}Wazuh Rule 115200${RESET}"
echo -e "  ${BLUE}Expected:${RESET} ${MAGENTA}Wazuh Rule 115210${RESET}"

echo

# ------------------------------------------------------------
# Successful authentication
# ------------------------------------------------------------

echo -e "${GREEN}${BOLD}━━━ PHASE 2: SUCCESSFUL AUTHENTICATION ━━━${RESET}"
echo

printf "  ${GREEN}[✓]${RESET} Attempt 5/5 ... "

timeout 20 xfreerdp \
    "${RDP_COMMON[@]}" \
    "/p:${TARGET_PASS_GOOD}" \
    >/dev/null 2>&1

echo -e "${GREEN}sent${RESET}"

sleep 2

echo
success "Successful authentication attempt sent."

echo -e "  ${BLUE}Expected:${RESET} ${YELLOW}Windows Event ID 4624${RESET}"
echo -e "  ${BLUE}Expected:${RESET} ${MAGENTA}Wazuh Rule 92657${RESET}"
echo -e "  ${BLUE}Expected:${RESET} ${MAGENTA}Wazuh Rule 115220${RESET}"

echo

# ------------------------------------------------------------
# Complete
# ------------------------------------------------------------

echo -e "${MAGENTA}${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║              SCENARIO COMPLETE               ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${RESET}"

echo
echo -e "${WHITE}${BOLD}Expected Windows Events:${RESET}"
echo -e "  ${RED}4625 × 4${RESET}  → Failed RDP logons"
echo -e "  ${GREEN}4624 × 1${RESET}  → Successful RDP logon"

echo
echo -e "${WHITE}${BOLD}Expected Wazuh Alerts:${RESET}"
echo -e "  ${CYAN}115200${RESET} → Individual failed logon"
echo -e "  ${YELLOW}115210${RESET} → Brute-force correlation"
echo -e "  ${GREEN}115220${RESET} → Successful logon after failures"

echo
echo -e "${BLUE}[*]${RESET} Check the Wazuh dashboard for the resulting alerts."
echo
