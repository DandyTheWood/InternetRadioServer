# 🎵 InternetRadioServer

Automated script for installing and configuring an internet radio player on a Raspberry Pi or any Linux server.

This project installs a lightweight radio player that automatically starts at boot using `mpv` and `systemd`.

The stream configuration is stored in:

```

conf/radio.json

````

Audio playback uses ALSA by default.

---

## ✅ Requirements

- Debian / Ubuntu based system
- systemd
- Internet connection
- Root access (sudo)

---

# 🚀 Setup

## Using wget

```bash
wget -qO- https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/main/install.sh | sudo bash
````

## Using curl

```bash
curl -fsSL https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/main/install.sh | sudo bash
```

---

# ⚙ Configuration

After installation, edit:

```bash
sudo nano /opt/radio-player/conf/radio.json
```

Example:

```json
{
  "url": "https://your-radio-stream-url",
  "amixer_dev": "Master"
}
```

To find your ALSA device:

```bash
amixer scontrols
```

---

# 🔄 Service Management

Start:

```bash
sudo systemctl start radio.service
```

Stop:

```bash
sudo systemctl stop radio.service
```

Restart:

```bash
sudo systemctl restart radio.service
```

Check status:

```bash
sudo systemctl status radio.service
```

View logs:

```bash
journalctl -u radio.service -f
```

---

# 📂 Installation Locations

Project directory:

```
/opt/radio-player
```

Systemd service file:

```
/etc/systemd/system/radio.service
```

---

# 🗑 Uninstall

```bash
sudo systemctl stop radio.service
sudo systemctl disable radio.service
sudo rm /etc/systemd/system/radio.service
sudo rm -rf /opt/radio-player
sudo userdel radiox
sudo systemctl daemon-reload
```

---

# 🔐 Security Notice

Piping remote scripts directly into `bash` is convenient but not always secure.

If preferred, download and inspect first:

```bash
wget https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/main/install.sh
cat install.sh
sudo bash install.sh
```
