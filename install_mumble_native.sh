#!/bin/bash

# Mumble Server Installation Script for Ubuntu & Debian
# This script installs and configures Mumble server (Murmur) on Ubuntu & Debian

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to ask yes/no questions
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local response
    
    while true; do
        if [[ "$default" == "Y" ]]; then
            read -p "$prompt [Y/n]: " response
            response=${response:-Y}
        else
            read -p "$prompt [y/N]: " response
            response=${response:-N}
        fi
        
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# Function to ask for text input
ask_input() {
    local prompt="$1"
    local default="$2"
    local response
    
    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        read -p "$prompt: " response
        echo "$response"
    fi
}

# Function to ask for numeric input
ask_number() {
    local prompt="$1"
    local default="$2"
    local min="$3"
    local max="$4"
    local response
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " response
            response=${response:-$default}
        else
            read -p "$prompt: " response
        fi
        
        if [[ "$response" =~ ^[0-9]+$ ]]; then
            if [[ -n "$min" ]] && [[ "$response" -lt "$min" ]]; then
                echo "Please enter a number at least $min."
                continue
            fi
            if [[ -n "$max" ]] && [[ "$response" -gt "$max" ]]; then
                echo "Please enter a number at most $max."
                continue
            fi
            echo "$response"
            break
        else
            echo "Please enter a valid number."
        fi
    done
}

# Function to detect the correct config file location
detect_config_file() {
    local config_file=""
    
    # Check systemd service file for the actual config path
    if [[ -f /lib/systemd/system/mumble-server.service ]] || [[ -f /usr/lib/systemd/system/mumble-server.service ]]; then
        local service_file=""
        if [[ -f /lib/systemd/system/mumble-server.service ]]; then
            service_file="/lib/systemd/system/mumble-server.service"
        else
            service_file="/usr/lib/systemd/system/mumble-server.service"
        fi
        
        # Extract config path from ExecStart line
        config_file=$(grep "ExecStart=" "$service_file" | grep -oP '(?<=-ini )[^ ]+' || true)
    fi
    
    # Fallback: check common locations
    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        if [[ -f /etc/mumble/mumble-server.ini ]]; then
            config_file="/etc/mumble/mumble-server.ini"
        elif [[ -f /etc/mumble-server.ini ]]; then
            config_file="/etc/mumble-server.ini"
        elif [[ -f /etc/murmur/murmur.ini ]]; then
            config_file="/etc/murmur/murmur.ini"
        fi
    fi
    
    echo "$config_file"
}

# Function to update configuration file
update_config() {
    local key="$1"
    local value="$2"
    
    if [[ -z "$CONFIG_FILE" ]] || [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    if grep -q "^${key}=" "$CONFIG_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
    elif grep -q "^#${key}=" "$CONFIG_FILE"; then
        sed -i "s|^#${key}=.*|${key}=${value}|" "$CONFIG_FILE"
    else
        echo "${key}=${value}" >> "$CONFIG_FILE"
    fi
}

# Function to backup configuration file
backup_config() {
    if [[ -z "$CONFIG_FILE" ]] || [[ ! -f "$CONFIG_FILE" ]]; then
        print_warning "Configuration file not found, skipping backup"
        return 1
    fi
    
    local backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup_file"
    print_status "Configuration backed up to: $backup_file"
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root or with sudo"
   exit 1
fi

print_status "Starting Mumble server installation..."

# Update package manager and system packages
print_status "Updating package lists..."
apt update

print_status "Upgrading system packages..."
apt upgrade -y

# Install UFW if not present
if ! command -v ufw &> /dev/null; then
    print_status "Installing UFW firewall..."
    apt install -y ufw
fi

# Configure UFW firewall
print_status "Configuring UFW firewall..."

# Allow SSH port first to prevent lockout
print_status "Allowing SSH port 22..."
ufw allow 22/tcp

# Allow Mumble ports (TCP and UDP 64738)
print_status "Allowing Mumble TCP port 64738..."
ufw allow 64738/tcp

print_status "Allowing Mumble UDP port 64738..."
ufw allow 64738/udp

# Enable UFW if not already enabled
if ! ufw status | grep -q "Status: active"; then
    print_status "Enabling UFW firewall..."
    ufw --force enable
fi

# Reload UFW to apply changes
print_status "Reloading firewall to confirm changes..."
ufw reload

print_status "Firewall configuration completed."

# Install Mumble server
print_status "Installing Mumble server..."
apt install -y mumble-server

# Detect configuration file location
print_status "Detecting configuration file location..."
CONFIG_FILE=$(detect_config_file)

if [[ -z "$CONFIG_FILE" ]] || [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "Could not detect Mumble configuration file location!"
    print_error "Please check if Mumble server was installed correctly."
    print_warning "Common locations are:"
    echo "  - /etc/mumble/mumble-server.ini"
    echo "  - /etc/mumble-server.ini"
    echo "  - /etc/murmur/murmur.ini"
    exit 1
fi

print_status "Using configuration file: $CONFIG_FILE"

# Configure Mumble server interactively
print_status "Launching Mumble server configuration..."
print_warning "You will now be prompted to configure Mumble server options."
print_warning "Please set the SuperUser password when prompted."

dpkg-reconfigure mumble-server

# Interactive configuration enhancement
print_status "Now let's configure some common settings for your Mumble server..."
echo ""

# Backup current configuration
backup_config

# Server name configuration
echo -e "${YELLOW}=== Server Identity ===${NC}"
server_name=$(ask_input "Enter your server name" "Mumble Server")
update_config "registerName" "\"$server_name\""

# Welcome message
welcome_msg=$(ask_input "Enter welcome message (HTML supported)" "<br />Welcome to <b>$server_name</b>!<br />Enjoy your stay!<br />")
update_config "welcometext" "\"$welcome_msg\""

# Server password
echo ""
echo -e "${YELLOW}=== Security Settings ===${NC}"
if ask_yes_no "Do you want to set a server password?" "N"; then
    server_password=$(ask_input "Enter server password" "")
    update_config "serverpassword" "\"$server_password\""
else
    server_password=""
    update_config "serverpassword" ""
fi

# User limits
echo ""
echo -e "${YELLOW}=== User Limits ===${NC}"
max_users=$(ask_number "Enter maximum concurrent users" "100" "1" "1000")
update_config "users" "$max_users"

# Bandwidth settings
echo ""
echo -e "${YELLOW}=== Audio Quality Settings ===${NC}"
echo "Bandwidth options:"
echo "  1) Low quality (9KB/s) - Good for slow connections"
echo "  2) Medium quality (36KB/s) - Balanced quality/bandwidth"
echo "  3) High quality (72KB/s) - Default, good quality"
echo "  4) Very high quality (144KB/s) - Best quality"

while true; do
    bandwidth_choice=$(ask_number "Select bandwidth quality (1-4)" "3" "1" "4")
    case "$bandwidth_choice" in
        1) bandwidth="72000"; break ;;
        2) bandwidth="288000"; break ;;
        3) bandwidth="558000"; break ;;
        4) bandwidth="1152000"; break ;;
    esac
done
update_config "bandwidth" "$bandwidth"

# Advanced settings
echo ""
echo -e "${YELLOW}=== Advanced Settings ===${NC}"

# SSL certificate requirement
if ask_yes_no "Require SSL certificates for all clients?" "N"; then
    update_config "certrequired" "true"
else
    update_config "certrequired" "false"
fi

# Obfuscate IPs
if ask_yes_no "Obfuscate IP addresses in logs (privacy)?" "N"; then
    update_config "obfuscate" "true"
else
    update_config "obfuscate" "false"
fi

# Allow recording
if ask_yes_no "Allow clients to record conversations?" "Y"; then
    update_config "allowRecording" "true"
else
    update_config "allowRecording" "false"
fi

# HTML in messages
if ask_yes_no "Allow HTML in text messages?" "Y"; then
    update_config "allowhtml" "true"
else
    update_config "allowhtml" "false"
fi

# Public server registration
echo ""
echo -e "${YELLOW}=== Public Server Registration ===${NC}"
if ask_yes_no "Register server with public Mumble server list?" "N"; then
    if [[ -z "$server_password" ]]; then
        register_url=$(ask_input "Enter your website URL" "https://example.com")
        register_hostname=$(ask_input "Enter your server hostname (e.g., mumble.example.com)" "")
        register_location=$(ask_input "Enter your 2-letter country code (e.g., US, GB, DE)" "US")
        register_password=$(ask_input "Enter registration password" "")
        
        update_config "registerUrl" "\"$register_url\""
        if [[ -n "$register_hostname" ]]; then
            update_config "registerHostname" "\"$register_hostname\""
        fi
        update_config "registerLocation" "\"$register_location\""
        update_config "registerPassword" "\"$register_password\""
        print_status "Server will be registered with public server list"
    else
        print_warning "Cannot register public server with password protection"
        print_warning "Remove server password to enable public registration"
    fi
fi

# Display completion message
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Mumble Server Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
print_status "Mumble server configuration has been updated."
echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "  Server Name: $server_name"
echo "  Max Users: $max_users"
echo "  Bandwidth: $bandwidth bits/s"
if [[ -n "$server_password" ]]; then
    echo "  Password Protected: Yes"
else
    echo "  Password Protected: No"
fi
echo ""
echo -e "${YELLOW}Connection Information:${NC}"
echo "  Server Port: 64738 (TCP/UDP)"
echo "  Default SuperUser: SuperUser (password set during dpkg-reconfigure)"
echo ""
echo -e "${YELLOW}Advanced Configuration:${NC}"
echo "For advanced configuration options, edit:"
echo "  sudo nano $CONFIG_FILE"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo "  Check status: sudo systemctl status mumble-server"
echo "  Restart:     sudo systemctl restart mumble-server"
echo "  Stop:        sudo systemctl stop mumble-server"
echo "  View logs:   sudo journalctl -u mumble-server -f"
echo ""
echo -e "${YELLOW}Configuration Backup:${NC}"
echo "Your original configuration has been backed up."
echo "Check ${CONFIG_FILE}.backup.* for backup files."
echo ""

# Final restart to apply all configuration changes
print_status "Restarting Mumble server to apply all configuration changes..."
systemctl restart mumble-server

# Wait a moment for service to start
sleep 2

# Verify service is running
if systemctl is-active --quiet mumble-server; then
    print_status "Mumble server is running successfully with new configuration!"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   Server is ready for connections!${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    print_error "Mumble server failed to start. Check logs with: journalctl -u mumble-server -xe"
    echo ""
    echo "Configuration file location: $CONFIG_FILE"
    exit 1
fi

echo ""
print_status "Installation and configuration script completed successfully!"
echo ""
