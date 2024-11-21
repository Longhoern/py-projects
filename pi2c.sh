#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default installation directory
INSTALL_DIR="/home/$SUDO_USER/display"

echo -e "${GREEN}Starting OLED display setup...${NC}"

# Function to check if a command was successful
check_status() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $1${NC}"
    else
        echo -e "${RED}✗ $1 failed${NC}"
        exit 1
    fi
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

# Update package list
echo -e "${YELLOW}Updating package list...${NC}"
apt update
check_status "Package list update"

# Install required packages
echo -e "${YELLOW}Installing required packages...${NC}"
apt install -y python3-pip python3-pil python3-psutil i2c-tools curl git
check_status "Package installation"

# Install luma.oled
echo -e "${YELLOW}Installing luma.oled...${NC}"
apt install -y python3-luma.oled
check_status "Luma.OLED installation"

# Enable I2C interface
echo -e "${YELLOW}Enabling I2C interface...${NC}"
if ! grep -q "i2c-dev" /etc/modules; then
    echo "i2c-dev" >> /etc/modules
fi
raspi-config nonint do_i2c 0
check_status "I2C interface enable"

# Create directory for the monitor script
echo -e "${YELLOW}Creating directory for monitor script...${NC}"
mkdir -p "$INSTALL_DIR"
check_status "Directory creation"

# Set proper ownership for the installation directory
chown -R $SUDO_USER:$SUDO_USER "$INSTALL_DIR"
check_status "Setting directory ownership"

# Create the network monitor script
echo -e "${YELLOW}Creating network monitor script...${NC}"
cat > "$INSTALL_DIR/network-display.py" << 'EOL'
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
EOL
check_status "Script creation"

# Set proper permissions for the script
chmod 755 "$INSTALL_DIR/network-display.py"
chown root:root "$INSTALL_DIR/network-display.py"
check_status "Script permissions"

# Create systemd service
echo -e "${YELLOW}Creating systemd service...${NC}"
cat > /etc/systemd/system/network-monitor.service << EOL
[Unit]
Description=Network Monitor OLED Display
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/network-display.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1
Environment=DISPLAY=:0

[Install]
WantedBy=multi-user.target
EOL
check_status "Service creation"

# Enable and start the service
echo -e "${YELLOW}Enabling and starting service...${NC}"
systemctl daemon-reload
systemctl enable network-monitor
systemctl start network-monitor
check_status "Service setup"

# Add current user to i2c group
if [ "$SUDO_USER" ]; then
    usermod -a -G i2c $SUDO_USER
    check_status "User added to i2c group"
fi

# Final checks
echo -e "${YELLOW}Performing final checks...${NC}"
if systemctl is-active --quiet network-monitor; then
    echo -e "${GREEN}✓ Service is running${NC}"
else
    echo -e "${RED}✗ Service failed to start${NC}"
    echo -e "${YELLOW}Checking service logs:${NC}"
    journalctl -u network-monitor -n 10
fi

# Installation cleanup
echo -e "${YELLOW}Performing installation cleanup...${NC}"
apt autoremove -y
apt clean
check_status "Cleanup"

echo -e "\n${GREEN}Installation complete!${NC}"
echo -e "\nInstallation details:"
echo -e "${YELLOW}Script location:${NC} $INSTALL_DIR/network-display.py"
echo -e "${YELLOW}Service location:${NC} /etc/systemd/system/network-monitor.service"
echo -e "\nUseful commands:"
echo -e "${YELLOW}Check service status:${NC} sudo systemctl status network-monitor"
echo -e "${YELLOW}View logs:${NC} sudo journalctl -u network-monitor -f"
echo -e "${YELLOW}Restart service:${NC} sudo systemctl restart network-monitor"
echo -e "${YELLOW}Stop service:${NC} sudo systemctl stop network-monitor"

# Check if I2C device is detected
echo -e "\n${YELLOW}Checking for I2C device...${NC}"
i2cdetect -y 1

echo -e "\n${GREEN}If you see '3C' in the i2cdetect output above, your OLED display is properly connected.${NC}"
echo -e "${GREEN}The network monitor should now be running on your OLED display!${NC}"

# Add uninstall instructions
echo -e "\n${YELLOW}To uninstall in the future, run these commands:${NC}"
echo "sudo systemctl stop network-monitor"
echo "sudo systemctl disable network-monitor"
echo "sudo rm /etc/systemd/system/network-monitor.service"
echo "sudo rm -rf $INSTALL_DIR"
echo "sudo systemctl daemon-reload"
