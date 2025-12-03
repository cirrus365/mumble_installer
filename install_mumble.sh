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

# Function to configure Debian repositories
configure_debian_repositories() {
    if [[ "$distro_id" == "debian" && "$distro_version" == "13" ]]; then
        print_status "Configuring Debian 13 repositories..."
        
        # Check if sources are properly configured
        local sources_file="/etc/apt/sources.list.d/debian.sources"
        local security_file="/etc/apt/sources.list.d/debian-security.sources"
        
        if [[ ! -f "$sources_file" ]] || 
           ! grep -q "non-free-firmware" "$sources_file" 2>/dev/null; then
            
            print_status "Adding non-free-firmware repository (required for UFW)..."
            
            # Create proper Debian 13 sources
            cat > "$sources_file" << 'EOF'
Types: deb deb-src
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
            
            # Add security repository
            cat > "$security_file" << 'EOF'
Types: deb deb-src
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
            
            # Update package lists
            print_status "Updating package lists with new repositories..."
            apt update
        fi
    fi
}

# Function to install essential packages (early version for root mode)
install_essential_packages_early() {
    # Only run as root and only if packages are missing
    if [[ $EUID -eq 0 ]]; then
        # Configure repositories first (especially for Debian 13)
        configure_debian_repositories
        
        # Update package lists with error handling
        if ! apt update; then
            print_error "Failed to update package lists"
            print_error "Please check your internet connection and package repositories"
            exit 1
        fi
        
        # Install essential packages that might be missing
        local packages="sudo"
        if ! is_package_installed "sudo"; then
            print_status "Installing sudo (required for user management)..."
            if ! apt install -y $packages; then
                print_error "Failed to install sudo"
                exit 1
            fi
            print_status "sudo installed successfully"
        fi
    fi
}

# Function to check if running as root and handle user creation
check_root() {
    if [[ $EUID -eq 0 ]]; then
        # Install essential packages first (especially sudo)
        install_essential_packages_early
        
        print_warning "Script is running as root."
        print_warning "For security reasons, we should create a normal user."
        echo
        
        read -p "Do you want to create a new user for Mumble server management? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            print_warning "Continuing as root is not recommended for security reasons."
            read -p "Are you sure you want to continue as root? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_status "Please create a normal user and run this script as that user."
                exit 0
            fi
            ROOT_MODE=true
            return
        fi
        
        create_user_and_sudo
        print_status "User created successfully. Please run this script as the new user:"
        echo "  su - $NEW_USERNAME"
        echo "  cd $(pwd)"
        echo "  ./install_mumble.sh"
        exit 0
    fi
    ROOT_MODE=false
}

# Function to create user and configure sudo
create_user_and_sudo() {
    while true; do
        read -p "Enter username for the new user: " NEW_USERNAME
        if [[ -z "$NEW_USERNAME" ]]; then
            print_error "Username cannot be empty."
            continue
        fi
        
        if id "$NEW_USERNAME" &>/dev/null; then
            print_error "User '$NEW_USERNAME' already exists."
            continue
        fi
        
        if [[ "$NEW_USERNAME" == "root" ]]; then
            print_error "Cannot create user named 'root'."
            continue
        fi
        
        break
    done
    
    # Create user
    print_status "Creating user '$NEW_USERNAME'..."
    useradd -m -s /bin/bash "$NEW_USERNAME"
    
    # Set password for user
    while true; do
        read -s -p "Enter password for $NEW_USERNAME: " USER_PASSWORD
        echo
        read -s -p "Confirm password: " USER_PASSWORD_CONFIRM
        echo
        
        if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
            print_error "Passwords do not match. Please try again."
        elif [[ -z "$USER_PASSWORD" ]]; then
            print_error "Password cannot be empty."
        else
            echo "$NEW_USERNAME:$USER_PASSWORD" | chpasswd
            break
        fi
    done
    
    # Configure sudo
    print_status "Configuring sudo access for $NEW_USERNAME..."
    
    # Sudo should already be installed by install_essential_packages_early
    if ! command -v sudo >/dev/null 2>&1; then
        print_error "Sudo not found after installation attempt"
        exit 1
    fi
    
    # Add user to sudo group
    usermod -aG sudo "$NEW_USERNAME"
    
    # Ensure sudo group has sudo privileges
    if [[ ! -f /etc/sudoers.d/sudo_group ]]; then
        echo "%sudo ALL=(ALL:ALL) ALL" > /etc/sudoers.d/sudo_group
        chmod 0440 /etc/sudoers.d/sudo_group
    fi
    
    print_status "User '$NEW_USERNAME' created and added to sudo group."
}

# Function to check sudo access
check_sudo() {
    if [[ "$ROOT_MODE" == "true" ]]; then
        return 0  # Already root, no need to check sudo
    fi
    
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
        # Try multiple patterns to extract password
        supw=$(docker logs mumble-server 2>&1 | grep -i "SuperUser" | grep -o "'[^']*'" | head -1 | tr -d "'" || echo "")
        
        # Alternative pattern if first one fails
        if [[ -z "$supw" ]]; then
            supw=$(docker logs mumble-server 2>&1 | grep -i "password.*SuperUser\|SuperUser.*password" | grep -o "'[^']*'" | head -1 | tr -d "'" || echo "")
        fi
        
        # Another alternative pattern
        if [[ -z "$supw" ]]; then
            supw=$(docker logs mumble-server 2>&1 | grep -i "set to" | grep -o "'[^']*'" | head -1 | tr -d "'" || echo "")
        fi
        
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
    print_warning "You can find it in the container logs with: docker logs mumble-server | grep -i SuperUser"
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
    command -v "$@" >/dev/null 2>&1
}

# Function to check if package is installed (Debian/Ubuntu specific)
is_package_installed() {
    dpkg -l | grep -q "^ii  $1 "
}

# Function to verify package installation with multiple methods
verify_package_installation() {
    local package="$1"
    local command="$2"
    
    # Method 1: Check dpkg database
    if is_package_installed "$package"; then
        return 0
    fi
    
    # Method 2: Check if command exists
    if command_exists "$command"; then
        return 0
    fi
    
    # Method 3: Check if package file exists
    if [[ -f "/usr/bin/$command" ]] || [[ -f "/usr/sbin/$command" ]]; then
        return 0
    fi
    
    return 1
}

# Function to install package with verification
install_package_with_verification() {
    local package="$1"
    local command="$2"
    
    print_status "Installing $package..."
    
    # Install with full output (no /dev/null)
    if $pkg_cmd install -y "$package"; then
        # Verify installation succeeded
        if verify_package_installation "$package" "$command"; then
            print_status "$package installed and verified successfully"
            return 0
        else
            print_error "$package installation verification failed"
            return 1
        fi
    else
        print_error "$package installation failed"
        return 1
    fi
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

# Function to install essential packages
install_essential_packages() {
    print_header "Installing Essential Packages"
    
    # Determine package manager command based on whether we're root
    local pkg_cmd="sudo apt"
    if [[ "$ROOT_MODE" == "true" ]]; then
        pkg_cmd="apt"
    fi
    
    # Detect distribution and adjust package names
    local distro_id=""
    local distro_version=""
    if [[ -f /etc/os-release ]]; then
        distro_id=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
        distro_version=$(grep "^VERSION_ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"' | cut -d'.' -f1)
    fi
    
    # Configure repositories first (especially for Debian 13)
    configure_debian_repositories
    
    # Update package lists with error handling
    print_status "Updating package lists..."
    if ! $pkg_cmd update; then
        print_error "Failed to update package lists"
        print_error "Please check your internet connection and package repositories"
        exit 1
    fi
    
    # Install essential packages with distribution-specific adjustments
    local packages=""
    case "$distro_id" in
        "debian")
            packages="curl wget gnupg ca-certificates apt-transport-https ufw"
            if [[ "$ROOT_MODE" != "true" ]]; then
                packages="$packages sudo"
            fi
            ;;
        "ubuntu")
            packages="curl wget gnupg2 software-properties-common ca-certificates apt-transport-https ufw"
            if [[ "$ROOT_MODE" != "true" ]]; then
                packages="$packages sudo"
            fi
            ;;
        *)
            # Default/fallback
            packages="curl wget gnupg software-properties-common ca-certificates apt-transport-https ufw"
            if [[ "$ROOT_MODE" != "true" ]]; then
                packages="$packages sudo"
            fi
            ;;
    esac
    
    # Install each package with verification
    for package in $packages; do
        if ! install_package_with_verification "$package" "$package"; then
            print_error "Failed to install $package"
            exit 1
        fi
    done
    
    print_status "All essential packages installed successfully"
}

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check if running as root
    check_root
    
    # Install essential packages first
    install_essential_packages
    
    # Check sudo access (only if not root)
    if [[ "$ROOT_MODE" != "true" ]]; then
        check_sudo
    fi
    
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
    
    # Determine package manager command based on whether we're root
    local pkg_cmd="sudo apt-get"
    if [[ "$ROOT_MODE" == "true" ]]; then
        pkg_cmd="apt-get"
    fi
    
    # Curl should already be installed by install_essential_packages
    if ! command_exists curl; then
        print_error "Curl not found after essential packages installation"
        exit 1
    fi
    
    print_status "Downloading Docker installation script..."
    if ! curl -fsSL https://get.docker.com -o /tmp/install-docker.sh; then
        print_error "Failed to download Docker installation script"
        exit 1
    fi
    
    print_status "Installing Docker..."
    local docker_cmd="sudo sh /tmp/install-docker.sh"
    if [[ "$ROOT_MODE" == "true" ]]; then
        docker_cmd="sh /tmp/install-docker.sh"
    fi
    
    if ! $docker_cmd; then
        print_error "Docker installation failed"
        exit 1
    fi
    
    # Add current user to docker group
    if [[ "$ROOT_MODE" != "true" ]]; then
        print_status "Adding current user to docker group..."
        sudo usermod -aG docker "$USER"
        print_warning "You may need to log out and log back in for group changes to take effect"
    else
        print_status "Docker installed successfully (running as root)"
    fi
    
    # Enable and start Docker service
    print_status "Enabling and starting Docker service..."
    local systemctl_cmd="sudo systemctl"
    if [[ "$ROOT_MODE" == "true" ]]; then
        systemctl_cmd="systemctl"
    fi
    
    # Enable Docker to start on boot
    if ! $systemctl_cmd enable docker >/dev/null 2>&1; then
        print_error "Failed to enable Docker service"
        exit 1
    fi
    
    # Start Docker service if not running
    if ! $systemctl_cmd is-active --quiet docker; then
        if ! $systemctl_cmd start docker >/dev/null 2>&1; then
            print_error "Failed to start Docker service"
            exit 1
        fi
    fi
    
    # Verify Docker is running
    if ! $systemctl_cmd is-active --quiet docker; then
        print_error "Docker service is not running after installation"
        exit 1
    fi
    
    # Clean up
    rm -f /tmp/install-docker.sh
    
    print_status "Docker installed and started successfully"
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
    
    # Ask about public listing
    echo
    read -p "Do you want to list this server in the public Mumble server list? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PUBLIC_LISTING=true
        print_status "Server will be listed publicly"
        
        # Register Hostname
        REGISTER_HOSTNAME=$(get_input "Enter public registration hostname (e.g., mumble.example.com)" "" "validate_not_empty" "Register Hostname")
        
        # Register Name
        REGISTER_NAME=$(get_input "Enter public registration name" "$SERVER_NAME" "" "")
        
        # Register Password
        REGISTER_PASSWORD=$(get_input "Enter registration password (leave empty if not required)" "" "" "")
        
        # Register URL
        REGISTER_URL=$(get_input "Enter server website URL" "" "" "")
    else
        PUBLIC_LISTING=false
        print_status "Server will be private (not listed publicly)"
        REGISTER_HOSTNAME=""
        REGISTER_NAME="$SERVER_NAME"
        REGISTER_PASSWORD=""
        REGISTER_URL=""
    fi
    
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
    if [[ "$PUBLIC_LISTING" == "true" ]]; then
        echo "  Public Listing: YES"
        echo "  Register Hostname: $REGISTER_HOSTNAME"
        echo "  Register Name: $REGISTER_NAME"
        echo "  Register Password: ${REGISTER_PASSWORD:-[NONE]}"
        echo "  Register URL: ${REGISTER_URL:-[NONE]}"
    else
        echo "  Public Listing: NO (Private Server)"
    fi
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
                if [[ "$PUBLIC_LISTING" == "true" && -n "$REGISTER_HOSTNAME" ]]; then
                    echo "      - MUMBLE_CONFIG_registerHostname=$REGISTER_HOSTNAME" >> "$temp_file"
                else
                    # Remove registration config for private servers
                    continue
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
                if [[ "$PUBLIC_LISTING" == "true" ]]; then
                    echo "      - MUMBLE_CONFIG_registerName=$REGISTER_NAME" >> "$temp_file"
                else
                    # Remove registration config for private servers
                    continue
                fi
                ;;
            *"MUMBLE_CONFIG_registerPassword="*)
                if [[ "$PUBLIC_LISTING" == "true" ]]; then
                    if [[ -n "$REGISTER_PASSWORD" ]]; then
                        echo "      - MUMBLE_CONFIG_registerPassword=$REGISTER_PASSWORD" >> "$temp_file"
                    else
                        echo "      - MUMBLE_CONFIG_registerPassword=" >> "$temp_file"
                    fi
                else
                    # Remove registration config for private servers
                    continue
                fi
                ;;
            *"MUMBLE_CONFIG_registerUrl="*)
                if [[ "$PUBLIC_LISTING" == "true" && -n "$REGISTER_URL" ]]; then
                    echo "      - MUMBLE_CONFIG_registerUrl=$REGISTER_URL" >> "$temp_file"
                elif [[ "$PUBLIC_LISTING" == "true" ]]; then
                    echo "      - MUMBLE_CONFIG_registerUrl=" >> "$temp_file"
                else
                    # Remove registration config for private servers
                    continue
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
    
    # Determine package manager command based on whether we're root
    local pkg_cmd="sudo apt-get"
    local ufw_cmd="sudo ufw"
    if [[ "$ROOT_MODE" == "true" ]]; then
        pkg_cmd="apt-get"
        ufw_cmd="ufw"
    fi
    
    # UFW should already be installed by install_essential_packages
    if ! command_exists ufw; then
        print_error "UFW not found after essential packages installation"
        exit 1
    fi
    
    # Configure UFW
    print_status "Configuring UFW firewall rules..."
    
    # Allow SSH
    $ufw_cmd allow 22/tcp >/dev/null 2>&1
    print_status "Allowed SSH port 22"
    
    # Allow Mumble ports
    $ufw_cmd allow "$PORT/tcp" >/dev/null 2>&1
    $ufw_cmd allow "$PORT/udp" >/dev/null 2>&1
    print_status "Allowed Mumble port $PORT (TCP/UDP)"
    
    # Enable UFW if not already enabled
    if ! $ufw_cmd --force enable >/dev/null 2>&1; then
        print_error "Failed to enable UFW firewall"
        exit 1
    fi
    
    # Reload UFW
    $ufw_cmd reload >/dev/null 2>&1
    
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
    if docker compose up -d; then
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
    if [[ "$ROOT_MODE" == "true" ]]; then
        ufw status verbose
    else
        sudo ufw status verbose
    fi
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
