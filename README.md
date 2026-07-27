# Topbar

A lightweight, feature-rich status bar for the [Niri](https://github.com/YaLTeR/niri) Wayland compositor, built with GTK4 and Vala.

## Features

### Left Section
- **System Resources** — Live CPU usage, RAM usage, CPU temperature, and disk usage. Click to open `btop`.
- **Apps** — Launcher button to open the application menu.
- **Tools** — Collapsible toolbar with:
  - Screen Recorder toggle
  - Color Picker
- **Niri Workspaces** — Per-monitor workspace indicators showing open windows with app icons. Supports:
  - Left-click to focus a workspace
  - Scroll to cycle through windows in a workspace
  - Long-press to toggle the Niri overview

### Center Section
- **Clock** — Live time display (250ms refresh). Click to toggle between local and UTC time.
- **Date** — Current date display. Click to open a calendar popover.

### Right Section
- **Bluetooth** — Shows connection status and connected device name.
  - Left-click to open the Bluetooth launcher
  - Right-click to toggle power
- **Volume** — Shows current volume level and mute state.
  - Left-click to toggle mute
  - Scroll to adjust volume
- **Wi-Fi** — Shows connected SSID and signal icon.
  - Click to open the NetworkManager text UI (`nmtui`)
- **Battery** — Shows charge percentage and charging status icon.
- **System Tray** — SNI (StatusNotifierItem) tray icon support.
- **Power Menu** — Button to open the power menu.

### OSD
- **Volume OSD** — On-screen display triggered via IPC for hardware key volume changes.

## Dependencies

- `gtk4`
- `gtk4-layer-shell`
- `glib-2.0` / `gio-2.0` / `gio-unix-2.0`
- `gee-0.8`
- `json-glib-1.0`
- `libnm` (NetworkManager)
- `sass` (for SCSS compilation)
- `vala` compiler
- `meson` build system

## Building & Installing

```bash
bash scripts/install.sh
```

This script performs a clean build and installs the binary system-wide:

```bash
rm -rf build/
meson setup build
meson compile -C build
sudo meson install -C build
```

## Running

```bash
topbar
```

To toggle (start if not running, kill if running):

```bash
bash scripts/toggle.sh
```

Logs are written to `/tmp/topbar.log` when run via the toggle script.

## IPC

Topbar listens on a Unix socket at `$XDG_RUNTIME_DIR/topbar.sock` for volume control commands. This is used to trigger the Volume OSD from hardware media keys.

Supported commands:

| Command        | Action              |
|----------------|---------------------|
| `volume-up`    | Increase volume     |
| `volume-down`  | Decrease volume     |
| `volume-mute`  | Toggle mute         |

### topbarctl

`topbarctl` is a companion CLI tool for sending IPC commands to a running topbar instance.

```bash
topbarctl <command>
```

Examples:

```bash
topbarctl volume-up
topbarctl volume-down
topbarctl volume-mute
```

You can also send commands manually via `socat`:

```bash
echo "volume-up" | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/topbar.sock
```

## Multi-Monitor Support

Topbar automatically creates one bar per connected monitor and handles hotplug events — monitors added or removed at runtime are handled gracefully.

## Project Structure

```
topbar/
├── assets/
│   ├── style.scss              # Bar stylesheet (compiled to CSS at build time)
│   ├── kitty-custom.svg        # Custom Kitty terminal icon
│   └── topbar.gresource.xml    # GResource manifest
├── src/
│   ├── main.vala               # Entry point
│   ├── app.vala                # Application lifecycle, monitor management
│   ├── ipc.vala                # Unix socket IPC server
│   ├── ui/
│   │   ├── bar.vala            # Bar window (layer shell setup)
│   │   ├── bar_left.vala       # Left section widgets
│   │   ├── bar_center.vala     # Clock and date widgets
│   │   ├── bar_right.vala      # Status widgets (volume, wifi, battery, etc.)
│   │   ├── niri_workspaces.vala
│   │   ├── system_resources.vala
│   │   └── tray.vala
│   ├── osd/
│   │   └── volume_osd.vala     # Volume on-screen display
│   └── services/
│       ├── niri_ipc.vala       # Niri compositor IPC client
│       ├── system_resources.vala
│       ├── battery.vala
│       ├── network.vala
│       ├── volume.vala
│       ├── bluetooth.vala
│       ├── screen_rec.vala
│       ├── tray.vala
│       └── utils.vala
├── tools/
│   └── topbarctl.vala          # CLI IPC client
├── scripts/
│   ├── install.sh              # Build and install script
│   └── toggle.sh               # Start/restart script
└── meson.build
```

## License

This project does not currently include a license file.
