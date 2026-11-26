# InternetRadioServer

A tiny internet radio player for Raspberry Pi and most Linux distributions. It plays a stream with [mpv](https://mpv.io/), runs as a system service under your user (systemd, OpenRC, runit or dinit), starts at boot and restarts itself if it stops.

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

It installs `mpv`, `alsa-utils`, `jq` and `curl` (skipped if they are already present), creates the service and starts playing. If an older install exists, it is moved to a `.backup.<date>` folder and its settings are offered as defaults. An old per-user systemd service from earlier versions is removed automatically.

### Supported systems

| Distribution                                    | Package manager | Init systems                   |
| ----------------------------------------------- | --------------- | ------------------------------ |
| Debian, Ubuntu, Raspberry Pi OS, Mint, Pop!_OS  | apt             | systemd                        |
| Fedora                                          | dnf             | systemd                        |
| RHEL, Rocky, Alma                               | dnf             | systemd                        |
| Arch, Manjaro, EndeavourOS, Artix               | pacman          | systemd, OpenRC, runit, dinit  |
| openSUSE Leap / Tumbleweed                      | zypper          | systemd                        |
| Alpine                                          | apk             | OpenRC                         |
| Void                                            | xbps            | runit                          |
| Gentoo                                          | emerge          | OpenRC, systemd                |

Notes:

- **RHEL / Rocky / Alma:** `mpv` comes from RPM Fusion. If the install fails, the installer prints the commands to enable CRB and RPM Fusion.
- **Alpine:** install `bash` first (`apk add bash`) and enable the `community` repository.
- **Other distributions:** install `mpv`, `alsa-utils`, `jq` and `curl` yourself, then run `--install`. It works as long as the init system is one of the four above.
- The init system is detected automatically. To override detection, set `RADIO_INIT=systemd|openrc|runit|dinit`.

Requirements: `sudo` or `doas`, working audio output.

## Configure

```bash
bash setup_radio_server.sh --configure
```

Asks the same questions with your current values as defaults, saves them and restarts the radio.

You can also edit `~/InternetRadioServer/conf/radio.json` by hand and restart the service (see [Commands](#commands)):

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

| Init    | Status                             | Restart                             | Logs                                |
| ------- | ---------------------------------- | ----------------------------------- | ----------------------------------- |
| systemd | `systemctl status radio`           | `sudo systemctl restart radio`      | `sudo journalctl -u radio -f`       |
| OpenRC  | `rc-service radio status`          | `sudo rc-service radio restart`     | `tail -f /var/log/radio.log`        |
| runit   | `sudo sv status /var/service/radio` | `sudo sv restart /var/service/radio` | `sudo tail -f /var/log/radio/current` |
| dinit   | `sudo dinitctl status radio`       | `sudo dinitctl restart radio`       | `tail -f /var/log/radio.log`        |

On Artix with runit, the service link is `/run/runit/service/radio` instead of `/var/service/radio`.

## Troubleshooting

- **No sound:** run `aplay -l` and `amixer scontrols`, and set `amixer_dev` to a control that exists.
- **Desktop with PipeWire/PulseAudio:** if the mixer setting has no effect, disable it (`-` in `--configure`). When you are logged in, mpv plays through your sound server.
- **Stream does not play:** test it with `mpv --no-video "<url>"`.
- **Service fails:** check the logs (see [Commands](#commands)).

## Tests

```bash
bash test/run_tests.sh            # all tests
bash test/run_tests.sh pacman     # only tests whose name contains "pacman"
```

The tests need only `bash` and `jq`. They do not need root and do not touch the system: the installer runs in a temporary sandbox, and `sudo`, `systemctl`, the package managers and the other system commands are replaced by mocks that only record their calls.

### Docker integration tests

```bash
bash test/docker/run.sh           # everything (~6 min)
bash test/docker/run.sh deps      # package install on each distribution
bash test/docker/run.sh init      # full lifecycle with a real init system as PID 1
bash test/docker/run.sh init runit   # only targets whose name contains "runit"
```

| Suite  | Targets |
| ------ | ------- |
| `deps` | Debian 13, Ubuntu 24.04, Fedora, Rocky 9 (also runs the printed RPM Fusion instructions), Arch, openSUSE Tumbleweed, Alpine, Void |
| `init` | systemd (Debian), OpenRC (Alpine, Artix), runit (Void, Artix), dinit (Artix) |

For each init system, the `init` suite runs `--install` as an unprivileged user and checks that mpv really plays the stream. It then kills the player and checks that the supervisor restarts it, runs `--configure`, restarts the container to check that the radio starts at boot, and finally runs `--uninstall`.

Containers never run with `--privileged` and see no host devices, so they cannot touch your sound card. Audio goes to an ALSA `null` device. The only extra permission is `CAP_SYS_ADMIN` for the systemd container, which systemd needs to remount its own private cgroup. Options: `JOBS=6` (targets run in parallel), `RADIO_TEST_STREAM=<url>`, `KEEP=1` (keep the containers for debugging).

## Uninstall

```bash
bash setup_radio_server.sh --uninstall
```

Installations from older versions used lingering. If nothing else needs it, disable it with `sudo loginctl disable-linger "$USER"`.
