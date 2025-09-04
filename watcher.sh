#!/bin/bash

# Folder inside the container to watch
WATCH_DIR="/watched"

# Name of your Nextcloud container
NEXTCLOUD_CONTAINER="nextcloud"

echo "Starting watcher on $WATCH_DIR ..."

inotifywait -m -r -e create -e delete -e modify -e move "$WATCH_DIR" |
while read -r directory events filename; do
    echo "Change detected: $directory$filename [$events]"
    docker exec -u www-data "$NEXTCLOUD_CONTAINER" php occ files:scan --all
done
