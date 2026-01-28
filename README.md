# DrapBox (Beta)

DrapBox is an **Arch Linux installation script** that transforms a standard **x86_64 PC** into a **living-room appliance**, mixing the experience of **Apple TV × Google TV**.

It provides:
- Android TV (via Waydroid – GApps or Vanilla)
- AirPlay receiver (UxPlay, always-on, PIN pairing)
- Miracast receiver (Android / Windows screen casting)
- Minimal Wayland environment (no traditional desktop)
- Fullscreen, TV-like UX

This project is currently in **beta** and uses a **modular, repo-based installer**.

---

## ⚠️ Important warnings

> [!CAUTION]  
> **This installer will ERASE the selected disk entirely.**  
> All existing data will be permanently lost.

> [!WARNING]  
> This is **not a beginner-friendly installer**.  
> You are expected to know:
> - how to boot an Arch ISO in UEFI mode
> - how to connect to the internet from the Arch live environment
> - how to use a terminal if something goes wrong

---

## ✨ Features

- **Android TV (Waydroid)**
  - Android 13 (LineageOS-based)
  - GApps **or** Vanilla (no Google) build
  - Widevine L3 support
- **AirPlay**
  - Always-on receiver (UxPlay)
  - Hostname-based device name
  - 4-digit PIN shown on screen (Apple TV–style)
- **Miracast**
  - Screen casting from Android & Windows
- **Minimal UI**
  - Wayland + Sway
  - No panels, no desktop clutter
  - Only Android TV and casting surfaces visible
- **Appliance mode**
  - Optional auto-login
  - Fast boot with systemd-boot + Plymouth
- **Local control panel**
  - “Host Actions” web UI (restart services, reboot, settings, etc.)

---

## 📦 Requirements

### Hardware
- x86_64 PC
- **UEFI firmware** (legacy BIOS is not supported)
- Intel or AMD GPU (iGPU recommended)
- Wi-Fi adapter with **Wi-Fi Direct** support (required for Miracast)
- Minimum **20 GB** of storage (more recommended)

### Software
- Arch Linux ISO (official)
- Internet connection during installation

---

## 🚀 Installation

1. Boot the **Arch Linux ISO** in **UEFI mode**
2. Connect to the internet (Ethernet or Wi-Fi)
3. Make sure `curl` is available
4. Run the installer:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DrapNard/DrapBox/refs/heads/main/install.sh)
````

The installer will guide you through:

* Disk selection and formatting
* Locale, timezone, keyboard
* Android TV variant (GApps or Vanilla)
* Swap configuration
* Appliance options (auto-login, casting behavior)

---

## 🔄 Updates (without reinstall)

The installed system keeps its scripts in `/usr/lib/drapbox`.  
To refresh them later without re-imaging the machine:

```bash
sudo drapbox-update
```

This fetches the latest repo scripts (firstboot + chroot helpers).

## 🧪 Project status

* **Status:** Beta
* **Installer:** Modular scripts (split into installer + firstboot modules)
* **Target use:** Personal / experimental / appliance builds
* **Stability:** Good, but expect rough edges

Current layout includes:

* `installer/` — modular installer flow + chroot config
* `firstboot/` — firstboot wizard and overlay menu modules
* `scripts/` — maintenance helpers (e.g., update)

---

## 🛠 Disclaimer

This project is provided **as-is**, without warranty.
Use it at your own risk.
Not affiliated with Google, Apple, or the Android TV project.

---

## 🙏 Special Thanks

This project would not be possible without the work and contributions of the open-source community.

Special thanks to:

- **supechicken**  
  For the **Waydroid Android TV builds** used as the base for DrapBox’s Android TV experience  
  (LineageOS Android TV, GApps/Vanilla variants, Widevine L3 support).  
  👉 https://github.com/supechicken/waydroid-androidtv-build

Additional thanks to the developers and maintainers of:
- Waydroid
- UxPlay
- PipeWire / WirePlumber
- Arch Linux
- The Android Open Source Project (AOSP)

If you believe your work should be credited here, feel free to open an issue or pull request.

---

## 📄 License

MIT (unless stated otherwise in specific components)
