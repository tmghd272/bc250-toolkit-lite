#!/usr/bin/env bash
# ==============================================================================
#  CachyOS BC250 Toolkit Lite
#  Main setup and configuration menu
# ==============================================================================

set -euo pipefail

# Re-launch with sudo if not already root
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# Capture the real user who invoked sudo (for AUR helpers that refuse to run as root)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"

SKIP_LIMINE_UPDATE=0

# ==============================================================================
# COLORS & FORMATTING
# ==============================================================================

RESET="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
WHITE="\e[97m"
BLUE="\e[34m"
MAGENTA="\e[35m"

BG_HEADER="\e[48;5;235m"

# ==============================================================================
# HELPERS
# ==============================================================================

print_banner() {
    clear
    local kernel
    kernel=$(uname -r)
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                              ║"
    echo "  ║                 CachyOS BC250 Toolkit Lite                   ║"
    printf "  ║              %-47s ║\n" "Kernel: ${kernel}"
    echo "  ║                                                              ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_section() {
    echo -e "  ${BOLD}${YELLOW}$1${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
}

print_item() {
    local num="$1"
    local label="$2"
    local desc="$3"
    printf "  ${BOLD}${WHITE}[${CYAN}%2s${WHITE}]${RESET}  %-19s ${DIM}%s${RESET}\n" "$num" "$label" "$desc"
}

print_success() {
    echo -e "\n  ${BOLD}${GREEN}✔  $1${RESET}\n"
}

print_error() {
    echo -e "\n  ${BOLD}${RED}✘  $1${RESET}\n"
}

print_info() {
    echo -e "  ${CYAN}→${RESET}  $1"
}

print_step() {
    echo -e "\n  ${BOLD}${MAGENTA}[$1]${RESET}  $2"
}

press_enter() {
    echo -e "\n  ${DIM}Press Enter to return to the menu...${RESET}"
    read -r
}

confirm() {
    local prompt="${1:-Are you sure?}"
    echo -e "\n  ${YELLOW}${prompt}${RESET} ${DIM}[y/N]${RESET} "
    read -rp "  → " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ==============================================================================
# SETUP TASKS — GOVERNORS
# ==============================================================================

run_cpu_governor() {
    print_step "01" "Installing CPU Governor"

    if systemctl is-enabled bc250-smu-oc.service &>/dev/null || \
       pipx list 2>/dev/null | grep -q 'bc250-smu-oc'; then
        print_info "CPU governor already installed — skipping."
        return 0
    fi

    print_info "Installing dependencies: python-pipx, stress"
    pacman -Syu python-pipx stress --noconfirm || { print_error "Failed to install dependencies."; return 1; }
    print_info "Cloning bc250_smu_oc repository..."
    if [[ -d "bc250_smu_oc" ]]; then
        print_info "Directory already exists — pulling latest changes..."
        git -C bc250_smu_oc pull || { print_error "Failed to pull repository."; return 1; }
    else
        git clone https://github.com/bc250-collective/bc250_smu_oc.git || { print_error "Failed to clone repository."; return 1; }
    fi
    cd bc250_smu_oc
    print_info "Installing via pipx..."
    pipx install . || { print_error "Failed to install via pipx."; cd ..; return 1; }
    pipx ensurepath || true
    export PATH="$PATH:/root/.local/bin"
    print_info "Running bc250-detect..."
    bc250-detect --frequency 3500 --vid 1000 --keep || { print_error "bc250-detect failed."; cd ..; return 1; }
    print_info "Applying overclock config..."
    bc250-apply --install overclock.conf || { print_error "bc250-apply failed."; cd ..; return 1; }
    print_info "Enabling systemd service..."
    systemctl enable bc250-smu-oc || { print_error "Failed to enable service."; cd ..; return 1; }
    cd ..
    print_success "CPU Governor installed successfully!"
}

run_gpu_governor() {
    print_step "02" "Installing GPU Governor"

    if systemctl is-enabled cyan-skillfish-governor-smu.service &>/dev/null || \
       pacman -Qq cyan-skillfish-governor-smu &>/dev/null; then
        print_info "GPU governor already installed — skipping."
        return 0
    fi

    print_info "Installing cyan-skillfish-governor-smu via paru (as $REAL_USER)..."
    sudo -u "$REAL_USER" paru -S cyan-skillfish-governor-smu --noconfirm
    print_info "Enabling and starting systemd service..."
    systemctl enable --now cyan-skillfish-governor-smu.service
    print_success "GPU Governor installed and started successfully!"
}

# ==============================================================================
# SETUP TASKS — LIMINE CONFIGURATION
# ==============================================================================

run_enable_swap() {
    print_step "03" "Configuring Swap"
    print_info "Disabling and removing existing swapfile..."
    swapoff /var/swap/swapfile 2>/dev/null || true
    rm -f /var/swap/swapfile 2>/dev/null || true

    print_info "Recreating Btrfs subvolume..."
    btrfs subvolume delete /var/swap 2>/dev/null || true
    btrfs subvolume create /var/swap

    print_info "Creating 16G swapfile..."
    btrfs filesystem mkswapfile --size 16G /var/swap/swapfile

    print_info "Updating /etc/fstab..."
    sed -i '/\/var\/swap\/swapfile/d' /etc/fstab
    echo '/var/swap/swapfile none swap defaults,nofail 0 0' | tee -a /etc/fstab > /dev/null

    print_info "Setting swappiness to 180..."
    echo 'vm.swappiness = 180' | tee /etc/sysctl.d/99-swappiness.conf > /dev/null
    sysctl vm.swappiness=180 > /dev/null

    print_info "Enabling swapfile..."
    swapon /var/swap/swapfile

    print_success "Swap configured! Current swap:"
    echo ""
    swapon --show | sed 's/^/    /'
    echo ""
}

run_disable_zram_enable_zswap() {
    local CONF="/etc/default/limine"
    print_step "04" "Disabling ZRAM & Enabling ZSWAP"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi

    if grep -q 'systemd\.zram=0' "$CONF"; then
        print_info "ZRAM already disabled in $CONF — skipping."
    else
        print_info "Disabling ZRAM..."
        sed -i '/^KERNEL_CMDLINE/s/"$/ systemd.zram=0"/' "$CONF"
        print_info "systemd.zram=0 added."
    fi

    if grep -q 'zswap\.enabled=1' "$CONF"; then
        print_info "ZSWAP already enabled in $CONF — skipping."
    else
        print_info "Enabling zswap (lz4, 25% pool)..."
        sed -i '/^KERNEL_CMDLINE/s/"$/ zswap.enabled=1 zswap.max_pool_percent=25 zswap.compressor=lz4"/' "$CONF"
        print_info "ZSWAP kernel parameters added."
    fi

    local MKINITCPIO="/etc/mkinitcpio.conf"
    if grep -q 'lz4' "$MKINITCPIO"; then
        print_info "lz4 modules already present in $MKINITCPIO — skipping."
    else
        print_info "Adding lz4 and lz4_compress modules to initramfs..."
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 lz4 lz4_compress)/' "$MKINITCPIO"
        print_info "Rebuilding initramfs (this may take a moment)..."
        mkinitcpio -P
        print_info "Initramfs rebuilt."
    fi

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        print_info "Regenerating /boot/limine.conf..."
        limine-update
    fi
    print_success "ZRAM disabled && ZSWAP enabled! Reboot to apply."
    echo -e "  ${DIM}After reboot, verify with: cat /sys/module/zswap/parameters/enabled${RESET}\n"
}

run_set_loglevel() {
    local CONF="/etc/default/limine"
    print_step "05" "Hiding RDSEED Warning — Setting loglevel=0 in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists — preserving original."
    fi

    if grep -q 'loglevel=' "$CONF"; then
        print_info "loglevel= found. Updating value to 0..."
        sed -i 's/loglevel=[0-9]*/loglevel=0/g' "$CONF"
    else
        print_info "loglevel= not found. Adding to KERNEL_CMDLINE[default]..."
        sed -i '/^KERNEL_CMDLINE\[default\]/ s/\"$/ loglevel=0\"/' "$CONF"
    fi

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        print_info "Regenerating /boot/limine.conf..."
        limine-update
    fi

    print_success "loglevel set to 0. Reboot to apply."
}

run_disable_mitigations() {
    local CONF="/etc/default/limine"
    print_step "06" "Disabling CPU Mitigations in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi

    if grep -q 'mitigations=off' "$CONF"; then
        print_info "mitigations=off already present in $CONF — skipping."
        return 0
    fi

    print_info "Adding mitigations=off..."
    sed -i '/^KERNEL_CMDLINE/s/"$/ mitigations=off"/' "$CONF"
    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        print_info "Regenerating /boot/limine.conf..."
        limine-update
    fi
    print_success "mitigations=off added. Reboot to apply."
    echo -e "  ${DIM}Note: this disables Spectre/Meltdown mitigations for a performance gain.${RESET}\n"
}

run_overcommit_memlock() {
    local SYSCTL_CONF="/etc/sysctl.d/99-overcommit.conf"
    local LIMITS_CONF="/etc/security/limits.d/99-memlock.conf"
    print_step "08" "Setting Overcommit Memory & Unlimited Memlock"

    if [[ -f "$SYSCTL_CONF" ]]; then
        print_info "$SYSCTL_CONF already exists — skipping."
    else
        print_info "Writing vm.overcommit_memory=1 to $SYSCTL_CONF..."
        echo 'vm.overcommit_memory = 1' > "$SYSCTL_CONF"
        print_info "Applying sysctl setting..."
        sysctl --system > /dev/null
    fi

    if [[ -f "$LIMITS_CONF" ]]; then
        print_info "$LIMITS_CONF already exists — skipping."
    else
        print_info "Writing unlimited memlock to $LIMITS_CONF..."
        {
            echo -e "*\tsoft\tmemlock\tunlimited"
            echo -e "*\thard\tmemlock\tunlimited"
        } > "$LIMITS_CONF"
    fi

    print_success "Overcommit memory & memlock configured!"
    echo -e "  ${DIM}memlock takes effect on next login/session — verify after re-login with: ulimit -l${RESET}\n"
    echo -e "  ${DIM}Verify overcommit now with: sysctl vm.overcommit_memory${RESET}\n"
}

# ==============================================================================
# REVERT FUNCTIONS
# ==============================================================================

run_revert_cpu_governor() {
    print_step "R-1" "Revert CPU Governor — Removing bc250-smu-oc"

    local CPU_DEST="/etc/bc250-smu-oc.conf"

    if ! systemctl is-enabled bc250-smu-oc.service &>/dev/null && \
       ! pipx list 2>/dev/null | grep -q 'bc250-smu-oc'; then
        print_info "CPU governor does not appear to be installed — nothing to revert."
        return 0
    fi

    if ! confirm "This will stop, disable, and remove the bc250-smu-oc service. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    print_info "Stopping and disabling bc250-smu-oc service..."
    systemctl stop bc250-smu-oc.service 2>/dev/null || true
    systemctl disable bc250-smu-oc.service 2>/dev/null || true

    print_info "Uninstalling via pipx..."
    pipx uninstall bc250-smu-oc 2>/dev/null || true

    if [[ -f "$CPU_DEST" ]]; then
        print_info "Removing config file $CPU_DEST..."
        rm -f "$CPU_DEST"
    fi

    print_success "CPU governor removed successfully."
}

run_revert_gpu_governor() {
    print_step "R-2" "Revert GPU Governor — Removing cyan-skillfish-governor-smu"

    if ! systemctl is-enabled cyan-skillfish-governor-smu.service &>/dev/null && \
       ! pacman -Qq cyan-skillfish-governor-smu &>/dev/null; then
        print_info "GPU governor does not appear to be installed — nothing to revert."
        return 0
    fi

    if ! confirm "This will stop, disable, and remove the cyan-skillfish-governor-smu service. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    print_info "Stopping and disabling cyan-skillfish-governor-smu service..."
    systemctl stop cyan-skillfish-governor-smu.service 2>/dev/null || true
    systemctl disable cyan-skillfish-governor-smu.service 2>/dev/null || true

    print_info "Removing package via paru (as $REAL_USER)..."
    sudo -u "$REAL_USER" paru -Rns --noconfirm cyan-skillfish-governor-smu 2>/dev/null || true

    print_success "GPU governor removed successfully."
}

run_revert_zswap() {
    local CONF="/etc/default/limine"
    print_step "R-4" "Revert ZSWAP — Re-enabling ZRAM, removing lz4 from initramfs"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if ! confirm "This will remove zswap kernel params and re-enable ZRAM. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    if grep -q 'zswap\.enabled=1' "$CONF"; then
        print_info "Removing zswap parameters..."
        sed -i 's/ zswap\.enabled=1//g;s/ zswap\.max_pool_percent=[0-9]*//g;s/ zswap\.compressor=[a-z0-9]*//g' "$CONF"
        print_info "ZSWAP parameters removed."
    else
        print_info "No zswap parameters found — skipping."
    fi

    if grep -q 'systemd\.zram=0' "$CONF"; then
        print_info "Re-enabling ZRAM..."
        sed -i 's/ systemd\.zram=0//g' "$CONF"
        print_info "ZRAM re-enabled."
    else
        print_info "systemd.zram=0 not found — ZRAM already enabled."
    fi

    local MKINITCPIO="/etc/mkinitcpio.conf"
    if grep -q 'lz4' "$MKINITCPIO"; then
        print_info "Removing lz4 modules from initramfs..."
        sed -i 's/ lz4_compress//g;s/ lz4//g' "$MKINITCPIO"
        print_info "Rebuilding initramfs..."
        mkinitcpio -P
        print_info "Initramfs rebuilt."
    else
        print_info "lz4 not found in $MKINITCPIO — skipping."
    fi

    print_info "Regenerating /boot/limine.conf..."
    limine-update
    print_success "ZSWAP reverted. Reboot to restore ZRAM."
    print_info "Note: ZRAM will not be active until after reboot."
    echo -e "  ${DIM}After reboot, verify with: systemctl is-active systemd-zram-setup@zram0.service${RESET}\n"
}

run_revert_loglevel() {
    local CONF="/etc/default/limine"
    print_step "R-5" "Revert loglevel — Restoring default"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if ! grep -q 'loglevel=' "$CONF"; then
        print_info "No loglevel parameter found — nothing to revert."
        return 0
    fi

    if grep -q 'loglevel=3' "$CONF"; then
        print_info "loglevel is already at default (3) — nothing to do."
        return 0
    fi

    if ! confirm "This will restore loglevel to 3 in $CONF. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    sed -i 's/loglevel=[0-9]*/loglevel=3/g' "$CONF"
    print_info "Regenerating /boot/limine.conf..."
    limine-update
    print_success "loglevel restored to 3. Reboot to apply."
}

run_revert_mitigations() {
    local CONF="/etc/default/limine"
    print_step "R-6" "Revert Mitigations — Re-enabling in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if ! confirm "This will remove mitigations=off from $CONF. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    if ! grep -q 'mitigations=off' "$CONF"; then
        print_info "mitigations=off not found — nothing to revert."
        return 0
    fi

    print_info "Removing mitigations=off..."
    sed -i 's/ mitigations=off//g' "$CONF"
    print_info "Regenerating /boot/limine.conf..."
    limine-update
    print_success "mitigations=off removed. Reboot to re-enable CPU security mitigations."
}

run_revert_overcommit_memlock() {
    local SYSCTL_CONF="/etc/sysctl.d/99-overcommit.conf"
    local LIMITS_CONF="/etc/security/limits.d/99-memlock.conf"
    print_step "R-7" "Revert Overcommit Memory & Memlock"

    if [[ ! -f "$SYSCTL_CONF" && ! -f "$LIMITS_CONF" ]]; then
        print_info "Neither config file found — nothing to revert."
        return 0
    fi

    if ! confirm "This will remove $SYSCTL_CONF and $LIMITS_CONF and reset overcommit_memory to default (0). Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    if [[ -f "$SYSCTL_CONF" ]]; then
        print_info "Removing $SYSCTL_CONF..."
        rm -f "$SYSCTL_CONF"
        sysctl vm.overcommit_memory=0 > /dev/null
        print_info "overcommit_memory reset to default (0)."
    fi

    if [[ -f "$LIMITS_CONF" ]]; then
        print_info "Removing $LIMITS_CONF..."
        rm -f "$LIMITS_CONF"
        print_info "memlock limit removed (takes effect on next login)."
    fi

    print_success "Overcommit/memlock settings reverted."
}

# ==============================================================================
# ADDITIONAL TOOLS
# ==============================================================================

run_toggle_boot_mode() {
    print_step "AT-1" "Toggle Boot Mode"

    local CONF_DIR="/etc/plasmalogin.conf.d"
    local OVERRIDE_FILE="$CONF_DIR/zzz-bc250-boot.conf"
    local USER_NAME="$REAL_USER"

    local current_session="gamescope"
    local current_relogin="true"
    if [[ -f "$OVERRIDE_FILE" ]]; then
        grep -q "plasma.desktop" "$OVERRIDE_FILE" && current_session="plasma"
        grep -q "Relogin=false"  "$OVERRIDE_FILE" && current_relogin="false"
    fi

    local current_mode
    if [[ "$current_session" == "gamescope" && "$current_relogin" == "true" ]]; then
        current_mode="${BOLD}${GREEN}Game Mode — no password${RESET}"
    elif [[ "$current_session" == "gamescope" && "$current_relogin" == "false" ]]; then
        current_mode="${BOLD}${GREEN}Game Mode — password required${RESET}"
    elif [[ "$current_session" == "plasma" && "$current_relogin" == "false" ]]; then
        current_mode="${BOLD}${CYAN}Desktop Mode — password required${RESET}"
    else
        current_mode="${BOLD}${CYAN}Desktop Mode — no password${RESET}"
    fi

    echo -e "  ${CYAN}→${RESET}  Current: $current_mode"
    echo ""
    print_item "1" "Game Mode"    "No password — boot straight to Steam UI"
    print_item "2" "Game Mode"    "Password required for desktop mode"
    print_item "3" "Desktop Mode" "Password required on boot"
    print_item "4" "Desktop Mode" "No password — autologin to Plasma"
    echo ""
    print_item "0" "Back"         "Return to menu"
    echo ""

    read -rp "$(echo -e "  ${BOLD}${WHITE}Select choice:${RESET} ")" mode_choice

    case "$mode_choice" in
        1)
            print_info "Switching to Game Mode (no password)..."
            rm -f "$OVERRIDE_FILE"
            print_success "Done. Reboot to apply."
            ;;
        2)
            print_info "Switching to Game Mode (password required)..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
Relogin=false
Session=gamescope-session.desktop
User=$USER_NAME
EOF
            print_success "Done. Reboot to apply."
            ;;
        3)
            print_info "Switching to Desktop Mode (password required)..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
User=
Session=plasma.desktop
EOF
            print_success "Done. Reboot to apply."
            ;;
        4)
            print_info "Switching to Desktop Mode (no password)..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
Relogin=true
Session=plasma.desktop
User=$USER_NAME
EOF
            print_success "Done. Reboot to apply."
            ;;
        0|*)
            print_info "No changes made."
            return 0
            ;;
    esac
}

run_cu_live_manager() {
    print_step "AT-2" "Compute Units Live Manager"
    print_info "Downloading bc250-cu-live-manager by WinnieLV..."

    local TMP_SCRIPT="/tmp/bc250-cu-live-manager.sh"
    curl -fsSL "https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/refs/heads/main/bc250-cu-live-manager.sh" \
        -o "$TMP_SCRIPT" \
        || { print_error "Failed to download script. Check your internet connection."; return 1; }

    chmod +x "$TMP_SCRIPT"
    print_info "Launching CU Live Manager..."
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
    print_info "Returned to BC250 Toolkit Lite."
}

_nct_status() {
    if lsmod | awk '$1=="nct6687" {found=1} END{exit !found}'; then
        local nct_color="$GREEN"; local nct_label="loaded (DKMS driver active)"
    else
        local nct_color="$DIM";   local nct_label="not loaded"
    fi

    if lsmod | awk '$1=="nct6683" {found=1} END{exit !found}'; then
        local old_color="$MAGENTA"; local old_label="loaded (in-kernel driver, should be blacklisted)"
    else
        local old_color="$DIM";     local old_label="not loaded"
    fi

    echo -e "  ${BOLD}${YELLOW}Driver Status${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${CYAN}nct6687${RESET}    (dkms)      ${nct_color}${nct_label}${RESET}"
    echo -e "  ${CYAN}nct6683${RESET}  (in-kernel)   ${old_color}${old_label}${RESET}"
    echo ""
}

run_nct_menu() {
    local WORKDIR="/tmp/nct6687d"
    local MODULES_LOAD_FILE="/etc/modules-load.d/nct6687d.conf"
    local OPTIONS_FILE="/etc/modprobe.d/nct6687d.conf"
    local BLACKLIST_FILE="/etc/modprobe.d/nct6683.conf"

    while true; do
        print_banner
        print_section "NCT6687 Driver Menu"
        _nct_status
        print_item "1" "Install Driver"    "Install NCT6687 DKMS driver"
        print_item "2" "Uninstall Driver"  "Completely remove NCT6687 DKMS driver"
        print_item "3" "Blacklist NCT6683" "Prevent NCT6683 from loading (Optional)"
        print_item "4" "Remove Blacklist"  "Remove NCT6683 blacklist"
        echo ""
        print_item "0" "Back"              "Return to main menu"
        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" opt

        case "$opt" in
            1)
                print_step "NCT-1" "Installing NCT6687 DKMS driver"

                if [[ -d "/usr/src/nct6687d-1.0" ]] || dkms status 2>/dev/null | grep -q 'nct6687d'; then
                    print_info "NCT6687 driver already installed — skipping."
                    press_enter; continue
                fi

                rm -rf "$WORKDIR"
                print_info "Installing dependencies..."
                pacman -Sy --needed --noconfirm git base-devel dkms linux-headers \
                    || { print_error "Failed to install dependencies."; press_enter; continue; }
                print_info "Cloning nct6687d repository..."
                git clone https://github.com/Fred78290/nct6687d "$WORKDIR" \
                    || { print_error "Failed to clone repository."; press_enter; continue; }
                cd "$WORKDIR"
                print_info "Installing via DKMS..."
                mkdir -p /usr/src/nct6687d-1.0
                cp -r . /usr/src/nct6687d-1.0/
                dkms add nct6687d/1.0 \
                    && dkms build nct6687d/1.0 \
                    && dkms install nct6687d/1.0 \
                    || { print_error "DKMS build/install failed."; cd /; press_enter; continue; }
                echo "nct6687" | tee "$MODULES_LOAD_FILE" >/dev/null
                echo "options nct6687 force=true" | tee "$OPTIONS_FILE" >/dev/null
                modprobe nct6687 || print_error "Module load failed — try rebooting."
                cd /
                print_success "NCT6687 driver installed successfully!"
                press_enter
                ;;
            2)
                print_step "NCT-2" "Uninstalling NCT6687 Driver"

                if [[ ! -d "/usr/src/nct6687d-1.0" ]] && ! dkms status 2>/dev/null | grep -q 'nct6687d'; then
                    print_info "NCT6687 driver does not appear to be installed — nothing to remove."
                    press_enter; continue
                fi

                print_info "Removing DKMS module..."
                dkms remove nct6687d/1.0 --all 2>/dev/null || true
                print_info "Cleaning up files..."
                rm -rf /usr/src/nct6687d-1.0
                rm -f "$MODULES_LOAD_FILE" "$OPTIONS_FILE" "$BLACKLIST_FILE"
                modprobe -r nct6687 2>/dev/null || true
                print_success "NCT6687 driver has been uninstalled. A reboot may be required"
                press_enter
                ;;
            3)
                print_step "NCT-3" "Blacklisting NCT6683"
                echo "blacklist nct6683" | tee "$BLACKLIST_FILE" >/dev/null
                print_success "NCT6683 has been blacklisted. Reboot recommended."
                press_enter
                ;;
            4)
                print_step "NCT-4" "Removing NCT6683 Blacklist"
                rm -f "$BLACKLIST_FILE"
                print_success "NCT6683 blacklist removed. Reboot recommended."
                press_enter
                ;;
            0) return ;;
            *)
                print_error "Invalid selection: '$opt'"
                sleep 1
                ;;
        esac
    done
}

_i2c_state_dir="/etc/bc250-toolkit"
_i2c_state_file="${_i2c_state_dir}/isl69247-bus"
_i2c_service_file="/etc/systemd/system/bc250-isl69247.service"
_i2c_modules_file="/etc/modules-load.d/isl68137.conf"
_i2c_chip="isl69247"
_i2c_addr="0x60"

# Single lightweight read on one known bus/address — safe to call often.
# Only meaningful BEFORE the device is bound: once a driver owns the address
# (i2cdetect shows "UU"), the kernel refuses raw i2c-dev access to it, so
# this will always fail post-bind even though that's the healthy state.
_i2c_probe_one() {
    local bus="$1"
    sudo -n true 2>/dev/null # no-op, keeps style consistent with rest of script
    i2cget -y "$bus" "$_i2c_addr" 0x78 b &>/dev/null
}

# The correct "is this bus okay" check for any point after install: if a
# driver is already bound (hwmon dir exists), that alone proves it's
# healthy — don't raw-probe an address the kernel already owns exclusively,
# since that probe would fail (resource busy) regardless of health.
# Only fall back to the raw probe when nothing is bound yet.
_i2c_bus_healthy() {
    local bus="$1"
    [[ -z "$bus" ]] && return 1
    if [[ -e "/sys/bus/i2c/devices/${bus}-0060/hwmon" ]]; then
        return 0
    fi
    _i2c_probe_one "$bus"
}

# Full multi-bus scan — only ever called ONCE per install, never looped or
# repeated. Repeated i2cdetect scans (or repeated new_device/delete_device
# cycles) were observed to wedge this bus until a reboot; a single pass is
# safe, but this must never be called speculatively or in a retry loop.
_i2c_detect_bus() {
    local found=""
    for b in $(i2cdetect -l | awk '{print $1}' | sed 's/i2c-//'); do
        local out; out=$(i2cdetect -y "$b" 2>/dev/null | string collect 2>/dev/null || i2cdetect -y "$b" 2>/dev/null)
        local count; count=$(echo "$out" | grep -oE ' [0-9a-f]{2} ?' | wc -l)
        local has60; has60=$(echo "$out" | awk '/^60:/{print $2}')
        if [[ "$has60" == "60" ]] && [[ "$count" -le 15 ]]; then
            found="$b"
            break
        fi
    done
    echo "$found"
}

_i2c_get_bus() {
    if [[ -f "$_i2c_state_file" ]]; then
        cat "$_i2c_state_file"
    fi
}

_i2c_read_vin_hwmon() {
    local bus="$1"
    local hwmon_dir
    hwmon_dir=$(ls -d "/sys/bus/i2c/devices/${bus}-0060/hwmon/hwmon"* 2>/dev/null | head -1)
    [[ -z "$hwmon_dir" ]] && return 1

    for label_file in "$hwmon_dir"/in*_label; do
        [[ -f "$label_file" ]] || continue
        if [[ "$(cat "$label_file" 2>/dev/null)" == "vin" ]]; then
            local input_file="${label_file/_label/_input}"
            if [[ -f "$input_file" ]]; then
                local raw; raw=$(cat "$input_file" 2>/dev/null)
                if [[ -n "$raw" ]] && [[ "$raw" =~ ^[0-9]+$ ]]; then
                    awk -v r="$raw" 'BEGIN{printf "%.2f V", r/1000}'
                    return 0
                fi
            fi
        fi
    done
    return 1
}

_i2c_status() {
    local bus="$1"
    local mod_loaded=0
    lsmod | awk '$1=="isl68137" {found=1} END{exit !found}' && mod_loaded=1

    echo -e "  ${BOLD}${YELLOW}Status${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    if [[ $mod_loaded -eq 1 ]]; then
        echo -e "  isl68137 module:   ${GREEN}loaded${RESET}"
    else
        echo -e "  isl68137 module:   ${DIM}not loaded${RESET}"
    fi

    if [[ -n "$bus" ]]; then
        echo -e "  Detected bus:      ${WHITE}i2c-${bus}${RESET} (address ${WHITE}${_i2c_addr}${RESET})"
        if [[ -e "/sys/bus/i2c/devices/${bus}-0060/hwmon" ]]; then
            echo -e "  Device bound:      ${GREEN}yes${RESET} (${_i2c_chip})"
            local vin vin_src=""
            vin=$(sensors 2>/dev/null | awk '/^isl69247/{f=1} f&&/^vin:/{print $2, $3; exit}')
            if [[ -n "$vin" ]] && [[ "$vin" != "N/A" ]]; then
                vin_src="lm-sensors"
            else
                vin=$(_i2c_read_vin_hwmon "$bus")
                [[ -n "$vin" ]] && vin_src="hwmon fallback"
            fi
            if [[ -n "$vin" ]]; then
                echo -e "  Live VIN reading:  ${WHITE}${vin}${RESET} ${DIM}(via ${vin_src})${RESET}"
            else
                echo -e "  Live VIN reading:  ${YELLOW}N/A — bus not responding right now${RESET}"
                echo -e "                     ${DIM}(bound OK, but reads fail after heavy bus use — try a reboot)${RESET}"
            fi
        else
            echo -e "  Device bound:      ${DIM}no${RESET}"
        fi
    else
        echo -e "  Detected bus:      ${DIM}not detected${RESET} (probe failed — check wiring, or run Re-detect Bus)"
    fi

    if [[ -f "$_i2c_service_file" ]]; then
        local svc_state; svc_state=$(systemctl is-enabled bc250-isl69247.service 2>/dev/null)
        echo -e "  Boot persistence:  ${GREEN}installed${RESET} (${svc_state:-unknown})"
    else
        echo -e "  Boot persistence:  ${DIM}not installed${RESET}"
    fi
    echo ""
}

run_i2c_menu() {
    # One lightweight probe per menu session, not per redraw — repeated
    # probing is what wedges this bus. If the cached bus is missing or
    # stale, try it once, then fall back to the documented common default
    # (bus 4) with a single probe before giving up and asking for a real
    # detect. Self-heals the cache file on success so next time is instant.
    local session_bus; session_bus=$(_i2c_get_bus)
    if [[ -z "$session_bus" ]] || ! _i2c_bus_healthy "$session_bus"; then
        if [[ "$session_bus" != "4" ]] && _i2c_bus_healthy 4; then
            session_bus=4
        else
            session_bus=""
        fi
    fi
    if [[ -n "$session_bus" ]]; then
        mkdir -p "$_i2c_state_dir"
        echo "$session_bus" > "$_i2c_state_file"
    fi

    while true; do
        print_banner
        print_section "I2C / isl69247 PMIC Sensor Menu"
        echo -e "  ${DIM}Requires the TPMS1<->I2C_HEADER1 hardware bridge — see BC250-Telemetry's${RESET}"
        echo -e "  ${DIM}hardware.md before installing. Detection runs at most once per install${RESET}"
        echo -e "  ${DIM}to avoid wedging the bus; if it stops responding, just reboot.${RESET}\n"
        _i2c_status "$session_bus"
        print_item "1" "Install"           "Load driver, detect bus, bind device, persist at boot"
        print_item "2" "Uninstall"         "Unbind device, remove driver + boot persistence"
        print_item "3" "Re-detect Bus"     "Only if the bus number has changed (rare)"
        echo ""
        print_item "0" "Back"              "Return to main menu"
        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" opt

        case "$opt" in
            1)
                print_step "I2C-1" "Installing isl69247 PMIC sensor support"

                if lsmod | awk '$1=="isl68137" {found=1} END{exit !found}'; then
                    print_info "isl68137 module already loaded — skipping modprobe."
                else
                    print_info "Loading isl68137 module (built into the kernel — no DKMS needed)..."
                    modprobe isl68137 || { print_error "modprobe failed."; press_enter; continue; }
                fi
                mkdir -p "$_i2c_state_dir"
                echo "isl68137" | tee "$_i2c_modules_file" >/dev/null

                local bus; bus=$(_i2c_get_bus)
                if [[ -n "$bus" ]] && _i2c_bus_healthy "$bus"; then
                    print_info "Using cached bus i2c-${bus} (still responding)."
                else
                    print_info "Detecting PMIC bus (single pass)..."
                    bus=$(_i2c_detect_bus)
                    if [[ -z "$bus" ]]; then
                        print_error "No device found at ${_i2c_addr} on any bus."
                        print_error "Check the TPMS1<->I2C_HEADER1 wiring bridge (see hardware.md)."
                        print_error "If it was working before, try a reboot first — this bus wedges"
                        print_error "under repeated scanning and only clears on reboot."
                        press_enter; continue
                    fi
                    echo "$bus" > "$_i2c_state_file"
                    print_success "Found PMIC at i2c-${bus}, ${_i2c_addr}."
                fi

                if [[ -e "/sys/bus/i2c/devices/${bus}-0060/hwmon" ]]; then
                    print_info "Device already bound — skipping."
                else
                    print_info "Binding ${_i2c_chip} at ${_i2c_addr} on i2c-${bus}..."
                    echo "${_i2c_chip} ${_i2c_addr}" | tee "/sys/bus/i2c/devices/i2c-${bus}/new_device" >/dev/null
                    sleep 1
                    if [[ ! -e "/sys/bus/i2c/devices/${bus}-0060/hwmon" ]]; then
                        print_error "Bind failed — no hwmon directory created. Check dmesg."
                        press_enter; continue
                    fi
                fi

                print_info "Installing boot-persistence service (sysfs binding doesn't survive reboot)..."
                cat > "$_i2c_service_file" << EOF
[Unit]
Description=Bind isl69247 PMIC sensor on i2c-${bus}
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'modprobe isl68137; [ -e /sys/bus/i2c/devices/${bus}-0060/hwmon ] || echo ${_i2c_chip} ${_i2c_addr} > /sys/bus/i2c/devices/i2c-${bus}/new_device'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable bc250-isl69247.service &>/dev/null
                print_success "Installed. ${_i2c_chip} will bind automatically on every boot."
                session_bus="$bus"
                press_enter
                ;;
            2)
                print_step "I2C-2" "Uninstalling isl69247 PMIC sensor support"
                local bus; bus=$(_i2c_get_bus)

                if [[ -n "$bus" ]] && [[ -e "/sys/bus/i2c/devices/${bus}-0060" ]]; then
                    print_info "Unbinding device..."
                    echo "$_i2c_addr" | tee "/sys/bus/i2c/devices/i2c-${bus}/delete_device" >/dev/null 2>&1 || true
                fi

                if [[ -f "$_i2c_service_file" ]]; then
                    print_info "Removing boot-persistence service..."
                    systemctl disable --now bc250-isl69247.service &>/dev/null
                    rm -f "$_i2c_service_file"
                    systemctl daemon-reload
                fi

                rm -f "$_i2c_modules_file" "$_i2c_state_file"
                modprobe -r isl68137 2>/dev/null || true
                print_success "isl69247 sensor support removed."
                session_bus=""
                press_enter
                ;;
            3)
                print_step "I2C-3" "Re-detecting PMIC bus"
                print_info "Running a single-pass scan (this is safe once, but avoid repeating it)..."
                local bus; bus=$(_i2c_detect_bus)
                if [[ -z "$bus" ]]; then
                    print_error "No device found at ${_i2c_addr} on any bus."
                else
                    mkdir -p "$_i2c_state_dir"
                    echo "$bus" > "$_i2c_state_file"
                    print_success "Found PMIC at i2c-${bus}. Re-run Install to bind/persist it."
                    session_bus="$bus"
                fi
                press_enter
                ;;
            0) return ;;
            *)
                print_error "Invalid selection: '$opt'"
                sleep 1
                ;;
        esac
    done
}

run_audio_fix() {
    print_step "AT-3" "Fix DisplayPort Audio Delay"

    local CONFIG_DIR="/home/$REAL_USER/.config/wireplumber/wireplumber.conf.d"
    print_info "Writing WirePlumber config to $CONFIG_DIR..."
    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_DIR/51-disable-suspension.conf" << 'EOF'
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
EOF

    cat > "$CONFIG_DIR/54-force-sync.conf" << 'EOF'
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.pci.*" } ]
    actions = {
      update-props = {
        api.alsa.headroom = 0
        api.alsa.disable-tsched = true
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
EOF

    chown -R "$REAL_USER:$REAL_USER" "/home/$REAL_USER/.config/wireplumber"
    print_info "Restarting WirePlumber as $REAL_USER..."
    sudo -u "$REAL_USER" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
        systemctl --user restart wireplumber \
            && print_success "Audio delay fix applied!" \
            || print_error "Failed to restart WirePlumber — you may need to log out and back in."
}

_run_as_user() {
    sudo -u "$REAL_USER" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
        "$@"
}

# ==============================================================================
# POWER & SLEEP — DECK MODE (steam-deckify.conf + Steam's config.vdf)
# ==============================================================================

_deck_config_vdf() {
    echo "/home/$REAL_USER/.local/share/Steam/config/config.vdf"
}

_deck_powerkey_current() {
    grep -oP '^HandlePowerKey=\K.*' /etc/systemd/logind.conf.d/steam-deckify.conf 2>/dev/null
}

_deck_sleep_current() {
    grep -oP '"IdleSuspendACSeconds"\s*"\K[0-9]+' "$(_deck_config_vdf)" 2>/dev/null
}

deck_powerkey_set() {
    local val="$1" label="$2"
    local f="/etc/systemd/logind.conf.d/steam-deckify.conf"

    if [[ ! -f "$f" ]]; then
        print_error "steam-deckify.conf not found — is cachyos-handheld installed?"
        return 1
    fi

    if [[ "$(_deck_powerkey_current)" == "$val" ]]; then
        print_info "Power button already set to '${label}' — skipping."
        return 0
    fi

    sed -i "s/^HandlePowerKey=.*/HandlePowerKey=${val}/" "$f"
    print_info "Reloading systemd-logind (SIGHUP — avoids the full-restart DRM/HDMI"
    print_info "glitch a 'systemctl restart' can cause mid-session)..."
    systemctl kill -s HUP systemd-logind
    sleep 1

    local current
    current=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager HandlePowerKey 2>/dev/null | awk '{print $2}' | tr -d '"')

    if [[ "$current" == "$val" ]]; then
        print_success "Power button set to '${label}'."
    else
        print_error "Runtime value is still '${current:-unknown}' — reload may not have applied cleanly."
    fi
}

deck_sleep_set() {
    local seconds="$1" label="$2"
    local f; f=$(_deck_config_vdf)

    if [[ ! -f "$f" ]]; then
        print_error "Steam config.vdf not found at $f — has Steam been run at least once?"
        return 1
    fi

    if [[ "$(_deck_sleep_current)" == "$seconds" ]]; then
        print_info "Sleep timer already set to ${label} — skipping."
        return 0
    fi

    print_info "Stopping Steam (needed so it doesn't overwrite this on exit)..."
    _run_as_user systemctl --user stop steam-launcher.service 2>/dev/null
    sleep 1
    sed -i "s/\"IdleSuspendACSeconds\"[[:space:]]*\"[0-9]*\"/\"IdleSuspendACSeconds\"\t\t\t\"${seconds}\"/" "$f"
    print_info "Restarting Steam..."
    _run_as_user systemctl --user start steam-launcher.service
    print_success "Sleep timer set to ${label}."
}

run_deck_powerkey_enable()  { print_step "PS-1" "Deck Mode: Power Button -> Shutdown";      deck_powerkey_set poweroff "Shutdown"; }
run_deck_powerkey_revert()  { print_step "PS-2" "Deck Mode: Power Button -> OEM Default";    deck_powerkey_set ignore   "Ignore (OEM default)"; }
run_deck_sleep_disable()    { print_step "PS-3" "Deck Mode: Sleep Timer -> Disabled";        deck_sleep_set 0    "Disabled"; }
run_deck_sleep_revert()     { print_step "PS-4" "Deck Mode: Sleep Timer -> Default (1 hour)"; deck_sleep_set 3600 "1 hour (default)"; }

# ==============================================================================
# POWER & SLEEP — DESKTOP MODE (KDE Powerdevil via kwriteconfig6/kreadconfig6)
# ==============================================================================

_desktop_rc() {
    echo "/home/$REAL_USER/.config/powerdevilrc"
}

_desktop_read() {
    local group1="$1" group2="$2" key="$3"
    _run_as_user kreadconfig6 --file "$(_desktop_rc)" --group "$group1" --group "$group2" --key "$key" 2>/dev/null
}

_desktop_write() {
    local group1="$1" group2="$2" key="$3" val="$4"
    # '--' terminates option parsing so a value like '-1' isn't mistaken for a flag
    _run_as_user kwriteconfig6 --file "$(_desktop_rc)" --group "$group1" --group "$group2" --key "$key" -- "$val"
}

desktop_powerbutton_set() {
    local val="$1" label="$2"
    if ! command -v kwriteconfig6 &>/dev/null; then
        print_error "kwriteconfig6 not found — is this a Plasma 6 session?"
        return 1
    fi
    if [[ "$(_desktop_read AC SuspendAndShutdown PowerButtonAction)" == "$val" ]]; then
        print_info "Power button already set to '${label}' — skipping."
        return 0
    fi
    _desktop_write AC SuspendAndShutdown PowerButtonAction "$val"
    print_success "Power button set to '${label}'. (Powerdevil applies this live — no restart needed.)"
}

desktop_screenoff_set() {
    local seconds="$1" label="$2"
    if ! command -v kwriteconfig6 &>/dev/null; then
        print_error "kwriteconfig6 not found — is this a Plasma 6 session?"
        return 1
    fi
    local cur_secs; cur_secs=$(_desktop_read AC Display TurnOffDisplayIdleTimeoutSec)
    # Plasma 6 omits this key entirely when it matches the true default (10 min/600s)
    if [[ "$cur_secs" == "$seconds" ]] || { [[ -z "$cur_secs" ]] && [[ "$seconds" == "600" ]]; }; then
        print_info "Screen timeout already set to '${label}' — skipping."
        return 0
    fi
    _desktop_write AC Display TurnOffDisplayIdleTimeoutSec "$seconds"
    if [[ "$seconds" == "-1" ]]; then
        # Real Powerdevil writes this explicitly false only when disabled.
        _desktop_write AC Display TurnOffDisplayWhenIdle "false"
    else
        # Real Powerdevil omits this key entirely when a timer is active —
        # delete it rather than setting it true, or a stale 'false' from a
        # prior disable will silently override the timeout.
        _run_as_user kwriteconfig6 --file "$(_desktop_rc)" --group AC --group Display \
            --key TurnOffDisplayWhenIdle --delete 2>/dev/null
    fi
    print_success "Screen timeout set to '${label}'. (Powerdevil applies this live — no restart needed.)"
}

run_desktop_powerbutton_shutdown() { print_step "PS-5" "Desktop Mode: Power Button -> Shut Down"; desktop_powerbutton_set 8 "Shut Down"; }
run_desktop_powerbutton_revert()   { print_step "PS-6" "Desktop Mode: Power Button -> OEM Default (Sleep)"; desktop_powerbutton_set 1 "Sleep (OEM default)"; }
run_desktop_screenoff_disable()    { print_step "PS-7" "Desktop Mode: Turn Off Screen -> Disabled"; desktop_screenoff_set -1 "Disabled"; }
run_desktop_screenoff_revert()     { print_step "PS-8" "Desktop Mode: Turn Off Screen -> OEM Default (10 min)"; desktop_screenoff_set 600 "10 minutes (OEM default)"; }

# ==============================================================================
# POWER & SLEEP — REVERT ALL
# ==============================================================================

run_power_sleep_shutdown_all() {
    print_step "PS-0c" "Enable Power Button Shutdown — Deck + Desktop"
    if ! confirm "Set BOTH Deck Mode and Desktop Mode power buttons to trigger a real shutdown?"; then
        print_info "Cancelled."
        return 0
    fi
    deck_powerkey_set        poweroff "Shutdown"
    desktop_powerbutton_set  8        "Shut Down"
    print_success "Power button now shuts down in both Deck Mode and Desktop Mode."
}

run_power_sleep_disable_all() {
    print_step "PS-0a" "Sleep/Screen: Disable (Both) — BC-250 has no working S3 support"
    if ! confirm "Set Deck Mode sleep timer and Desktop Mode screen-off timer both to Off?"; then
        print_info "Cancelled."
        return 0
    fi
    deck_sleep_set         0 "Disabled"
    desktop_screenoff_set -1 "Disabled"
    print_success "Deck sleep timer and Desktop screen-off timer both disabled."
}

run_power_sleep_revert_all() {
    print_step "PS-0b" "Revert ALL Power & Sleep settings to OEM defaults"
    if ! confirm "Reset Deck Mode power button (ignore), Deck Mode sleep timer (1hr), Desktop power button (Sleep), and Desktop screen-off (10 min) — all back to their original out-of-box values?"; then
        print_info "Cancelled."
        return 0
    fi
    deck_powerkey_set        ignore "Ignore (OEM default)"
    deck_sleep_set            3600  "1 hour (default)"
    desktop_powerbutton_set   1     "Sleep (OEM default)"
    desktop_screenoff_set     600   "10 minutes (OEM default)"
    print_success "All Power & Sleep settings reverted to OEM defaults."
}

# ==============================================================================
# POWER & SLEEP — SUBMENU
# ==============================================================================

_power_sleep_status() {
    local dk_pw dk_sl dt_pw dt_so_sec

    dk_pw=$(_deck_powerkey_current)
    dk_sl=$(_deck_sleep_current)
    if command -v kreadconfig6 &>/dev/null; then
        dt_pw=$(_desktop_read AC SuspendAndShutdown PowerButtonAction)
        dt_so_sec=$(_desktop_read AC Display TurnOffDisplayIdleTimeoutSec)
    fi

    local action_label
    action_label() {
        case "$1" in
            0) echo "Do Nothing" ;;
            1) echo "Sleep" ;;
            2) echo "Hibernate" ;;
            8) echo "Shut Down" ;;
            "") echo "Do Nothing (default)" ;;
            *) echo "Unknown ($1)" ;;
        esac
    }

    echo -e "  ${BOLD}${YELLOW}Current Status${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${CYAN}Deck Mode${RESET}"
    echo -e "    Power Button:      ${WHITE}${dk_pw:-unknown}${RESET}"
    if [[ "$dk_sl" == "0" ]]; then
        echo -e "    Sleep Timer:       ${WHITE}Disabled${RESET}"
    elif [[ -n "$dk_sl" ]]; then
        echo -e "    Sleep Timer:       ${WHITE}${dk_sl}s ($(( dk_sl / 60 )) min)${RESET}"
    else
        echo -e "    Sleep Timer:       ${DIM}unknown (config.vdf not found?)${RESET}"
    fi
    echo -e "  ${CYAN}Desktop Mode${RESET}"
    echo -e "    Power Button:      ${WHITE}$(action_label "$dt_pw")${RESET}"
    if [[ "$dt_so_sec" == "-1" ]]; then
        echo -e "    Turn Off Screen:   ${WHITE}Disabled${RESET}"
    elif [[ -z "$dt_so_sec" ]]; then
        echo -e "    Turn Off Screen:   ${WHITE}10 min (default)${RESET}"
    else
        echo -e "    Turn Off Screen:   ${WHITE}${dt_so_sec}s ($(( dt_so_sec / 60 )) min)${RESET}"
    fi
    echo ""
}

show_power_sleep_menu() {
    print_banner
    print_section "Power & Sleep"
    echo -e "  ${DIM}Deck Mode (steam-deckify.conf + Steam config.vdf) and Desktop Mode${RESET}"
    echo -e "  ${DIM}(KDE Powerdevil) power button and screen-off behavior.${RESET}\n"

    _power_sleep_status

    echo -e "  ${BOLD}${YELLOW}Deck Mode${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    print_item "1" "Power Button: Shutdown" "HandlePowerKey=poweroff"
    print_item "2" "Power Button: Revert"   "Back to OEM default (ignore)"
    print_item "3" "Sleep: Disable"         "IdleSuspendACSeconds=0"
    print_item "4" "Sleep: Revert"          "Back to OEM default (1 hour)"
    echo ""
    echo -e "  ${BOLD}${YELLOW}Desktop Mode${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    print_item "5" "Power Button: Shutdown" "PowerButtonAction=8"
    print_item "6" "Power Button: Revert"   "Back to OEM default (Sleep)"
    print_item "7" "Screen Off: Disable"    "Never turn off display when idle"
    print_item "8" "Screen Off: Revert"     "Back to OEM default (10 min)"
    echo ""
    print_item "P" "Power Button: Shutdown (Both)" "Set Deck & Desktop power buttons to Shut Down"
    print_item "D" "Sleep/Screen: Disable (Both)"  "Set Deck & Desktop sleep/screen timers to Off"
    print_item "A" "Revert ALL"                    "Reset every setting above to OEM defaults"
    print_item "0" "Back"                            "Return to main menu"
    echo ""
    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

run_power_sleep_menu() {
    while true; do
        show_power_sleep_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" ps_choice
        case "${ps_choice^^}" in
            1) run_deck_powerkey_enable;         press_enter ;;
            2) run_deck_powerkey_revert;          press_enter ;;
            3) run_deck_sleep_disable;            press_enter ;;
            4) run_deck_sleep_revert;              press_enter ;;
            5) run_desktop_powerbutton_shutdown;   press_enter ;;
            6) run_desktop_powerbutton_revert;     press_enter ;;
            7) run_desktop_screenoff_disable;      press_enter ;;
            8) run_desktop_screenoff_revert;       press_enter ;;
            P) run_power_sleep_shutdown_all;      press_enter ;;
            D) run_power_sleep_disable_all;        press_enter ;;
            A) run_power_sleep_revert_all;         press_enter ;;
            0) return ;;
            *)
                print_error "Invalid selection: '$ps_choice'"
                sleep 1
                ;;
        esac
    done
}

_rtw_status() {
    if lsmod | awk '$1=="rtw88_8822bu" {found=1} END{exit !found}'; then
        local old_color="$MAGENTA"; local old_label="loaded (in-kernel driver, should be replaced)"
    else
        local old_color="$DIM";     local old_label="not loaded"
    fi

    if lsmod | awk '$1=="88x2bu" {found=1} END{exit !found}'; then
        local new_color="$GREEN"; local new_label="loaded (DKMS driver active)"
    else
        local new_color="$DIM";   local new_label="not loaded"
    fi

    echo -e "  ${BOLD}${YELLOW}Driver Status${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${CYAN}rtw88_8822bu${RESET}  (old)   ${old_color}${old_label}${RESET}"
    echo -e "  ${CYAN}88x2bu      ${RESET}  (new)   ${new_color}${new_label}${RESET}"
    echo ""
}

run_realtek_wifi_menu() {
    local DRIVER_DIR="/usr/src/rtl88x2bu-git"
    local BLACKLIST_FILE="/etc/modprobe.d/rtw8822bu.conf"
    local MODULES_LOAD_FILE="/etc/modules-load.d/88x2bu.conf"
    local OPTIONS_FILE="/etc/modprobe.d/88x2bu.conf"

    while true; do
        print_banner
        print_section "Realtek WiFi USB Menu  —  RTL88x2BU"
        _rtw_status
        print_item "1" "Install Driver"       "Fresh DKMS install from RinCat/RTL88x2BU-Linux-Driver"
        print_item "2" "Upgrade Driver"       "git fetch + rebase + dkms build/install --force"
        print_item "3" "Uninstall Driver"     "Remove DKMS module, blacklist, options & src"
        print_item "4" "Force USB 3.0 Mode"   "Force 88x2bu to use USB 3.0 mode"
        print_item "5" "Force USB 2.0 Mode"   "Force 88x2bu to use USB 2.0 mode"
        print_item "6" "Clear 88x2bu Options" "Reset 88x2bu USB mode and options to default"
        echo ""
        print_item "0" "Back"                 "Return to main menu"
        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" rtw_choice

        case "$rtw_choice" in
            1)
                print_step "RTW-1" "Installing RTL88x2BU DKMS driver"
                if [[ -d "$DRIVER_DIR/.git" ]]; then
                    print_info "Driver source already exists at $DRIVER_DIR — use Upgrade instead."
                    press_enter; continue
                fi
                print_info "Installing dependencies: git, base-devel, dkms, linux-headers..."
                pacman -Sy --needed --noconfirm git base-devel dkms linux-headers \
                    || { print_error "Failed to install dependencies."; press_enter; continue; }
                print_info "Cloning RTL88x2BU driver to $DRIVER_DIR..."
                git clone "https://github.com/RinCat/RTL88x2BU-Linux-Driver.git" "$DRIVER_DIR" \
                    || { print_error "Failed to clone repository."; press_enter; continue; }
                print_info "Patching dkms.conf version string..."
                sed -i 's/PACKAGE_VERSION="@PKGVER@"/PACKAGE_VERSION="git"/g' "$DRIVER_DIR/dkms.conf"
                print_info "Adding to DKMS..."
                dkms add -m rtl88x2bu -v git \
                    || { print_error "DKMS add failed."; press_enter; continue; }
                print_info "Running dkms autoinstall..."
                dkms autoinstall \
                    || { print_error "DKMS autoinstall failed."; press_enter; continue; }
                print_info "Blacklisting old rtw88_8822bu kernel driver..."
                echo "blacklist rtw88_8822bu" > "$BLACKLIST_FILE"
                print_info "Writing modules-load entry for 88x2bu..."
                echo "88x2bu" > "$MODULES_LOAD_FILE"
                print_info "Unloading old driver (if present)..."
                modprobe -r rtw88_8822bu 2>/dev/null || true
                print_info "Loading new driver..."
                modprobe 88x2bu \
                    && print_success "RTL88x2BU driver installed and loaded!" \
                    || print_error "Module load failed — try rebooting."
                press_enter
                ;;
            2)
                print_step "RTW-2" "Upgrading RTL88x2BU DKMS driver"
                if [[ ! -d "$DRIVER_DIR/.git" ]]; then
                    print_error "Driver not installed — run Install first."
                    press_enter; continue
                fi
                cd "$DRIVER_DIR"
                print_info "Fetching latest source..."
                git fetch || { print_error "git fetch failed."; cd /; press_enter; continue; }
                print_info "Rebasing onto origin/master..."
                git rebase origin/master --autostash \
                    || { print_error "git rebase failed."; cd /; press_enter; continue; }
                print_info "Building updated driver..."
                dkms build rtl88x2bu/git --force \
                    || { print_error "DKMS build failed."; cd /; press_enter; continue; }
                print_info "Installing updated driver..."
                dkms install rtl88x2bu/git --force \
                    || { print_error "DKMS install failed."; cd /; press_enter; continue; }
                cd /
                print_info "Reloading module..."
                modprobe -r 88x2bu 2>/dev/null || true
                modprobe 88x2bu \
                    && print_success "Driver upgraded and reloaded!" \
                    || print_error "Module reload failed — try rebooting."
                press_enter
                ;;
            3)
                print_step "RTW-3" "Uninstalling RTL88x2BU DKMS driver"
                if ! confirm "This will remove the DKMS module, config files, and source directory. Proceed?"; then
                    print_info "Cancelled."
                    press_enter; continue
                fi
                print_info "Unloading module..."
                modprobe -r 88x2bu 2>/dev/null || true
                print_info "Removing DKMS module..."
                dkms remove rtl88x2bu/git --all 2>/dev/null || true
                print_info "Removing source directory $DRIVER_DIR..."
                rm -rf "$DRIVER_DIR"
                print_info "Removing config files..."
                rm -f "$BLACKLIST_FILE" "$MODULES_LOAD_FILE" "$OPTIONS_FILE"
                print_info "Reloading old driver (if available)..."
                modprobe rtw88_8822bu 2>/dev/null \
                    && print_info "rtw88_8822bu reloaded." \
                    || print_info "rtw88_8822bu not available — may need reboot."
                print_success "RTL88x2BU driver uninstalled."
                press_enter
                ;;
            4)
                print_step "RTW-4" "Forcing USB 3.0 mode"
                echo "options 88x2bu rtw_switch_usb_mode=1" | tee "$OPTIONS_FILE" >/dev/null
                modprobe -r 88x2bu 2>/dev/null || true
                modprobe 88x2bu
                print_success "USB 3.0 mode applied (replug may be required)."
                press_enter
                ;;
            5)
                print_step "RTW-5" "Forcing USB 2.0 mode"
                echo "options 88x2bu rtw_switch_usb_mode=2" | tee "$OPTIONS_FILE" >/dev/null
                modprobe -r 88x2bu 2>/dev/null || true
                modprobe 88x2bu
                print_success "USB 2.0 mode applied (replug may be required)."
                press_enter
                ;;
            6)
                print_step "RTW-6" "Clearing 88x2bu options"
                rm -f "$OPTIONS_FILE"
                modprobe -r 88x2bu 2>/dev/null || true
                modprobe 88x2bu
                print_success "88x2bu options removed and USB mode reset to default."
                press_enter
                ;;
            0) return ;;
            *)
                print_error "Invalid selection: '$rtw_choice'"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# SYSTEM — STATUS & MODULE CHECKER
# ==============================================================================

run_status() {
    print_banner
    print_section "System Status"

    local LIMINE_CONF="/etc/default/limine"
    local CPU_CONF="/etc/bc250-smu-oc.conf"
    local GPU_CONF="/etc/cyan-skillfish-governor-smu/config.toml"
    local MKINITCPIO="/etc/mkinitcpio.conf"

    # --- System ---
    echo -e "  ${BOLD}${YELLOW}System${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"

    local OVERRIDE_FILE="/etc/plasmalogin.conf.d/zzz-bc250-boot.conf"
    local boot_session="gamescope" boot_relogin="true"
    if [[ -f "$OVERRIDE_FILE" ]]; then
        grep -q "plasma.desktop" "$OVERRIDE_FILE" && boot_session="plasma"
        grep -q "User=$" "$OVERRIDE_FILE"         && boot_relogin="false"
    fi
    local boot_mode boot_login
    [[ "$boot_session" == "gamescope" ]] \
        && boot_mode="${BOLD}${GREEN}Game Mode${RESET}" \
        || boot_mode="${BOLD}${CYAN}Desktop Mode${RESET}"
    [[ "$boot_relogin" == "false" ]] \
        && boot_login="${DIM}password required${RESET}" \
        || boot_login="${DIM}no password${RESET}"
    echo -e "  ${CYAN}Boot Mode${RESET}         ${boot_mode}  ${boot_login}"
    echo -e "  ${CYAN}Kernel${RESET}            $(uname -r)"
    echo ""

    # --- Governors ---
    echo -e "  ${BOLD}${YELLOW}Governors${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    local cpu_svc_enabled cpu_svc_result gpu_svc_state
    cpu_svc_enabled=$(systemctl is-enabled bc250-smu-oc.service 2>/dev/null || echo "disabled")
    cpu_svc_result=$(systemctl show bc250-smu-oc.service --property=ExecMainStatus --value 2>/dev/null || echo "unknown")
    gpu_svc_state=$(systemctl is-active cyan-skillfish-governor-smu.service 2>/dev/null || echo "unknown")
    local cpu_color cpu_label gpu_color
    if [[ "$cpu_svc_enabled" == "enabled" && "$cpu_svc_result" == "0" ]]; then
        cpu_color="$GREEN"; cpu_label="enabled (applied successfully)"
    elif [[ "$cpu_svc_enabled" == "enabled" ]]; then
        cpu_color="$YELLOW"; cpu_label="enabled (exit code: ${cpu_svc_result})"
    else
        cpu_color="$RED"; cpu_label="disabled"
    fi
    [[ "$gpu_svc_state" == "active" ]] && gpu_color="$GREEN" || gpu_color="$RED"
    echo -e "  ${CYAN}CPU Service${RESET}       ${cpu_color}${cpu_label}${RESET}"
    echo -e "  ${CYAN}GPU Service${RESET}       ${gpu_color}${gpu_svc_state}${RESET}"
    echo ""

    # --- Memory & Swap ---
    echo -e "  ${BOLD}${YELLOW}Memory & Swap${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    local zswap_enabled zswap_compressor zswap_pool zswap_color
    zswap_enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
    zswap_compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo "N/A")
    zswap_pool=$(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo "N/A")
    [[ "$zswap_enabled" == "Y" ]] && zswap_color="$GREEN" || zswap_color="$RED"
    echo -e "  ${CYAN}ZSWAP${RESET}              ${zswap_color}${zswap_enabled}${RESET}  compressor=${zswap_compressor}  pool=${zswap_pool}%"
    local zram_state="inactive" zram_color
    [[ -d /sys/block/zram0 ]] && zram_state="active"
    [[ "$zram_state" == "active" ]] && zram_color="$GREEN" || zram_color="$DIM"
    echo -e "  ${CYAN}ZRAM${RESET}               ${zram_color}${zram_state}${RESET}"
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "N/A")
    echo -e "  ${CYAN}Swappiness${RESET}         ${swappiness}"
    local swapfile_status
    [[ -f "/var/swap/swapfile" ]] \
        && swapfile_status="${GREEN}present${RESET}" \
        || swapfile_status="${DIM}not found${RESET}"
    echo -e "  ${CYAN}Swapfile${RESET}           ${swapfile_status}"
    echo -e "  ${CYAN}Swap Devices${RESET}"
    local swap_output
    swap_output=$(swapon --show --noheadings 2>/dev/null)
    if [[ -z "$swap_output" ]]; then
        echo -e "    ${DIM}(No active swap devices found)${RESET}"
    else
        echo "$swap_output" | while read -r name type size used prio; do
            echo -e "    ${DIM}${name}  ${type}  size=${size}  used=${used}  prio=${prio}${RESET}"
        done
    fi
    echo ""

    local overcommit overcommit_color
    overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo "N/A")
    [[ "$overcommit" == "1" ]] && overcommit_color="$GREEN" || overcommit_color="$DIM"
    echo -e "  ${CYAN}Overcommit Memory${RESET}  ${overcommit_color}${overcommit}${RESET}"
    local memlock_conf="/etc/security/limits.d/99-memlock.conf" memlock_status
    [[ -f "$memlock_conf" ]] \
        && memlock_status="${GREEN}configured${RESET} ${DIM}(unlimited, active next login)${RESET}" \
        || memlock_status="${DIM}not configured${RESET}"
    echo -e "  ${CYAN}Memlock Limit${RESET}      ${memlock_status}"
    echo ""

    # --- Disk Space ---
    echo -e "  ${BOLD}${YELLOW}Disk Space${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    local df_root df_boot
    df_root=$(df -h / | awk 'NR==2 {printf "%s used of %s (%s free)", $3, $2, $4}')
    df_boot=$(df -h /boot | awk 'NR==2 {printf "%s used of %s (%s free)", $3, $2, $4}')
    echo -e "  ${CYAN}/${RESET}                 ${df_root}"
    echo -e "  ${CYAN}/boot${RESET}             ${df_boot}"
    echo ""

    # --- Kernel Parameters ---
    echo -e "  ${BOLD}${YELLOW}Kernel Parameters${RESET}  ${DIM}(source: $LIMINE_CONF)${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    if [[ -f "$LIMINE_CONF" ]]; then
        local loglevel mitigations_off zram_disabled zswap_conf lz4_initrd
        loglevel=$(grep -o 'loglevel=[0-9]*' "$LIMINE_CONF" | head -1 || echo "not set")
        grep -q 'mitigations=off' "$LIMINE_CONF" \
            && mitigations_off="off ${RED}(vulnerable)${RESET}" \
            || mitigations_off="${GREEN}on (default)${RESET}"
        grep -q 'systemd\.zram=0' "$LIMINE_CONF" \
            && zram_disabled="${RED}disabled${RESET}" \
            || zram_disabled="${GREEN}enabled (default)${RESET}"
        grep -q 'zswap\.enabled=1' "$LIMINE_CONF" \
            && zswap_conf="${GREEN}enabled${RESET}" \
            || zswap_conf="${DIM}not set${RESET}"
        grep -q 'lz4' "$MKINITCPIO" 2>/dev/null \
            && lz4_initrd="${GREEN}yes${RESET}" \
            || lz4_initrd="${DIM}no${RESET}"
        echo -e "  ${CYAN}loglevel${RESET}          ${loglevel}"
        echo -e "  ${CYAN}Mitigations${RESET}       ${mitigations_off}"
        echo -e "  ${CYAN}ZRAM (cmdline)${RESET}    ${zram_disabled}"
        echo -e "  ${CYAN}ZSWAP (cmdline)${RESET}   ${zswap_conf}"
        echo -e "  ${CYAN}lz4 in initramfs${RESET}  ${lz4_initrd}"
    else
        echo -e "  ${RED}$LIMINE_CONF not found${RESET}"
    fi
    echo ""

    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

run_module_checker() {
    while true; do
        print_banner
        print_section "Module Configuration Checker"

        # --- /etc/modules-load.d/ ---
        echo -e "  ${BOLD}${YELLOW}/etc/modules-load.d/${RESET}  ${DIM}(modules loaded at boot)${RESET}"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
        local load_files
        load_files=$(ls /etc/modules-load.d/*.conf 2>/dev/null)
        if [[ -z "$load_files" ]]; then
            echo -e "  ${DIM}(no .conf files found)${RESET}"
        else
            for f in $load_files; do
                echo -e "  ${CYAN}$(basename "$f")${RESET}"
                while IFS= read -r line; do
                    [[ -z "$line" || "$line" == \#* ]] && continue
                    if lsmod | awk -v mod="$line" '$1==mod {found=1} END{exit !found}' 2>/dev/null; then
                        echo -e "    ${GREEN}▸ ${line}${RESET}  ${DIM}(loaded)${RESET}"
                    else
                        echo -e "    ${DIM}▸ ${line}  (not loaded)${RESET}"
                    fi
                done < "$f"
            done
        fi
        echo ""

        # --- /etc/modprobe.d/ ---
        echo -e "  ${BOLD}${YELLOW}/etc/modprobe.d/${RESET}  ${DIM}(module options & blacklists)${RESET}"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
        local probe_files
        probe_files=$(ls /etc/modprobe.d/*.conf 2>/dev/null)
        if [[ -z "$probe_files" ]]; then
            echo -e "  ${DIM}(no .conf files found)${RESET}"
        else
            for f in $probe_files; do
                echo -e "  ${CYAN}$(basename "$f")${RESET}"
                while IFS= read -r line; do
                    [[ -z "$line" || "$line" == \#* ]] && continue
                    if [[ "$line" == blacklist* ]]; then
                        echo -e "    ${RED}▸ ${line}${RESET}"
                    else
                        echo -e "    ${MAGENTA}▸ ${line}${RESET}"
                    fi
                done < "$f"
            done
        fi
        echo ""

        # --- NCT6683 Blacklist Status ---
        echo -e "  ${BOLD}${YELLOW}NCT6683 Blacklist${RESET}"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
        if [[ -f "/etc/modprobe.d/nct6683.conf" ]] && grep -q 'blacklist nct6683' /etc/modprobe.d/nct6683.conf; then
            echo -e "  ${GREEN}▸ blacklisted${RESET}  ${DIM}(/etc/modprobe.d/nct6683.conf)${RESET}"
        else
            echo -e "  ${DIM}▸ not blacklisted${RESET}"
        fi
        if lsmod | awk '$1=="nct6683" {found=1} END{exit !found}' 2>/dev/null; then
            echo -e "  ${MAGENTA}▸ nct6683 is currently loaded${RESET}  ${DIM}(reboot to apply blacklist)${RESET}"
        else
            echo -e "  ${DIM}▸ nct6683 not loaded${RESET}"
        fi
        echo ""

        # --- WirePlumber DP Audio Fix Status ---
        echo -e "  ${BOLD}${YELLOW}DisplayPort Audio Fix${RESET}  ${DIM}(WirePlumber)${RESET}"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
        local wp_dir="/home/$REAL_USER/.config/wireplumber/wireplumber.conf.d"
        local f51="$wp_dir/51-disable-suspension.conf"
        local f54="$wp_dir/54-force-sync.conf"
        if [[ -f "$f51" ]]; then
            echo -e "  ${GREEN}▸ 51-disable-suspension.conf${RESET}  ${DIM}present${RESET}"
        else
            echo -e "  ${DIM}▸ 51-disable-suspension.conf  missing${RESET}"
        fi
        if [[ -f "$f54" ]]; then
            echo -e "  ${GREEN}▸ 54-force-sync.conf${RESET}  ${DIM}present${RESET}"
        else
            echo -e "  ${DIM}▸ 54-force-sync.conf  missing${RESET}"
        fi
        if [[ -f "$f51" && -f "$f54" ]]; then
            echo -e "  ${GREEN}▸ DP audio fix fully applied${RESET}"
        elif [[ -f "$f51" || -f "$f54" ]]; then
            echo -e "  ${YELLOW}▸ DP audio fix partially applied — one file missing${RESET}"
        else
            echo -e "  ${DIM}▸ DP audio fix not installed${RESET}"
        fi
        echo ""

        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
        print_item  "S"  "Show Raw Files"  "ls all files inside the config directories"
        print_item  "0"  "Back"            "Return to main menu"
        echo ""
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" mc_choice

        case "${mc_choice^^}" in
            S)
                print_banner
                print_section "Raw File Listing"

                local dirs=(
                    "/etc/modules-load.d"
                    "/etc/modprobe.d"
                    "/home/$REAL_USER/.config/wireplumber/wireplumber.conf.d"
                )

                for dir in "${dirs[@]}"; do
                    echo -e "  ${BOLD}${YELLOW}${dir}/${RESET}"
                    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
                    if [[ -d "$dir" ]]; then
                        local files
                        files=$(ls -1A "$dir" 2>/dev/null)
                        if [[ -z "$files" ]]; then
                            echo -e "  ${DIM}(empty)${RESET}"
                        else
                            while IFS= read -r fname; do
                                echo -e "  ${CYAN}▸${RESET} ${fname}"
                            done <<< "$files"
                        fi
                    else
                        echo -e "  ${DIM}(directory does not exist)${RESET}"
                    fi
                    echo ""
                done

                echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
                print_item "0" "Back" "Return to Module Checker"
                echo ""
                read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" _back
                ;;
            0) return ;;
            *)
                print_error "Invalid selection: '$mc_choice'"
                sleep 1
                ;;
        esac
    done
}

run_revert_swap() {
    print_step "R-0" "Revert Swap — Removing swapfile and resetting swappiness"

    if ! confirm "This will disable and remove the swapfile, delete the Btrfs subvolume, remove the fstab entry, and reset swappiness to default (60). Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    if swapon --show | grep -q '/var/swap/swapfile'; then
        print_info "Disabling swapfile..."
        swapoff /var/swap/swapfile || { print_error "Failed to disable swapfile."; return 1; }
        print_info "Swapfile disabled."
    else
        print_info "Swapfile not active — skipping swapoff."
    fi

    if [[ -f "/var/swap/swapfile" ]]; then
        print_info "Removing swapfile..."
        rm -f /var/swap/swapfile
        print_info "Swapfile removed."
    else
        print_info "Swapfile not found — skipping."
    fi

    if btrfs subvolume show /var/swap &>/dev/null; then
        print_info "Deleting Btrfs subvolume /var/swap..."
        btrfs subvolume delete /var/swap || { print_error "Failed to delete subvolume."; return 1; }
        print_info "Subvolume deleted."
    else
        print_info "/var/swap subvolume not found — skipping."
    fi

    if grep -q '/var/swap/swapfile' /etc/fstab; then
        print_info "Removing swapfile entry from /etc/fstab..."
        sed -i '/\/var\/swap\/swapfile/d' /etc/fstab
        print_info "fstab entry removed."
    else
        print_info "No swapfile entry in /etc/fstab — skipping."
    fi

    if [[ -f "/etc/sysctl.d/99-swappiness.conf" ]]; then
        print_info "Removing swappiness config..."
        rm -f /etc/sysctl.d/99-swappiness.conf
        sysctl vm.swappiness=60 > /dev/null
        print_info "Swappiness reset to default (60)."
    else
        print_info "No swappiness config found — skipping."
    fi

    print_success "Swap reverted. Reboot recommended."
}

# ==============================================================================
# REVERT MENU
# ==============================================================================

show_revert_menu() {
    print_banner
    print_section "Revert / Undo"
    echo -e "  ${DIM}Undo previously applied settings and restore defaults.${RESET}\n"
    print_item "1" "Revert CPU Governor" "Disable and remove bc250-smu-oc service"
    print_item "2" "Revert GPU Governor" "Disable and remove cyan-skillfish-governor-smu"
    print_item "3" "Revert Swap"         "Disable swapfile, remove subvolume & reset swappiness"
    print_item "4" "Revert ZSWAP"        "Remove zswap params & re-enable ZRAM"
    print_item "5" "Revert loglevel"     "Restore loglevel to default (3)"
    print_item "6" "Revert Mitigations"  "Re-enable CPU security mitigations"
    print_item "7" "Revert Overcommit/Memlock" "Remove overcommit & memlock configs"
    echo ""
    print_item "0" "Back"                "Return to main menu"
    echo ""
    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

run_revert_menu() {
    while true; do
        show_revert_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" rev_choice
        case "${rev_choice^^}" in
            1) run_revert_cpu_governor; press_enter ;;
            2) run_revert_gpu_governor; press_enter ;;
            3) run_revert_swap;         press_enter ;;
            4) run_revert_zswap;        press_enter ;;
            5) run_revert_loglevel;     press_enter ;;
            6) run_revert_mitigations;  press_enter ;;
            7) run_revert_overcommit_memlock; press_enter ;;
            0) return ;;
            *)
                print_error "Invalid selection: '$rev_choice'"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

show_menu() {
    print_banner
    print_section "Setup Tasks"
    print_item  "1"  "CPU Governor"        "bc250-smu-oc CPU overclock service"
    print_item  "2"  "GPU Governor"        "cyan-skillfish GPU governor service"
    print_item  "3"  "CU Live Manager"     "Compute Units Live Manager by WinnieLV"
    echo ""
    print_section "Limine Configuration"
    print_item  "4"  "Enable Swap"         "16G Btrfs swapfile, swappiness=180"
    print_item  "5"  "ZRAM -> ZSWAP"       "Disable ZRAM, enable ZSWAP w/ lz4"
    print_item  "6"  "Hide RDSEED Warning" "Set loglevel=0 in /boot/limine.conf"
    print_item  "7"  "Disable Mitigations" "Add mitigations=off to limine.conf"
    print_item  "8"  "Overcommit/Memlock"  "vm.overcommit_memory=1 & unlimited memlock"
    echo ""
    print_section "Revert / Undo"
    print_item  "R"  "Revert Menu"         "Undo previously applied settings"
    echo ""
    print_section "Additional Tools"
    print_item  "B"  "Toggle Boot Mode"    "Switch between Game Mode & Desktop"
    print_item  "N"  "NCT Menu"            "NCT6687 sensor driver management"
    print_item  "I"  "I2C Menu"            "isl69247 sensor driver management"
    print_item  "D"  "DP Audio Fix"        "Fix DisplayPort audio delay via WirePlumber"
    print_item  "W"  "Realtek WiFi USB"    "RTL88x2BU driver — install, upgrade, uninstall"
    print_item  "L"  "Power & Sleep"       "Deck + Desktop: shutdown power button, disable sleep/screen"
    echo ""
    print_section "System"
    print_item  "S"  "Status"              "Current system summary"
    print_item  "M"  "Module Checker"      "View current module, driver, and WirePlumber configuration"
    print_item  "0"  "Exit"                ""
    echo ""
    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

while true; do
    show_menu
    read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" choice

    case "${choice^^}" in
        1) run_cpu_governor;              press_enter ;;
        2) run_gpu_governor;              press_enter ;;
        3) run_cu_live_manager;           press_enter ;;
        4) run_enable_swap;               press_enter ;;
        5) run_disable_zram_enable_zswap; press_enter ;;
        6) run_set_loglevel;              press_enter ;;
        7) run_disable_mitigations;       press_enter ;;
        8) run_overcommit_memlock;        press_enter ;;
        R) run_revert_menu ;;
        B) run_toggle_boot_mode;          press_enter ;;
        N) run_nct_menu ;;
        I) run_i2c_menu ;;
        D) run_audio_fix;                 press_enter ;;
        W) run_realtek_wifi_menu ;;
        L) run_power_sleep_menu ;;
        S) run_status;                    press_enter ;;
        M) run_module_checker ;;
        0)
            echo -e "\n  ${DIM}Reboot recommended if you applied any system changes!${RESET}\n"
            exit 0
            ;;
        *)
            print_error "Invalid selection: '$choice'"
            sleep 1
            ;;
    esac
done
