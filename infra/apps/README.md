# Android World App Installation System

This directory contains scripts and configuration for automatically downloading, installing, and configuring Android apps required by android_world testing.

## Directory Structure

```
infra/apps/
├── install-apps.sh         # Main app installation script
├── grant-permissions.sh    # Permission management script  
├── app-mapping.yaml        # App name to APK file mapping
├── apks/                   # Downloaded APK files cache
└── README.md              # This file
```

## Scripts

### [`install-apps.sh`](install-apps.sh)
**Purpose**: Downloads and installs Android APK files based on device configuration

**Configuration Variables** (edit at top of file):
- `CONFIG_FILE`: YAML config file path (default: core-apps-config.yaml)
- `ADB_DEVICE`: Target device (auto-detect if empty)
- `APK_CACHE_DIR`: APK download cache directory
- `SKIP_EXISTING`: Skip already downloaded APKs
- `FORCE_REINSTALL`: Force reinstall even if app present

**Usage**:
```bash
# Install apps from core config
./infra/apps/install-apps.sh

# Use different config
CONFIG_FILE="infra/genymotion/device-configs/full-suite-config.yaml" ./infra/apps/install-apps.sh

# Specify ADB device
ADB_DEVICE="192.168.1.100:5555" ./infra/apps/install-apps.sh
```

### [`grant-permissions.sh`](grant-permissions.sh)
**Purpose**: Automatically grants permissions to installed apps

**Configuration Variables**:
- `CONFIG_FILE`: YAML config file path
- `ADB_DEVICE`: Target device (auto-detect if empty)
- `FORCE_GRANT`: Grant permissions even if already granted

**Usage**:
```bash
# Grant permissions to installed apps
./infra/apps/grant-permissions.sh
```

## Configuration Files

### [`app-mapping.yaml`](app-mapping.yaml)
Maps android_world app names to actual APK files and download sources.

**Structure**:
```yaml
apps:
  app-name:
    apk_file: "filename.apk"
    package_name: "com.example.app"
    download_url: "https://example.com/app.apk"
    source: "f-droid|github|android_world"
    description: "App description"
```

**Supported Sources**:
- **F-Droid**: Open source Android apps
- **GitHub**: Direct APK releases
- **android_world**: Custom apps (need to be built)
- **system**: Pre-installed system apps

## Workflow

The typical app installation workflow:

1. **Read Configuration**: Parse device config YAML for app list
2. **Download APKs**: Download missing APK files to cache
3. **Install Apps**: Install APKs via ADB to connected device
4. **Grant Permissions**: Auto-grant required permissions
5. **Verify Installation**: Confirm apps are installed and functional

## App Categories

### Core Apps (from [`core-apps-config.yaml`](../genymotion/device-configs/core-apps-config.yaml))
- `simple-sms-messenger`: SMS functionality
- `contacts`: Contact management
- `simple-calendar-pro`: Calendar operations
- `markor`: Note-taking and file editing
- `camera`: Camera functionality
- `settings`: System settings (pre-installed)

### Full Suite Apps (from [`full-suite-config.yaml`](../genymotion/device-configs/full-suite-config.yaml))
Additional apps for comprehensive testing:
- Media: `audio-recorder`, `simple-gallery-pro`, `retro-music`, `vlc`
- Creative: `simple-draw-pro`
- Utility: `files`, `chrome`, `clock`, `osmand`
- Custom: `recipe-app`, `expense-app`, `miniwob-app`

## Permission Management

Permissions are automatically granted based on app categories:

- **SMS Apps**: `SEND_SMS`, `READ_SMS`, `RECEIVE_SMS`
- **Contact Apps**: `READ_CONTACTS`, `WRITE_CONTACTS`
- **Camera Apps**: `CAMERA`, `RECORD_AUDIO`
- **All Apps**: `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`

## Troubleshooting

### Common Issues

**No ADB devices found**
```bash
# Check device connection
adb devices

# Connect to Genymotion device
adb connect 192.168.1.100:5555
```

**APK download failures**
- Check internet connection
- Verify download URLs in `app-mapping.yaml`
- Some F-Droid URLs may need updating

**Permission grant failures**
- Ensure app is installed first
- Some permissions may require user interaction
- Check Android version compatibility

**Missing tools**
```bash
# Install required tools
brew install yq jq wget  # macOS
sudo apt install yq jq wget  # Ubuntu
```

## Adding New Apps

To add a new app to android_world:

1. **Add to device config** (`device-configs/*.yaml`):
```yaml
apps:
  - new-app-name
```

2. **Add to app mapping** (`app-mapping.yaml`):
```yaml
apps:
  new-app-name:
    apk_file: "new-app.apk"
    package_name: "com.example.newapp"
    download_url: "https://example.com/new-app.apk"
    source: "f-droid"
    description: "New app description"
```

3. **Add permissions** (if needed) to device config:
```yaml
permissions:
  new_category:
    - android.permission.NEW_PERMISSION
```

## Integration

This app installation system integrates with:

- **[Genymotion Provisioning](../genymotion/)**: Device creation and configuration
- **[Android World](../../external/android_world/)**: Task evaluation framework
- **[Docker Container](../../Dockerfile)**: Containerized execution environment

## Metrics

The installation scripts track:
- **Successfully Installed**: Apps installed without errors
- **Skipped**: Apps already installed or cached
- **Failed**: Apps that failed to download/install

Check `/tmp/android-app-install.log` for detailed logs.