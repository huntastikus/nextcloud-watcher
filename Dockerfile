FROM alpine:latest

# Labels
LABEL maintainer="nextcloud-watcher"
LABEL description="A multi-path file watcher that triggers Nextcloud file scans when changes are detected"
LABEL version="2.0"

# Install required packages
# - inotify-tools: for file system event monitoring
# - bash: for advanced script features
# - docker-cli: for executing commands in Nextcloud container
# - coreutils: for dirname, basename and other path utilities
RUN apk add --no-cache inotify-tools bash docker-cli coreutils

# Environment variables with defaults
# Multi-path configuration (new approach)
ENV MONITOR_PATHS=""
ENV NC_SCAN_PATHS=""

# Legacy single-path support (backward compatibility)
ENV WATCH_DIR=""
ENV SCAN_PATHS=""

# Container execution configuration
ENV NEXTCLOUD_CONTAINER=nextcloud
ENV SCAN_USER=www-data
ENV LOG_LEVEL=INFO

# Copy in the watcher script
COPY watcher.sh /usr/local/bin/watcher.sh
RUN chmod +x /usr/local/bin/watcher.sh

# Create default watch directory for backward compatibility
RUN mkdir -p /watched

# Health check to ensure inotifywait is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pidof inotifywait || exit 1

CMD ["/usr/local/bin/watcher.sh"]
