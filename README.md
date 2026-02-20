# InternetRadioServer
Automated script for installing and configuring internet radio server such as Raspberry Pi or any Linux server

A lightweight Linux radio player that automatically starts at boot using `mpv` and `systemd`.

It reads stream configuration from `conf/radio.json` and plays audio using ALSA.

---

## Requirements

- Debian / Ubuntu based system
- systemd
- Internet connection
- Root access (sudo)

---

# Setup

## Using wget

```bash
wget -qO- https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/refs/heads/main/install.sh | sudo bash

## Using curl
```bash
curl -fsSL https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/refs/heads/main/install.sh | sudo bash
