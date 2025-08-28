# Android World Container
# Packages android_world framework with Genymotion Cloud integration

FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ===== SYSTEM DEPENDENCIES =====

# Install base system packages
RUN apt-get update && apt-get install -y \
    # Core utilities
    curl \
    wget \
    unzip \
    git \
    build-essential \
    # Python and pip
    python3 \
    python3-pip \
    python3-venv \
    # Android development tools
    openjdk-17-jdk \
    android-tools-adb \
    # Network tools
    net-tools \
    iputils-ping \
    socat \
    # Process management
    supervisor \
    # Clean up
    && rm -rf /var/lib/apt/lists/*

# ===== ANDROID SDK TOOLS =====

# Set up Android SDK environment
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=${PATH}:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/tools/bin

# Download and install Android SDK command line tools
RUN mkdir -p ${ANDROID_HOME} && \
    cd ${ANDROID_HOME} && \
    wget --no-check-certificate https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O tools.zip && \
    unzip tools.zip && \
    rm tools.zip && \
    echo "=== DEBUG: What was extracted? ===" && \
    ls -la && \
    echo "=== DEBUG: Finding cmdline-tools ===" && \
    find . -name "cmdline-tools" -type d && \
    echo "=== DEBUG: Current structure ===" && \
    ls -la cmdline-tools/ 2>/dev/null || echo "No cmdline-tools directory found" && \
    echo "=== DEBUG: Setting up directory structure ===" && \
    if [ -d "cmdline-tools" ]; then \
        mv cmdline-tools temp-cmdline-tools && \
        mkdir -p cmdline-tools/latest && \
        mv temp-cmdline-tools/* cmdline-tools/latest/ && \
        rmdir temp-cmdline-tools; \
    else \
        echo "No cmdline-tools directory found, checking for extracted files"; \
        ls -la; \
    fi && \
    echo "=== DEBUG: Final structure ===" && \
    ls -la cmdline-tools/latest/ 2>/dev/null || echo "Failed to create proper structure"

# Update PATH to include cmdline-tools
ENV PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin

# ===== YAML AND JSON TOOLS =====

# Install yq for YAML processing
RUN wget --no-check-certificate -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

# Install websocat for WebSocket-to-TCP bridging
RUN wget --no-check-certificate -qO /usr/local/bin/websocat https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl && \
    chmod +x /usr/local/bin/websocat

# Install jq for JSON processing
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*

# ===== PYTHON ENVIRONMENT =====

# Create Python virtual environment
RUN python3 -m venv /opt/android_world_venv
ENV PATH="/opt/android_world_venv/bin:$PATH"

# Upgrade pip and install common packages (bypass certificate verification)
RUN pip install --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org --upgrade pip setuptools wheel

# ===== ANDROID WORLD FRAMEWORK =====

# Create working directory
WORKDIR /app

# Copy android_world source code
COPY external/android_world/ ./android_world/

# Install android_world Python dependencies
RUN cd android_world && \
    pip install --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org -e . && \
    pip install --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org -r requirements.txt || echo "No requirements.txt found"

# Install additional Python packages commonly needed
RUN pip install --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org \
    # HTTP and API clients
    requests \
    httpx \
    # WebSocket support for ADB bridge
    websockets \
    # Image processing
    pillow \
    opencv-python-headless \
    # Data processing
    numpy \
    pandas \
    # Testing and automation
    pytest \
    selenium \
    # Utilities
    python-dotenv \
    pyyaml \
    # Genymotion Cloud CLI
    gmsaas

# ===== INFRASTRUCTURE SCRIPTS =====

# Copy our infrastructure components
COPY infra/ ./infra/

# Make scripts executable
RUN chmod +x infra/genymotion/provision-emulator.sh && \
    chmod +x infra/apps/install-apps.sh && \
    chmod +x infra/apps/grant-permissions.sh

# ===== CONFIGURATION =====

# Environment variables for android_world
ENV ANDROID_WORLD_HOME=/app/android_world
ENV PYTHONPATH="/app/android_world:/opt/android_world_venv/lib/python3.11/site-packages"

# ADB server configuration
ENV ADB_SERVER_SOCKET=tcp:5037

# Default configuration paths
ENV CONFIG_FILE="/app/infra/genymotion/device-configs/core-apps-config.yaml"
ENV APP_MAPPING_FILE="/app/infra/apps/app-mapping.yaml"

# Create directories for logs and cache
RUN mkdir -p /app/logs /app/cache /app/results

# ===== RUNTIME SETUP =====

# Copy entrypoint script
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD adb version || exit 1

# Expose ADB port for external connections
EXPOSE 5037

# Labels for container metadata
LABEL maintainer="android_world_deployment" \
      version="1.0" \
      description="Android World testing framework with Genymotion Cloud integration" \
      android_sdk_version="34" \
      python_version="3.10"

# Set default entrypoint
ENTRYPOINT ["/app/run.sh"]

# Default command (can be overridden)
CMD ["--help"]