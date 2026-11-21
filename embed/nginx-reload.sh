#!/bin/sh
# Reloads nginx when admin-ui writes the fifo; same container, so nginx stays pid 1.
[ -p /signals/nginx ] || exit 0

# 3<> keeps a reader and a writer open, so no write is ever lost or blocked.
(
  exec 3<> /signals/nginx
  while read -r _ <&3; do
    nginx -s reload -c /tmp/nginx.conf
  done
) &
