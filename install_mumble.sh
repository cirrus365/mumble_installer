#!/bin/bash

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
BACKUP_FILE="$SCRIPT_DIR/docker-compose.yml.backup"

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

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root for security reasons."
        print_error "Please run as a regular user with sudo privileges."
        exit 1
    fi
}

# Function to check sudo access
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_status "Checking sudo access..."
        if ! sudo -v; then
            print_error "This script requires sudo privileges to install Docker and configure firewall."
            exit 1
        fi
    fi
}

# Function to validate input is not empty
validate_not_empty() {
    local input="$1"
    local field_name="$2"
    
    if [[ -z "$input" ]]; then
        print_error "$field_name cannot be empty."
        return 1
    fi
    return 0
}

# Function to validate port number
validate_port() {
    local port="$1"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        print_error "Port must be a number between 1 and 65535."
        return 1
    fi
    return 0
}

# Function to get SuperUser password from container logs
get_supw_from_container() {
    local supw
    local max_attempts=30
    local attempt=0
    
    print_status "Waiting for SuperUser password generation..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        supw=$(docker logs mumble-server 2>&1 | grep -o "SuperUser password is '[^']*'" | grep -o "'[^']*'" | tr -d "'" || echo "")
        
        if [[ -n "$supw" ]]; then
            echo "$supw"
            return 0
        fi
        
        sleep 2
        ((attempt++))
        echo -n "."
    done
    
    echo ""
    print_warning "Could not retrieve SuperUser password automatically."
    print_warning "You can find it in the container logs with: docker logs mumble-server"
    return 1
}

# Function to get user input with validation
get_input() {
    local prompt="$1"
    local default="$2"
    local validation_func="$3"
    local field_name="$4"
    local input
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " input
            input="${input:-$default}"
        else
            read -p "$prompt: " input
        fi
        
        if [[ -n "$validation_func" ]]; then
            if $validation_func "$input" "$field_name"; then
                echo "$input"
                break
            fi
        else
            echo "$input"
            break
        fi
    done
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to backup docker-compose.yml
backup_compose_file() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        cp "$COMPOSE_FILE" "$BACKUP_FILE"
        print_status "Backup of docker-compose.yml created at $BACKUP_FILE"
    fi
}

# Function to restore backup on error
restore_backup() {
    if [[ -f "$BACKUP_FILE" ]]; then
        mv "$BACKUP_FILE" "$COMPOSE_FILE"
        print_status "Restored docker-compose.yml from backup"
    fi
}

# Function to cleanup on exit
cleanup() {
    if [[ $? -ne 0 ]]; then
        restore_backup
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# Function to display welcome message
show_welcome() {
    clear
    print_header "Mumble Server Auto-Installer"
    echo
    echo "This script will automatically install Docker and deploy a Mumble voice server."
    echo "You will be prompted for configuration options during the installation."
    echo
    echo "Requirements:"
    echo "  - Ubuntu/Debian-based Linux system"
    echo "  - Sudo privileges"
    echo "  - Internet connection"
    echo
    echo "The script will:"
    echo "  1. Install Docker using the official installer"
    echo "  2. Configure Mumble server settings"
    echo "  3. Update docker-compose.yml with your settings"
    echo "  4. Configure firewall (UFW) for SSH and Mumble ports"
    echo "  5. Deploy the Mumble server"
    echo
    read -p "Press Enter to continue or Ctrl+C to cancel..."
}

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check if running as root
    check_root
    
    # Check sudo access
    check_sudo
    
    # Check if docker-compose.yml exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        print_error "docker-compose.yml not found in $SCRIPT_DIR"
        exit 1
    fi
    
    # Check internet connection
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        print_warning "Could not verify internet connection. Please ensure you're online."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    print_status "Prerequisites check passed"
}

# Function to install Docker
install_docker() {
    print_header "Installing Docker"
    
    if command_exists docker; then
        print_warning "Docker is already installed."
        read -p "Do you want to reinstall/upgrade Docker? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Skipping Docker installation"
            return
        fi
    fi
    
    print_status "Downloading Docker installation script..."
    if ! curl -fsSL https://get.docker.com -o /tmp/install-docker.sh; then
        print_error "Failed to download Docker installation script"
        exit 1
    fi
    
    print_status "Installing Docker..."
    if ! sudo sh /tmp/install-docker.sh; then
        print_error "Docker installation failed"
        exit 1
    fi
    
    # Add current user to docker group
    print_status "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"
    
    # Clean up
    rm -f /tmp/install-docker.sh
    
    print_status "Docker installed successfully"
    print_warning "You may need to log out and log back in for group changes to take effect"
}

# Function to get Mumble configuration
get_mumble_config() {
    print_header "Mumble Server Configuration"
    
    # Server Name (required, no default)
    SERVER_NAME=$(get_input "Enter your Mumble server name" "" "validate_not_empty" "Server Name")
    
    # Welcome Message
    WELCOME_TEXT=$(get_input "Enter welcome message (HTML supported)" "<b>Welcome to $SERVER_NAME!</b>")
    
    # Note: SuperUser password will be auto-generated by Mumble
    print_status "SuperUser password will be auto-generated by Mumble server"
    
    # Server Password (optional)
    SERVER_PASSWORD=$(get_input "Enter server password (leave empty for no password)" "" "" "")
    
    # Register Hostname
    REGISTER_HOSTNAME=$(get_input "Enter public registration hostname (e.g., mumble.example.com)" "" "" "")
    
    # Register Name
    REGISTER_NAME=$(get_input "Enter public registration name" "$SERVER_NAME" "" "")
    
    # Register Password
    REGISTER_PASSWORD=$(get_input "Enter registration password (leave empty if not required)" "" "" "")
    
    # Register URL
    REGISTER_URL=$(get_input "Enter server website URL" "" "" "")
    
    # Port
    PORT=$(get_input "Enter Mumble server port" "64738" "validate_port" "Port")
    
    # Timezone
    TIMEZONE=$(get_input "Enter timezone" "UTC" "" "")
    
    echo
    print_status "Configuration summary:"
    echo "  Server Name: $SERVER_NAME"
    echo "  Welcome Message: $WELCOME_TEXT"
    echo "  SuperUser Password: [AUTO-GENERATED]"
    echo "  Server Password: ${SERVER_PASSWORD:-[NONE]}"
    echo "  Register Hostname: ${REGISTER_HOSTNAME:-[NONE]}"
    echo "  Register Name: $REGISTER_NAME"
    echo "  Register Password: ${REGISTER_PASSWORD:-[NONE]}"
    echo "  Register URL: ${REGISTER_URL:-[NONE]}"
    echo "  Port: $PORT"
    echo "  Timezone: $TIMEZONE"
    echo
    read -p "Press Enter to continue or Ctrl+C to cancel..."
}

# Function to update docker-compose.yml
update_compose_file() {
    print_header "Updating docker-compose.yml"
    
    backup_compose_file
    
    # Create temporary file
    local temp_file=$(mktemp)
    
    # Read and modify the docker-compose.yml
    while IFS= read -r line; do
        case "$line" in
            *"MUMBLE_SUPW="*)
                # Remove the SUPW line to let Mumble auto-generate
                continue
                ;;
            *"MUMBLE_CONFIG_host="*)
                echo "      - MUMBLE_CONFIG_host=0.0.0.0" >> "$temp_file"
                ;;
            *"MUMBLE_CONFIG_registerHostname="*)
                if [[ -n "$REGISTER_HOSTNAME" ]]; then
                    echo "      - MUMBLE_CONFIG_registerHostname=$REGISTER_HOSTNAME" >> "$temp_file"
                else
                    echo "$line" >> "$temp_file"
                fi
                ;;
            *"MUMBLE_CONFIG_port="*)
                echo "      - MUMBLE_CONFIG_port=$PORT" >> "$temp_file"
                ;;
            *"MUMBLE_CONFIG_welcometext="*)
                echo "      - MUMBLE_CONFIG_welcometext=$WELCOME_TEXT" >> "$temp_file"
                ;;
            *"MUMBLE_CONFIG_serverpassword="*)
                echo "      - MUMBLE_CONFIG_serverpassword=$SERVER_PASSWORD" >> "$temp_file"
                ;;
            *"MUMBLE_CONFIG_registerName="*)
                echo "      - MUMBLE_CONFIG_registerName=$REGISTER_NAME" >> "$temp_file"
                ;;
            *"MUMBLE_CONFIG_registerPassword="*)
                if [[ -n "$REGISTER_PASSWORD" ]]; then
                    echo "      - MUMBLE_CONFIG_registerPassword=$REGISTER_PASSWORD" >> "$temp_file"
                else
                    echo "      - MUMBLE_CONFIG_registerPassword=" >> "$temp_file"
                fi
                ;;
            *"MUMBLE_CONFIG_registerUrl="*)
                if [[ -n "$REGISTER_URL" ]]; then
                    echo "      - MUMBLE_CONFIG_registerUrl=$REGISTER_URL" >> "$temp_file"
                else
                    echo "$line" >> "$temp_file"
                fi
                ;;
            *"MUMBLE_CONFIG_allowping="*)
                echo "      - MUMBLE_CONFIG_allowping=true" >> "$temp_file"
                ;;
            *"TZ="*)
                echo "      - TZ=$TIMEZONE" >> "$temp_file"
                ;;
            *"$PORT:$PORT"*)
                echo "      - \"$PORT:$PORT\"" >> "$temp_file"
                ;;
            *"$PORT:$PORT/udp"*)
                echo "      - \"$PORT:$PORT/udp\"" >> "$temp_file"
                ;;
            *)
                echo "$line" >> "$temp_file"
                ;;
        esac
    done < "$COMPOSE_FILE"
    
    # Replace original file
    mv "$temp_file" "$COMPOSE_FILE"
    
    print_status "docker-compose.yml updated successfully"
}

# Function to configure firewall
configure_firewall() {
    print_header "Configuring Firewall"
    
    # Check if UFW is installed
    if ! command_exists ufw; then
        print_status "Installing UFW firewall..."
        sudo apt-get update >/dev/null 2>&1
        sudo apt-get install -y ufw >/dev/null 2>&1
    fi
    
    # Configure UFW
    print_status "Configuring UFW firewall rules..."
    
    # Allow SSH
    sudo ufw allow 22/tcp >/dev/null 2>&1
    print_status "Allowed SSH port 22"
    
    # Allow Mumble ports
    sudo ufw allow "$PORT/tcp" >/dev/null 2>&1
    sudo ufw allow "$PORT/udp" >/dev/null 2>&1
    print_status "Allowed Mumble port $PORT (TCP/UDP)"
    
    # Enable UFW if not already enabled
    if ! sudo ufw --force enable >/dev/null 2>&1; then
        print_error "Failed to enable UFW firewall"
        exit 1
    fi
    
    # Reload UFW
    sudo ufw reload >/dev/null 2>&1
    
    print_status "Firewall configured successfully"
}

# Function to deploy Mumble service
deploy_service() {
    print_header "Deploying Mumble Service"
    
    # Check if docker-compose is available
    if ! command_exists docker-compose && ! docker compose version >/dev/null 2>&1; then
        print_error "docker-compose is not available"
        exit 1
    fi
    
    # Change to script directory
    cd "$SCRIPT_DIR"
    
    # Stop existing container if running
    if docker ps -q -f name=mumble-server >/dev/null 2>&1; then
        print_status "Stopping existing Mumble container..."
        docker-compose down >/dev/null 2>&1 || true
    fi
    
    # Start the service
    print_status "Starting Mumble server..."
    if docker-compose up -d; then
        print_status "Mumble server started successfully"
    else
        print_error "Failed to start Mumble server"
        exit 1
    fi
    
    # Wait a moment for container to initialize and generate password
    sleep 10
    
    # Verify container is running
    if docker ps -q -f name=mumble-server >/dev/null 2>&1; then
        print_status "Mumble container is running"
    else
        print_error "Mumble container failed to start"
        exit 1
    fi
}

# Function to show completion information
show_completion() {
    print_header "Installation Complete!"
    
    echo
    print_status "Your Mumble server is now running!"
    echo
    echo "Connection Information:"
    echo "  Server Address: $(hostname -I | awk '{print $1}'):$PORT"
    if [[ -n "$REGISTER_HOSTNAME" ]]; then
        echo "  Public Hostname: $REGISTER_HOSTNAME:$PORT"
    fi
    echo "  Server Name: $SERVER_NAME"
    echo
    
    # Get and display SuperUser password
    echo "Admin Credentials:"
    echo "  Username: SuperUser"
    
    SUPW=$(get_supw_from_container)
    if [[ $? -eq 0 && -n "$SUPW" ]]; then
        echo "  Password: $SUPW"
    else
        echo "  Password: [Check container logs: docker logs mumble-server]"
    fi
    echo
    
    echo "Useful Commands:"
    echo "  View logs: docker-compose logs -f"
    echo "  Get SuperUser password: docker logs mumble-server | grep 'SuperUser password'"
    echo "  Stop server: docker-compose down"
    echo "  Start server: docker-compose up -d"
    echo "  Restart server: docker-compose restart"
    echo
    echo "Firewall Status:"
    sudo ufw status verbose
    echo
    print_warning "Save the SuperUser password securely!"
    print_status "Enjoy your Mumble server!"
}

# Main function
main() {
    show_welcome
    check_prerequisites
    install_docker
    get_mumble_config
    update_compose_file
    configure_firewall
    deploy_service
    show_completion
}

# Run main function
main "$@"