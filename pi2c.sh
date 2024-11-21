import time
import psutil
import subprocess
from luma.core.interface.serial import i2c
from luma.core.render import canvas
from luma.oled.device import ssd1306

def get_ip_address(interface):
    try:
        cmd = f"hostname -I | cut -d' ' -f1"
        result = subprocess.check_output(cmd, shell=True).decode().strip()
        return result if result else "Not connected"
    except:
        return "Not connected"

def format_speed(speed_kbps):
    """Convert speed to appropriate unit and return formatted string"""
    if speed_kbps >= 1024 * 1024:  # >= 1 GB/s
        return f"{speed_kbps / (1024 * 1024):.1f} GB/s"
    elif speed_kbps >= 1024:  # >= 1 MB/s
        return f"{speed_kbps / 1024:.1f} MB/s"
    else:  # < 1 MB/s
        return f"{speed_kbps:.1f} KB/s"

def get_network_speed(interface):
    try:
        # Reset network stats to prevent stuck counters
        psutil.net_io_counters.cache_clear()
        
        # Get initial bytes
        net_stat = psutil.net_io_counters(pernic=True)
        if interface not in net_stat:
            return 0, 0
            
        bytes_sent = net_stat[interface].bytes_sent
        bytes_recv = net_stat[interface].bytes_recv
        
        time.sleep(1)  # Wait 1 second
        
        # Clear cache again before second reading
        psutil.net_io_counters.cache_clear()
        
        # Get final bytes
        net_stat = psutil.net_io_counters(pernic=True)
        bytes_sent_new = net_stat[interface].bytes_sent
        bytes_recv_new = net_stat[interface].bytes_recv
        
        # Calculate speed in KB/s
        upload_speed = (bytes_sent_new - bytes_sent) / 1024
        download_speed = (bytes_recv_new - bytes_recv) / 1024
        
        # Sanity check - if values are unreasonable, return 0
        if upload_speed < 0 or upload_speed > 1024 * 1024 * 1024:  # > 1 TB/s is unlikely
            upload_speed = 0
        if download_speed < 0 or download_speed > 1024 * 1024 * 1024:
            download_speed = 0
            
        return upload_speed, download_speed
    except Exception as e:
        print(f"Error getting network speed: {e}")
        return 0, 0

def get_active_interface():
    """Find the active network interface (either wlan0 or eth0)"""
    try:
        # Check if wlan0 is up and has an IP
        wlan_ip = subprocess.check_output("ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}'", shell=True).decode().strip()
        if wlan_ip:
            return "wlan0"
    except:
        pass
    
    try:
        # Check if eth0 is up and has an IP
        eth_ip = subprocess.check_output("ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}'", shell=True).decode().strip()
        if eth_ip:
            return "eth0"
    except:
        pass
    
    return "wlan0"  # Default to wlan0 if nothing is found

def main():
    # Initialize I2C
    serial = i2c(port=1, address=0x3C)
    
    # Initialize OLED
    device = ssd1306(serial, width=128, height=64)
    
    # Counter for periodic full reset
    reset_counter = 0
    
    while True:
        try:
            # Get active interface
            interface = get_active_interface()
            
            # Get IP addresses
            local_ip = get_ip_address(interface)
            try:
                public_ip = subprocess.check_output("curl -s ifconfig.me", shell=True).decode().strip()
            except:
                public_ip = "Unable to get"
            
            # Get network speeds
            upload_speed, download_speed = get_network_speed(interface)
            
            # Format speeds with appropriate units
            upload_str = format_speed(upload_speed)
            download_str = format_speed(download_speed)
            
            # Draw on OLED
            with canvas(device) as draw:
                draw.text((0, 0), f"Ext: {public_ip}", fill="white")
                draw.text((0, 16), f"Int: {local_ip}", fill="white")
                draw.text((0, 32), f"Up: {upload_str}", fill="white")
                draw.text((0, 48), f"Down: {download_str}", fill="white")
            
            # Increment reset counter
            reset_counter += 1
            
            # Every 60 iterations (about 1 minute), clear psutil's cache completely
            if reset_counter >= 60:
                psutil.net_io_counters.cache_clear()
                reset_counter = 0
            
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Error in main loop: {e}")
            with canvas(device) as draw:
                draw.text((0, 0), "Error:", fill="white")
                draw.text((0, 16), str(e)[:20], fill="white")
            time.sleep(5)
            # Reset psutil cache on error
            psutil.net_io_counters.cache_clear()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Exiting...")
