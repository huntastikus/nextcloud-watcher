# nextcloud-watcher

A Docker container that monitors multiple directories for file changes and automatically triggers Nextcloud file scans to keep your Nextcloud instance in sync with external changes (e.g., SMB shares, NFS mounts, local directories).

## Features

- **Multi-path monitoring**: Monitor multiple directories simultaneously
- **Path correlation**: Proper mapping between container paths and Nextcloud paths
- **Real-time file monitoring** using inotify
- **Selective scanning**: Only scan changed directories, not entire filesystem
- **Configurable via environment variables**
- **Comprehensive logging** with timestamps and debug levels
- **Container health validation** and health checks
- **Backward compatibility** with v1 configuration

## Quick Start

### Complete Docker Run Example

This example shows **ALL** available options (remove what you don't need):

```bash
docker run -d \
  --name nextcloud-watcher \
  --restart unless-stopped \
  \
  # ═══ REQUIRED VOLUMES ═══
  # Docker socket - MANDATORY for container communication
  -v /var/run/docker.sock:/var/run/docker.sock \
  # Mount directories to monitor
  -v /mnt/photos:/watched/photos \
  -v /mnt/documents:/watched/docs \
  \
  # ═══ REQUIRED ENVIRONMENT VARIABLES ═══
  # Space-separated lists (must have same number of items)
  -e MONITOR_PATHS="/watched/photos /watched/docs" \
  -e NC_SCAN_PATHS="/alice/files/Photos /shared/Documents" \
  \
  # ═══ OPTIONAL ENVIRONMENT VARIABLES ═══
  # (showing defaults - omit lines you don't need to change)
  -e NEXTCLOUD_CONTAINER="nextcloud" \
  -e SCAN_USER="www-data" \
  -e LOG_LEVEL="INFO" \
  -e INOTIFY_EVENTS="create,delete,modify,move" \
  \
  # ═══ LEGACY (v1) VARIABLES ═══
  # Only use these if migrating from single-path setup
  #-e WATCH_DIR="/watched/single" \
  #-e SCAN_PATHS="/alice/files/SingleFolder" \
  \
  nextcloud-watcher:latest
```

**Security Note**: This container does **NOT** require `--privileged` mode. Only the Docker socket mount is needed.

### Minimal Example

For quick testing (monitors one directory, scans from Nextcloud root):

```bash
docker run -d \
  --name nextcloud-watcher \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /mnt/photos:/watched \
  -e MONITOR_PATHS="/watched" \
  nextcloud-watcher
```

## Configuration

### Environment Variables

#### Required Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MONITOR_PATHS` | *none* | **Required**: Space-separated list of container paths to monitor for file changes |
| `NC_SCAN_PATHS` | *none* | **Required**: Space-separated list of corresponding Nextcloud paths to scan |

**Important**: `MONITOR_PATHS` and `NC_SCAN_PATHS` must contain the same number of space-separated items and are matched positionally (1-to-1).

**Exception**: If you specify only one `MONITOR_PATHS` and omit `NC_SCAN_PATHS`, it defaults to scanning from Nextcloud root (`/`) - useful for quick testing.

#### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NEXTCLOUD_CONTAINER` | `nextcloud` | Name/ID of the Nextcloud Docker container to execute commands in |
| `SCAN_USER` | `www-data` | Linux user inside the Nextcloud container that owns the data files |
| `LOG_LEVEL` | `INFO` | Logging verbosity: `INFO` or `DEBUG` (case-insensitive) |
| `INOTIFY_EVENTS` | `create,delete,modify,move` | Comma-separated list of file events to monitor |

#### Legacy Variables (v1 Compatibility)

| Variable | Default | Description |
|----------|---------|-------------|
| `WATCH_DIR` | *none* | Single directory to monitor (automatically maps to `MONITOR_PATHS`) |
| `SCAN_PATHS` | *none* | Single scan path (automatically maps to `NC_SCAN_PATHS`) |

**Migration**: If you used v1, keep your existing `WATCH_DIR`/`SCAN_PATHS` - they still work! The new variables are only needed for multi-path setups.

## Usage Examples

### Defaults Reference

If an optional variable is omitted, the default value is used automatically. Here are all the defaults:

- `NEXTCLOUD_CONTAINER=nextcloud`
- `SCAN_USER=www-data`  
- `LOG_LEVEL=INFO`
- `INOTIFY_EVENTS=create,delete,modify,move`

**Minimum viable configuration** consists of:
- Docker socket mount (`-v /var/run/docker.sock:/var/run/docker.sock`)
- One or more volume mounts for directories to monitor
- `MONITOR_PATHS` environment variable

### Multi-Path Docker Run

```bash
docker run -d \
  --name nextcloud-watcher \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /mnt/smb/photos:/container/photos \
  -v /mnt/smb/videos:/container/videos \
  -v /mnt/local/docs:/container/documents \
  -e MONITOR_PATHS="/container/photos /container/videos /container/documents" \
  -e NC_SCAN_PATHS="/user1/files/Photos /user2/files/Videos /shared/Documents" \
  -e NEXTCLOUD_CONTAINER=my-nextcloud \
  -e LOG_LEVEL=DEBUG \
  nextcloud-watcher
```

### Docker Compose (Recommended)

```yaml
version: '3.8'

services:
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    volumes:
      - nextcloud_data:/var/www/html
      - /mnt/smb/photos:/var/www/html/data/user1/files/Photos
      - /mnt/smb/videos:/var/www/html/data/user2/files/Videos
    # ... your nextcloud configuration

  nextcloud-watcher:
    image: nextcloud-watcher:latest
    container_name: nextcloud-watcher
    depends_on:
      - nextcloud
    volumes:
      # REQUIRED: Docker socket for container communication
      - /var/run/docker.sock:/var/run/docker.sock
      # Mount the same external directories
      - /mnt/smb/photos:/watched/photos
      - /mnt/smb/videos:/watched/videos
    environment:
      - MONITOR_PATHS=/watched/photos /watched/videos
      - NC_SCAN_PATHS=/user1/files/Photos /user2/files/Videos
      - NEXTCLOUD_CONTAINER=nextcloud
      - SCAN_USER=www-data
      - LOG_LEVEL=INFO
    restart: unless-stopped

volumes:
  nextcloud_data:
```

## Volume Mounts

### Required Volumes

1. **Docker Socket** (MANDATORY)
   ```
   -v /var/run/docker.sock:/var/run/docker.sock
   ```
   **Required** to execute commands in the Nextcloud container. **Do not** use `--privileged` mode - only this socket mount is needed.

2. **Monitored Directories**
   Mount your external directories (SMB shares, NFS mounts, etc.) into the container:
   ```
   -v /host/path:/container/path
   ```

### Privilege Requirements

This container **does NOT require**:
- `--privileged` mode
- `--cap-add` capabilities  
- Special user permissions
- Root access

**Only requirement**: Read/write access to `/var/run/docker.sock` (usually granted by default).

### Path Correlation Examples

The key to proper operation is correctly mapping container paths to Nextcloud paths:

```bash
# Example: SMB share mounted on host
Host: /mnt/smb/user_photos
Container mount: -v /mnt/smb/user_photos:/watched/photos
MONITOR_PATHS: /watched/photos
NC_SCAN_PATHS: /user1/files/Photos

# This means:
# - Watch for changes in /watched/photos (inside container)
# - When changes occur, scan /user1/files/Photos (inside Nextcloud)
```

## Path Configuration Guide

### Understanding Nextcloud Paths

Nextcloud paths for `occ files:scan --path` follow this pattern:
- `/USERNAME/files/FOLDER` - User's personal files
- `/shared/FOLDER` - Shared files (if using shared folders)

Examples:
- `/alice/files/Documents` - Alice's Documents folder
- `/bob/files/Photos/2024` - Bob's 2024 Photos subfolder
- `/shared/CompanyFiles` - Shared company files

### Common Configurations

#### Single User, Multiple Folders
```bash
MONITOR_PATHS="/watched/docs /watched/photos /watched/videos"
NC_SCAN_PATHS="/alice/files/Documents /alice/files/Photos /alice/files/Videos"
```

#### Multiple Users
```bash
MONITOR_PATHS="/watched/alice-docs /watched/bob-photos"
NC_SCAN_PATHS="/alice/files/Documents /bob/files/Photos"
```

#### Mixed Personal and Shared
```bash
MONITOR_PATHS="/watched/personal /watched/shared"
NC_SCAN_PATHS="/alice/files/Personal /shared/CompanyFiles"
```

## Logging

The container provides structured logging with timestamps:

### Log Levels
- `INFO` (default): Startup config, file changes, scan results
- `DEBUG`: Detailed path mapping, command execution, troubleshooting info

### Viewing Logs
```bash
docker logs nextcloud-watcher
docker logs -f nextcloud-watcher  # Follow mode
```

### Sample Log Output
```
[2024-01-15 10:30:15] [INFO] ✓ Validation complete - starting file monitoring
[2024-01-15 10:30:15] [INFO] Configuration:
[2024-01-15 10:30:15] [INFO]   Nextcloud container: nextcloud
[2024-01-15 10:30:15] [INFO] Path mappings:
[2024-01-15 10:30:15] [INFO]   [0] Monitor: '/watched/photos' → Scan: '/user1/files/Photos'
[2024-01-15 10:30:20] [INFO] File change detected: IMG_001.jpg
[2024-01-15 10:30:20] [INFO] ✓ Scan completed successfully for: /user1/files/Photos
```

## Troubleshooting

### Common Issues

#### 1. Container exits with "Docker socket not mounted"
**Solution**: Add the required Docker socket mount:
```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

#### 2. Container exits with "MONITOR_PATHS and NC_SCAN_PATHS must have the same number of items"
**Solution**: Ensure both variables have matching numbers of paths:
```bash
# ✗ Wrong - 2 monitor paths, 1 scan path
MONITOR_PATHS="/watched/a /watched/b"
NC_SCAN_PATHS="/user1/files/A"

# ✓ Correct - 2 monitor paths, 2 scan paths
MONITOR_PATHS="/watched/a /watched/b"
NC_SCAN_PATHS="/user1/files/A /user1/files/B"
```

#### 3. Container exits with "Monitor path does not exist"
**Solution**: Verify your volume mounts and paths:
```bash
# Check that the host path exists
ls -la /mnt/smb/photos

# Verify container mount point matches MONITOR_PATHS
docker run --rm -v /mnt/smb/photos:/watched/photos alpine ls -la /watched/photos
```

#### 4. Container exits with "Nextcloud container is not running"
**Solution**: 
- Verify container name: `docker ps`
- Set correct `NEXTCLOUD_CONTAINER` environment variable

#### 5. "Scan failed" errors
**Solutions**:
- Check Nextcloud container logs: `docker logs nextcloud`
- Verify `SCAN_USER` has proper permissions
- Ensure Nextcloud paths are correct (use `docker exec nextcloud php occ files:scan --help`)

### Debug Mode

Enable debug logging for detailed troubleshooting:
```bash
-e LOG_LEVEL=DEBUG
```

This shows:
- Path mapping details
- Exact `occ` commands being executed
- File change event details

### Health Checks

The container includes a health check that verifies `inotifywait` is running:
```bash
docker ps  # Shows health status
docker inspect nextcloud-watcher  # Detailed health info
```

## Migration from v1

If you're upgrading from the original single-path version:

### Option 1: Use Legacy Variables (Easiest)
Keep your existing configuration - it still works:
```bash
# v1 configuration still supported
-e WATCH_DIR=/watched
-e SCAN_PATHS="/user1/files/Documents"
```

### Option 2: Migrate to Multi-Path (Recommended)
Convert to the new multi-path format:
```bash
# Old v1 way:
-e WATCH_DIR=/watched
-e SCAN_PATHS="/user1/files/Documents"

# New v2 way:
-e MONITOR_PATHS="/watched"
-e NC_SCAN_PATHS="/user1/files/Documents"
```

## Security Considerations

1. **Docker Socket Access**: The container requires Docker socket access to execute commands in the Nextcloud container. This is necessary but grants significant privileges.

2. **File Permissions**: Ensure the `SCAN_USER` (default: www-data) has appropriate permissions in the Nextcloud container.

3. **Network Isolation**: Consider running in a dedicated Docker network for better isolation.

## Building from Source

```bash
git clone https://github.com/huntastikus/nextcloud-watcher.git
cd nextcloud-watcher
docker build -t nextcloud-watcher:latest .
```

## Performance Considerations

- **Selective Scanning**: The watcher only scans directories that actually changed, not the entire filesystem
- **Path Optimization**: Use specific paths rather than broad scans when possible
- **Multiple Paths**: Monitor multiple specific directories rather than one large parent directory
- **Resource Usage**: Each monitored path uses minimal resources; you can monitor dozens of paths efficiently

## License

MIT License - see repository for details.
