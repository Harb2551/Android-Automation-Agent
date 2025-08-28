#!/bin/bash

# Android World Main Orchestration Script
# Coordinates device provisioning, app installation, and test execution

set -e  # Exit on any error

# ===== CONFIGURATION VARIABLES =====
# Edit these variables to customize your setup

# Operation mode
OPERATION_MODE="provision_and_test"  # provision_only, install_apps_only, test_only, provision_and_test

# Configuration files
CONFIG_FILE="${CONFIG_FILE:-infra/genymotion/device-configs/core-apps-config.yaml}"
APP_MAPPING_FILE="${APP_MAPPING_FILE:-infra/apps/app-mapping.yaml}"

# Genymotion Cloud settings (required for provision operations)
GENYMOTION_API_KEY="${GENYMOTION_API_KEY:-}"

# ADB settings
ADB_DEVICE="${ADB_DEVICE:-}"  # Auto-detect if empty
ADB_CONNECTION_TIMEOUT=60

# Android World test settings
ANDROID_WORLD_AGENT="m3a"  # m3a, t3a, seeact, human, random
ANDROID_WORLD_TASK_FAMILY="android"  # android, miniwob, information_retrieval
ANDROID_WORLD_MAX_STEPS=10
ANDROID_WORLD_OUTPUT_DIR="/app/results"

# Operation flags
PROVISION_DEVICE=true     # Create Genymotion Cloud instance
INSTALL_APPS=true         # Install required Android apps
GRANT_PERMISSIONS=true    # Grant app permissions
RUN_TESTS=true           # Execute android_world tests
CLEANUP_ON_EXIT=true     # Delete cloud instance when done

# Debug settings
DEBUG_MODE=true
LOG_FILE="./logs/android_world_run.log"

# ===== END CONFIGURATION =====

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
GENYMOTION_INSTANCE_ID=""
GENYMOTION_INSTANCE_IP=""
ADB_DEVICE_CONNECTED=""

# Logging functions
log_info() {
    local msg="[INFO] $1"
    echo -e "${GREEN}$msg${NC}"
    echo "$(date): $msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[WARN] $1"
    echo -e "${YELLOW}$msg${NC}"
    echo "$(date): $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[ERROR] $1"
    echo -e "${RED}$msg${NC}"
    echo "$(date): $msg" >> "$LOG_FILE"
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        local msg="[DEBUG] $1"
        echo -e "${BLUE}$msg${NC}"
        echo "$(date): $msg" >> "$LOG_FILE"
    fi
}

# Show usage information
show_usage() {
    echo "Android World Test Runner"
    echo ""
    echo "Usage: $0 [OPTIONS] [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  provision       Provision Genymotion Cloud device only"
    echo "  install-apps    Install Android apps only (requires existing device)"
    echo "  test            Run android_world tests only (requires setup device)"
    echo "  full            Full workflow: provision + apps + test (default)"
    echo "  cleanup         Delete Genymotion Cloud instance"
    echo "  --help          Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  GENYMOTION_API_KEY     Genymotion Cloud API key (required)"
    echo "  CONFIG_FILE            Device configuration YAML"
    echo "  ADB_DEVICE             Specific ADB device to use"
    echo "  ANDROID_WORLD_AGENT    Agent type (m3a, t3a, seeact)"
    echo ""
    echo "Examples:"
    echo "  $0 full                                    # Complete workflow"
    echo "  $0 provision                               # Just create device"
    echo "  CONFIG_FILE=full-suite-config.yaml $0     # Use full app suite"
    echo "  ADB_DEVICE=192.168.1.100:5555 $0 test     # Test on specific device"
}

# Initialize logging and directories
initialize_environment() {
    log_info "Initializing Android World environment..."
    
    # Create necessary directories
    mkdir -p "$(dirname "$LOG_FILE")" "$ANDROID_WORLD_OUTPUT_DIR" /app/cache ./logs
    
    # Initialize log file
    echo "=== Android World Run Log $(date) ===" > "$LOG_FILE"
    
    # Log configuration
    log_debug "Operation Mode: $OPERATION_MODE"
    log_debug "Configuration: $CONFIG_FILE"
    log_debug "Agent: $ANDROID_WORLD_AGENT"
    log_debug "Task Family: $ANDROID_WORLD_TASK_FAMILY"
    log_debug "Output Directory: $ANDROID_WORLD_OUTPUT_DIR"
}

# Provision Genymotion Cloud device
provision_device() {
    if [ "$PROVISION_DEVICE" != true ]; then
        log_info "Skipping device provisioning (disabled)"
        return 0
    fi
    
    log_info "===== PROVISIONING GENYMOTION CLOUD DEVICE ====="
    
    # Check for API key
    if [ -z "$GENYMOTION_API_KEY" ]; then
        log_error "GENYMOTION_API_KEY environment variable is required"
        log_error "Export your API key: export GENYMOTION_API_KEY='your_key_here'"
        exit 1
    fi
    
    # Export API key for provisioning script
    export GENYMOTION_API_KEY="$GENYMOTION_API_KEY"
    
    # Run provisioning script
    if ./infra/genymotion/provision-emulator.sh; then
        log_info "Device provisioning completed successfully"
        
        # Extract connection info from provisioning output
        # Note: In a real implementation, the provisioning script would output
        # connection details in a parseable format (JSON/YAML)
        log_debug "Device should be available for ADB connection"
    else
        log_error "Device provisioning failed"
        exit 1
    fi
}

# Start WebSocket ADB bridge if needed
start_websocket_bridge() {
    # Check for Genymotion connection details
    if [ ! -f "/tmp/genymotion_connection.env" ]; then
        log_debug "No Genymotion connection file found"
        return 0
    fi
    
    # Source the connection environment
    source /tmp/genymotion_connection.env
    
    # Check connection type
    local connection_type="${GENYMOTION_CONNECTION_TYPE:-tcp}"
    log_info "Detected connection type: $connection_type"
    
    if [ "$connection_type" = "tcp" ]; then
        log_info "TCP ADB connection - no bridge needed"
        ADB_DEVICE="$GENYMOTION_HOST:$GENYMOTION_TCP_PORT"
        return 0
    elif [ "$connection_type" = "websocket" ]; then
        log_info "WebSocket ADB detected - starting bridge for ADB compatibility"
        
        # Check if bridge is already running
        if [ -f "/tmp/websocket_bridge.pid" ]; then
            local existing_pid
            existing_pid=$(cat /tmp/websocket_bridge.pid)
            if kill -0 "$existing_pid" 2>/dev/null; then
                log_info "WebSocket bridge already running (PID: $existing_pid)"
                ADB_DEVICE="localhost:5555"
                return 0
            fi
        fi
        
        # Verify WebSocket URL is available
        local websocket_url="${GENYMOTION_WEBSOCKET_URL:-}"
        
        # If not set, try to get from ADB_URL but ensure it's WebSocket format
        if [ -z "$websocket_url" ] || [ "$websocket_url" = "null" ]; then
            if [[ "${GENYMOTION_ADB_URL:-}" =~ ^wss:// ]]; then
                websocket_url="$GENYMOTION_ADB_URL"
            else
                log_error "No WebSocket ADB URL found in connection environment"
                log_error "Available URLs: GENYMOTION_ADB_URL=${GENYMOTION_ADB_URL:-none}, GENYMOTION_WEBSOCKET_URL=${GENYMOTION_WEBSOCKET_URL:-none}"
                return 1
            fi
        fi
        
        # Validate WebSocket URL format
        if [[ ! "$websocket_url" =~ ^wss:// ]]; then
            log_error "Invalid WebSocket URL format: $websocket_url"
            log_error "Expected WebSocket URL starting with wss://"
            return 1
        fi
        
        log_info "Starting WebSocket-to-TCP ADB bridge..."
        log_info "Bridge: $websocket_url -> localhost:5555"
        
        # Kill any existing ADB connections and bridges
        adb kill-server 2>/dev/null || true
        pkill -f "websocket-adb-bridge" 2>/dev/null || true
        sleep 2
        
        # Set environment for bridge
        export GENYMOTION_WEBSOCKET_URL="$websocket_url"
        
        # Start bridge
        python3 /app/infra/websocket-bridge/websocket-adb-bridge.py > /tmp/websocket_bridge.log 2>&1 &
        local bridge_pid=$!
        
        # Check if process started successfully
        sleep 1
        if ! kill -0 "$bridge_pid" 2>/dev/null; then
            log_error "Failed to start WebSocket bridge process"
            cat /tmp/websocket_bridge.log 2>/dev/null || echo "No bridge log available"
            return 1
        fi
        
        echo "$bridge_pid" > /tmp/websocket_bridge.pid
        log_info "Bridge started with PID: $bridge_pid"
        
        # Wait for bridge to initialize
        log_info "Waiting for bridge to initialize..."
        sleep 8
        
        # Restart ADB and test connection
        adb start-server
        
        local max_attempts=10
        local attempt=1
        local bridge_ready=false
        
        while [ $attempt -le $max_attempts ]; do
            log_info "Testing bridge (attempt $attempt/$max_attempts)..."
            
            if adb connect localhost:5555 2>&1 | grep -q "connected\|already connected"; then
                log_info "✓ WebSocket ADB bridge ready!"
                ADB_DEVICE="localhost:5555"
                bridge_ready=true
                break
            fi
            
            if ! kill -0 "$bridge_pid" 2>/dev/null; then
                log_error "Bridge process died"
                cat /tmp/websocket_bridge.log 2>/dev/null || echo "No bridge log"
                return 1
            fi
            
            sleep 3
            ((attempt++))
        done
        
        if [ "$bridge_ready" != "true" ]; then
            log_error "Bridge failed to initialize"
            kill "$bridge_pid" 2>/dev/null || true
            return 1
        fi
    fi
}

# Install Android applications
install_applications() {
    if [ "$INSTALL_APPS" != true ]; then
        log_info "Skipping app installation (disabled)"
        return 0
    fi
    
    log_info "===== INSTALLING ANDROID APPLICATIONS ====="
    
    # Export configuration for app installation script
    export CONFIG_FILE="$CONFIG_FILE"
    export ADB_DEVICE="$ADB_DEVICE"
    
    # Run app installation
    if ./infra/apps/install-apps.sh; then
        log_info "App installation completed successfully"
    else
        log_error "App installation failed"
        exit 1
    fi
}

# Grant application permissions
grant_permissions() {
    if [ "$GRANT_PERMISSIONS" != true ]; then
        log_info "Skipping permission granting (disabled)"
        return 0
    fi
    
    log_info "===== GRANTING APPLICATION PERMISSIONS ====="
    
    # Export configuration for permission script
    export CONFIG_FILE="$CONFIG_FILE"
    export ADB_DEVICE="$ADB_DEVICE"
    
    # Run permission granting
    if ./infra/apps/grant-permissions.sh; then
        log_info "Permission granting completed successfully"
    else
        log_warn "Permission granting had some issues (continuing)"
    fi
}

# Run Android World tests
run_android_world_tests() {
    if [ "$RUN_TESTS" != true ]; then
        log_info "Skipping android_world test execution (disabled)"
        return 0
    fi
    
    log_info "===== RUNNING ANDROID WORLD TESTS ====="
    
    # Bridge should already be started by start_websocket_bridge()
    log_info "Using ADB connection established by bridge setup"
    
    # If ADB_DEVICE not set, try to detect from existing connections
    if [ -z "$ADB_DEVICE" ]; then
        log_info "ADB device not set, detecting from available connections..."
        ADB_DEVICE=$(adb devices | grep -E "device$|emulator$" | head -1 | awk '{print $1}')
        
        if [ -n "$ADB_DEVICE" ]; then
            log_info "Using detected ADB device: $ADB_DEVICE"
        fi
    fi
    # Change to android_world directory
    cd android_world
    
    # Set up Android World environment
    export ANDROID_WORLD_OUTPUT_DIR="$ANDROID_WORLD_OUTPUT_DIR"
    
    # Detect ADB device if not specified
    if [ -z "$ADB_DEVICE" ]; then
        ADB_DEVICE=$(adb devices | grep -E "device$|emulator$" | head -1 | awk '{print $1}')
        if [ -z "$ADB_DEVICE" ]; then
            log_error "No ADB devices found for testing"
            
            # Additional guidance for WebSocket connections
            if [ -f "/tmp/genymotion_connection.env" ]; then
                log_error ""
                log_error "Note: WebSocket ADB connections (wss://) are detected"
                log_error "WebSocket ADB requires special handling not supported by android_world"
            fi
            
            exit 1
        fi
        log_info "Using ADB device: $ADB_DEVICE"
    fi
    
    # Build android_world test command
    # First check if android_world module is properly installed
    if ! python3 -c "import android_world" 2>/dev/null; then
        log_error "android_world module not found. Installing..."
        cd android_world && pip install -e . && cd ..
    fi
    
    # Try different possible android_world entry points
    local test_cmd=""
    if python3 -c "import android_world.bin.run_episode" 2>/dev/null; then
        test_cmd="python3 -m android_world.bin.run_episode"
    elif python3 -c "import android_world.run_episode" 2>/dev/null; then
        test_cmd="python3 -m android_world.run_episode"
    elif [ -f "android_world/bin/run_episode.py" ]; then
        test_cmd="python3 android_world/bin/run_episode.py"
    elif [ -f "android_world/run_episode.py" ]; then
        test_cmd="python3 android_world/run_episode.py"
    elif [ -f "android_world/episode_runner.py" ]; then
        log_info "Using episode_runner.py entry point"
        test_cmd="python3 android_world/episode_runner.py"
    else
        log_error "Could not find android_world entry point"
        log_info "Available android_world modules:"
        find android_world -name "*.py" -type f | grep -E "(run|episode|bin)" | head -10
        exit 1
    fi
    
    test_cmd="$test_cmd --agent=$ANDROID_WORLD_AGENT"
    test_cmd="$test_cmd --task_family=$ANDROID_WORLD_TASK_FAMILY"
    test_cmd="$test_cmd --max_steps=$ANDROID_WORLD_MAX_STEPS"
    test_cmd="$test_cmd --device_id=$ADB_DEVICE"
    test_cmd="$test_cmd --output_dir=$ANDROID_WORLD_OUTPUT_DIR"
    
    log_info "Executing android_world tests..."
    log_debug "Command: $test_cmd"
    
    # Add pre-execution debugging
    log_info "Pre-execution checks:"
    log_info "ADB devices: $(adb devices)"
    log_info "ADB connect test: $(adb connect $ADB_DEVICE 2>&1 || echo 'Connection failed')"
    log_info "ADB devices after connect: $(adb devices)"
    
    # Run the tests with verbose output
    log_info "Starting android_world execution with verbose output..."
    if eval "$test_cmd" 2>&1 | tee /tmp/android_world_output.log; then
        log_info "Android World tests completed successfully"
        
        # Show execution output for debugging
        log_info "Android World execution output:"
        tail -20 /tmp/android_world_output.log 2>/dev/null || echo "No output log found"
        
        # Display results summary
        if [ -d "$ANDROID_WORLD_OUTPUT_DIR" ]; then
            local result_count
            result_count=$(find "$ANDROID_WORLD_OUTPUT_DIR" -name "*.json" | wc -l)
            log_info "Generated $result_count test result files in $ANDROID_WORLD_OUTPUT_DIR"
            
            # List any files that were created
            log_info "Files in output directory:"
            ls -la "$ANDROID_WORLD_OUTPUT_DIR" 2>/dev/null || echo "Output directory is empty or doesn't exist"
            
            # Check for any error logs or other output files
            if [ -d "$ANDROID_WORLD_OUTPUT_DIR" ]; then
                find "$ANDROID_WORLD_OUTPUT_DIR" -type f -exec ls -la {} \; 2>/dev/null || echo "No files found in output directory"
            fi
        fi
    else
        log_error "Android World tests failed"
        log_info "Error output:"
        tail -20 /tmp/android_world_output.log 2>/dev/null || echo "No error log found"
        exit 1
    fi
    
    # Return to main directory
    cd ..
}

# Cleanup resources
cleanup_resources() {
    if [ "$CLEANUP_ON_EXIT" != true ]; then
        log_info "Skipping cleanup (disabled)"
        return 0
    fi
    
    log_info "===== CLEANING UP RESOURCES ====="
    
    # Cleanup WebSocket ADB bridge if running
    if [ -f "/tmp/websocket_bridge.pid" ]; then
        local bridge_pid
        bridge_pid=$(cat /tmp/websocket_bridge.pid)
        if kill -0 "$bridge_pid" 2>/dev/null; then
            log_info "Stopping WebSocket ADB bridge (PID: $bridge_pid)..."
            kill "$bridge_pid" 2>/dev/null || true
            rm -f /tmp/websocket_bridge.pid
        fi
    fi
    
    # Get Genymotion instance ID from connection file if available
    local genymotion_instance_id=""
    if [ -f "/tmp/genymotion_connection.env" ]; then
        genymotion_instance_id=$(grep "GENYMOTION_INSTANCE_ID=" /tmp/genymotion_connection.env | cut -d'=' -f2 | tr -d '"')
    fi
    
    # Cleanup Genymotion instance if we created one
    if [ -n "$genymotion_instance_id" ] && [ -n "$GENYMOTION_API_KEY" ]; then
        log_info "Deleting Genymotion Cloud instance: $genymotion_instance_id"
        
        curl -s --insecure -X DELETE \
            -H "x-api-token: $GENYMOTION_API_KEY" \
            "https://api.geny.io/cloud/v1/instances/$genymotion_instance_id" > /dev/null || \
            log_warn "Failed to delete Genymotion instance (may need manual cleanup)"
    elif [ -n "$GENYMOTION_INSTANCE_ID" ] && [ -n "$GENYMOTION_API_KEY" ]; then
        log_info "Deleting Genymotion Cloud instance: $GENYMOTION_INSTANCE_ID"
        
        curl -s --insecure -X DELETE \
            -H "x-api-token: $GENYMOTION_API_KEY" \
            "https://api.geny.io/cloud/v1/instances/$GENYMOTION_INSTANCE_ID" > /dev/null || \
            log_warn "Failed to delete Genymotion instance (may need manual cleanup)"
    fi
    
    # Disconnect ADB devices
    if [ -n "$ADB_DEVICE_CONNECTED" ]; then
        log_debug "Disconnecting ADB device: $ADB_DEVICE_CONNECTED"
        adb disconnect "$ADB_DEVICE_CONNECTED" 2>/dev/null || true
    fi
    
    # Clean up connection files
    rm -f /tmp/genymotion_connection.env
    
    log_info "Cleanup completed"
}

# Main execution function
main() {
    # Parse command line arguments
    case "${1:-full}" in
        "provision")
            OPERATION_MODE="provision_only"
            INSTALL_APPS=false
            RUN_TESTS=false
            ;;
        "install-apps")
            OPERATION_MODE="install_apps_only"
            PROVISION_DEVICE=false
            RUN_TESTS=false
            ;;
        "test")
            OPERATION_MODE="test_only"
            PROVISION_DEVICE=false
            INSTALL_APPS=false
            GRANT_PERMISSIONS=false
            ;;
        "full")
            OPERATION_MODE="full_workflow"
            # All operations enabled by default
            ;;
        "cleanup")
            OPERATION_MODE="cleanup_only"
            PROVISION_DEVICE=false
            INSTALL_APPS=false
            GRANT_PERMISSIONS=false
            RUN_TESTS=false
            cleanup_resources
            exit 0
            ;;
        "--help"|"-h"|"help")
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
    
    log_info "Starting Android World deployment pipeline..."
    log_info "Mode: $OPERATION_MODE"
    
    # Initialize environment
    initialize_environment
    
    # Execute workflow steps
    provision_device
    start_websocket_bridge  # Start bridge early for both apps and tests
    install_applications
    grant_permissions
    run_android_world_tests
    
    # Success summary
    log_info "===== ANDROID WORLD DEPLOYMENT COMPLETED ====="
    log_info "Operation: $OPERATION_MODE"
    log_info "Configuration: $CONFIG_FILE"
    log_info "Results: $ANDROID_WORLD_OUTPUT_DIR"
    log_info "Logs: $LOG_FILE"
    
    if [ "$CLEANUP_ON_EXIT" = true ]; then
        cleanup_resources
    else
        log_warn "Cleanup disabled - remember to delete Genymotion Cloud instances manually"
    fi
}

# Set up cleanup trap
trap cleanup_resources EXIT

# Run main function
main "$@"