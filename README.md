# Pi Easy Connect

**One command to share your Windows PC's internet with any Linux device over an Ethernet cable — and SSH straight into it.**

Works out of the box with **Raspberry Pi, Orange Pi, Jetson, BeagleBone, VMs and every Linux machine with a network port**. No router, no extra hardware, no device-side configuration: Windows Internet Connection Sharing (ICS) turns your PC into a bridge with its own DHCP server, and the script finds the device and opens SSH for you.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue.svg)](https://learn.microsoft.com/en-us/windows/win32/api/netcon/nn-netcon-inetsharingconfiguration)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](https://learn.microsoft.com/en-us/powershell/)

---

## Why this script

Setting up a Raspberry Pi or Orange Pi without internet is painful: no Wi-Fi credentials, no router port free, no monitor handy. **Pi Easy Connect** fixes the two classic problems:

1. **Give the device internet** — the PC shares its own connection (Wi-Fi, Ethernet, 4G/5G dongle, hotspot) to the device over a simple Ethernet cable using Windows ICS.
2. **Reach it via SSH** — the script discovers the device on the `192.168.137.x` subnet (ping sweep + ARP/neighbor cache) and opens an SSH session for you.

The whole point is **ease of use**: plug the cable, run one command, confirm, done.

## Features

- ⚡ **Zero device configuration** — the device gets an IP from ICS's built-in DHCP server automatically.
- 🧭 **No adapter guessing** — the internet source is detected from the IPv4 **default route**, not from adapter names.
- 🛡️ **Safe by design** — verifies the host still has internet *before and after* activation; on any problem it **auto-rolls back** to the previous state.
- 🧹 **Self-healing** — cleans the stale ICS state (`0x80040201` issue) left behind by interrupted runs, in the WMI namespace and in the registry.
- 🔁 **Resilient** — restarts the `SharedAccess` service and retries once if the first activation fails.
- 🧩 **General purpose** — any Linux box, any SSH user (`-SshUser`), even devices with a **static IP** (`-StaticIp`).
- 🧽 **Clean shutdown** — `-Undo` disables sharing, restores DHCP and clears leftovers.

## How it works

```
        Internet (Wi-Fi / Ethernet / hotspot)
                      │
                ┌─────▼─────┐
                │  Windows  │   ← ICS "public" adapter (keeps its IP)
                │    PC      │
                └─────┬─────┘
                      │  Ethernet cable
                ┌─────▼─────┐
                │  Device    │   ← ICS "private" adapter: 192.168.137.1/24 + DHCP
                │ (Linux)    │      device gets e.g. 192.168.137.148 by itself
                └────────────┘
                      │
                 SSH: orangepi@192.168.137.148
```

Under the hood it uses the official **HNetCfg COM API** (`INetSharingConfiguration::EnableSharing`) with the documented constants `ICSSHARINGTYPE_PUBLIC = 0` / `ICSSHARINGTYPE_PRIVATE = 1` (the inverted constants are the reason many home-made ICS scripts kill the host's internet).

## Requirements

- Windows 10 or Windows 11 (PowerShell 5.1+, run as Administrator — the script self-elevates)
- One free Ethernet port on the PC (onboard or USB-Ethernet adapter)
- An Ethernet cable
- A Linux device with SSH server enabled (`openssh-server`)

## Quick start

```powershell
# 1. Connect the Ethernet cable between the PC and the device, power the device on.
# 2. Run (from the project folder):
.\pi-easy-connect.ps1

# 3. Confirm the plan, wait for discovery, then type the device password in SSH.
```

That's it. The device gets internet and you land in its shell.

**SSH session:** by default the script hands over to the native OpenSSH client and the **device asks you for the credentials**. If `ssh.exe` is not available on the system (or you prefer a module-based session), add `-UseSshModule`: the script **auto-installs Posh-SSH** (user scope, no admin) and prompts for the credentials with a secure dialog, then gives you an interactive remote shell (type `exit` to close it).

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-SshUser <user>` | `orangepi` | SSH user of the target device (e.g. `pi` for Raspberry Pi OS) |
| `-StaticIp <ip>` | *(empty)* | Known static IP of the device — checked first, no sweep needed |
| `-DiscoveryTimeoutSec <n>` | `120` | How long to search the `192.168.137.x` subnet |
| `-UseSshModule` | off | Use the Posh-SSH module for the SSH session (auto-installed if missing) instead of the native OpenSSH client |
| `-ProbeHost <host>` | `1.1.1.1` | Host used to check the host PC's internet before/after activation |
| `-Force` | off | Skip the interactive confirmation |
| `-Undo` | off | Disable ICS, restore DHCP and clean leftovers |

## Recommend a static IP on the device

The ICS DHCP lease can change between reboots. Give the device a fixed address so every connection is deterministic:

```bash
# On the device (NetworkManager / Raspberry Pi OS, Armbian, Orange Pi OS...):
nmcli con mod "Wired connection 1" ipv4.method manual \
  ipv4.addresses 192.168.137.100/24 \
  ipv4.gateway 192.168.137.1 \
  ipv4.dns "192.168.137.1 1.1.1.1"
nmcli con up "Wired connection 1"
```

Then connect instantly with `.\pi-easy-connect.ps1 -StaticIp 192.168.137.100`.

## Troubleshooting

**"Error enabling ICS: an event was unable to invoke any of the subscribers (0x80040201)"**
Leftover ICS state from interrupted runs (dead adapters still flagged public/private in `root\Microsoft\HomeNet`). The script cleans it automatically on every run; a manual cleanup is the same operation `icsmanager` performs — resetting the `IsIcsPublic`/`IsIcsPrivate` flags.

**"Device not found within the timeout"**
- The ICS DHCP server can take a minute to start serving after a service restart — increase patience with `-DiscoveryTimeoutSec 300`.
- Make sure the device uses **DHCP** and its Ethernet interface is up.
- If the device has a static IP, pass it with `-StaticIp`.
- The script stays active: ICS keeps running, so the device already has internet — check the ARP table printed at the end.

**"The device has internet but I can't SSH"**
Install/enable `openssh-server` on the device (`sudo apt install openssh-server`) and pass the right user with `-SshUser`.

## Reference

- `SHARINGCONNECTIONTYPE` (netcon.h) — `ICSSHARINGTYPE_PUBLIC = 0`, `ICSSHARINGTYPE_PRIVATE = 1`: [Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/netcon/ne-netcon-sharingconnectiontype)
- `INetSharingConfiguration::EnableSharing` / `DisableSharing`: [Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/netcon/nn-netcon-inetsharingconfiguration)
- KB4055559 — ICS service behavior: [Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/ics-not-work-after-computer-or-service-restart)

## License

MIT — see [LICENSE](LICENSE).

---

*Windows Internet Connection Sharing, ICS, Ethernet bridge, Raspberry Pi, Orange Pi, single-board computer, SSH, PowerShell script, share internet from PC to Linux device over Ethernet.*
