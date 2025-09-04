FROM alpine:3.20

# Install inotify-tools and bash
RUN apk add --no-cache inotify-tools bash docker-cli

# Copy in the watcher script
COPY watcher.sh /usr/local/bin/watcher.sh
RUN chmod +x /usr/local/bin/watcher.sh

CMD ["/usr/local/bin/watcher.sh"]
