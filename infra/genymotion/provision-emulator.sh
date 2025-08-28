#!/bin/bash

# Genymotion Cloud Android Emulator Provisioning Script (gmsaas CLI)
# Creates and configures Genymotion Cloud instances for android_world testing

set -e  # Exit on any error

# ===== CONFIGURATION VARIABLES =====
# Edit these variables to customize your setup

# Device Configuration
CONFIG_FILE="infra/genymotion/device-configs/core-apps-config.yaml"  # Change this to switch configs
DEVICE_NAME="AndroidWorld-Test"
GENYMOTION_REGION="us-east-1"

# gmsaas CLI Configuration
# Set your API key as environment variable: export GENYMOTION_API_KEY="your_key_here"

# Timeouts and Retry Settings
BOOT_TIMEOUT=300          # 5 minutes to wait for device boot
CONNECTION_TIMEOUT=60     # 1 minute for ADB connection
POLL_INTERVAL=10         # Check status every 10 seconds
MAX_RETRIES=3            # Maximum retry attempts

# Debug Settings
DEBUG_MODE=true         # Set to true for verbose output
CLEANUP_ON_FAILURE=true  # Auto-delete failed instances
LOG_FILE="/tmp/genymotion-provision.log"

# ===== END CONFIGURATION =====

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
INSTANCE_ID=""
INSTANCE_IP=""
ADB_PORT="5555"

# Logging functions
log_info() {
    local msg="[INFO] $1"
    echo -e "${GREEN}$msg${NC}" >&2
    echo "$(date): $msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[WARN] $1"
    echo -e "${YELLOW}$msg${NC}" >&2
    echo "$(date): $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[ERROR] $1"
    echo -e "${RED}$msg${NC}" >&2
    echo "$(date): $msg" >> "$LOG_FILE"
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        local msg="[DEBUG] $1"
        echo -e "${BLUE}$msg${NC}" >&2
        echo "$(date): $msg" >> "$LOG_FILE"
    fi
}

# Check if required tools are installed
check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_tools=()
    
    # Check for yq (YAML parser)
    if ! command -v yq &> /dev/null; then
        missing_tools+=("yq")
    fi
    
    # Check for curl
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    # Check for jq (JSON parser)
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    # Check for adb
    if ! command -v adb &> /dev/null; then
        missing_tools+=("adb")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install missing tools:"
        log_error "  - yq: https://github.com/mikefarah/yq"
        log_error "  - curl: usually pre-installed"
        log_error "  - jq: https://stedolan.github.io/jq/"
        log_error "  - adb: Android SDK Platform Tools"
        exit 1
    fi
    
    log_info "All dependencies found"
}

# Validate API key and connection
validate_api_connection() {
    log_info "Validating Genymotion Cloud API connection..."
    
    if [ -z "$GENYMOTION_API_KEY" ]; then
        log_error "GENYMOTION_API_KEY environment variable is not set"
        log_error "Please set it with: export GENYMOTION_API_KEY='your_key_here'"
        exit 1
    fi
    
    # Test API connection
    local response
    response=$(curl -s --insecure -w "%{http_code}" -H "x-api-token: $GENYMOTION_API_KEY" \
        "$GENYMOTION_API_ENDPOINT/v3/recipes/" -o /tmp/api_test.json)
    
    local http_code="${response: -3}"
    
    if [ "$http_code" != "200" ]; then
        log_error "API connection failed (HTTP $http_code)"
        log_error "Please check your GENYMOTION_API_KEY"
        exit 1
    fi
    
    log_info "API connection validated successfully"
}

# Read and parse YAML configuration
read_config() {
    log_info "Reading configuration from: $CONFIG_FILE"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Parse device configuration
    DEVICE_RECIPE=$(yq eval '.device.recipe' "$CONFIG_FILE")
    DEVICE_ANDROID_VERSION=$(yq eval '.device.android_version' "$CONFIG_FILE")
    DEVICE_RAM=$(yq eval '.device.ram' "$CONFIG_FILE")
    DEVICE_DISK=$(yq eval '.device.disk' "$CONFIG_FILE")
    DEVICE_REGION=$(yq eval '.device.region' "$CONFIG_FILE")
    
    # Override with config file values if they exist
    if [ "$DEVICE_REGION" != "null" ]; then
        GENYMOTION_REGION="$DEVICE_REGION"
    fi
    
    if [ "$DEVICE_NAME" = "" ]; then
        DEVICE_NAME=$(yq eval '.device.name' "$CONFIG_FILE")
    fi
    
    log_debug "Device Recipe: $DEVICE_RECIPE"
    log_debug "Android Version: $DEVICE_ANDROID_VERSION"
    log_debug "RAM: ${DEVICE_RAM}MB"
    log_debug "Disk: ${DEVICE_DISK}GB"
    log_debug "Region: $GENYMOTION_REGION"
}

# Find recipe ID for the specified device
find_recipe_id() {
    log_info "Finding recipe ID for $DEVICE_RECIPE (Android $DEVICE_ANDROID_VERSION)..."
    
    local recipes_response
    recipes_response=$(curl -s --insecure -H "x-api-token: $GENYMOTION_API_KEY" \
        "$GENYMOTION_API_ENDPOINT/v3/recipes/")
    
    log_debug "Recipes API response: $recipes_response"
    
    # Search for matching recipe in the results array
    local recipe_id
    recipe_id=$(echo "$recipes_response" | jq -r --arg recipe "$DEVICE_RECIPE" --arg version "$DEVICE_ANDROID_VERSION" \
        '.results[] | select(.name | test($recipe; "i")) | select(.os_image.os_version.os_version | test($version)) | .uuid' | head -1)
    
    if [ -z "$recipe_id" ] || [ "$recipe_id" = "null" ]; then
        log_error "No matching recipe found for $DEVICE_RECIPE with Android $DEVICE_ANDROID_VERSION"
        log_error "Available recipes:"
        echo "$recipes_response" | jq -r '.results[] | "\(.name) - Android \(.os_image.os_version.os_version) API \(.os_image.os_version.sdk_version)"' | head -10
        exit 1
    fi
    
    log_info "Found recipe ID: $recipe_id"
    echo "$recipe_id"
}

# Check for existing instances with the same name
check_existing_instances() {
    log_info "Checking for existing instances with name: $DEVICE_NAME"
    
    local instances_response
    instances_response=$(curl -s --insecure -H "x-api-token: $GENYMOTION_API_KEY" \
        "$GENYMOTION_API_ENDPOINT/v1/instances/")
    
    log_debug "Instances API response: $instances_response"
    
    # Look for running instances with matching name
    local existing_instance
    existing_instance=$(echo "$instances_response" | jq -r --arg name "$DEVICE_NAME" \
        '.results[]? | select(.name == $name and (.state == "ONLINE" or .state == "BOOTING" or .state == "STARTING")) | .uuid' | head -1)
    
    if [ -n "$existing_instance" ] && [ "$existing_instance" != "null" ]; then
        log_info "Found existing instance: $existing_instance"
        
        # Get instance details
        local instance_details
        instance_details=$(curl -s --insecure -H "x-api-token: $GENYMOTION_API_KEY" \
            "$GENYMOTION_API_ENDPOINT/v1/instances/$existing_instance")
        
        local state
        state=$(echo "$instance_details" | jq -r '.state')
        
        log_info "Existing instance state: $state"
        
        if [ "$state" = "ONLINE" ]; then
            log_info "Reusing existing ONLINE instance: $existing_instance"
            INSTANCE_ID="$existing_instance"
            return 0
        elif [ "$state" = "BOOTING" ] || [ "$state" = "STARTING" ]; then
            log_info "Found existing instance still starting: $existing_instance"
            log_info "Waiting for existing instance to come online..."
            INSTANCE_ID="$existing_instance"
            return 0
        fi
    fi
    
    log_info "No existing running instance found - will create new one"
    return 1
}

# Create and start Genymotion Cloud instance
create_instance() {
    local recipe_id="$1"
    
    # First check if we already have a running instance
    if check_existing_instances; then
        log_info "Using existing instance: $INSTANCE_ID"
        return 0
    fi
    
    log_info "Creating and starting new Genymotion Cloud instance..."
    log_info "Making API call to Genymotion Cloud (this may take 30-60 seconds)..."
    
    local create_payload
    create_payload=$(cat <<EOF
{
    "instance_name": "$DEVICE_NAME",
    "rename_on_conflict": true
}
EOF
)
    
    log_debug "API endpoint: $GENYMOTION_API_ENDPOINT/v1/recipes/$recipe_id/start-disposable"
    log_debug "Payload: $create_payload"
    
    local create_response
    local http_code
    
    # Add aggressive timeout settings and capture HTTP status code
    create_response=$(curl -s --insecure -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        -H "x-api-token: $GENYMOTION_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$create_payload" \
        "$GENYMOTION_API_ENDPOINT/v1/recipes/$recipe_id/start-disposable")
    
    # Extract HTTP code from end of response
    http_code="${create_response: -3}"
    create_response="${create_response%???}"
    
    log_debug "HTTP Status: $http_code"
    log_debug "Create instance response: $create_response"
    
    # Check HTTP status code
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        log_error "API call failed with HTTP $http_code"
        log_error "Response: $create_response"
        
        # Try to extract error message from response
        local error_msg
        error_msg=$(echo "$create_response" | jq -r '.message // .error // "Unknown error"' 2>/dev/null || echo "Unknown error")
        log_error "Error message: $error_msg"
        exit 1
    fi
    
    # Check if response is valid JSON
    if ! echo "$create_response" | jq -e . >/dev/null 2>&1; then
        log_error "Invalid JSON response from API"
        log_error "Raw response: $create_response"
        exit 1
    fi
    
    INSTANCE_ID=$(echo "$create_response" | jq -r '.uuid')
    
    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
        log_error "Failed to extract instance ID from response"
        log_error "Response: $create_response"
        exit 1
    fi
    
    log_info "Instance created and starting with ID: $INSTANCE_ID"
}

# Instance is already starting from create_instance, so this function is no longer needed
# but kept for compatibility
start_instance() {
    log_info "Instance $INSTANCE_ID is already starting from creation..."
}

# Wait for instance to be online
wait_for_instance_online() {
    log_info "Waiting for instance to come online (timeout: ${BOOT_TIMEOUT}s)..."
    log_info "This typically takes 3-5 minutes for cloud instances..."
    
    # Temporarily disable set -e to prevent premature exit on API failures
    set +e
    
    local start_time
    start_time=$(date +%s)
    local timeout_time=$((start_time + BOOT_TIMEOUT))
    local last_state=""
    local dots_count=0
    
    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $current_time -gt $timeout_time ]; then
            echo ""  # New line after dots
            log_error "Timeout waiting for instance to come online after ${elapsed}s"
            cleanup_failed_instance
            exit 1
        fi
        
        # Get instance status
        local status_response
        status_response=$(curl -s --insecure -H "x-api-token: $GENYMOTION_API_KEY" \
            "$GENYMOTION_API_ENDPOINT/v1/instances/$INSTANCE_ID")
        
        log_debug "Status response: $status_response"
        
        local state
        state=$(echo "$status_response" | jq -r '.state')
        
        log_debug "Instance state: $state"
        
        # Show state change messages
        if [ "$state" != "$last_state" ]; then
            if [ -n "$last_state" ]; then
                echo ""  # New line after dots
            fi
            case "$state" in
                "CREATING")
                    log_info "Instance state: CREATING - Allocating cloud resources..."
                    ;;
                "BOOTING")
                    log_info "Instance state: BOOTING - Android OS starting up..."
                    ;;
                "STARTING")
                    log_info "Instance state: STARTING - Finalizing boot process..."
                    ;;
            esac
            last_state="$state"
            dots_count=0
        fi
        
        case "$state" in
            "ONLINE")
                echo ""  # New line after dots
                log_info "Instance is online! Boot completed in ${elapsed}s"
                
                # Extract both WebSocket ADB URL and TCP ADB port
                local adb_url tcp_adb_port instance_host
                adb_url=$(echo "$status_response" | jq -r '.adb_url')
                tcp_adb_port=$(echo "$status_response" | jq -r '.providerData.adbTcpPort // .adbTcpPort')
                instance_host=$(echo "$status_response" | jq -r '.ipAddress // .streamer_fqdn')
                
                log_info "WebSocket ADB URL: $adb_url"
                log_info "TCP ADB Port: $tcp_adb_port"
                log_info "Instance Host: $instance_host"
                
                # Prefer TCP ADB over WebSocket for direct compatibility
                if [[ -n "$tcp_adb_port" && "$tcp_adb_port" != "null" && -n "$instance_host" && "$instance_host" != "null" ]]; then
                    INSTANCE_IP="$instance_host"
                    ADB_PORT="$tcp_adb_port"
                    log_info "Using TCP ADB connection: $INSTANCE_IP:$ADB_PORT"
                    log_info "TCP ADB provides direct android_world compatibility"
                    
                    # Save TCP connection details for android_world
                    cat > /tmp/genymotion_connection.env << EOF
GENYMOTION_INSTANCE_ID="$INSTANCE_ID"
GENYMOTION_HOST="$INSTANCE_IP"
GENYMOTION_TCP_PORT="$ADB_PORT"
GENYMOTION_ADB_URL="tcp://$INSTANCE_IP:$ADB_PORT"
GENYMOTION_CONNECTION_TYPE="tcp"
GENYMOTION_WEBSOCKET_URL="$adb_url"
EOF
                    
                elif [[ -n "$adb_url" && "$adb_url" != "null" ]]; then
                    log_warn "TCP ADB port not available, using WebSocket ADB"
                    
                    # Handle WebSocket URLs
                    if [[ "$adb_url" =~ wss://([^/]+)/([0-9]+) ]]; then
                        INSTANCE_IP="${BASH_REMATCH[1]}"
                        ADB_PORT="${BASH_REMATCH[2]}"
                        log_info "WebSocket ADB connection - Host: $INSTANCE_IP, Port: $ADB_PORT"
                        
                        # Save WebSocket connection info for containers
                        cat > /tmp/genymotion_connection.env << EOF
GENYMOTION_INSTANCE_ID="$INSTANCE_ID"
GENYMOTION_ADB_URL="$adb_url"
GENYMOTION_HOST="$INSTANCE_IP"
GENYMOTION_PORT="$ADB_PORT"
GENYMOTION_CONNECTION_TYPE="websocket"
GENYMOTION_WEBSOCKET_URL="$adb_url"
EOF
                        
                    else
                        log_error "Invalid WebSocket ADB URL format: $adb_url"
                        exit 1
                    fi
                else
                    log_error "No ADB connection method available (neither TCP nor WebSocket)"
                    exit 1
                fi
                return 0
                ;;
            "ERROR"|"FAILED")
                echo ""  # New line after dots
                log_error "Instance failed to start (state: $state)"
                cleanup_failed_instance
                exit 1
                ;;
            "CREATING"|"BOOTING"|"STARTING")
                # Show progress dots with elapsed time
                echo -n "."
                ((dots_count++))
                
                # Show elapsed time every 30 seconds (3 dots at 10s interval)
                if [ $((dots_count % 3)) -eq 0 ]; then
                    printf " (%ds)" "$elapsed"
                fi
                
                # New line every 60 dots to prevent long lines
                if [ $((dots_count % 60)) -eq 0 ]; then
                    echo ""
                fi
                
                sleep $POLL_INTERVAL
                ;;
            *)
                echo ""  # New line after dots
                log_warn "Unknown instance state: $state (elapsed: ${elapsed}s)"
                last_state="$state"
                sleep $POLL_INTERVAL
                ;;
        esac
    done
    
    # Re-enable set -e
    set -e
}

# Connect ADB to the instance
connect_adb() {
    # Check connection type from saved environment
    local connection_type="tcp"  # Default to TCP
    if [ -f "/tmp/genymotion_connection.env" ]; then
        connection_type=$(grep "GENYMOTION_CONNECTION_TYPE=" /tmp/genymotion_connection.env | cut -d'=' -f2 | tr -d '"')
    fi
    
    log_info "Connection type: $connection_type"
    
    if [ "$connection_type" = "websocket" ]; then
        log_info "WebSocket ADB detected - will be handled by android_world"
        log_info "Connection details saved to: /tmp/genymotion_connection.env"
        return 0
    fi
    
    # TCP ADB connection (preferred for android_world)
    log_info "Connecting TCP ADB to $INSTANCE_IP:$ADB_PORT..."
    
    # Test TCP ADB connectivity
    log_info "Testing TCP ADB connectivity..."
    if timeout 10 bash -c "</dev/tcp/$INSTANCE_IP/$ADB_PORT" 2>/dev/null; then
        log_info "✓ TCP ADB port $ADB_PORT is accessible"
    else
        log_warn "TCP ADB port $ADB_PORT not accessible (firewall/network restriction)"
        log_warn "Falling back to WebSocket ADB connection"
        
        # Update connection type to websocket as fallback
        if [ -f "/tmp/genymotion_connection.env" ]; then
            sed -i 's/GENYMOTION_CONNECTION_TYPE="tcp"/GENYMOTION_CONNECTION_TYPE="websocket"/' /tmp/genymotion_connection.env
            log_info "Updated connection type to websocket due to connectivity issues"
        fi
        return 0
    fi
    
    # Kill any existing ADB server
    adb kill-server 2>/dev/null || true
    adb start-server
    
    # Connect to the instance using TCP
    local retry_count=0
    while [ $retry_count -lt $MAX_RETRIES ]; do
        local connect_output
        connect_output=$(adb connect "$INSTANCE_IP:$ADB_PORT" 2>&1)
        
        if [[ "$connect_output" =~ "connected to" ]] && [[ ! "$connect_output" =~ "failed to connect" ]]; then
            log_info "TCP ADB connected successfully to $INSTANCE_IP:$ADB_PORT"
            log_info "Output: $connect_output"
            break
        else
            ((retry_count++))
            log_warn "TCP ADB connection attempt $retry_count failed: $connect_output"
            sleep 5
        fi
        
        if [ $retry_count -eq $MAX_RETRIES ]; then
            log_warn "Failed to connect TCP ADB after $MAX_RETRIES attempts"
            log_warn "Falling back to WebSocket ADB mode"
            
            # Update connection type to websocket
            if [ -f "/tmp/genymotion_connection.env" ]; then
                sed -i 's/GENYMOTION_CONNECTION_TYPE="tcp"/GENYMOTION_CONNECTION_TYPE="websocket"/' /tmp/genymotion_connection.env
                log_info "Updated connection type to websocket"
            fi
            return 0
        fi
    done
    
    # Wait for device to be ready
    log_info "Waiting for Android to boot completely..."
    adb -s "$INSTANCE_IP:$ADB_PORT" wait-for-device
    
    # Wait for boot to complete
    local boot_timeout=$((BOOT_TIMEOUT / 2))
    timeout $boot_timeout adb -s "$INSTANCE_IP:$ADB_PORT" shell 'while [[ -z $(getprop sys.boot_completed) ]]; do sleep 1; done'
    
    log_info "Android boot completed - Device ready for android_world testing"
}

# Configure device settings based on YAML config
configure_device() {
    # Check connection type from saved environment
    local connection_type="tcp"  # Default to TCP
    if [ -f "/tmp/genymotion_connection.env" ]; then
        connection_type=$(grep "GENYMOTION_CONNECTION_TYPE=" /tmp/genymotion_connection.env | cut -d'=' -f2 | tr -d '"')
    fi
    
    if [ "$connection_type" = "websocket" ]; then
        log_info "Skipping device configuration - WebSocket ADB requires container-based setup"
        log_info "Configure device settings from within Docker container after ADB connection"
        return 0
    fi
    
    log_info "Configuring device settings via TCP ADB..."
    
    local adb_device="$INSTANCE_IP:$ADB_PORT"
    
    # Enable developer options
    log_debug "Enabling developer options..."
    adb -s "$adb_device" shell settings put global development_settings_enabled 1
    adb -s "$adb_device" shell settings put global adb_enabled 1
    adb -s "$adb_device" shell settings put global stay_on_while_plugged_in 7
    
    # Configure system settings based on YAML
    local disable_animations
    disable_animations=$(yq eval '.settings.animations_disabled' "$CONFIG_FILE")
    if [ "$disable_animations" = "true" ]; then
        log_debug "Disabling animations..."
        adb -s "$adb_device" shell settings put global window_animation_scale 0
        adb -s "$adb_device" shell settings put global transition_animation_scale 0
        adb -s "$adb_device" shell settings put global animator_duration_scale 0
    fi
    
    # Screen timeout
    local screen_timeout
    screen_timeout=$(yq eval '.settings.screen_timeout' "$CONFIG_FILE")
    if [ "$screen_timeout" = "unlimited" ]; then
        log_debug "Setting unlimited screen timeout..."
        adb -s "$adb_device" shell settings put system screen_off_timeout 2147483647
    fi
    
    # Install unknown apps
    local install_unknown
    install_unknown=$(yq eval '.settings.install_unknown_apps' "$CONFIG_FILE")
    if [ "$install_unknown" = "true" ]; then
        log_debug "Enabling installation from unknown sources..."
        adb -s "$adb_device" shell settings put secure install_non_market_apps 1
    fi
    
    # Location services
    local location_services
    location_services=$(yq eval '.settings.location_services' "$CONFIG_FILE")
    if [ "$location_services" = "true" ]; then
        log_debug "Enabling location services..."
        adb -s "$adb_device" shell settings put secure location_providers_allowed +gps
        adb -s "$adb_device" shell settings put secure location_providers_allowed +network
    fi
    
    log_info "Device configuration completed"
}

# Cleanup failed instance
cleanup_failed_instance() {
    if [ "$CLEANUP_ON_FAILURE" = true ] && [ -n "$INSTANCE_ID" ]; then
        log_warn "Cleaning up failed instance: $INSTANCE_ID"
        curl -s --insecure -X DELETE \
            -H "x-api-token: $GENYMOTION_API_KEY" \
            "$GENYMOTION_API_ENDPOINT/v1/instances/$INSTANCE_ID" > /dev/null
    fi
}

# Output connection information
output_connection_info() {
    log_info "===== GENYMOTION CLOUD INSTANCE READY ====="
    echo ""
    echo "Instance ID: $INSTANCE_ID"
    echo "Instance Host: $INSTANCE_IP"
    echo "ADB Port: $ADB_PORT"
    
    # Check connection type from saved environment
    local connection_type="tcp"  # Default to TCP
    if [ -f "/tmp/genymotion_connection.env" ]; then
        connection_type=$(grep "GENYMOTION_CONNECTION_TYPE=" /tmp/genymotion_connection.env | cut -d'=' -f2 | tr -d '"')
    fi
    
    echo ""
    echo "Connection Type: $connection_type"
    echo "Connection details saved to: /tmp/genymotion_connection.env"
    echo ""
    
    if [ "$connection_type" = "tcp" ]; then
        echo "TCP ADB CONNECTION (android_world compatible)"
        echo "Direct ADB Connection: $INSTANCE_IP:$ADB_PORT"
        echo ""
        echo "For Docker containers:"
        echo "  source /tmp/genymotion_connection.env"
        echo "  adb connect \$GENYMOTION_HOST:\$GENYMOTION_TCP_PORT"
        echo ""
        echo "This TCP connection provides full android_world compatibility!"
    else
        echo "WEBSOCKET ADB CONNECTION (requires bridge or modification)"
        echo "WebSocket ADB requires special handling in containers."
        echo ""
        echo "For Docker containers:"
        echo "  source /tmp/genymotion_connection.env"
        echo "  # Use GENYMOTION_WEBSOCKET_URL for WebSocket connections"
        echo ""
        echo "Note: WebSocket ADB may need android_world modifications for compatibility"
    fi
    
    echo ""
    echo "To stop/delete instance (disposable instances stop automatically):"
    echo "  curl -X DELETE -H \"x-api-token: \$GENYMOTION_API_KEY\" \\"
    echo "    \"$GENYMOTION_API_ENDPOINT/v1/instances/$INSTANCE_ID\""
    echo ""
    log_info "Provisioning completed successfully!"
    
    if [ "$connection_type" = "tcp" ]; then
        log_info "Ready for android_world testing with TCP ADB!"
    else
        log_warn "WebSocket ADB detected - may need android_world modifications"
    fi
}

# Main execution function
main() {
    log_info "Starting Genymotion Cloud provisioning..."
    log_info "Configuration: $CONFIG_FILE"
    log_info "Device Name: $DEVICE_NAME"
    
    # Initialize log file
    echo "=== Genymotion Provisioning Log $(date) ===" > "$LOG_FILE"
    
    # Execute provisioning steps
    check_dependencies
    validate_api_connection
    read_config
    
    local recipe_id
    recipe_id=$(find_recipe_id)
    
    create_instance "$recipe_id"
    start_instance
    wait_for_instance_online
    connect_adb
    configure_device
    
    output_connection_info
}

# Trap to cleanup on script exit (only on failure)
trap cleanup_failed_instance EXIT

# Run main function and clear trap on success
main "$@"

# Clear trap on successful completion
trap - EXIT