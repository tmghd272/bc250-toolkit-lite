# bc250-toolkit-lite

Setup script for the BC250 on CachyOS.

A lightweight version of the BC250 Toolkit that focuses on installing essential drivers, fixes, and utilities. The overclock menu has been removed.

### **You must be using the Limine bootloader for all functions in this script to work properly.**

Please use with caution.

## Features

1. **CPU Governor** – Installs `bc250_smu_oc` by [bc250-collective](https://github.com/bc250-collective/bc250_smu_oc/)
2. **GPU Governor** – Installs `cyan-skillfish-governor-smu` by [filippor](https://github.com/filippor/cyan-skillfish-governor)
3. **CU Live Manager** – Launches the Compute Units Live Manager (`bc250-cu-live-manager.sh`) by [WinnieLV](https://github.com/WinnieLV/bc250-cu-live-manager)
4. **Enable Swap** – Creates a dedicated swap file used as virtual memory
5. **Hide RDSEED Warning** – Hides the RDSEED warning message shown during boot
6. **Enable ZSWAP** – Enables compressed RAM caching for swapped memory pages
7. **Disable Mitigations** – Improves CPU performance at the cost of reduced security
8. **Toggle Boot Mode** – Switches CachyOS Deckify between Steam Gaming Mode and KDE Plasma Desktop Mode
9. **NCT Menu** – Manage the NCT6687 sensor driver. Install or uninstall the driver and optionally blacklist the in-kernel `nct6683` driver. The NCT6687 driver provides fan control support that is unavailable with the stock driver.
10. **DP Audio Fix** – Fixes DisplayPort audio wake-up delay using WirePlumber
11. **Realtek WiFi USB** – Installs the RTL88x2BU DKMS driver by [RinCat](https://github.com/RinCat/RTL88x2BU-Linux-Driver), which generally provides better support than the stock in-kernel driver
12. **Status Menu** – Displays current Limine settings and the installation status of CPU/GPU governors and drivers

## Usage

In Desktop Mode, run the following command in Konsole:

```
curl -sSLO https://raw.githubusercontent.com/tmghd272/bc250-toolkit/main/bc250-toolkit-lite.sh && chmod +x bc250-toolkit-lite.sh && ./bc250-toolkit-lite.sh
```

```

  ╔══════════════════════════════════════════════════════════════╗
  ║                                                              ║
  ║                 CachyOS BC250 Toolkit Lite                   ║
  ║              Kernel: {kernel}-cachyos-deckify                ║
  ║                                                              ║
  ╚══════════════════════════════════════════════════════════════╝

  Setup Tasks
  ──────────────────────────────────────────────────────────────
  [ 1]  CPU Governor        bc250-smu-oc CPU overclock service
  [ 2]  GPU Governor        cyan-skillfish GPU governor service
  [ 3]  CU Live Manager     Compute Units Live Manager by WinnieLV

  Limine Configuration
  ──────────────────────────────────────────────────────────────
  [ 4]  Enable Swap         16G Btrfs swapfile, swappiness=180
  [ 5]  ZRAM -> ZSWAP       Disable ZRAM, enable ZSWAP w/ lz4
  [ 6]  Hide RDSEED Warning Set loglevel=0 in /boot/limine.conf
  [ 7]  Disable Mitigations Add mitigations=off to limine.conf

  Revert / Undo
  ──────────────────────────────────────────────────────────────
  [ R]  Revert Menu         Undo previously applied settings

  Additional Tools
  ──────────────────────────────────────────────────────────────
  [ B]  Toggle Boot Mode    Switch between Game Mode & Desktop
  [ N]  NCT Menu            NCT6687 sensor driver management
  [ D]  DP Audio Fix        Fix DisplayPort audio delay via WirePlumber
  [ W]  Realtek WiFi USB    RTL88x2BU driver — install, upgrade, uninstall

  System
  ──────────────────────────────────────────────────────────────
  [ S]  Status              Current system summary
  [ M]  Module Checker      View /etc/modules-load.d/ & /etc/modprobe.d/
  [ 0]  Exit

  ══════════════════════════════════════════════════════════════
...
...

