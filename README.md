# Ultimate Linux Setup (for humans)

An overview of my Linux setup: distro, desktop environment, system tooling, and a few handcrafted pieces of software to fill the gaps left by commercial ecosystems.

- **Base Distro:** Ubuntu Desktop 26.04 LTS
- **DE:** GNOME (but I'm thinking to swith to Hyprland + Niri + Dank)

---

## Core Features

- **Kernel:**
  - Optimized for x86_v3 and LTO
  - 7.1 to have out of the box:
    - Low-Latency Preemptive Kernel
    - 1000 Hz timer, idle tickless, -O3 optimization
    - Built with gcc and '-march=native' optimizations.
  - patches:
    - AMD P-State driver
    - BMQ Scheduler
    - BBR3 TCP congestion control
    - Multi-generational LRU
    - Adaptive Deadline I/O Scheduler (ADIOS)
    - CachyOS patches
    - Lucjan patches
    - Xanmod patches
    - PF-kernel patches
    - FUTEX Proton/Wine Fsync support
    - NT sync primitives emulation driver
    - Steamdeck/Valve patches
    - Graysky GCC optimizations
    - Various arch patches
    - IO scheduler patches
    - AUFS support
    - VirtualBox support
    - Compiled with LLVM/Clang instead of GCC
- **Scheduler:** BORE (better for desktop)
- **Filesystem:** BTRFS
- **Swap/RAM compression:** zram
- **Boot manager:** Limine (supports snapper and BTRFS)

---

## Backups

- **System snapshots:** snapper + grub-btrfs (select snapshot at boot) + btrfs-assistant (GUI)
- **User file backups (Time Machine like):** restic + Déjà Dup (GUI)

---

## System Features

- Wake on USB/Bluetooth

---

## Universal Clipboard

**ClipSync** — handcrafted shared clipboard across my devices.

![ClipSync](images/clipsync.png)

- Repo: [https://github.com/antoniopicone/clipsync/](https://github.com/antoniopicone/clipsync/)

---

## Security

- **Disk encryption:** LUKS with TPM2 unlock
- **Face recognition unlock:** Howdy
- **USBGuard** to prevent auto-mounting of USB devices, with a fork of USBGuard notifier for dedicated notification

  ![USBGuard notifier](images/usbguard-notifier.png)

  - Setup script [gist](https://gist.github.com/antoniopicone/2c2e8c005f421a432110100cec6bbb3a#file-setup-usbguard-sh)
  - USBGuard Notifier fork [https://github.com/antoniopicone/usbguard-notifier](https://github.com/antoniopicone/usbguard-notifier)

- **Password manager: Pass** (handcrafted) — also available as a Chrome/Brave extension

  ![Pass — Chrome extension](images/pass___chrome_extension.png)

  - Repo: [https://github.com/antoniopicone/pass/](https://github.com/antoniopicone/pass/)

---

## Applications

- **Terminal:** zsh on Ghostty
- **Resource viewer:** Resources (by nokyan, on Software)
- **Markdown editor:** Zennotes (extracted from squashfs-root + created a .desktop file)
- **Email: Melia / Mailview** (handcrafted)

  ![Mailview](images/mailview.png)

  - Repo: [https://github.com/antoniopicone/email](https://github.com/antoniopicone/email)

- **Reading List / Bookmarks: Karakeep**, with a dedicated handcrafted sidebar for Chromium/Brave

  ![Karakeep — reading list Chromium extension](images/karakeep-reading_list_chromium_extension.png)

  - Repo: [https://github.com/antoniopicone/karakeep-browser-extension](https://github.com/antoniopicone/karakeep-browser-extension)

- **Browser:** Chromium / Brave with extensions:
  - Karakeep sidebar (handcrafted)
  - Pass (handcrafted)

---

## Tweaks / Fixes

- **Oversaturation: Display Color Correction** (handcrafted GNOME extension), with per-monitor configuration

  ![Display Color Correction](images/display-color-correction.png)

  - Repo: [https://github.com/antoniopicone/gnome-display-color-correction-extension](https://github.com/antoniopicone/gnome-display-color-correction-extension)

  - Published on [Gnome Extensions](https://extensions.gnome.org/extension/10321/display-color-correction/)

--- 

- **Wake on USB** (gist): https://gist.github.com/antoniopicone/812fab59aba535a70e8ed3258b479534
- **Touchpad scrolling:** Wayland Scroll Factor (0.18 vertical scroll)
- **Icon set:** Yaru (Prussian Green Dark), installed via `yay -S yaru-icon-theme`

---

## Services

- Tailscale
- Podman
- Avahi-daemon
- restic
- USBGuard
