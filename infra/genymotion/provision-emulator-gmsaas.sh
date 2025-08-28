#!/bin/bash

# Genymotion Cloud Android Emulator Provisioning Script (gmsaas CLI)
# Simple workflow using gmsaas CLI commands

set -e  # Exit on any error (will be disabled temporarily for debugging)

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
        
        # Try to match this ADB device with a gmsaas instance
        local instances_output
        instances_output=$(gmsaas instances list 2>/dev/null | tail -n +2)  # Skip header line
        
        # Look for ONLINE instances and try to match ADB serial
        local matching_instance
        matching_instance=$(echo "$instances_output" | grep "ONLINE" | head -1 | awk '{print $1}')
        
        if [ -n "$matching_instance" ]; then
            log_info "Found matching ONLINE instance: $matching_instance"
            INSTANCE_ID="$matching_instance"
        else
            log_info "No matching gmsaas instance found, using host-managed"
            INSTANCE_ID="host-managed"
        fi
        
        # Set global ADB_DEVICE variable
        ADB_DEVICE="$device_serial"
        
        # Create connection info for existing device
        cat > /tmp/genymotion_connection.env << EOF
GENYMOTION_INSTANCE_ID="$INSTANCE_ID"
GENYMOTION_ADB_DEVICE="$device_serial"
GENYMOTION_CONNECTION_TYPE="existing"
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

# Create new instance
create_instance() {
    log_info "Creating new Genymotion Cloud instance..."
    log_info "Recipe: Samsung Galaxy S23"
    log_info "Name: $DEVICE_NAME"
    
    # Hardcoded Samsung Galaxy S23 UUID (known working)
    local recipe_uuid="37499e5d-6bee-46d1-b07a-e594ff3fcb0d"
    log_info "Using recipe UUID: $recipe_uuid"
    
    # Start new instance with UUID
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

# Wait for instance to be online and fully ready
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
            log_info "Waiting 45 seconds for ADB services to fully initialize..."
            sleep 45
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
    # Check if we already have ADB_DEVICE from existing connection
    if [ -n "$ADB_DEVICE" ]; then
        log_info "Using existing ADB connection: $ADB_DEVICE"
        log_info "Verifying existing connection..."
        
        # Test the existing connection
        if adb -s "$ADB_DEVICE" shell echo "test" >/dev/null 2>&1; then
            log_info "✓ Existing ADB connection is working"
            
            # Save connection info for other scripts
            cat > /tmp/genymotion_connection.env << EOF
GENYMOTION_INSTANCE_ID="$INSTANCE_ID"
GENYMOTION_ADB_DEVICE="$ADB_DEVICE"
GENYMOTION_CONNECTION_TYPE="existing"
EOF
            return 0
        else
            log_warn "Existing ADB connection test failed, will check all devices..."
        fi
    fi
    
    # Container-specific ADB setup for macOS host (Docker Desktop)
    log_info "Setting up container ADB connection for macOS host..."
    
    # Kill container's ADB server to connect to host's ADB server
    log_info "Killing container's ADB server..."
    adb kill-server >/dev/null 2>&1 || true
    
    # Set environment to connect to host ADB server
    export ANDROID_ADB_SERVER_ADDRESS="host.docker.internal"
    log_info "Set ANDROID_ADB_SERVER_ADDRESS=host.docker.internal"
    
    # Connect to host ADB device on port 5555
    log_info "Connecting to host ADB device on port 5555..."
    adb connect host.docker.internal:5555
    
    # Check for devices after connection
    log_info "Checking for devices on host ADB server..."
    local devices
    devices=$(adb devices 2>&1)
    local adb_devices_exit_code=$?
    
    log_info "adb devices exit code: $adb_devices_exit_code"
    log_info "ADB devices output:"
    echo "$devices"
    
    # Extract any working device from adb devices output
    local device_line
    device_line=$(echo "$devices" | grep -E "device$|emulator$" | head -1)
    
    if [ -n "$device_line" ]; then
        ADB_DEVICE=$(echo "$device_line" | awk '{print $1}')
        log_info "✓ Found working ADB device: $ADB_DEVICE"
        
        # Test this device
        if adb -s "$ADB_DEVICE" shell echo "connectivity test" >/dev/null 2>&1; then
            log_info "✓ ADB device connectivity confirmed"
            
            # Save connection info for other scripts
            cat > /tmp/genymotion_connection.env << EOF
GENYMOTION_INSTANCE_ID="$INSTANCE_ID"
GENYMOTION_ADB_DEVICE="$ADB_DEVICE"
GENYMOTION_CONNECTION_TYPE="host-managed"
EOF
            return 0
        else
            log_warn "Device $ADB_DEVICE found but not responding to commands"
        fi
    fi
    
    log_error "No working ADB devices found on host"
    log_error "Please establish gmsaas connection on host first:"
    log_error "  1. adb kill-server"
    log_error "  2. gmsaas auth token <your_token>"
    log_error "  3. gmsaas instances adbconnect --adb-serial-port 5555 <instance_id>"
    log_error "  4. Then run this container"
    exit 1
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