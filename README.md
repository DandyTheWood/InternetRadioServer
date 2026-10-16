# InternetRadioServer

A tiny internet radio player for Raspberry Pi, Debian and Ubuntu. It plays a stream with [mpv](https://mpv.io/), runs as a systemd user service, starts at boot and restarts itself if it stops.

## Usage

```bash
bash setup_radio_server.sh              # show help
bash setup_radio_server.sh --install    # install and start the radio
bash setup_radio_server.sh --configure  # change settings and restart the radio
bash setup_radio_server.sh --uninstall  # remove everything
```

## Install

```bash
bash setup_radio_server.sh --install
```

The installer asks for:

- stream URL
- station name
- volume (0-100)
- ALSA mixer control (auto-detected, press Enter to accept)

It installs `mpv`, `alsa-utils`, `jq` and `curl`, creates the service and starts playing. If an older install exists, it is moved to a `.backup.<date>` folder and its settings are offered as defaults.

Requirements: Debian/Ubuntu-based system, systemd, `sudo`, working audio output.

## Configure

```bash
bash setup_radio_server.sh --configure
```

Asks the same questions with your current values as defaults, saves them and restarts the radio.

You can also edit `~/InternetRadioServer/conf/radio.json` by hand and run `systemctl --user restart radio.service`:

```json
{
    "station_name": "My Radio",
    "stream_url": "https://example.com/radio.mp3",
    "volume": 70,
    "amixer_dev": "Master"
}
```

| Option         | Description                                 |
| -------------- | ------------------------------------------- |
| `station_name` | Shown in the logs                           |
| `stream_url`   | Stream address                              |
| `volume`       | mpv volume, 0-100                           |
| `amixer_dev`   | ALSA mixer control to unmute (empty = skip) |

## Commands

```bash
systemctl --user status radio.service      # status
systemctl --user restart radio.service     # restart
systemctl --user stop radio.service        # stop
journalctl --user -u radio.service -f      # live logs
```

## Troubleshooting

- **No sound:** run `aplay -l` and `amixer scontrols`, and set `amixer_dev` to a control that exists. If the installer added you to the `audio` group, reboot once.
- **Stream does not play:** test it with `mpv --no-video "<url>"`.
- **Service fails:** `journalctl --user -u radio.service -n 50 --no-pager`.

## Uninstall

```bash
bash setup_radio_server.sh --uninstall
```

Optionally disable lingering afterwards: `sudo loginctl disable-linger "$USER"`.
