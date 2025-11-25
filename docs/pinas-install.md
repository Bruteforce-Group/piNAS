# piNAS Installer Overview

This document summarizes what the piNAS installer scripts do and how the system is structured, based on:

- `/usr/local/sbin/pinas-install.sh`
- `/usr/local/sbin/pinas-cache-deps.sh`

The scripts you imaged live at:

- `Projects/piNAS/sbin/pinas-install.sh`
- `Projects/piNAS/sbin/pinas-cache-deps.sh`
- `Projects/piNAS/scripts/setup-sdcard.sh` – helper run on your workstation to copy the installer assets + cloud-init data onto an SD card.

All paths below are from the Pi's perspective (i.e., when these scripts are actually executed on piNAS).

---

## 1. High-Level Goals

The piNAS installer turns a Raspberry Pi into a small NAS + USB gadget appliance with:

1. **XC9022 2.8" TFT as a front-panel display**
   - During install: shows a live log tail on the TFT.
   - After install: shows a NAS status dashboard (CPU, RAM, network, USB shares, etc.), including touch input.

2. **USB storage NAS**
   - Auto-mounts USB disks under `/srv/usb-shares`.
   - Auto-exposes each mounted USB device as a **guest Samba share**.

3. **USB mass-storage gadget**
   - Creates a backing image under `/srv/usb-gadget/pinas-gadget.img`.
   - Presents the Pi as a USB mass-storage device to a host via the USB-C port.

4. **Offline-first installs**
   - Can download and cache all needed `.deb` and `.whl` files to the SD card.
   - Main installer prefers offline caches if present, then falls back to network when available.

---

## 2. Offline Cache Script (`pinas-cache-deps.sh`)

**Path on Pi:** `/usr/local/sbin/pinas-cache-deps.sh`  
**Imaged copy:** `Projects/piNAS/sbin/pinas-cache-deps.sh`

### Purpose

Prepare **offline caches** on the boot partition so the main installer can run with minimal or no network:

- APT `.deb` cache: `/boot/firmware/pinas-apt` (or `/boot/pinas-apt`)
- Pip wheels cache: `/boot/firmware/pinas-py` (or `/boot/pinas-py`)

### What it installs & caches

**APT packages (`NAS_APT_PKGS`):**

- `samba` – SMB server
- `ntfs-3g`, `exfat-fuse`, `exfatprogs` – filesystem support for common USB disks
- `python3-venv`, `python3-pip`, `python3-dev`, `libjpeg-dev`, `zlib1g-dev` – for Python venvs and Pillow
- `i2c-tools`, `libgpiod-dev`, `python3-libgpiod` – GPIO / I2C support

**Python packages (downloaded as wheels):**

- Base display stack:
  - `adafruit-blinka`
  - `adafruit-circuitpython-rgb-display`
  - `pillow`
- Extra for dashboard:
  - `adafruit-circuitpython-stmpe610` (touch controller)
  - `psutil` (system stats)

### Steps

1. Detect boot mount (`/boot/firmware` or `/boot`).
2. Create cache dirs: `$BOOT_MNT/pinas-apt`, `$BOOT_MNT/pinas-py`.
3. `apt-get update && apt-get install -y` all `NAS_APT_PKGS`.
4. Copy `/var/cache/apt/archives/*.deb` to `$APT_CACHE_DIR`.
5. Create a **temporary venv** under `/tmp/pinas-cache-venv`.
6. `pip download -d "$PIP_CACHE_DIR"` all Python packages listed above.
7. Remove the temp venv.

Result: the SD card now holds all required `.deb` and `.whl` files for later offline installs.

---

## 3. Main Installer (`pinas-install.sh`)

**Path on Pi:** `/usr/local/sbin/pinas-install.sh`  
**Imaged copy:** `Projects/piNAS/sbin/pinas-install.sh`

### 3.1. Logging, progress tracking & environment setup

- Detects the boot mount: `/boot/firmware` or `/boot`.
- Logs to:
  - `/var/log/pinas-install.log`
  - `$BOOT_MNT/pinas-install.log` (for reading from another machine via SD card).
- Mirrors all output using `tee` so everything goes to both log files.
- Detects network connectivity by pinging `1.1.1.1`:
  - Sets `ONLINE=1` if ping works, otherwise `ONLINE=0`.
- Derives cache directories:
  - `APT_CACHE_DIR="$BOOT_MNT/pinas-apt"`
  - `PIP_CACHE_DIR="$BOOT_MNT/pinas-py"`
- Detects the **main user** (`APP_USER`): first UID ≥ 1000 in `/etc/passwd` (excluding `nobody`), falling back to `pi`.
- Ensures the kernel command line (`/boot/firmware/cmdline.txt` or `/boot/cmdline.txt`) contains `modules-load=dwc2,g_ether` so gadget mode modules come up automatically on every boot.
- Keeps only curated boot assets (`boot/user-data` + templates) in the repo; the original full `/boot` mirror lives in `archive/boot-stock-full/` for reference.
- Installs and enables a small systemd unit (`pinas-install-onboot.service`) that re-runs the installer automatically on the *next* boot whenever a manual run completes. That automatic pass reboots the Pi again when it finishes so kernel/device-tree changes are guaranteed to take effect without human intervention.
- Creates a machine-readable progress file at `$BOOT_MNT/pinas-progress.json` that records the status of each installation stage.
- Emits a concise stage dashboard in the console log so you can watch progress over SSH/XTerm as well as on the TFT.
- Stage order:
  1. `init_display` – bring up the temporary TFT viewer.
  2. `packages` – install core APT dependencies.
  3. `usb_nas` – configure USB auto shares.
  4. `dashboard` – deploy the permanent TFT dashboard service.
  5. `usb_gadget` – configure the USB mass-storage gadget.
  6. `finalize` – wait for the dashboard to become active and tear down the temporary viewer.

### 3.2. Package helper functions

- `install_apt_pkgs "pkgs..."`:
  - If `$APT_CACHE_DIR` contains `.deb`, runs `dpkg -i` on all of them, then `apt-get -f install`.
  - If online and no cache, runs `apt-get update` + `apt-get install -y` on the given package list.
  - If offline and no cache, errors out.

- `pip_install_offline_first "/path/to/venv/bin" pkgs...`:
  - If `$PIP_CACHE_DIR` has `.whl`, runs `pip install --no-index --find-links="$PIP_CACHE_DIR" ...`.
  - Else, if online, runs `pip install ...` from the network.
  - Else, errors out.

These helpers are used throughout the rest of the installer.

---

## 4. Install-time TFT Log Viewer (`setup_install_display`)

### Purpose

Bring up the XC9022 TFT **early** in the install process and show a live tail of the installer log (`/var/log/pinas-install.log`). This provides feedback even before the full NAS dashboard is set up.

### Steps

1. Create base directory:
   - `/opt/pinas-dashboard`

2. Create a **Python venv** at `/opt/pinas-dashboard/.venv`:
   - If `python3-venv` isn’t present, it calls `install_apt_pkgs python3-venv python3-pip python3-dev libjpeg-dev zlib1g-dev`.

3. Upgrade `pip` in the venv.

4. Install display dependencies (offline-first):
   - `adafruit-blinka`
   - `adafruit-circuitpython-rgb-display`
   - `adafruit-circuitpython-xpt2046`
   - `pillow`

5. Create `/usr/local/sbin/pinas-install-display.py`:
   - Uses `board`, `digitalio`, `adafruit_rgb_display.ili9341`, and Pillow.
   - Panel wiring:
     - TFT SPI: `board.SPI()`
     - `CS = board.CE0`
     - `DC = board.D25`
     - `RST = None`
     - `BAUDRATE = 24_000_000`
     - `rotation = 270`
   - Reads log from `/var/log/pinas-install.log` by default (or other path via argv).
   - Reads structured progress data from `$BOOT_MNT/pinas-progress.json` and shows the state of every stage at the top of the screen (queued, running, done, failed), fulfilling the “series of XTerm graphical screens” requirement whether you’re local or remote.
   - Tails roughly the last 13 lines, truncating long lines to ~40 chars.
   - Renders a black background, header (`"piNAS install log"`), and the tail lines.
   - Refreshes about every 0.5s.

6. Marks `pinas-install-display.py` executable and starts it in the background using the dashboard venv. The viewer now shows both the stage board and a live log tail.

Result: while the main installer is running, you see a continuously updating log view on the XC9022.

---

## 5. USB NAS + Samba (`setup_usb_nas`)

### Purpose

Provide an **automatic USB-backed NAS**:

- Any USB drive that appears as a block device gets auto-mounted.
- Each mount under `/srv/usb-shares` is auto-exposed as a simple guest-accessible Samba share.

### Steps

1. Create and own the mount root:
   - `MOUNT_ROOT="/srv/usb-shares"`
   - `mkdir -p /srv/usb-shares`
   - `chown "$APP_USER":"$APP_GROUP" /srv/usb-shares`

2. Backup existing Samba config if not already backed up:
   - `/etc/samba/smb.conf.pinas.bak`

3. Write a **minimal Samba config** at `/etc/samba/smb.conf`:
   - Workgroup `WORKGROUP`.
   - `server string = piNAS`.
   - Guest, standalone server configuration.
   - Includes `include = /etc/samba/usb-shares.conf`.

4. Create `/etc/samba/usb-shares.conf` (auto-generated content later) with proper permissions.

5. Create `/usr/local/sbin/usb-autoshare`:
   - Called by udev with `ACTION` (add/remove) and `DEVNAME` (e.g. `sda1`).
   - For `add` events on USB partitions:
     - Determine human-readable label via `blkid -s LABEL`, falling back to device name.
     - Normalize label to a safe directory name.
     - Mount under `/srv/usb-shares/<SAFE_LABEL>` with `uid=APP_USER`, `gid=APP_GROUP`, `umask=000`.
   - For `remove` events:
     - `umount` the device.
   - Rebuilds `/etc/samba/usb-shares.conf` from current mounts under `/srv/usb-shares` by scanning `/proc/mounts`.
     - Each mount becomes a share section with `guest ok = yes`, `read only = no`, and forced user/group.
   - Triggers `systemctl reload smbd` (or restart) if Samba is active.

   The script replaces a `__APP_USER__` placeholder with the actual `APP_USER`.

6. Install udev rules at `/etc/udev/rules.d/99-usb-autoshare.rules`:
   - For block devices `sd*[0-9]` on USB bus, run `usb-autoshare add %k` on add, and `usb-autoshare remove %k` on remove (via `systemd-run`).

7. Reload udev and trigger for block devices:
   - `udevadm control --reload`
   - `udevadm trigger --subsystem-match=block`

8. Enable and start Samba:
   - `systemctl enable --now smbd nmbd || true`

Result: plugging in a USB drive immediately creates a mount under `/srv/usb-shares/<LABEL>` and a matching Samba share accessible by name.

---

## 6. XC9022 TFT NAS Dashboard (`setup_dashboard`)

### Purpose

Set up the **permanent** XC9022 dashboard which runs on boot and shows NAS status:

- CPU, temperature, RAM
- Network interface and throughput
- USB shares and free space
- Simple touch interaction to toggle detail view vs. compact view

### Steps

1. Ensure the dashboard venv has extra packages:
   - `adafruit-circuitpython-stmpe610` – for XC9022 shields that use STMPE610 touch.
   - `adafruit-circuitpython-xpt2046` – for shields that use the XPT2046 touch controller (driver borrowed from the ESP32 project). 
   - `psutil` – for CPU/memory/disk/network stats.
   - Uses `pip_install_offline_first` with `/opt/pinas-dashboard/.venv/bin`.

2. Create `/opt/pinas-dashboard/nas_dashboard.py`:
   - Uses:
     - `PIL.Image`, `ImageDraw`, `ImageFont`
     - `board`, `digitalio`
     - `adafruit_rgb_display.ili9341`, `color565`
     - `adafruit_stmpe610` *or* `adafruit_xpt2046` (auto-detected at runtime)
     - `psutil`
   - Paths and constants:
     - `MOUNT_ROOT = "/srv/usb-shares"`
     - Display pins: `TFT_CS = board.CE0`, `TFT_DC = board.D25`, `TFT_RST = None`, `BAUDRATE = 24_000_000`, `rotation = 270`.
     - Touch pins: `TOUCH_CS = board.CE1`, `TOUCH_IRQ = board.D24`.
   - Key behaviors:
     - Initializes SPI and TFT, plus STMPE610 over SPI.
     - Loads Dejavu fonts if available, otherwise uses default bitmap font.
     - `get_cpu_temp_c()` uses `psutil.sensors_temperatures()` or `/sys/class/thermal/thermal_zone0/temp`.
     - Picks a primary network interface (preferring `eth0`, `enp0s31f6`, `wlan0`).
     - Samples network IO counters to compute RX/TX rates in bytes/sec.
     - Scans `/proc/mounts` for paths under `/srv/usb-shares`.
     - Displays:
       - Hostname + time
       - CPU usage (%) and temperature (°C)
       - RAM usage (used/total in MB, plus percent)
       - Network interface name + RX/TX rates (formatted as human-readable bytes/s)
       - For up to three USB mountpoints: share name, used percent, free space in GB
       - Footer instructing to tap the screen to toggle detail/compact view
     - Touch handling toggles `show_details` on press, with simple debouncing.

3. Permissions and groups:
   - Marks `nas_dashboard.py` executable.
   - Adds `APP_USER` to `gpio`, `spi`, `i2c` groups.
   - `chown -R APP_USER:APP_GROUP /opt/pinas-dashboard`.

4. Create systemd unit `/etc/systemd/system/pinas-dashboard.service`:

   - Service:
     - Runs as `User=APP_USER`, `Group=APP_USER`.
     - `WorkingDirectory=/opt/pinas-dashboard`.
     - `ExecStart=/opt/pinas-dashboard/.venv/bin/python /opt/pinas-dashboard/nas_dashboard.py`.
     - `Restart=always`.
   - `WantedBy=multi-user.target`.

5. Replace `__APP_USER__` placeholder with the real username and enable the service:
   - `systemctl daemon-reload`
   - `systemctl enable --now pinas-dashboard.service || true`

Result: on each boot, the XC9022 displays the NAS dashboard as a continuous status panel. During startup the dashboard now probes for `STMPE610` first and falls back to `XPT2046`, applying controller-specific calibration curves (the XPT numbers come from the ESP32 Marauder implementation). If no touch controller responds, the dashboard keeps running with tap-to-toggle disabled.

---

## 7. USB Mass-Storage Gadget (`setup_usb_gadget`)

### Purpose

Make the Pi appear as a **USB mass-storage device** to another host via its USB-C port, backed by a large image file stored on the Pi.

### Config.txt adjustments

- Determine `CONFIG_TXT` as `$BOOT_MNT/config.txt` (fallback `/boot/config.txt`).
- Ensure:
  - `dtoverlay=dwc2,dr_mode=peripheral`.
  - `dtparam=spi=on`.
  - `dtparam=i2c_arm=on`.

This ensures the DWC2 USB controller is in **device** mode and SPI/I2C are enabled for the TFT/touch.

### Modules and backing file

1. Write `/etc/modules-load.d/usb-gadget.conf` with:
   - `libcomposite`

2. Create `/srv/usb-gadget`.

3. Install `/usr/local/sbin/create-pinas-backfile.sh`:
   - Creates `/srv/usb-gadget/pinas-gadget.img` as a **sparse file** sized to most of the free space on `/`, while reserving 2 GiB.
   - Aborts if the resulting image would be < 512 MiB.

### Gadget start/stop scripts

Install:

- `/usr/local/sbin/pinas-usb-gadget-start.sh`
  - Mounts `configfs` (TeslaUSB style) if needed and loads `libcomposite`.
  - Creates `/sys/kernel/config/usb_gadget/pinas`, using deterministic serials derived from `/etc/machine-id`.
  - Sets vendor/product IDs, strings, and `MaxPower` according to the detected Pi model (Pi 5 can request more current).
  - Creates `functions/mass_storage.usb0`, points it at `/srv/usb-gadget/pinas-gadget.img`, and links it into `configs/c.1`.
  - Binds the gadget to the first available UDC (`/sys/class/udc/*`), emitting a helpful error if the platform lacks device mode.

- `/usr/local/sbin/pinas-usb-gadget-stop.sh`
  - Unbinds the gadget and removes mass-storage functions/configs before deleting the gadget directory (mirrors TeslaUSB teardown).

### Systemd unit for gadget

Create `/etc/systemd/system/pinas-usb-gadget.service`:

- Type: `oneshot` with `RemainAfterExit=yes`.
- Executes, in order:
  - `ExecStart=/usr/local/sbin/create-pinas-backfile.sh`
  - `ExecStart=/usr/local/sbin/pinas-usb-gadget-start.sh`
  - `ExecStop=/usr/local/sbin/pinas-usb-gadget-stop.sh`
- `WantedBy=multi-user.target`.

Then:

- `systemctl daemon-reload`
- `systemctl enable --now pinas-usb-gadget.service || true`

Result: on boot, the mass-storage gadget is automatically created and exported to the host.

---

## 8. Overall Execution Flow

`pinas-install.sh` runs the following steps in order:

1. `setup_install_display` – bring up the XC9022 and display the installer log in real time.
2. `install_packages` – install required APT packages (offline-first) using `install_apt_pkgs`.
3. `setup_usb_nas` – configure Samba, auto-mount USB devices, and expose them as guest shares.
4. `setup_dashboard` – install and enable the permanent XC9022 NAS dashboard service.
5. `setup_usb_gadget` – ensure `modules-load=dwc2,g_ether` is present in `cmdline.txt`, then install TeslaUSB-style start/stop scripts and the gadget systemd service.
6. `finalize_install` – wait for `pinas-dashboard.service` to report `active`, stop the temporary TFT log viewer, and start the permanent dashboard.
7. Print a final message + schedule an automatic re-run on the *next* boot (by touching `/var/lib/pinas-installer/run-on-boot.flag`). The auto-run unit (`pinas-install-onboot.service`) clears the flag and reboots again when that second pass succeeds.

After the reboot, the system should:

- Start `pinas-dashboard.service` → XC9022 NAS dashboard.
- Auto-mount any USB devices under `/srv/usb-shares` and expose them via SMB.
- Start `pinas-usb-gadget.service` → Pi appears as a USB mass-storage device backed by `/srv/usb-gadget/pinas-gadget.img`.
- Detect the scheduling flag, run `pinas-install.sh` automatically once more via systemd, and reboot itself upon completion. Subsequent boots revert to normal operation because the flag is cleared.

This markdown summarizes everything in the current versions of `pinas-install.sh` and `pinas-cache-deps.sh`, so you can safely reference it from tooling like Cursor or use it as documentation when modifying or extending piNAS.
