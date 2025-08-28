#!/bin/bash

# Android World App Installation Script
# Downloads and installs APK files for android_world testing

set -e  # Exit on any error

# ===== CONFIGURATION VARIABLES =====
# Edit these variables to customize your setup

# Configuration file and device settings
CONFIG_FILE="infra/genymotion/device-configs/core-apps-config.yaml"  # Change this to switch configs
ADB_DEVICE=""  # Auto-detect if empty, or specify like "192.168.1.100:5555"
APK_CACHE_DIR="infra/apps/apks"
APP_MAPPING_FILE="infra/apps/app-mapping.yaml"

# Download settings
DOWNLOAD_TIMEOUT=300  # 5 minutes per APK
MAX_RETRIES=3
USER_AGENT="AndroidWorld/1.0"

# Installation behavior
SKIP_EXISTING=true    # Skip apps already installed
FORCE_REINSTALL=false # Force reinstall even if present

# Debug settings
DEBUG_MODE=true
LOG_FILE="/tmp/android-app-install.log"

# ===== END CONFIGURATION =====

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
INSTALLED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

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

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_tools=()
    
    # Check for required tools
    if ! command -v yq &> /dev/null; then
        missing_tools+=("yq")
    fi
    
    if ! command -v adb &> /dev/null; then
        missing_tools+=("adb")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    if ! command -v wget &> /dev/null; then
        missing_tools+=("wget")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install missing tools and try again"
        exit 1
    fi
    
    log_info "All dependencies found"
}

# Detect ADB device
detect_adb_device() {
    if [ -n "$ADB_DEVICE" ]; then
        log_info "Using specified ADB device: $ADB_DEVICE"
        return
    fi
    
    # Check for WebSocket connection first
    if [ -f "/tmp/genymotion_connection.env" ]; then
        log_info "Genymotion WebSocket connection detected"
        
        # Source the connection environment
        source /tmp/genymotion_connection.env
        
        if [[ "$GENYMOTION_ADB_URL" =~ wss:// ]]; then
            log_warn "WebSocket ADB connection detected: $GENYMOTION_ADB_URL"
            log_warn "WebSocket ADB is not supported by standard ADB commands"
            log_warn "For WebSocket ADB connections, you need:"
            log_warn "1. Use Genymotion's gmtool for device management"
            log_warn "2. Use a WebSocket-to-TCP ADB bridge"
            log_warn "3. Or connect via Genymotion Desktop application"
            log_warn ""
            log_warn "Skipping app installation due to WebSocket ADB limitation"
            log_warn "This is expected behavior for Genymotion Cloud instances"
            exit 0
        fi
    fi
    
    log_info "Auto-detecting ADB device..."
    
    # Get list of connected devices
    local devices
    devices=$(adb devices | grep -v "List of devices" | grep -E "device$|emulator$" | awk '{print $1}')
    
    if [ -z "$devices" ]; then
        log_error "No ADB devices found. Please ensure:"
        log_error "1. Genymotion emulator is running"
        log_error "2. ADB is connected (adb connect IP:PORT)"
        log_error "3. Device is authorized"
        
        # Additional guidance for WebSocket connections
        if [ -f "/tmp/genymotion_connection.env" ]; then
            log_error ""
            log_error "Note: WebSocket ADB connections (wss://) are detected"
            log_error "WebSocket ADB requires special handling not supported by standard adb commands"
        fi
        
        exit 1
    fi
    
    # Use first device if multiple found
    ADB_DEVICE=$(echo "$devices" | head -1)
    local device_count
    device_count=$(echo "$devices" | wc -l)
    
    if [ "$device_count" -gt 1 ]; then
        log_warn "Multiple devices found, using: $ADB_DEVICE"
        log_warn "Available devices:"
        echo "$devices" | sed 's/^/  - /'
    else
        log_info "Found ADB device: $ADB_DEVICE"
    fi
}

# Validate ADB connection
validate_adb_connection() {
    log_info "Validating ADB connection to $ADB_DEVICE..."
    
    # Test basic ADB command
    if ! adb -s "$ADB_DEVICE" shell echo "test" > /dev/null 2>&1; then
        log_error "Cannot communicate with ADB device: $ADB_DEVICE"
        log_error "Please check device connection and authorization"
        exit 1
    fi
    
    # Get device info
    local device_model
    local android_version
    device_model=$(adb -s "$ADB_DEVICE" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    android_version=$(adb -s "$ADB_DEVICE" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
    
    log_info "Device: $device_model (Android $android_version)"
    log_info "ADB connection validated"
}

# Read app list from configuration
read_app_list() {
    log_info "Reading app list from: $CONFIG_FILE"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Extract app names from YAML
    local app_list
    app_list=$(yq eval '.apps[]' "$CONFIG_FILE" 2>/dev/null | grep -v "null")
    
    if [ -z "$app_list" ]; then
        log_error "No apps found in configuration file"
        exit 1
    fi
    
    log_info "Found $(echo "$app_list" | wc -l) apps to install"
    log_debug "Apps: $(echo "$app_list" | tr '\n' ' ')"
    
    echo "$app_list"
}

# Get APK info for app name
get_apk_info() {
    local app_name="$1"
    
    # Check if we have mapping file
    if [ ! -f "$APP_MAPPING_FILE" ]; then
        log_error "App mapping file not found: $APP_MAPPING_FILE"
        exit 1
    fi
    
    # Get APK filename and download URL from mapping
    local apk_file
    local download_url
    local package_name
    
    apk_file=$(yq eval ".apps.$app_name.apk_file" "$APP_MAPPING_FILE" 2>/dev/null)
    download_url=$(yq eval ".apps.$app_name.download_url" "$APP_MAPPING_FILE" 2>/dev/null)  
    package_name=$(yq eval ".apps.$app_name.package_name" "$APP_MAPPING_FILE" 2>/dev/null)
    
    if [ "$apk_file" = "null" ] || [ -z "$apk_file" ]; then
        log_error "No APK mapping found for app: $app_name"
        return 1
    fi
    
    echo "$apk_file|$download_url|$package_name"
}

# Check if app is already installed
is_app_installed() {
    local package_name="$1"
    
    if [ -z "$package_name" ] || [ "$package_name" = "null" ]; then
        return 1  # Cannot check without package name
    fi
    
    # Check if package is installed
    if adb -s "$ADB_DEVICE" shell pm list packages | grep -q "package:$package_name"; then
        return 0  # Installed
    else
        return 1  # Not installed
    fi
}

# Download APK file
download_apk() {
    local app_name="$1"
    local apk_file="$2"
    local download_url="$3"
    local apk_path="$APK_CACHE_DIR/$apk_file"
    
    # Create APK directory if needed
    mkdir -p "$APK_CACHE_DIR"
    
    # Skip if already downloaded
    if [ "$SKIP_EXISTING" = true ] && [ -f "$apk_path" ]; then
        log_debug "APK already downloaded: $apk_file"
        return 0
    fi
    
    log_info "Downloading $app_name APK..."
    log_debug "URL: $download_url"
    log_debug "File: $apk_path"
    
    # Download with wget (more reliable for large files)
    if ! wget -q --timeout="$DOWNLOAD_TIMEOUT" \
               --tries="$MAX_RETRIES" \
               --user-agent="$USER_AGENT" \
               --output-document="$apk_path" \
               "$download_url"; then
        log_error "Failed to download APK for $app_name"
        rm -f "$apk_path"  # Clean up partial download
        return 1
    fi
    
    # Verify APK file
    if [ ! -f "$apk_path" ] || [ ! -s "$apk_path" ]; then
        log_error "Downloaded APK is empty or missing: $apk_file"
        return 1
    fi
    
    log_info "Downloaded: $apk_file ($(du -h "$apk_path" | cut -f1))"
    return 0
}

# Install APK on device
install_apk() {
    local app_name="$1"
    local apk_file="$2"
    local apk_path="$APK_CACHE_DIR/$apk_file"
    
    if [ ! -f "$apk_path" ]; then
        log_error "APK file not found: $apk_path"
        return 1
    fi
    
    log_info "Installing $app_name..."
    log_debug "APK: $apk_path"
    
    # Install with ADB
    local install_output
    if install_output=$(adb -s "$ADB_DEVICE" install -r "$apk_path" 2>&1); then
        if echo "$install_output" | grep -q "Success"; then
            log_info "Successfully installed: $app_name"
            return 0
        else
            log_error "Installation failed for $app_name: $install_output"
            return 1
        fi
    else
        log_error "ADB install command failed for $app_name"
        return 1
    fi
}

# Install single app
install_single_app() {
    local app_name="$1"
    
    log_debug "Processing app: $app_name"
    
    # Get APK information
    local apk_info
    if ! apk_info=$(get_apk_info "$app_name"); then
        log_error "Cannot find APK info for: $app_name"
        ((FAILED_COUNT++))
        return 1
    fi
    
    # Parse APK info
    local apk_file
    local download_url  
    local package_name
    IFS='|' read -r apk_file download_url package_name <<< "$apk_info"
    
    # Check if already installed (unless force reinstall)
    if [ "$FORCE_REINSTALL" = false ] && is_app_installed "$package_name"; then
        log_info "App already installed, skipping: $app_name ($package_name)"
        ((SKIPPED_COUNT++))
        return 0
    fi
    
    # Download APK if needed
    if ! download_apk "$app_name" "$apk_file" "$download_url"; then
        log_error "Failed to download APK for: $app_name"
        ((FAILED_COUNT++))
        return 1
    fi
    
    # Install APK
    if install_apk "$app_name" "$apk_file"; then
        ((INSTALLED_COUNT++))
        return 0
    else
        ((FAILED_COUNT++))
        return 1
    fi
}

# Install all apps from configuration
install_all_apps() {
    log_info "Starting app installation process..."
    
    # Get app list
    local app_list
    app_list=$(read_app_list)
    
    # Install each app
    while IFS= read -r app_name; do
        [ -z "$app_name" ] && continue
        install_single_app "$app_name"
    done <<< "$app_list"
}

# Output installation summary
output_summary() {
    log_info "===== APP INSTALLATION SUMMARY ====="
    echo ""
    echo "✅ Successfully Installed: $INSTALLED_COUNT apps"
    echo "⏭️  Skipped (Already Installed): $SKIPPED_COUNT apps"  
    echo "❌ Failed: $FAILED_COUNT apps"
    echo ""
    
    if [ "$FAILED_COUNT" -gt 0 ]; then
        log_warn "Some apps failed to install. Check logs for details."
        log_info "Log file: $LOG_FILE"
    else
        log_info "All apps processed successfully!"
    fi
}

# Main execution function
main() {
    log_info "Starting Android World app installation..."
    log_info "Configuration: $CONFIG_FILE"
    log_info "APK Cache: $APK_CACHE_DIR"
    
    # Initialize log file
    echo "=== Android App Installation Log $(date) ===" > "$LOG_FILE"
    
    # Execute installation steps
    check_dependencies
    detect_adb_device
    validate_adb_connection
    install_all_apps
    
    output_summary
}

# Run main function
main "$@"