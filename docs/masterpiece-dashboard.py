#!/usr/bin/env python3
"""
piNAS Dashboard - Modern Masterpiece Edition
A stunning, premium dashboard with glassmorphism, smooth gradients, and elite design
Optimized for 320x240 ILI9341 TFT Display
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
import math

import psutil
from PIL import Image, ImageDraw, ImageFont, ImageFilter

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

# ==================== CONFIGURATION ====================
MOUNT_ROOT = "/srv/usb-shares"
VERSION_FILE = "/usr/local/pinas/VERSION"
TFT_CS = board.CE0
TFT_DC = board.D25
TFT_RST = None
TOUCH_CS = board.CE1
TOUCH_IRQ = board.D24
BAUDRATE = 24_000_000
UPDATE_INTERVAL = 0.3  # Faster updates for smooth animations
HOSTNAME = socket.gethostname()
WIDTH, HEIGHT = 320, 240

# Data storage
HISTORY_SIZE = 100
cpu_history = deque(maxlen=HISTORY_SIZE)
memory_history = deque(maxlen=HISTORY_SIZE)
disk_history = deque(maxlen=HISTORY_SIZE)
network_history = deque(maxlen=HISTORY_SIZE)

# UI State
current_screen = 0
max_screens = 3
last_touch_time = 0
touch_debounce = 0.2
animation_phase = 0

# ==================== PREMIUM COLOR PALETTE ====================
# Dark theme with vibrant accents
BG_DARK = (10, 10, 15)
BG_CARD = (20, 22, 30)
BG_CARD_HOVER = (28, 30, 40)

# Gradients
GRADIENT_PRIMARY = [(100, 40, 240), (180, 100, 255)]  # Purple
GRADIENT_SUCCESS = [(0, 200, 120), (0, 255, 180)]     # Emerald
GRADIENT_WARNING = [(255, 150, 0), (255, 200, 60)]    # Amber
GRADIENT_ERROR = [(255, 50, 80), (255, 120, 140)]     # Rose
GRADIENT_INFO = [(30, 150, 255), (100, 200, 255)]     # Sky

# Text colors
TEXT_PRIMARY = (255, 255, 255)
TEXT_SECONDARY = (160, 165, 180)
TEXT_MUTED = (100, 105, 120)

# Chart colors with glow
COLOR_CPU = (255, 90, 120)
COLOR_CPU_GLOW = (255, 90, 120, 80)
COLOR_MEM = (100, 220, 255)
COLOR_MEM_GLOW = (100, 220, 255, 80)
COLOR_DISK = (160, 100, 255)
COLOR_DISK_GLOW = (160, 100, 255, 80)
COLOR_NET = (255, 200, 80)
COLOR_NET_GLOW = (255, 200, 80, 80)

# Status colors
STATUS_ONLINE = (0, 255, 150)
STATUS_WARNING = (255, 180, 0)
STATUS_ERROR = (255, 60, 80)

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

# ==================== INITIALIZATION ====================
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
        except:
            pass

    if not touch and adafruit_xpt2046:
        try:
            touch_cs = digitalio.DigitalInOut(TOUCH_CS)
            touch = adafruit_xpt2046.Touch(spi, cs=touch_cs)
            touch_driver = "XPT2046"
        except:
            pass

    return display, touch, touch_driver

def load_fonts():
    try:
        font_title = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 24)
        font_big = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 18)
        font_medium = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 14)
        font_regular = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 12)
        font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 10)
        font_tiny = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 8)
    except OSError:
        font_title = font_big = font_medium = font_regular = font_small = font_tiny = ImageFont.load_default()
    return font_title, font_big, font_medium, font_regular, font_small, font_tiny

# ==================== DATA FUNCTIONS ====================
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
        with urllib.request.urlopen(url, timeout=3) as response:
            data = json.loads(response.read())
            latest_version = data.get("tag_name", "")
            return current_version >= latest_version.lstrip('v')
    except:
        return True

def get_system_stats():
    stats = {}
    stats['cpu_percent'] = psutil.cpu_percent(interval=None)

    try:
        temps = psutil.sensors_temperatures()
        stats['temperature'] = temps.get('cpu_thermal', [type('obj', (), {'current': None})])[0].current
    except:
        stats['temperature'] = None

    mem = psutil.virtual_memory()
    stats['memory_percent'] = mem.percent
    stats['memory_used_gb'] = mem.used / (1024**3)
    stats['memory_total_gb'] = mem.total / (1024**3)

    disk = psutil.disk_usage('/')
    stats['disk_percent'] = disk.percent
    stats['disk_used_gb'] = disk.used / (1024**3)
    stats['disk_total_gb'] = disk.total / (1024**3)

    net = psutil.net_io_counters()
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

# ==================== DRAWING UTILITIES ====================
def interpolate_color(color1, color2, factor):
    """Smooth color interpolation"""
    return tuple(int(c1 + (c2 - c1) * factor) for c1, c2 in zip(color1, color2))

def draw_gradient_rect(draw, x1, y1, x2, y2, color1, color2, vertical=True):
    """Draw smooth gradient rectangle"""
    if vertical:
        for y in range(y1, y2):
            factor = (y - y1) / (y2 - y1) if y2 > y1 else 0
            color = interpolate_color(color1, color2, factor)
            draw.line([(x1, y), (x2, y)], fill=color)
    else:
        for x in range(x1, x2):
            factor = (x - x1) / (x2 - x1) if x2 > x1 else 0
            color = interpolate_color(color1, color2, factor)
            draw.line([(x, y1), (x, y2)], fill=color)

def draw_rounded_rect(draw, x, y, width, height, radius, fill, outline=None, width_outline=1):
    """Draw rounded rectangle (card)"""
    # Clamp radius to prevent negative dimensions
    radius = min(radius, width // 2, height // 2)

    # Main rectangle
    if width > radius * 2:
        draw.rectangle([x + radius, y, x + width - radius, y + height], fill=fill)
    if height > radius * 2:
        draw.rectangle([x, y + radius, x + width, y + height - radius], fill=fill)

    # Corners
    if radius > 0:
        draw.pieslice([x, y, x + radius * 2, y + radius * 2], 180, 270, fill=fill)
        draw.pieslice([x + width - radius * 2, y, x + width, y + radius * 2], 270, 360, fill=fill)
        draw.pieslice([x, y + height - radius * 2, x + radius * 2, y + height], 90, 180, fill=fill)
        draw.pieslice([x + width - radius * 2, y + height - radius * 2, x + width, y + height], 0, 90, fill=fill)

    if outline:
        # Outline
        draw.arc([x, y, x + radius * 2, y + radius * 2], 180, 270, fill=outline, width=width_outline)
        draw.arc([x + width - radius * 2, y, x + width, y + radius * 2], 270, 360, fill=outline, width=width_outline)
        draw.arc([x, y + height - radius * 2, x + radius * 2, y + height], 90, 180, fill=outline, width=width_outline)
        draw.arc([x + width - radius * 2, y + height - radius * 2, x + width, y + height], 0, 90, fill=outline, width=width_outline)
        draw.line([(x + radius, y), (x + width - radius, y)], fill=outline, width=width_outline)
        draw.line([(x + radius, y + height), (x + width - radius, y + height)], fill=outline, width=width_outline)
        draw.line([(x, y + radius), (x, y + height - radius)], fill=outline, width=width_outline)
        draw.line([(x + width, y + radius), (x + width, y + height - radius)], fill=outline, width=width_outline)

def draw_glow_circle(draw, cx, cy, radius, color, intensity=0.5):
    """Draw glowing circle effect"""
    for i in range(5):
        r = radius + i * 2
        alpha = int(intensity * 50 / (i + 1))
        glow_color = tuple(list(color[:3]) + [alpha])
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=color)

def draw_sparkline(draw, x, y, width, height, data, color, glow_color, fill=True):
    """Draw beautiful sparkline chart with glow"""
    if len(data) < 2:
        return

    points = []
    step = width / (len(data) - 1)

    for i, val in enumerate(data):
        px = x + i * step
        py = y + height - (val / 100.0 * height)
        points.append((px, py))

    # Glow effect (draw thicker lines underneath)
    if glow_color and len(points) > 1:
        for i in range(len(points) - 1):
            draw.line([points[i], points[i + 1]], fill=glow_color[:3], width=3)

    # Fill area
    if fill and len(points) > 1:
        fill_points = [(x, y + height)] + points + [(x + width, y + height)]
        # Create darker fill
        fill_color = tuple(int(c * 0.3) for c in color)
        draw.polygon(fill_points, fill=fill_color)

    # Main line
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=color, width=2)

    # Draw dots on peaks
    if len(points) > 0:
        # Last point
        px, py = points[-1]
        draw.ellipse([px - 2, py - 2, px + 2, py + 2], fill=color)

def draw_circular_progress(draw, cx, cy, radius, percent, color, bg_color, thickness=6):
    """Draw circular progress indicator"""
    # Background circle
    draw.arc([cx - radius, cy - radius, cx + radius, cy + radius], 0, 360, fill=bg_color, width=thickness)

    # Progress arc
    if percent > 0:
        angle = int(360 * percent / 100)
        draw.arc([cx - radius, cy - radius, cx + radius, cy + radius], -90, -90 + angle, fill=color, width=thickness)

def draw_status_badge(draw, x, y, text, color, font):
    """Draw status badge with gradient"""
    bbox = font.getbbox(text)
    width = bbox[2] - bbox[0] + 12
    height = 16

    # Draw pill shape
    draw_rounded_rect(draw, x, y, width, height, 8, fill=color)

    # Text
    text_x = x + 6
    text_y = y + 2
    draw.text((text_x, text_y), text, font=font, fill=TEXT_PRIMARY)

    return width

# ==================== MAIN SCREENS ====================
def draw_overview_screen(draw, fonts, stats, version, is_latest, drives, phase):
    """Ultra-modern overview with glassmorphism and animations"""
    font_title, font_big, font_medium, font_regular, font_small, font_tiny = fonts

    # === ANIMATED BACKGROUND GRADIENT ===
    # Subtle animated gradient background
    gradient_offset = int(20 * math.sin(phase * 0.1))
    for y in range(HEIGHT):
        factor = (y + gradient_offset) / HEIGHT
        color = interpolate_color((5, 5, 10), (15, 10, 25), factor)
        draw.line([(0, y), (WIDTH, y)], fill=color)

    # === GLASSMORPHIC HEADER CARD ===
    draw_rounded_rect(draw, 5, 5, 310, 42, 8, fill=BG_CARD, outline=(50, 50, 70), width_outline=1)

    # Animated status dot
    dot_x = 15
    dot_y = 15
    pulse = 0.5 + 0.5 * math.sin(phase * 0.3)
    dot_color = interpolate_color((0, 200, 100), (0, 255, 150), pulse)
    draw.ellipse([dot_x, dot_y, dot_x + 8, dot_y + 8], fill=dot_color)
    draw.ellipse([dot_x - 2, dot_y - 2, dot_x + 10, dot_y + 10], outline=dot_color)

    # piNAS Title with gradient effect
    draw.text((28, 8), "piNAS", font=font_big, fill=TEXT_PRIMARY)

    # Version badge
    version_color = GRADIENT_SUCCESS[1] if is_latest else GRADIENT_WARNING[1]
    version_x = 100
    version_y = 10
    badge_width = draw_status_badge(draw, version_x, version_y, f"v{version}", version_color, font_small)

    # Update indicator
    if not is_latest:
        update_x = version_x + badge_width + 5
        draw.ellipse([update_x, version_y + 4, update_x + 8, version_y + 12], fill=GRADIENT_WARNING[1])
        draw.text((update_x + 12, version_y + 1), "UPDATE", font=font_tiny, fill=GRADIENT_WARNING[1])

    # Time display
    now = datetime.now()
    time_str = now.strftime("%H:%M")
    draw.text((250, 8), time_str, font=font_big, fill=TEXT_PRIMARY)

    # Date and IP
    date_str = now.strftime("%d %b")
    draw.text((252, 26), date_str, font=font_tiny, fill=TEXT_SECONDARY)
    draw.text((28, 28), f"IP {stats['ip_address']}", font=font_tiny, fill=TEXT_SECONDARY)

    # === SYSTEM METRICS CARDS (2x2 Grid) ===
    card_width = 150
    card_height = 64
    card_margin = 5
    cards_start_y = 52

    # CPU Card
    cpu_x, cpu_y = 5, cards_start_y
    draw_rounded_rect(draw, cpu_x, cpu_y, card_width, card_height, 6, fill=BG_CARD)
    draw.text((cpu_x + 8, cpu_y + 6), "CPU", font=font_small, fill=TEXT_SECONDARY)

    # CPU circular progress
    cpu_center_x = cpu_x + 30
    cpu_center_y = cpu_y + 38
    draw_circular_progress(draw, cpu_center_x, cpu_center_y, 20, stats['cpu_percent'], COLOR_CPU, (30, 30, 40), 4)
    draw.text((cpu_center_x - 10, cpu_center_y - 6), f"{stats['cpu_percent']:.0f}", font=font_medium, fill=COLOR_CPU)

    # CPU sparkline
    draw_sparkline(draw, cpu_x + 65, cpu_y + 15, 80, 40, cpu_history, COLOR_CPU, COLOR_CPU_GLOW)

    # Temp indicator
    if stats['temperature']:
        temp_color = STATUS_ERROR if stats['temperature'] > 75 else STATUS_WARNING if stats['temperature'] > 65 else STATUS_ONLINE
        draw.text((cpu_x + 65, cpu_y + 6), f"{stats['temperature']:.0f}°C", font=font_tiny, fill=temp_color)

    # Memory Card
    mem_x, mem_y = 160, cards_start_y
    draw_rounded_rect(draw, mem_x, mem_y, card_width, card_height, 6, fill=BG_CARD)
    draw.text((mem_x + 8, mem_y + 6), "MEMORY", font=font_small, fill=TEXT_SECONDARY)

    # Memory circular progress
    mem_center_x = mem_x + 30
    mem_center_y = mem_y + 38
    draw_circular_progress(draw, mem_center_x, mem_center_y, 20, stats['memory_percent'], COLOR_MEM, (30, 30, 40), 4)
    draw.text((mem_center_x - 10, mem_center_y - 6), f"{stats['memory_percent']:.0f}", font=font_medium, fill=COLOR_MEM)

    # Memory sparkline
    draw_sparkline(draw, mem_x + 65, mem_y + 15, 80, 40, memory_history, COLOR_MEM, COLOR_MEM_GLOW)

    # Memory size
    draw.text((mem_x + 65, mem_y + 6), f"{stats['memory_used_gb']:.1f}GB", font=font_tiny, fill=TEXT_SECONDARY)

    # Disk Card
    disk_x, disk_y = 5, cards_start_y + card_height + 5
    draw_rounded_rect(draw, disk_x, disk_y, card_width, card_height, 6, fill=BG_CARD)
    draw.text((disk_x + 8, disk_y + 6), "STORAGE", font=font_small, fill=TEXT_SECONDARY)

    # Disk circular progress
    disk_center_x = disk_x + 30
    disk_center_y = disk_y + 38
    draw_circular_progress(draw, disk_center_x, disk_center_y, 20, stats['disk_percent'], COLOR_DISK, (30, 30, 40), 4)
    draw.text((disk_center_x - 10, disk_center_y - 6), f"{stats['disk_percent']:.0f}", font=font_medium, fill=COLOR_DISK)

    # Disk sparkline
    draw_sparkline(draw, disk_x + 65, disk_y + 15, 80, 40, disk_history, COLOR_DISK, COLOR_DISK_GLOW)

    # Disk size
    draw.text((disk_x + 65, disk_y + 6), f"{stats['disk_used_gb']:.0f}GB", font=font_tiny, fill=TEXT_SECONDARY)

    # Network Card
    net_x, net_y = 160, cards_start_y + card_height + 5
    draw_rounded_rect(draw, net_x, net_y, card_width, card_height, 6, fill=BG_CARD)
    draw.text((net_x + 8, net_y + 6), "NETWORK", font=font_small, fill=TEXT_SECONDARY)

    # Network circular indicator
    net_center_x = net_x + 30
    net_center_y = net_y + 38
    net_scaled = min(100, stats['net_speed_kb'] / 10)
    draw_circular_progress(draw, net_center_x, net_center_y, 20, net_scaled, COLOR_NET, (30, 30, 40), 4)

    # Network speed
    if stats['net_speed_kb'] < 1000:
        speed_text = f"{stats['net_speed_kb']:.0f}KB/s"
    else:
        speed_text = f"{stats['net_speed_kb']/1024:.1f}MB/s"
    draw.text((net_center_x - 15, net_center_y - 6), speed_text[:4], font=font_tiny, fill=COLOR_NET)

    # Network sparkline
    draw_sparkline(draw, net_x + 65, net_y + 15, 80, 40, network_history, COLOR_NET, COLOR_NET_GLOW)

    # === USB DRIVES SECTION ===
    drives_y = 191
    draw_rounded_rect(draw, 5, drives_y, 310, 42, 6, fill=BG_CARD)

    # Header
    draw.text((12, drives_y + 6), "USB DRIVES", font=font_small, fill=TEXT_SECONDARY)

    if drives:
        drive_count_text = f"{len(drives)}"
        draw_status_badge(draw, 85, drives_y + 4, drive_count_text, GRADIENT_INFO[1], font_tiny)

        # Show first drive
        drive = drives[0]
        drive_x = 12
        drive_y = drives_y + 22

        # Status indicator
        status_color = GRADIENT_SUCCESS[1] if drive.is_shared() else (60, 60, 70)
        draw.rectangle([drive_x, drive_y, drive_x + 6, drive_y + 6], fill=status_color)

        # Drive name
        drive_name = drive.name[:20]
        draw.text((drive_x + 10, drive_y - 2), drive_name, font=font_regular, fill=TEXT_PRIMARY)

        # Progress bar
        bar_x = drive_x + 10
        bar_y = drive_y + 12
        bar_width = 180
        bar_height = 4

        # Background
        draw_rounded_rect(draw, bar_x, bar_y, bar_width, bar_height, 2, fill=(30, 30, 40))

        # Fill
        if drive.used_percent > 0:
            fill_width = int(bar_width * drive.used_percent / 100)
            bar_color = STATUS_ERROR if drive.used_percent > 90 else STATUS_WARNING if drive.used_percent > 75 else GRADIENT_INFO[1]
            draw_rounded_rect(draw, bar_x, bar_y, fill_width, bar_height, 2, fill=bar_color)

        # Size text
        size_text = f"{drive.format_size(drive.used_bytes)} / {drive.format_size(drive.total_bytes)}"
        draw.text((bar_x + bar_width + 5, drive_y + 10), size_text, font=font_tiny, fill=TEXT_SECONDARY)

        if len(drives) > 1:
            more_text = f"+{len(drives)-1}"
            draw.text((280, drives_y + 24), more_text, font=font_tiny, fill=TEXT_MUTED)
    else:
        draw.text((12, drives_y + 20), "No drives connected", font=font_small, fill=TEXT_MUTED)

    # === SCREEN INDICATORS ===
    for i in range(max_screens):
        ind_x = 140 + i * 15
        ind_y = 235
        if i == current_screen:
            draw_rounded_rect(draw, ind_x, ind_y, 10, 3, 1, fill=TEXT_PRIMARY)
        else:
            draw.ellipse([ind_x + 3, ind_y, ind_x + 6, ind_y + 3], fill=(60, 60, 70))

def draw_drives_screen(draw, fonts, drives, phase):
    """Modern drives management screen"""
    font_title, font_big, font_medium, font_regular, font_small, font_tiny = fonts

    # Background
    for y in range(HEIGHT):
        factor = y / HEIGHT
        color = interpolate_color((5, 5, 10), (15, 10, 25), factor)
        draw.line([(0, y), (WIDTH, y)], fill=color)

    # Header
    draw_rounded_rect(draw, 5, 5, 310, 30, 6, fill=BG_CARD)
    draw.text((12, 10), "USB DRIVE MANAGER", font=font_medium, fill=TEXT_PRIMARY)

    if not drives:
        # Empty state
        empty_y = 100
        draw.text((WIDTH//2 - 60, empty_y), "No USB drives", font=font_big, fill=TEXT_MUTED)
        draw.text((WIDTH//2 - 80, empty_y + 25), "Insert a drive to get started", font=font_small, fill=TEXT_MUTED)
        return

    # Drives list
    y = 42
    for i, drive in enumerate(drives[:3]):  # Show up to 3 drives
        if y > HEIGHT - 60:
            break

        # Drive card
        card_height = 50
        draw_rounded_rect(draw, 5, y, 310, card_height, 6, fill=BG_CARD)

        # Status indicator
        is_shared = drive.is_shared()
        status_color = GRADIENT_SUCCESS[1] if is_shared else STATUS_ERROR
        draw.rectangle([12, y + 8, 20, y + 16], fill=status_color)

        # Drive name
        draw.text((26, y + 6), drive.name[:25], font=font_medium, fill=TEXT_PRIMARY)

        # Status badge
        status_text = "SHARED" if is_shared else "PRIVATE"
        badge_x = 26
        badge_y = y + 24
        draw_status_badge(draw, badge_x, badge_y, status_text, status_color, font_tiny)

        # Filesystem
        fs_type = drive.get_filesystem_type().upper()
        draw.text((badge_x + 65, badge_y + 2), fs_type, font=font_tiny, fill=TEXT_MUTED)

        # Usage bar
        bar_x = 180
        bar_y = y + 15
        bar_width = 120
        bar_height = 20

        # Background
        draw_rounded_rect(draw, bar_x, bar_y, bar_width, bar_height, 4, fill=(25, 25, 35))

        # Fill with gradient
        if drive.used_percent > 0:
            fill_width = int(bar_width * drive.used_percent / 100)
            bar_color = STATUS_ERROR if drive.used_percent > 90 else STATUS_WARNING if drive.used_percent > 75 else GRADIENT_INFO[1]
            draw_rounded_rect(draw, bar_x, bar_y, fill_width, bar_height, 4, fill=bar_color)

        # Percentage text
        percent_text = f"{drive.used_percent:.0f}%"
        text_bbox = font_small.getbbox(percent_text)
        text_width = text_bbox[2] - text_bbox[0]
        draw.text((bar_x + (bar_width - text_width) // 2, bar_y + 5), percent_text, font=font_small, fill=TEXT_PRIMARY)

        y += card_height + 6

    # Show more indicator
    if len(drives) > 3:
        more_text = f"+ {len(drives) - 3} more drives"
        draw.text((12, y), more_text, font=font_small, fill=TEXT_MUTED)

    # Screen indicators
    for i in range(max_screens):
        ind_x = 140 + i * 15
        ind_y = 235
        if i == current_screen:
            draw_rounded_rect(draw, ind_x, ind_y, 10, 3, 1, fill=TEXT_PRIMARY)
        else:
            draw.ellipse([ind_x + 3, ind_y, ind_x + 6, ind_y + 3], fill=(60, 60, 70))

def draw_stats_screen(draw, fonts, stats, phase):
    """Detailed statistics screen"""
    font_title, font_big, font_medium, font_regular, font_small, font_tiny = fonts

    # Background
    for y in range(HEIGHT):
        factor = y / HEIGHT
        color = interpolate_color((5, 5, 10), (15, 10, 25), factor)
        draw.line([(0, y), (WIDTH, y)], fill=color)

    # Header
    draw_rounded_rect(draw, 5, 5, 310, 30, 6, fill=BG_CARD)
    draw.text((12, 10), "SYSTEM STATISTICS", font=font_medium, fill=TEXT_PRIMARY)

    # Stats cards
    y = 42

    # CPU Details
    draw_rounded_rect(draw, 5, y, 152, 60, 6, fill=BG_CARD)
    draw.text((12, y + 6), "CPU", font=font_small, fill=TEXT_SECONDARY)
    draw.text((12, y + 22), f"{stats['cpu_percent']:.1f}%", font=font_big, fill=COLOR_CPU)
    if stats['temperature']:
        temp_text = f"{stats['temperature']:.1f}°C"
        temp_color = STATUS_ERROR if stats['temperature'] > 75 else STATUS_WARNING if stats['temperature'] > 65 else STATUS_ONLINE
        draw.text((12, y + 42), temp_text, font=font_small, fill=temp_color)

    # Memory Details
    draw_rounded_rect(draw, 163, y, 152, 60, 6, fill=BG_CARD)
    draw.text((170, y + 6), "MEMORY", font=font_small, fill=TEXT_SECONDARY)
    draw.text((170, y + 22), f"{stats['memory_percent']:.1f}%", font=font_big, fill=COLOR_MEM)
    mem_text = f"{stats['memory_used_gb']:.2f} / {stats['memory_total_gb']:.1f} GB"
    draw.text((170, y + 42), mem_text, font=font_tiny, fill=TEXT_SECONDARY)

    y += 68

    # Disk Details
    draw_rounded_rect(draw, 5, y, 152, 60, 6, fill=BG_CARD)
    draw.text((12, y + 6), "STORAGE", font=font_small, fill=TEXT_SECONDARY)
    draw.text((12, y + 22), f"{stats['disk_percent']:.1f}%", font=font_big, fill=COLOR_DISK)
    disk_text = f"{stats['disk_used_gb']:.1f} / {stats['disk_total_gb']:.1f} GB"
    draw.text((12, y + 42), disk_text, font=font_tiny, fill=TEXT_SECONDARY)

    # Network Details
    draw_rounded_rect(draw, 163, y, 152, 60, 6, fill=BG_CARD)
    draw.text((170, y + 6), "NETWORK", font=font_small, fill=TEXT_SECONDARY)
    if stats['net_speed_kb'] < 1000:
        speed_text = f"{stats['net_speed_kb']:.0f}"
        unit = "KB/s"
    else:
        speed_text = f"{stats['net_speed_kb']/1024:.1f}"
        unit = "MB/s"
    draw.text((170, y + 22), speed_text, font=font_big, fill=COLOR_NET)
    draw.text((170, y + 42), unit, font=font_tiny, fill=TEXT_SECONDARY)

    y += 68

    # System info card
    draw_rounded_rect(draw, 5, y, 310, 40, 6, fill=BG_CARD)
    draw.text((12, y + 6), "IP ADDRESS", font=font_tiny, fill=TEXT_SECONDARY)
    draw.text((12, y + 18), stats['ip_address'], font=font_medium, fill=TEXT_PRIMARY)

    # Screen indicators
    for i in range(max_screens):
        ind_x = 140 + i * 15
        ind_y = 235
        if i == current_screen:
            draw_rounded_rect(draw, ind_x, ind_y, 10, 3, 1, fill=TEXT_PRIMARY)
        else:
            draw.ellipse([ind_x + 3, ind_y, ind_x + 6, ind_y + 3], fill=(60, 60, 70))

# ==================== TOUCH HANDLING ====================
def handle_touch(x, y, drives):
    global current_screen, last_touch_time

    current_time = time.time()
    if current_time - last_touch_time < touch_debounce:
        return
    last_touch_time = current_time

    # Cycle through screens on any touch
    current_screen = (current_screen + 1) % max_screens

# ==================== LIQUID BLOB BOOT ANIMATION ====================
def draw_boot_animation(display, fonts):
    """Epic liquid blob animation with spinning, merging blobs - Optimized for smooth 60 FPS"""
    frames = 90  # Optimized frame count

    # Use lower resolution for rendering, then scale up
    render_width, render_height = 160, 120  # Half resolution = 4x faster rendering

    # Blob colors
    blob_colors = [GRADIENT_PRIMARY[0], COLOR_CPU, GRADIENT_SUCCESS[0], COLOR_NET]

    # Define 4 blobs that spin and merge
    num_blobs = 4

    for frame in range(frames):
        # Render at lower resolution
        image = Image.new("RGB", (render_width, render_height), BG_DARK)
        draw = ImageDraw.Draw(image)

        # Animation progress
        t = frame / frames
        angle = t * math.pi * 6  # 3 full rotations

        # Phase 1: Blobs spin in from corners (0-40%)
        # Phase 2: Blobs orbit center, growing (40-70%)
        # Phase 3: Blobs merge and explode (70-100%)

        cx, cy = render_width // 2, render_height // 2

        if t < 0.4:
            # Spin in from corners
            phase_t = t / 0.4
            orbit_radius = 80 * (1 - phase_t)  # Start far, move to center
            blob_size = 8 * phase_t  # Small to medium
            explosion = 0
        elif t < 0.7:
            # Orbit and grow
            phase_t = (t - 0.4) / 0.3
            orbit_radius = 25
            blob_size = 8 + 8 * phase_t  # Medium to large
            explosion = 0
        else:
            # Merge and explode
            phase_t = (t - 0.7) / 0.3
            orbit_radius = 25 * (1 - phase_t * 0.8)  # Pull together
            blob_size = 16 + 30 * phase_t  # Grow massive
            explosion = phase_t

        # Draw each blob
        for i in range(num_blobs):
            blob_angle = angle + (i * math.pi * 2 / num_blobs)

            # Calculate blob position (spinning around center)
            bx = int(cx + math.cos(blob_angle) * orbit_radius)
            by = int(cy + math.sin(blob_angle) * orbit_radius)

            # Blob color
            color = blob_colors[i]

            # Add pulsing effect
            pulse = 1.0 + 0.2 * math.sin(angle * 2 + i)
            current_size = int(blob_size * pulse)

            # Draw glow
            if explosion > 0:
                glow_size = int(current_size + explosion * 40)
                glow_alpha = 0.3 * (1 - explosion)
                for g in range(glow_size, current_size, -3):
                    glow_color = tuple(int(c * glow_alpha) for c in color)
                    draw.ellipse([bx - g, by - g, bx + g, by + g], fill=glow_color)
            else:
                # Normal glow
                for g in range(current_size + 8, current_size, -2):
                    glow_alpha = 0.4 * (1 - (g - current_size) / 8)
                    glow_color = tuple(int(c * glow_alpha) for c in color)
                    draw.ellipse([bx - g, by - g, bx + g, by + g], fill=glow_color)

            # Draw main blob
            draw.ellipse([bx - current_size, by - current_size,
                         bx + current_size, by + current_size], fill=color)

            # Add shine/highlight
            shine_offset = current_size // 3
            shine_size = current_size // 4
            shine_color = tuple(min(255, int(c * 1.5)) for c in color)
            draw.ellipse([bx - shine_offset - shine_size, by - shine_offset - shine_size,
                         bx - shine_offset + shine_size, by - shine_offset + shine_size],
                        fill=shine_color)

        # Draw connecting tendrils between blobs when merging
        if t > 0.6:
            tendril_alpha = (t - 0.6) / 0.4
            for i in range(num_blobs):
                blob_angle1 = angle + (i * math.pi * 2 / num_blobs)
                blob_angle2 = angle + ((i + 1) % num_blobs * math.pi * 2 / num_blobs)

                bx1 = int(cx + math.cos(blob_angle1) * orbit_radius)
                by1 = int(cy + math.sin(blob_angle1) * orbit_radius)
                bx2 = int(cx + math.cos(blob_angle2) * orbit_radius)
                by2 = int(cy + math.sin(blob_angle2) * orbit_radius)

                # Draw tendril with gradient
                color1 = blob_colors[i]
                color2 = blob_colors[(i + 1) % num_blobs]

                for w in range(int(8 * tendril_alpha), 0, -2):
                    alpha = w / (8 * tendril_alpha)
                    line_color = tuple(int((c1 + c2) / 2 * alpha) for c1, c2 in zip(color1, color2))
                    draw.line([bx1, by1, bx2, by2], fill=line_color, width=w)

        # Explosion particles
        if explosion > 0.5:
            num_particles = int((explosion - 0.5) * 80)
            for p in range(num_particles):
                particle_angle = (p / num_particles) * math.pi * 2 + angle
                particle_dist = explosion * 100
                px = int(cx + math.cos(particle_angle) * particle_dist)
                py = int(cy + math.sin(particle_angle) * particle_dist)

                if 0 <= px < render_width and 0 <= py < render_height:
                    particle_color = blob_colors[p % num_blobs]
                    particle_alpha = 1 - (explosion - 0.5) * 2
                    particle_color = tuple(int(c * particle_alpha) for c in particle_color)
                    particle_size = 2 + int(explosion * 2)
                    draw.ellipse([px - particle_size, py - particle_size,
                                px + particle_size, py + particle_size], fill=particle_color)

        # Text fade in
        if t > 0.5:
            text_alpha = (t - 0.5) / 0.5
            text = "piNAS"
            text_color = tuple(int(c * text_alpha) for c in GRADIENT_PRIMARY[1])

            # Draw text with glow (use smaller font for lower res)
            font_medium = fonts[2]  # Use medium font for lower res
            bbox = draw.textbbox((0, 0), text, font=font_medium)
            text_width = bbox[2] - bbox[0]
            text_x = (render_width - text_width) // 2
            text_y = render_height - 25

            # Glow effect (less intensive)
            for offset in range(3, 0, -1):
                glow_color = tuple(int(c * text_alpha * 0.3) for c in GRADIENT_PRIMARY[0])
                draw.text((text_x, text_y), text, font=font_medium,
                         fill=glow_color, stroke_width=offset)

            draw.text((text_x, text_y), text, font=font_medium, fill=text_color)

        # Scale up to full resolution
        image = image.resize((WIDTH, HEIGHT), Image.Resampling.BILINEAR)
        display.image(image)

        # Save frame for monitoring
        try:
            image.save("/tmp/pinas-dashboard-live.png")
        except:
            pass

        time.sleep(0.016)  # 60 FPS target - optimized rendering

def draw_shutdown_animation(display, fonts):
    """Epic implosion and color drain shutdown animation - Optimized for smooth 60 FPS"""
    frames = 60  # Optimized frame count

    # Use lower resolution for rendering
    render_width, render_height = 160, 120

    for frame in range(frames):
        image = Image.new("RGB", (render_width, render_height), BG_DARK)
        draw = ImageDraw.Draw(image)

        t = frame / frames

        # Create implosion effect - rings collapsing to center
        cx, cy = render_width // 2, render_height // 2
        num_rings = 15  # Reduce rings for performance

        for i in range(num_rings):
            ring_t = (i / num_rings)
            ring_progress = t + ring_t

            if ring_progress < 1.0:
                # Ring size shrinks over time
                radius = int((1.0 - ring_progress) * max(render_width, render_height))

                # Color cycles through palette
                color_idx = int((ring_t * 4 + t) * len([GRADIENT_PRIMARY[0], COLOR_CPU,
                                                         GRADIENT_SUCCESS[0], COLOR_NET]))
                colors = [GRADIENT_PRIMARY[0], COLOR_CPU, GRADIENT_SUCCESS[0], COLOR_NET]
                color = colors[color_idx % len(colors)]

                # Fade out
                alpha = 1.0 - ring_progress
                color = tuple(int(c * alpha) for c in color)

                # Draw ring
                draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius],
                           outline=color, width=2)

        # Spiraling particles (reduced for performance)
        num_particles = 20
        for i in range(num_particles):
            particle_t = (i / num_particles) * math.pi * 2
            spiral_angle = particle_t + t * math.pi * 4
            spiral_radius = (1.0 - t) * 60  # Scale for lower res

            px = int(cx + math.cos(spiral_angle) * spiral_radius)
            py = int(cy + math.sin(spiral_angle) * spiral_radius)

            if 0 <= px < render_width and 0 <= py < render_height:
                particle_color = [COLOR_CPU, GRADIENT_PRIMARY[1],
                                COLOR_NET, GRADIENT_SUCCESS[1]][i % 4]
                alpha = 1.0 - t
                particle_color = tuple(int(c * alpha) for c in particle_color)
                draw.ellipse([px-2, py-2, px+2, py+2], fill=particle_color)

        # Text fade out
        if t < 0.6:
            text_alpha = 1.0 - (t / 0.6)
            text = "Shutting Down"
            text_color = tuple(int(c * text_alpha) for c in (150, 150, 150))

            font_small = fonts[4]  # Use small font for lower res
            bbox = draw.textbbox((0, 0), text, font=font_small)
            text_width = bbox[2] - bbox[0]
            text_x = (render_width - text_width) // 2
            text_y = render_height // 2 - 5

            draw.text((text_x, text_y), text, font=font_small, fill=text_color)

        # Scale up to full resolution
        image = image.resize((WIDTH, HEIGHT), Image.Resampling.BILINEAR)
        display.image(image)

        # Save frame for monitoring
        try:
            image.save("/tmp/pinas-dashboard-live.png")
        except:
            pass

        time.sleep(0.016)  # 60 FPS target - optimized rendering

    # Final black screen
    image = Image.new("RGB", (WIDTH, HEIGHT), BG_DARK)
    display.image(image)

# ==================== MAIN LOOP ====================
def main():
    display, touch, driver = init_display_and_touch()
    fonts = load_fonts()

    print("=" * 50)
    print("piNAS Dashboard - MASTERPIECE EDITION")
    print("=" * 50)
    print(f"Display: {WIDTH}x{HEIGHT} @ {BAUDRATE}Hz")
    print(f"Touch: {driver if driver else 'None'}")
    print("Premium features: Glassmorphism, Gradients, Animations, 3D Boot/Shutdown")
    print("=" * 50)

    # Play epic boot animation
    print("Playing boot animation...")
    draw_boot_animation(display, fonts)
    print("Boot animation complete!")

    global current_screen, animation_phase
    last_update = 0

    try:
        while True:
            current_time = time.time()
            animation_phase += 0.1

            # Touch input
            if touch:
                touch_pos = map_touch(touch, driver)
                if touch_pos:
                    handle_touch(touch_pos[0], touch_pos[1], get_usb_drives())

            # Update display
            if current_time - last_update >= UPDATE_INTERVAL:
                stats = get_system_stats()
                version, is_latest = get_version_info()
                drives = get_usb_drives()

                # Update histories
                cpu_history.append(stats['cpu_percent'])
                memory_history.append(stats['memory_percent'])
                disk_history.append(stats['disk_percent'])
                network_history.append(min(100, stats['net_speed_kb'] / 10))

                # Create frame
                image = Image.new("RGB", (WIDTH, HEIGHT), BG_DARK)
                draw = ImageDraw.Draw(image)

                # Draw current screen
                if current_screen == 0:
                    draw_overview_screen(draw, fonts, stats, version, is_latest, drives, animation_phase)
                elif current_screen == 1:
                    draw_drives_screen(draw, fonts, drives, animation_phase)
                else:
                    draw_stats_screen(draw, fonts, stats, animation_phase)

                display.image(image)

                # Save screenshot for remote monitoring
                try:
                    image.save("/tmp/pinas-dashboard-live.png")
                except:
                    pass

                last_update = current_time

            time.sleep(0.05)

    except KeyboardInterrupt:
        print("\nShutting down masterpiece dashboard...")
        # Play epic shutdown animation
        draw_shutdown_animation(display, fonts)
        print("Shutdown animation complete!")

if __name__ == "__main__":
    main()
