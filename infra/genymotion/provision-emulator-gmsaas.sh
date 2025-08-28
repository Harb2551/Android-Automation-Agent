#!/bin/bash

# Genymotion Cloud Android Emulator Provisioning Script (gmsaas CLI)
# Simple workflow using gmsaas CLI commands

set -e  # Exit on any error

# ===== CONFIGURATION =====
DEVICE_NAME="AndroidWorld-Test"
RECIPE_NAME="Google Pixel 8"
ANDROID_VERSION="14.0"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    if ! command -v gmsaas &> /dev/null; then
        log_error "gmsaas CLI not found. Install with: pip install gmsaas"
        exit 1
    fi
    
    if ! command -v adb &> /dev/null; then
        log_error "adb not found. Install Android SDK Platform Tools"
        exit 1
    fi
    
    log_info "All dependencies found"
}

# Authenticate with Genymotion
authenticate_gmsaas() {
    log_info "Authenticating with Genymotion API..."
    
    if [ -z "$GENYMOTION_API_TOKEN" ]; then
        log_error "GENYMOTION_API_TOKEN environment variable not set"
        log_error "Set it with: export GENYMOTION_API_TOKEN='your_token_here'"
        exit 1
    fi
    
    # Configure Android SDK path for gmsaas (use container's Android SDK path)
    local android_sdk_path="${ANDROID_HOME:-/opt/android-sdk}"
    log_info "Configuring Android SDK path: $android_sdk_path"
    
    # Debug: Check if SDK path exists and what's in it
    log_info "Checking Android SDK path..."
    if [ -d "$android_sdk_path" ]; then
        log_info "✓ Android SDK directory exists"
        log_info "Contents: $(ls -la "$android_sdk_path" 2>/dev/null)"
        if [ -d "$android_sdk_path/platform-tools" ]; then
            log_info "✓ platform-tools directory exists"
            log_info "platform-tools contents: $(ls -la "$android_sdk_path/platform-tools" 2>/dev/null)"
        else
            log_warn "platform-tools directory missing"
        fi
    else
        log_error "Android SDK path does not exist: $android_sdk_path"
        exit 1
    fi
    
    # Try to configure gmsaas with SDK path
    log_info "Setting gmsaas android-sdk-path..."
    if ! gmsaas config set android-sdk-path "$android_sdk_path"; then
        log_error "Failed to configure Android SDK path for gmsaas"
        log_error "Trying to debug gmsaas config..."
        gmsaas config show || true
        exit 1
    fi
    log_info "✓ Android SDK path configured successfully"
    
    # Authenticate using gmsaas auth token command
    log_info "Authenticating with API token..."
    if ! gmsaas auth token "$GENYMOTION_API_TOKEN" >/dev/null 2>&1; then
        log_error "gmsaas authentication failed. Check your API token."
        exit 1
    fi
    
    # Test authentication by listing instances
    log_info "Testing authentication..."
    if ! gmsaas instances list >/dev/null 2>&1; then
        log_error "gmsaas authentication test failed."
        log_error "Running gmsaas doctor for diagnostics..."
        gmsaas doctor || true
        exit 1
    fi
    
    log_info "Authentication successful"
}

# Check for existing instances or ADB connections
check_existing_instance() {
    log_info "Checking for existing instances..."
    
    # First check if ADB devices are already available (from host)
    local existing_devices
    existing_devices=$(adb devices 2>/dev/null | grep -E "device$|emulator$" | head -1)
    
    if [ -n "$existing_devices" ]; then
        local device_serial
        device_serial=$(echo "$existing_devices" | awk '{print $1}')
        log_info "Found existing ADB device: $device_serial"
        log_info "Skipping instance provisioning - using existing connection"
        
        # Create mock connection info for existing device
        cat > /tmp/genymotion_connection.env << EOF
GENYMOTION_INSTANCE_ID="host-managed"
GENYMOTION_ADB_DEVICE="$device_serial"
GENYMOTION_CONNECTION_TYPE="gmsaas"
EOF
        return 0
    fi
    
    # Check gmsaas instances if no ADB devices found
    local instances_output
    instances_output=$(gmsaas instances list 2>/dev/null | tail -n +2)  # Skip header line
    
    local existing_instance
    existing_instance=$(echo "$instances_output" | grep "$DEVICE_NAME" | grep "ONLINE" | awk '{print $1}' | head -1)
    
    if [ -n "$existing_instance" ]; then
        log_info "Found existing ONLINE instance: $existing_instance"
        INSTANCE_ID="$existing_instance"
        return 0
    fi
    
    log_info "No existing ONLINE instance or ADB device found"
    return 1
}

# Find recipe UUID by name
find_recipe_uuid() {
    log_info "Finding recipe UUID for: $RECIPE_NAME"
    
    local recipes_output
    recipes_output=$(gmsaas recipes list --format json 2>/dev/null)
    
    log_info "Recipes API response (first 500 chars): $(echo "$recipes_output" | head -c 500)"
    
    local recipe_uuid
    recipe_uuid=$(echo "$recipes_output" | jq -r --arg recipe "$RECIPE_NAME" \
        '.[] | select(.name == $recipe) | .uuid' | head -1)
    
    log_info "jq search result: '$recipe_uuid'"
    
    if [ -z "$recipe_uuid" ] || [ "$recipe_uuid" = "null" ]; then
        log_error "Recipe not found: $RECIPE_NAME"
        log_error "Available recipes:"
        gmsaas recipes list | head -10
        log_error "Raw JSON search for debugging:"
        echo "$recipes_output" | jq -r '.[] | "\(.name) -> \(.uuid)"' | head -5
        exit 1
    fi
    
    log_info "✓ Found recipe UUID: $recipe_uuid"
    echo "$recipe_uuid"
}

# Create new instance
create_instance() {
    log_info "Creating new Genymotion Cloud instance..."
    log_info "Recipe: $RECIPE_NAME"
    log_info "Name: $DEVICE_NAME"
    
    # Get recipe UUID first
    local recipe_uuid
    recipe_uuid=$(find_recipe_uuid)
    
    # Start new instance with UUID (not name)
    log_info "Starting instance: gmsaas instances start $recipe_uuid $DEVICE_NAME"
    local start_output
    start_output=$(gmsaas instances start "$recipe_uuid" "$DEVICE_NAME" 2>&1)
    local exit_code=$?
    
    log_info "gmsaas exit code: $exit_code"
    log_info "Output: $start_output"
    
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to start instance"
        log_error "Command: gmsaas instances start $recipe_uuid $DEVICE_NAME"
        log_error "Output: $start_output"
        exit 1
    fi
    
    # Extract UUID from output
    INSTANCE_ID=$(echo "$start_output" | grep -o '[0-9a-f-]\{36\}' | head -1)
    
    if [ -z "$INSTANCE_ID" ]; then
        log_error "Failed to extract instance ID from gmsaas output"
        log_error "Output: $start_output"
        exit 1
    fi
    
    log_info "Instance created with ID: $INSTANCE_ID"
}

# Wait for instance to be online
wait_for_online() {
    log_info "Waiting for instance to come ONLINE..."
    
    local max_attempts=30  # 5 minutes at 10s intervals
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # gmsaas instances list format: UUID  NAME  ADB SERIAL  STATE
        local instances_output
        instances_output=$(gmsaas instances list 2>/dev/null | tail -n +2)  # Skip header
        
        local status
        status=$(echo "$instances_output" | grep "$INSTANCE_ID" | awk '{print $4}' | head -1)
        
        log_info "Instance status: $status (attempt $attempt/$max_attempts)"
        
        if [ "$status" = "ONLINE" ]; then
            log_info "✓ Instance is ONLINE!"
            return 0
        fi
        
        sleep 10
        ((attempt++))
    done
    
    log_error "Timeout waiting for instance to come online"
    exit 1
}

# Connect ADB using gmsaas
connect_adb() {
    log_info "Starting ADB tunnel service..."
    
    # First start the ADB service (like we did manually)
    gmsaas adb start >/dev/null 2>&1
    sleep 2
    
    log_info "Connecting ADB to instance $INSTANCE_ID..."
    
    # Use gmsaas instances adbconnect to connect to specific instance
    local adb_endpoint
    adb_endpoint=$(gmsaas instances adbconnect "$INSTANCE_ID" 2>&1)
    
    log_info "ADB tunnel created: $adb_endpoint"
    
    # Verify ADB connection
    sleep 3
    local devices
    devices=$(adb devices 2>/dev/null)
    
    log_info "ADB devices output:"
    echo "$devices"
    
    # Extract device from adb devices output
    local device_line
    device_line=$(echo "$devices" | grep "device$" | head -1)
    
    if [ -n "$device_line" ]; then
        ADB_DEVICE=$(echo "$device_line" | awk '{print $1}')
        log_info "✓ ADB device ready: $ADB_DEVICE"
        
        # Save connection info for other scripts
        cat > /tmp/genymotion_connection.env << EOF
GENYMOTION_INSTANCE_ID="$INSTANCE_ID"
GENYMOTION_ADB_DEVICE="$ADB_DEVICE"
GENYMOTION_CONNECTION_TYPE="gmsaas"
EOF
        
        return 0
    else
        log_error "ADB connection failed - no devices found"
        log_error "ADB devices output: $devices"
        exit 1
    fi
}

# Test device connectivity
test_device() {
    log_info "Testing device connectivity..."
    
    # Basic connectivity test
    if adb shell echo "AndroidWorld connectivity test" >/dev/null 2>&1; then
        log_info "✓ Device connectivity test passed"
        
        # Get device info
        local model version
        model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')
        version=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
        
        log_info "Device: $model (Android $version)"
        return 0
    else
        log_error "Device connectivity test failed"
        exit 1
    fi
}

# Output connection info
output_connection_info() {
    log_info "===== GENYMOTION INSTANCE READY ====="
    echo ""
    echo "Instance ID: $INSTANCE_ID"
    echo "ADB Device: $ADB_DEVICE"
    echo "Connection Type: gmsaas CLI"
    echo ""
    echo "Connection details saved to: /tmp/genymotion_connection.env"
    echo ""
    echo "Ready for AndroidWorld testing!"
    echo ""
    echo "To stop instance:"
    echo "  gmsaas instances stop $INSTANCE_ID"
    echo ""
}

# Main execution
main() {
    log_info "Starting Genymotion Cloud provisioning with gmsaas CLI..."
    
    check_dependencies
    authenticate_gmsaas
    
    # Check for existing instance or create new one
    if ! check_existing_instance; then
        create_instance
        wait_for_online
    fi
    
    connect_adb
    test_device
    output_connection_info
    
    log_info "Provisioning completed successfully!"
}

# Cleanup function
cleanup() {
    if [ -n "$INSTANCE_ID" ] && [ "$1" = "cleanup" ]; then
        log_info "Cleaning up instance: $INSTANCE_ID"
        gmsaas instances stop "$INSTANCE_ID" >/dev/null 2>&1 || true
    fi
}

# Handle cleanup argument
if [ "$1" = "cleanup" ]; then
    INSTANCE_ID="$2"
    cleanup cleanup
    exit 0
fi

# Run main function
main "$@"