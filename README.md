# InternetRadioServer

InternetRadioServer is a lightweight internet radio player designed for Raspberry Pi, Debian, Ubuntu, and other Linux systems using systemd.

The project uses [mpv](https://mpv.io/) for audio playback and a systemd user service to keep the radio player running automatically.

The installer provides an interactive setup where you can configure the radio stream URL, station name, and initial volume during installation.

## Features

* Lightweight internet radio playback
* Interactive installation
* Configurable radio stream URL
* Configurable station name
* Configurable initial volume
* Automatic service restart if the player exits
* Automatic startup through systemd
* Optional operation without an active login session
* Configuration stored in JSON
* Playback through mpv and ALSA
* Suitable for Raspberry Pi and Linux servers

## Requirements

* Debian or Ubuntu-based Linux distribution
* systemd
* Internet connection
* A working audio output device
* `sudo` access

The installer automatically installs the required packages:

* [mpv](https://mpv.io/) - media player and audio playback
* [ALSA](https://www.alsa-project.org/) utilities - Linux audio configuration
* [jq](https://jqlang.github.io/jq/) - JSON processing
* [curl](https://curl.se/) - downloading project files

## Installation

The recommended method is to download the installer, inspect it, and then execute it.

### Download with curl

```bash
curl -fSL https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/main/install.sh -o install.sh
```

### Download with wget

```bash
wget https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/main/install.sh
```

Review the installer before executing it:

```bash
less install.sh
```

Then run:

```bash
bash install.sh
```

The installer will request the following information:

```text
Radio stream URL:
Radio station name:
Initial volume:
```

For example:

```text
Radio stream URL: https://example.com/radio.mp3
Radio station name: My Radio
Initial volume: 70
```

The installer then creates the configuration and systemd service and starts the radio player.

## Configuration

The configuration file is located at:

```text
~/InternetRadioServer/conf/radio.json
```

Example:

```json
{
    "station_name": "My Radio",
    "stream_url": "https://example.com/radio.mp3",
    "volume": 70
}
```

### Configuration options

| Option         | Description                           |
| -------------- | ------------------------------------- |
| `station_name` | Name displayed in the service logs    |
| `stream_url`   | URL of the internet radio stream      |
| `volume`       | Initial playback volume from 0 to 100 |

After changing the configuration, restart the service:

```bash
systemctl --user restart radio.service
```

## Finding an Audio Device

The project uses mpv for playback and normally uses the system's default audio output.

To inspect available ALSA controls:

```bash
amixer scontrols
```

To inspect available playback devices:

```bash
aplay -l
```

If your Raspberry Pi or Linux system does not produce sound, verify that the correct audio output is configured at the operating-system level before modifying the radio player.

## Service Management

InternetRadioServer runs as a systemd user service.

### Start

```bash
systemctl --user start radio.service
```

### Stop

```bash
systemctl --user stop radio.service
```

### Restart

```bash
systemctl --user restart radio.service
```

### Check status

```bash
systemctl --user status radio.service
```

### Follow live logs

```bash
journalctl --user -u radio.service -f
```

### View recent logs

```bash
journalctl --user -u radio.service -n 100 --no-pager
```

### Check whether the service is enabled

```bash
systemctl --user is-enabled radio.service
```

### Check whether the service is running

```bash
systemctl --user is-active radio.service
```

## Automatic Startup

The installer enables the service using systemd:

```bash
systemctl --user enable radio.service
```

It also enables systemd user lingering:

```bash
sudo loginctl enable-linger "$USER"
```

This allows the user systemd instance to operate without requiring an interactive login session.

## Installation Locations

The default installation directory is:

```text
~/InternetRadioServer
```

The project files are organized as follows:

```text
~/InternetRadioServer/
├── conf/
│   └── radio.json
└── src/
    └── radio.sh
```

The systemd service is stored at:

```text
~/.config/systemd/user/radio.service
```

## Troubleshooting

### Service will not start

Check the service status:

```bash
systemctl --user status radio.service
```

Then inspect the logs:

```bash
journalctl --user -u radio.service -n 100 --no-pager
```

### Check mpv

Verify that mpv is installed:

```bash
mpv --version
```

### Check the radio stream

Test the stream URL independently:

```bash
curl -I "https://your-radio-stream-url"
```

Some streaming servers do not respond correctly to HTTP `HEAD` requests. In that case, a failed `curl -I` test does not necessarily mean the stream is unavailable.

You can also test the stream directly with mpv:

```bash
mpv --no-video "https://your-radio-stream-url"
```

### Check audio hardware

List available ALSA playback devices:

```bash
aplay -l
```

List ALSA mixer controls:

```bash
amixer scontrols
```

## Uninstallation

Stop the service:

```bash
systemctl --user stop radio.service
```

Disable it:

```bash
systemctl --user disable radio.service
```

Remove the service:

```bash
rm -f ~/.config/systemd/user/radio.service
```

Reload systemd:

```bash
systemctl --user daemon-reload
```

Remove the project:

```bash
rm -rf ~/InternetRadioServer
```

If user lingering is no longer required, disable it with:

```bash
sudo loginctl disable-linger "$USER"
```

## Security Considerations

The installer downloads project files from GitHub and executes the radio player script as the current user.

For this reason, users should inspect the installer and downloaded source before executing it, particularly when installing software on an internet-connected server.

Avoid blindly executing remote scripts with commands such as:

```bash
curl https://example.com/install.sh | bash
```

Instead, download and inspect the file first:

```bash
curl -fSL https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/main/install.sh -o install.sh
```

Review it:

```bash
less install.sh
```

Then execute it:

```bash
bash install.sh
```

For production deployments, consider pinning the installer and project files to a specific Git commit or release rather than downloading from the `main` branch.

## Project

Source code:

[GitHub - DandyTheWood/InternetRadioServer](https://github.com/DandyTheWood/InternetRadioServer)

## Dependencies

* [mpv](https://mpv.io/)
* [ALSA](https://www.alsa-project.org/)
* [jq](https://jqlang.github.io/jq/)
* [curl](https://curl.se/)
* [systemd](https://systemd.io/)

## License

See the repository for the project's current license and licensing information.
