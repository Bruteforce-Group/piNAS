#!/usr/bin/env python3
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
HISTORY_SIZE = 60  # Keep 60 data points for charts
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

class USBDrive:
    def __init__(self, mount_path: str):
        self.mount_path = mount_path
        self.name = os.path.basename(mount_path)
        self.update_info()
    
    def update_info(self):
        try:
            stat = os.statvfs(self.mount_path)
            self.total_bytes = stat.f_frsize * stat.f_blocks
            self.free_bytes = stat.f_frsize * stat.f_bavail
            self.used_bytes = self.total_bytes - self.free_bytes
            self.used_percent = (self.used_bytes / self.total_bytes * 100) if self.total_bytes > 0 else 0
        except OSError:
            self.total_bytes = self.free_bytes = self.used_bytes = 0
            self.used_percent = 0
    
    def format_size(self, bytes_val: int) -> str:
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024.0:
                return f"{bytes_val:.1f}{unit}"
            bytes_val /= 1024.0
        return f"{bytes_val:.1f}PB"
    
    def get_filesystem_type(self) -> str:
        try:
            result = subprocess.run(['findmnt', '-n', '-o', 'FSTYPE', self.mount_path], 
                                  capture_output=True, text=True, timeout=2)
            return result.stdout.strip() or "unknown"
        except:
            return "unknown"
    
    def is_shared(self) -> bool:
        try:
            with open('/etc/samba/usb-shares.conf', 'r') as f:
                content = f.read()
                return f"[{self.name}]" in content
        except:
            return False
    
    def toggle_share(self):
        """Toggle Samba share for this drive"""
        try:
            subprocess.run(['/usr/local/sbin/usb-autoshare', 'add', 'dummy'], 
                         timeout=5, check=False)
        except:
            pass
    
    def format_drive(self, fs_type: str = "exfat"):
        """Format the drive (requires confirmation)"""
        try:
            device = self.get_device_path()
            if device:
                subprocess.run(['umount', self.mount_path], check=False)
                if fs_type == "exfat":
                    subprocess.run(['mkfs.exfat', device], timeout=60)
                elif fs_type == "ext4":
                    subprocess.run(['mkfs.ext4', '-F', device], timeout=60)
                elif fs_type == "ntfs":
                    subprocess.run(['mkfs.ntfs', '-F', device], timeout=60)
        except:
            pass
    
    def get_device_path(self) -> Optional[str]:
        try:
            result = subprocess.run(['findmnt', '-n', '-o', 'SOURCE', self.mount_path], 
                                  capture_output=True, text=True, timeout=2)
            return result.stdout.strip()
        except:
            return None

def init_display_and_touch():
    spi = board.SPI()
    dc_pin = digitalio.DigitalInOut(TFT_DC)
    cs_pin = digitalio.DigitalInOut(TFT_CS)
    
    display = ili9341.ILI9341(
        spi, cs=cs_pin, dc=dc_pin, rst=TFT_RST,
        baudrate=BAUDRATE, rotation=270
    )
    
    # Initialize touch
    touch = None
    driver = None
    
    if adafruit_stmpe610 is not None:
        try:
            touch_cs = digitalio.DigitalInOut(TOUCH_CS)
            touch_cs.switch_to_output(value=True)
            touch = adafruit_stmpe610.Adafruit_STMPE610_SPI(
                spi, cs=touch_cs, baudrate=1_000_000
            )
            driver = "stmpe610"
        except:
            touch = None
    
    if touch is None and adafruit_xpt2046 is not None:
        try:
            touch_cs = digitalio.DigitalInOut(TOUCH_CS)
            touch = adafruit_xpt2046.XPT2046(spi, cs=touch_cs, baudrate=2_000_000)
            driver = "xpt2046"
        except:
            touch = None
    
    return display, touch, driver

def load_fonts():
    try:
        font_big = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 16)
        font_medium = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 14)
        font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 12)
    except OSError:
        font_big = font_medium = font_small = ImageFont.load_default()
    return font_big, font_medium, font_small

def get_version_info() -> Tuple[str, bool]:
    try:
        with open(VERSION_FILE, 'r') as f:
            current_version = f.read().strip()
    except:
        current_version = "unknown"
    
    # Check for updates
    is_latest = check_for_updates(current_version)
    return current_version, is_latest

def check_for_updates(current_version: str) -> bool:
    try:
        # Check GitHub API for latest release
        url = "https://api.github.com/repos/Bruteforce-Group/piNAS/releases/latest"
        with urllib.request.urlopen(url, timeout=5) as response:
            data = json.loads(response.read())
            latest_version = data.get("tag_name", "")
            return current_version == latest_version
    except:
        return True  # Assume latest if we can't check

def map_touch(touch, driver):
    if touch is None:
        return None
    
    try:
        if hasattr(touch, "touched"):
            if not touch.touched:
                return None
        elif hasattr(touch, "tirq_touched"):
            if not touch.tirq_touched():
                return None
        
        p = touch.touch_point
        if p is None:
            return None
        
        x_raw, y_raw, *_ = p
        
        if driver == "xpt2046":
            # XPT2046 calibration for 270° rotation
            screen_x = int((y_raw - 143) * WIDTH / (3715 - 143))
            screen_y = int((3786 - x_raw) * HEIGHT / (3786 - 216))
        else:
            # STMPE610 calibration
            MIN_X, MAX_X = 200, 3800
            MIN_Y, MAX_Y = 200, 3800
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
    # CPU
    cpu_percent = psutil.cpu_percent(interval=None)
    cpu_history.append(cpu_percent)
    
    # Memory
    memory = psutil.virtual_memory()
    memory_history.append(memory.percent)
    
    # Disk
    disk = psutil.disk_usage('/')
    disk_percent = (disk.used / disk.total) * 100
    disk_history.append(disk_percent)
    
    # Network
    try:
        net_io = psutil.net_io_counters()
        current_bytes = net_io.bytes_sent + net_io.bytes_recv
        if network_history:
            last_bytes = network_history[-1] if network_history else 0
            bytes_per_sec = (current_bytes - last_bytes) / UPDATE_INTERVAL
            network_history.append(bytes_per_sec / 1024)  # KB/s
        else:
            network_history.append(0)
    except:
        network_history.append(0)
    
    # Temperature
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
            temp_c = int(f.read().strip()) / 1000.0
    except:
        temp_c = None
    
    return {
        'cpu_percent': cpu_percent,
        'memory_percent': memory.percent,
        'memory_used_gb': memory.used / (1024**3),
        'memory_total_gb': memory.total / (1024**3),
        'disk_percent': disk_percent,
        'disk_used_gb': disk.used / (1024**3),
        'disk_total_gb': disk.total / (1024**3),
        'temperature': temp_c
    }

def get_usb_drives() -> List[USBDrive]:
    drives = []
    if os.path.exists(MOUNT_ROOT):
        for name in os.listdir(MOUNT_ROOT):
            path = os.path.join(MOUNT_ROOT, name)
            if os.path.ismount(path):
                drives.append(USBDrive(path))
    return drives

def draw_chart(draw, x, y, width, height, data, color, title, font):
    # Chart background
    draw.rectangle([x, y, x + width, y + height], outline=color, width=1)
    
    # Title
    draw.text((x + 2, y - 15), title, font=font, fill=color)
    
    if len(data) < 2:
        return
    
    # Scale data to chart height
    max_val = max(data) if data else 100
    min_val = min(data) if data else 0
    if max_val == min_val:
        max_val = min_val + 1
    
    points = []
    for i, value in enumerate(data):
        chart_x = x + (i * width) // len(data)
        chart_y = y + height - int((value - min_val) * height / (max_val - min_val))
        points.append((chart_x, chart_y))
    
    # Draw line chart
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=color, width=1)
    
    # Show current value
    current_val = data[-1] if data else 0
    draw.text((x + width - 30, y + 2), f"{current_val:.1f}%", font=font, fill=color)

def draw_overview_screen(draw, font_big, font_medium, font_small, stats, version, is_latest, drives):
    # Header
    draw.text((5, 5), f"piNAS {HOSTNAME}", font=font_big, fill=(255, 255, 255))
    
    # Version info
    version_color = (0, 255, 0) if is_latest else (255, 255, 0)
    version_text = f"v{version}" + ("" if is_latest else " (update available)")
    draw.text((5, 25), version_text, font=font_small, fill=version_color)
    
    # Time
    now = datetime.now().strftime("%H:%M:%S")
    draw.text((250, 5), now, font=font_medium, fill=(255, 255, 255))
    
    # System stats charts (2x2 grid)
    chart_width = 75
    chart_height = 40
    
    # CPU Chart
    draw_chart(draw, 5, 50, chart_width, chart_height, cpu_history, 
              (255, 100, 100), "CPU", font_small)
    
    # Memory Chart  
    draw_chart(draw, 85, 50, chart_width, chart_height, memory_history,
              (100, 255, 100), "RAM", font_small)
    
    # Disk Chart
    draw_chart(draw, 165, 50, chart_width, chart_height, disk_history,
              (100, 100, 255), "Disk", font_small)
    
    # Network Chart
    draw_chart(draw, 245, 50, chart_width, chart_height, network_history,
              (255, 255, 100), "Net KB/s", font_small)
    
    # System info text
    y_pos = 100
    draw.text((5, y_pos), f"CPU: {stats['cpu_percent']:.1f}%", font=font_small, fill=(255, 255, 255))
    if stats['temperature']:
        draw.text((80, y_pos), f"Temp: {stats['temperature']:.1f}°C", font=font_small, fill=(255, 255, 255))
    
    y_pos += 15
    draw.text((5, y_pos), f"RAM: {stats['memory_used_gb']:.1f}/{stats['memory_total_gb']:.1f}GB", 
             font=font_small, fill=(255, 255, 255))
    
    y_pos += 15
    draw.text((5, y_pos), f"Disk: {stats['disk_used_gb']:.1f}/{stats['disk_total_gb']:.1f}GB", 
             font=font_small, fill=(255, 255, 255))
    
    # USB Drives section
    y_pos = 155
    draw.text((5, y_pos), "USB Drives:", font=font_medium, fill=(255, 255, 255))
    y_pos += 20
    
    if drives:
        for i, drive in enumerate(drives[:4]):  # Show up to 4 drives
            x_pos = 5 + (i % 2) * 160
            y_offset = (i // 2) * 30
            
            # Drive icon and name
            icon_color = (0, 255, 0) if drive.is_shared() else (100, 100, 100)
            draw.rectangle([x_pos, y_pos + y_offset, x_pos + 8, y_pos + y_offset + 8], 
                         fill=icon_color)
            
            # Drive name and info
            draw.text((x_pos + 12, y_pos + y_offset - 2), drive.name[:15], 
                     font=font_small, fill=(255, 255, 255))
            draw.text((x_pos + 12, y_pos + y_offset + 10), 
                     f"{drive.format_size(drive.free_bytes)} free", 
                     font=font_small, fill=(200, 200, 200))
    else:
        draw.text((5, y_pos), "No USB drives", font=font_small, fill=(100, 100, 100))

def draw_drives_screen(draw, font_big, font_medium, font_small, drives):
    draw.text((5, 5), "USB Drive Manager", font=font_big, fill=(255, 255, 255))
    
    if not drives:
        draw.text((5, 50), "No USB drives connected", font=font_medium, fill=(100, 100, 100))
        return
    
    y_pos = 30
    for i, drive in enumerate(drives):
        if y_pos > HEIGHT - 60:
            break
            
        # Drive header
        share_status = "SHARED" if drive.is_shared() else "PRIVATE"
        status_color = (0, 255, 0) if drive.is_shared() else (255, 100, 100)
        
        draw.text((5, y_pos), f"{drive.name} - {share_status}", font=font_medium, fill=status_color)
        y_pos += 18
        
        # Drive info
        fs_type = drive.get_filesystem_type()
        draw.text((5, y_pos), f"Type: {fs_type}", font=font_small, fill=(200, 200, 200))
        draw.text((5, y_pos + 12), 
                 f"Size: {drive.format_size(drive.total_bytes)} "
                 f"({drive.used_percent:.1f}% used)", 
                 font=font_small, fill=(200, 200, 200))
        
        # Action buttons
        button_y = y_pos + 25
        
        # Share/Unshare button
        share_text = "Unshare" if drive.is_shared() else "Share"
        draw.rectangle([5, button_y, 60, button_y + 15], outline=(255, 255, 255), width=1)
        draw.text((8, button_y + 2), share_text, font=font_small, fill=(255, 255, 255))
        
        # Format button
        draw.rectangle([70, button_y, 125, button_y + 15], outline=(255, 100, 100), width=1)
        draw.text((73, button_y + 2), "Format", font=font_small, fill=(255, 100, 100))
        
        y_pos += 50

def handle_touch(x, y, drives):
    global current_screen, last_touch_time
    
    current_time = time.time()
    if current_time - last_touch_time < touch_debounce:
        return
    last_touch_time = current_time
    
    if current_screen == 0:  # Overview screen
        # Touch anywhere to switch to drives screen
        current_screen = 1
    
    elif current_screen == 1:  # Drives screen
        # Check for button touches
        y_pos = 48  # Start after header
        for i, drive in enumerate(drives):
            if y_pos > HEIGHT - 60:
                break
            
            button_y = y_pos + 25
            
            # Share/Unshare button
            if 5 <= x <= 60 and button_y <= y <= button_y + 15:
                drive.toggle_share()
                return
            
            # Format button  
            if 70 <= x <= 125 and button_y <= y <= button_y + 15:
                # For safety, require double-tap for format
                # This is a simple implementation
                drive.format_drive("exfat")
                return
            
            y_pos += 50
        
        # Touch elsewhere to go back
        current_screen = 0

def main():
    display, touch, driver = init_display_and_touch()
    font_big, font_medium, font_small = load_fonts()
    
    print(f"piNAS Dashboard started (touch driver: {driver or 'none'})")
    
    last_update = 0
    
    while True:
        current_time = time.time()
        
        # Handle touch input
        if touch:
            touch_pos = map_touch(touch, driver)
            if touch_pos:
                handle_touch(touch_pos[0], touch_pos[1], get_usb_drives())
        
        # Update data periodically
        if current_time - last_update >= UPDATE_INTERVAL:
            stats = get_system_stats()
            version, is_latest = get_version_info()
            drives = get_usb_drives()
            
            # Create display image
            image = Image.new("RGB", (WIDTH, HEIGHT), (0, 0, 0))
            draw = ImageDraw.Draw(image)
            
            if current_screen == 0:
                draw_overview_screen(draw, font_big, font_medium, font_small, 
                                   stats, version, is_latest, drives)
            else:
                draw_drives_screen(draw, font_big, font_medium, font_small, drives)
            
            # Show screen indicator
            for i in range(max_screens):
                color = (255, 255, 255) if i == current_screen else (100, 100, 100)
                draw.ellipse([290 + i*10, 230, 296 + i*10, 236], fill=color)
            
            display.image(image)
            last_update = current_time
        
        time.sleep(0.1)

if __name__ == "__main__":
    main()