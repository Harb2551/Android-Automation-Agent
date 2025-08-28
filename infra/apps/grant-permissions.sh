#!/bin/bash

# Android World Permission Management Script
# Automatically grants permissions to installed apps based on YAML configuration

set -e  # Exit on any error

# ===== CONFIGURATION VARIABLES =====
# Edit these variables to customize your setup

CONFIG_FILE="infra/genymotion/device-configs/core-apps-config.yaml"  # Change this to switch configs
ADB_DEVICE=""  # Auto-detect if empty, or specify like "192.168.1.100:5555"
APP_MAPPING_FILE="infra/apps/app-mapping.yaml"

# Permission settings
FORCE_GRANT=true     # Force grant permissions even if already granted
IGNORE_FAILURES=true # Continue even if some permissions fail

# Debug settings
DEBUG_MODE=true

# ===== END CONFIGURATION =====

# Source common functions from install script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-apps.sh" 2>/dev/null || {
    echo "Error: Cannot source install-apps.sh functions"
    exit 1
}

# Override main function to prevent auto-execution
main() { :; }

# Permission-specific functions
grant_permission() {
    local package_name="$1"
    local permission="$2"
    
    log_debug "Granting $permission to $package_name..."
    
    # Grant permission using ADB
    if adb -s "$ADB_DEVICE" shell pm grant "$package_name" "$permission" 2>/dev/null; then
        log_debug "Successfully granted: $permission"
        return 0
    else
        log_error "Failed to grant permission: $permission"
        return 1
    fi
}

# Grant app-specific permissions
grant_app_permissions() {
    local app_name="$1"
    
    log_debug "Processing permissions for app: $app_name"
    
    # Get package name using existing function
    local apk_info
    if ! apk_info=$(get_apk_info "$app_name"); then
        log_warn "Cannot find package info for app: $app_name"
        return 1
    fi
    
    local package_name
    package_name=$(echo "$apk_info" | cut -d'|' -f3)
    
    # Check if app is installed using existing function
    if ! is_app_installed "$package_name"; then
        log_warn "App not installed, skipping permissions: $app_name"
        return 0
    fi
    
    log_info "Granting permissions for: $app_name ($package_name)"
    
    # Grant permissions based on app type
    case "$app_name" in
        "simple-sms-messenger"|"dialer")
            yq eval '.permissions.sms[]' "$CONFIG_FILE" | while read -r perm; do
                [ -n "$perm" ] && grant_permission "$package_name" "$perm"
            done
            ;;
        "contacts"|"simple-contacts-pro")
            yq eval '.permissions.contacts[]' "$CONFIG_FILE" | while read -r perm; do
                [ -n "$perm" ] && grant_permission "$package_name" "$perm"
            done
            ;;
        "camera"|"simple-camera")
            yq eval '.permissions.camera[]' "$CONFIG_FILE" | while read -r perm; do
                [ -n "$perm" ] && grant_permission "$package_name" "$perm"
            done
            ;;
        *)
            # Storage permissions for all other apps
            yq eval '.permissions.storage[]' "$CONFIG_FILE" | while read -r perm; do
                [ -n "$perm" ] && grant_permission "$package_name" "$perm"
            done
            ;;
    esac
}

# Grant permissions for all apps
grant_all_permissions() {
    log_info "Starting permission granting process..."
    
    # Use existing function to get app list
    local app_list
    app_list=$(read_app_list)
    
    # Process each app
    while IFS= read -r app_name; do
        [ -z "$app_name" ] && continue
        grant_app_permissions "$app_name"
    done <<< "$app_list"
    
    log_info "Permission granting completed!"
}

# Permission-specific main function
permission_main() {
    log_info "Starting Android World permission management..."
    
    # Use existing validation functions
    check_dependencies
    detect_adb_device
    validate_adb_connection
    
    # Grant permissions
    grant_all_permissions
}

# Run permission main function
permission_main "$@"