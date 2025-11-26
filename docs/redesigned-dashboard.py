#!/usr/bin/env python3
"""
Redesigned piNAS Dashboard - Optimized layout for 320x240 TFT display
Features:
- Cleaner header with better spacing
- Larger, more readable charts
- Better use of vertical space
- Status bar with network info
- Improved USB drive display
"""
import json
import os
import socket
import subprocess
import time
import urllib.request
from collections import deque
from datetime import datetime
from typing import Dict, List, Optional, Tuple

import psutil
from PIL import Image, ImageDraw, ImageFont

import board
import digitalio
from adafruit_rgb_display import ili9341, color565
try:
    import adafruit_stmpe610
except ImportError:
    adafruit_stmpe610 = None
try:
    import adafruit_xpt2046
except ImportError:
    adafruit_xpt2046 = None

# Configuration
MOUNT_ROOT = "/srv/usb-shares"
VERSION_FILE = "/usr/local/pinas/VERSION"
TFT_CS = board.CE0
TFT_DC = board.D25
TFT_RST = None
TOUCH_CS = board.CE1
TOUCH_IRQ = board.D24
BAUDRATE = 24_000_000
UPDATE_INTERVAL = 0.5
HOSTNAME = socket.gethostname()
WIDTH, HEIGHT = 320, 240

# Data storage for charts
HISTORY_SIZE = 80  # Keep 80 data points for smoother charts
cpu_history = deque(maxlen=HISTORY_SIZE)
memory_history = deque(maxlen=HISTORY_SIZE)
disk_history = deque(maxlen=HISTORY_SIZE)
network_history = deque(maxlen=HISTORY_SIZE)

# UI State
current_screen = 0
max_screens = 2
last_touch_time = 0
touch_debounce = 0.3
selected_drive = None

# Color scheme
COLOR_BG = (0, 0, 0)
COLOR_TEXT = (255, 255, 255)
COLOR_SUBTEXT = (180, 180, 180)
COLOR_SUCCESS = (0, 255, 0)
COLOR_WARNING = (255, 200, 0)
COLOR_ERROR = (255, 50, 50)
COLOR_INFO = (100, 150, 255)
COLOR_CHART_CPU = (255, 80, 80)
COLOR_CHART_MEM = (80, 255, 80)
COLOR_CHART_DISK = (80, 80, 255)
COLOR_CHART_NET = (255, 200, 80)

class USBDrive:
    def __init__(self, mount_path):
        self.mount_path = mount_path
        self.name = os.path.basename(mount_path)
        try:
            stat = os.statvfs(mount_path)
            self.total_bytes = stat.f_blocks * stat.f_frsize
            self.free_bytes = stat.f_bavail * stat.f_frsize
            self.used_bytes = self.total_bytes - self.free_bytes
            self.used_percent = (self.used_bytes / self.total_bytes * 100) if self.total_bytes > 0 else 0
        except:
            self.total_bytes = self.free_bytes = self.used_bytes = 0
            self.used_percent = 0

    def format_size(self, bytes_val):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024.0:
                return f"{bytes_val:.1f}{unit}"
            bytes_val /= 1024.0
        return f"{bytes_val:.1f}PB"

    def is_shared(self):
        try:
            output = subprocess.check_output(['smbstatus', '-S'], text=True)
            return self.name in output
        except:
            return False

    def get_filesystem_type(self):
        try:
            result = subprocess.run(['findmnt', '-n', '-o', 'FSTYPE', self.mount_path],
                                  capture_output=True, text=True)
            return result.stdout.strip() or "unknown"
        except:
            return "unknown"

def init_display_and_touch():
    spi = board.SPI()
    cs_pin = digitalio.DigitalInOut(TFT_CS)
    dc_pin = digitalio.DigitalInOut(TFT_DC)

    display = ili9341.ILI9341(spi, cs=cs_pin, dc=dc_pin, rst=TFT_RST,
                              baudrate=BAUDRATE, rotation=270)

    touch_driver = None
    touch = None

    if adafruit_stmpe610:
        try:
            i2c = board.I2C()
            touch = adafruit_stmpe610.Adafruit_STMPE610_I2C(i2c, address=0x41)
            touch_driver = "STMPE610"
            print("Detected STMPE610 touch controller")
        except:
            pass

    if not touch and adafruit_xpt2046:
        try:
            touch_cs = digitalio.DigitalInOut(TOUCH_CS)
            touch = adafruit_xpt2046.Touch(spi, cs=touch_cs)
            touch_driver = "XPT2046"
            print("Detected XPT2046 touch controller")
        except:
            pass

    if not touch:
        print("WARNING: No touch controller detected")

    return display, touch, touch_driver

def load_fonts():
    try:
        font_huge = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 20)
        font_big = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 16)
        font_medium = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 14)
        font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 11)
        font_tiny = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 9)
    except OSError:
        font_huge = font_big = font_medium = font_small = font_tiny = ImageFont.load_default()
    return font_huge, font_big, font_medium, font_small, font_tiny

def get_version_info() -> Tuple[str, bool]:
    try:
        with open(VERSION_FILE, 'r') as f:
            current_version = f.read().strip()
    except:
        current_version = "unknown"

    is_latest = check_for_updates(current_version)
    return current_version, is_latest

def check_for_updates(current_version: str) -> bool:
    try:
        url = "https://api.github.com/repos/Bruteforce-Group/piNAS/releases/latest"
        with urllib.request.urlopen(url, timeout=5) as response:
            data = json.loads(response.read())
            latest_version = data.get("tag_name", "")
            return current_version >= latest_version.lstrip('v')
    except:
        return True

def map_touch(touch, driver):
    try:
        if driver == "STMPE610":
            if not touch.touched:
                return None
            x_raw, y_raw, z = touch.read_data()
            MIN_X, MAX_X = 200, 3800
            MIN_Y, MAX_Y = 200, 3800
            x_norm = max(0, min(1, (x_raw - MIN_X) / (MAX_X - MIN_X)))
            y_norm = max(0, min(1, (y_raw - MIN_Y) / (MAX_Y - MIN_Y)))
            screen_x = int(y_norm * WIDTH)
            screen_y = int((1.0 - x_norm) * HEIGHT)
        elif driver == "XPT2046":
            if not touch.touch_point:
                return None
            x_raw, y_raw = touch.touch_point
            MIN_X, MAX_X = 300, 3800
            MIN_Y, MAX_Y = 300, 3800
            x_norm = max(0, min(1, (x_raw - MIN_X) / (MAX_X - MIN_X)))
            y_norm = max(0, min(1, (y_raw - MIN_Y) / (MAX_Y - MIN_Y)))
            screen_x = int(y_norm * WIDTH)
            screen_y = int((1.0 - x_norm) * HEIGHT)

        screen_x = max(0, min(WIDTH - 1, screen_x))
        screen_y = max(0, min(HEIGHT - 1, screen_y))
        return (screen_x, screen_y)
    except:
        return None

def get_system_stats():
    stats = {}

    # CPU
    stats['cpu_percent'] = psutil.cpu_percent(interval=None)

    # Temperature
    try:
        temps = psutil.sensors_temperatures()
        if 'cpu_thermal' in temps:
            stats['temperature'] = temps['cpu_thermal'][0].current
        else:
            stats['temperature'] = None
    except:
        stats['temperature'] = None

    # Memory
    mem = psutil.virtual_memory()
    stats['memory_percent'] = mem.percent
    stats['memory_used_gb'] = mem.used / (1024**3)
    stats['memory_total_gb'] = mem.total / (1024**3)

    # Disk
    disk = psutil.disk_usage('/')
    stats['disk_percent'] = disk.percent
    stats['disk_used_gb'] = disk.used / (1024**3)
    stats['disk_total_gb'] = disk.total / (1024**3)

    # Network
    net = psutil.net_io_counters()
    stats['net_sent_kb'] = net.bytes_sent / 1024
    stats['net_recv_kb'] = net.bytes_recv / 1024

    # Network speed (calculate from previous sample)
    if not hasattr(get_system_stats, 'last_net'):
        get_system_stats.last_net = (net.bytes_sent, net.bytes_recv, time.time())
        stats['net_speed_kb'] = 0
    else:
        last_sent, last_recv, last_time = get_system_stats.last_net
        time_delta = time.time() - last_time
        if time_delta > 0:
            speed = ((net.bytes_sent - last_sent) + (net.bytes_recv - last_recv)) / time_delta / 1024
            stats['net_speed_kb'] = speed
        else:
            stats['net_speed_kb'] = 0
        get_system_stats.last_net = (net.bytes_sent, net.bytes_recv, time.time())

    # IP address
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        stats['ip_address'] = s.getsockname()[0]
        s.close()
    except:
        stats['ip_address'] = "N/A"

    return stats

def get_usb_drives():
    drives = []
    if os.path.exists(MOUNT_ROOT):
        for name in os.listdir(MOUNT_ROOT):
            path = os.path.join(MOUNT_ROOT, name)
            if os.path.ismount(path):
                drives.append(USBDrive(path))
    return drives

def draw_chart(draw, x, y, width, height, data, color, title, font, show_grid=True):
    """Enhanced chart with grid lines and better visualization"""
    # Background
    draw.rectangle([x, y, x + width, y + height], outline=color, width=1)

    # Grid lines (25%, 50%, 75%)
    if show_grid:
        for i in [25, 50, 75]:
            grid_y = y + height - int(height * i / 100)
            draw.line([x, grid_y, x + width, grid_y], fill=(40, 40, 40), width=1)

    # Title
    draw.text((x + 2, y - 14), title, font=font, fill=color)

    # Data line
    if len(data) < 2:
        return

    points = []
    step = width / (len(data) - 1)
    for i, val in enumerate(data):
        px = x + i * step
        py = y + height - (val / 100.0 * height)
        points.append((px, py))

    # Fill area under curve
    if len(points) > 1:
        fill_points = [(x, y + height)] + points + [(x + width, y + height)]
        # Create semi-transparent fill color
        fill_color = tuple(int(c * 0.2) for c in color)
        draw.polygon(fill_points, fill=fill_color)

        # Draw line
        for i in range(len(points) - 1):
            draw.line([points[i], points[i + 1]], fill=color, width=2)

    # Current value
    current_val = data[-1] if data else 0
    val_text = f"{current_val:.0f}%"
    draw.text((x + width - 32, y + 2), val_text, font=font, fill=color)

def draw_overview_screen(draw, fonts, stats, version, is_latest, drives):
    """Redesigned overview screen with better layout"""
    font_huge, font_big, font_medium, font_small, font_tiny = fonts

    # === HEADER SECTION (0-35px) ===
    # Hostname and version on same line
    draw.text((5, 2), f"piNAS", font=font_huge, fill=COLOR_TEXT)
    hostname_width = font_huge.getbbox("piNAS")[2]

    # Version with status indicator
    version_color = COLOR_SUCCESS if is_latest else COLOR_WARNING
    version_text = f"v{version}"
    draw.text((hostname_width + 10, 6), version_text, font=font_medium, fill=version_color)

    # Update indicator dot
    if not is_latest:
        draw.ellipse([hostname_width + font_medium.getbbox(version_text)[2] + 15, 10,
                      hostname_width + font_medium.getbbox(version_text)[2] + 21, 16],
                     fill=COLOR_WARNING)

    # Time and date
    now = datetime.now()
    time_str = now.strftime("%H:%M:%S")
    date_str = now.strftime("%d %b")
    draw.text((WIDTH - 75, 2), time_str, font=font_medium, fill=COLOR_TEXT)
    draw.text((WIDTH - 75, 18), date_str, font=font_tiny, fill=COLOR_SUBTEXT)

    # IP Address
    draw.text((5, 22), f"IP: {stats['ip_address']}", font=font_tiny, fill=COLOR_SUBTEXT)

    # Separator line
    draw.line([0, 36, WIDTH, 36], fill=COLOR_SUBTEXT, width=1)

    # === CHARTS SECTION (37-117px) - 2 rows x 2 cols ===
    chart_width = 150
    chart_height = 38
    chart_margin = 5

    # Row 1
    draw_chart(draw, 5, 42, chart_width, chart_height, cpu_history,
              COLOR_CHART_CPU, "CPU", font_tiny, show_grid=True)
    draw_chart(draw, 165, 42, chart_width, chart_height, memory_history,
              COLOR_CHART_MEM, "Memory", font_tiny, show_grid=True)

    # Row 2
    draw_chart(draw, 5, 86, chart_width, chart_height, disk_history,
              COLOR_CHART_DISK, "Disk", font_tiny, show_grid=True)
    draw_chart(draw, 165, 86, chart_width, chart_height, network_history,
              COLOR_CHART_NET, "Network", font_tiny, show_grid=True)

    # === STATS SECTION (130-165px) ===
    y = 132
    col1_x = 5
    col2_x = 165

    # CPU & Temp
    cpu_text = f"CPU: {stats['cpu_percent']:.1f}%"
    draw.text((col1_x, y), cpu_text, font=font_small, fill=COLOR_TEXT)
    if stats['temperature']:
        temp_color = COLOR_ERROR if stats['temperature'] > 80 else COLOR_WARNING if stats['temperature'] > 70 else COLOR_SUCCESS
        temp_text = f"{stats['temperature']:.0f}°C"
        draw.text((col1_x + 70, y), temp_text, font=font_small, fill=temp_color)

    # Memory
    draw.text((col2_x, y), f"RAM: {stats['memory_used_gb']:.1f}/{stats['memory_total_gb']:.1f}GB",
             font=font_small, fill=COLOR_TEXT)

    y += 16
    # Disk
    draw.text((col1_x, y), f"Disk: {stats['disk_used_gb']:.0f}/{stats['disk_total_gb']:.0f}GB",
             font=font_small, fill=COLOR_TEXT)

    # Network speed
    net_text = f"Net: {stats['net_speed_kb']:.0f} KB/s"
    draw.text((col2_x, y), net_text, font=font_small, fill=COLOR_TEXT)

    # Separator
    draw.line([0, 166, WIDTH, 166], fill=COLOR_SUBTEXT, width=1)

    # === USB DRIVES SECTION (167-228px) ===
    y = 170
    draw.text((5, y), "USB Drives:", font=font_medium, fill=COLOR_TEXT)

    # Drive count indicator
    if drives:
        count_text = f"({len(drives)})"
        draw.text((90, y + 2), count_text, font=font_tiny, fill=COLOR_SUBTEXT)

    y += 18

    if drives:
        # Show up to 2 drives in detail
        for i, drive in enumerate(drives[:2]):
            # Status indicator
            status_color = COLOR_SUCCESS if drive.is_shared() else (80, 80, 80)
            draw.rectangle([5, y, 13, y + 8], fill=status_color)

            # Drive name
            name_text = drive.name[:18]
            draw.text((17, y - 1), name_text, font=font_small, fill=COLOR_TEXT)

            # Size info
            size_text = f"{drive.format_size(drive.used_bytes)}/{drive.format_size(drive.total_bytes)}"
            used_color = COLOR_ERROR if drive.used_percent > 90 else COLOR_WARNING if drive.used_percent > 75 else COLOR_SUBTEXT
            draw.text((17, y + 10), size_text, font=font_tiny, fill=used_color)

            # Usage bar
            bar_width = 120
            bar_x = 170
            draw.rectangle([bar_x, y + 3, bar_x + bar_width, y + 11], outline=COLOR_SUBTEXT, width=1)
            if drive.used_percent > 0:
                fill_width = int(bar_width * drive.used_percent / 100)
                bar_color = COLOR_ERROR if drive.used_percent > 90 else COLOR_WARNING if drive.used_percent > 75 else COLOR_INFO
                draw.rectangle([bar_x + 1, y + 4, bar_x + fill_width, y + 10], fill=bar_color)

            # Percentage
            draw.text((bar_x + bar_width + 4, y + 1), f"{drive.used_percent:.0f}%",
                     font=font_tiny, fill=used_color)

            y += 28

        # Show count of additional drives
        if len(drives) > 2:
            more_text = f"+ {len(drives) - 2} more drive(s)"
            draw.text((17, y), more_text, font=font_tiny, fill=COLOR_SUBTEXT)
    else:
        draw.text((5, y), "No USB drives connected", font=font_small, fill=(80, 80, 80))

    # === FOOTER (229-240px) ===
    # Screen indicators
    for i in range(max_screens):
        indicator_color = COLOR_TEXT if i == current_screen else (60, 60, 60)
        draw.ellipse([290 + i*12, 232, 296 + i*12, 238], fill=indicator_color)

def draw_drives_screen(draw, fonts, drives):
    """Enhanced drives management screen"""
    font_huge, font_big, font_medium, font_small, font_tiny = fonts

    # Header
    draw.text((5, 5), "USB Drive Manager", font=font_big, fill=COLOR_TEXT)
    draw.line([0, 28, WIDTH, 28], fill=COLOR_SUBTEXT, width=1)

    if not drives:
        draw.text((5, 50), "No USB drives connected", font=font_medium, fill=(100, 100, 100))
        draw.text((5, 75), "Insert a USB drive to see it here", font=font_small, fill=(80, 80, 80))
        return

    y = 35
    for i, drive in enumerate(drives):
        if y > HEIGHT - 70:
            more_count = len(drives) - i
            draw.text((5, y), f"+ {more_count} more drive(s) (scroll to view)",
                     font=font_small, fill=COLOR_SUBTEXT)
            break

        # Drive header with status
        share_status = "SHARED" if drive.is_shared() else "PRIVATE"
        status_color = COLOR_SUCCESS if drive.is_shared() else COLOR_ERROR

        # Status indicator
        draw.rectangle([5, y, 15, y + 10], fill=status_color)
        draw.text((20, y - 1), f"{drive.name}", font=font_medium, fill=COLOR_TEXT)
        draw.text((20, y + 14), share_status, font=font_tiny, fill=status_color)

        y += 30

        # Filesystem and size
        fs_type = drive.get_filesystem_type()
        draw.text((20, y), f"Type: {fs_type.upper()}", font=font_small, fill=COLOR_SUBTEXT)
        y += 14

        size_info = f"{drive.format_size(drive.total_bytes)} total, {drive.format_size(drive.free_bytes)} free"
        draw.text((20, y), size_info, font=font_small, fill=COLOR_SUBTEXT)
        y += 14

        # Usage bar
        bar_width = 280
        bar_x = 20
        draw.rectangle([bar_x, y, bar_x + bar_width, y + 8], outline=COLOR_SUBTEXT, width=1)
        if drive.used_percent > 0:
            fill_width = int(bar_width * drive.used_percent / 100)
            bar_color = COLOR_ERROR if drive.used_percent > 90 else COLOR_WARNING if drive.used_percent > 75 else COLOR_INFO
            draw.rectangle([bar_x + 1, y + 1, bar_x + fill_width, y + 7], fill=bar_color)

        percent_text = f"{drive.used_percent:.1f}% used"
        draw.text((bar_x + bar_width + 5, y - 1), percent_text, font=font_tiny, fill=COLOR_SUBTEXT)

        y += 18

        # Action buttons
        button_width = 95
        button_height = 20
        button_y = y

        # Share/Unshare button
        if drive.is_shared():
            button_color = COLOR_ERROR
            button_text = "Unshare"
        else:
            button_color = COLOR_SUCCESS
            button_text = "Share"

        draw.rectangle([20, button_y, 20 + button_width, button_y + button_height],
                      outline=button_color, width=2)
        text_bbox = font_small.getbbox(button_text)
        text_width = text_bbox[2] - text_bbox[0]
        draw.text((20 + (button_width - text_width) // 2, button_y + 4),
                 button_text, font=font_small, fill=button_color)

        # Refresh button
        draw.rectangle([125, button_y, 125 + button_width, button_y + button_height],
                      outline=COLOR_INFO, width=2)
        text_bbox = font_small.getbbox("Refresh")
        text_width = text_bbox[2] - text_bbox[0]
        draw.text((125 + (button_width - text_width) // 2, button_y + 4),
                 "Refresh", font=font_small, fill=COLOR_INFO)

        y += 30

        # Separator
        if i < len(drives) - 1:
            draw.line([0, y, WIDTH, y], fill=(40, 40, 40), width=1)
            y += 5

    # Footer - screen indicators
    for i in range(max_screens):
        indicator_color = COLOR_TEXT if i == current_screen else (60, 60, 60)
        draw.ellipse([290 + i*12, 232, 296 + i*12, 238], fill=indicator_color)

def handle_touch(x, y, drives):
    global current_screen, last_touch_time

    current_time = time.time()
    if current_time - last_touch_time < touch_debounce:
        return
    last_touch_time = current_time

    if current_screen == 0:  # Overview screen
        # Touch anywhere to switch
        current_screen = 1

    elif current_screen == 1:  # Drives screen
        # Check for button touches (simplified - would need proper bounds)
        if x < 160:  # Left half - go back
            current_screen = 0
        # Could add button detection here

def main():
    display, touch, driver = init_display_and_touch()
    fonts = load_fonts()

    print(f"piNAS Dashboard v2.0 - Redesigned")
    print(f"Display: {WIDTH}x{HEIGHT}")
    print(f"Touch: {driver if driver else 'None'}")

    global current_screen
    last_update = 0

    try:
        while True:
            current_time = time.time()

            # Check for touch
            if touch:
                touch_pos = map_touch(touch, driver)
                if touch_pos:
                    handle_touch(touch_pos[0], touch_pos[1], get_usb_drives())

            # Update display
            if current_time - last_update >= UPDATE_INTERVAL:
                stats = get_system_stats()
                version, is_latest = get_version_info()
                drives = get_usb_drives()

                # Update history
                cpu_history.append(stats['cpu_percent'])
                memory_history.append(stats['memory_percent'])
                disk_history.append(stats['disk_percent'])
                network_history.append(min(100, stats['net_speed_kb'] / 10))  # Scale network

                # Create display image
                image = Image.new("RGB", (WIDTH, HEIGHT), COLOR_BG)
                draw = ImageDraw.Draw(image)

                if current_screen == 0:
                    draw_overview_screen(draw, fonts, stats, version, is_latest, drives)
                else:
                    draw_drives_screen(draw, fonts, drives)

                display.image(image)
                last_update = current_time

            time.sleep(0.05)

    except KeyboardInterrupt:
        print("\nShutting down dashboard...")
        # Clear display
        image = Image.new("RGB", (WIDTH, HEIGHT), (0, 0, 0))
        display.image(image)

if __name__ == "__main__":
    main()
