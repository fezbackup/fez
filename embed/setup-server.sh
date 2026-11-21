#!/bin/bash
#
# fez server-side setup.
# Called over ssh by install.sh with HOST_ADDR, TLS_PORT, SHARE and MULTIUSER set.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Only attempt install dependencies that are missing.
MISSING=""
command -v docker > /dev/null 2>&1 || MISSING="$MISSING docker.io"
docker compose version > /dev/null 2>&1 || MISSING="$MISSING docker-compose-v2"
command -v openssl > /dev/null 2>&1 || MISSING="$MISSING openssl"

if [ -n "$MISSING" ]; then
  echo "--- installing packages:$MISSING"
  apt-get update -qq
  apt-get install -y -qq $MISSING > /dev/null
else
  echo "--- docker and openssl are already installed"
fi

# Only touch the service if we are the ones who installed Docker.
case "$MISSING" in
  *docker.io*) systemctl enable --now docker > /dev/null 2>&1 || true ;;
esac

# Fail early with a clear reason if deps missing
need() { echo "$1" >&2; exit 1; }
command -v docker > /dev/null 2>&1 || need "docker is not installed; install it and re-run"
docker compose version > /dev/null 2>&1 || need "the docker compose plugin is missing: apt-get install docker-compose-v2"
docker info > /dev/null 2>&1 || need "docker is installed but not usable; is the daemon running?"
command -v openssl > /dev/null 2>&1 || need "openssl is missing: apt-get install openssl"

# Create global directories and top-level configs.
mkdir -p /etc/fez /tm
# Root only. Containers reach what they need through named bind mounts, which
# docker resolves as root, so nothing inside has to traverse this.
chmod 700 /etc/fez
mkdir -p /etc/fez/users
chmod 700 /etc/fez/users
# admin-certs.pem is only populated with --multiuser, but it has to exist or
# docker would create a directory in its place at the mount point.
touch /etc/fez/client-certs.pem /etc/fez/admin-certs.pem /etc/fez/install.sh
# Pending invitations, written by admin-ui and read by enroll-queue as nobody.
[ -s /etc/fez/enrollments.json ] || echo '[]' > /etc/fez/enrollments.json
chown root:65534 /etc/fez/enrollments.json
chmod 640 /etc/fez/enrollments.json
chmod 644 /etc/fez/client-certs.pem /etc/fez/admin-certs.pem /etc/fez/install.sh
if [ "${MULTIUSER:-0}" = "1" ] && [ ! -s /etc/fez/admin-certs.pem ]; then
  # First certificate in the bundle, which is the Mac that set this server up.
  awk '/-----BEGIN CERTIFICATE-----/{n++} n==1 {print} /-----END CERTIFICATE-----/{if (n==1) exit}' \
    /etc/fez/client-certs.pem > /etc/fez/admin-certs.pem
  chmod 644 /etc/fez/admin-certs.pem
fi

# Regenerate a pre-CA:TRUE cert too: macOS clients can't verify those at all.
if [ ! -f /etc/fez/server-cert.pem ]; then
  echo "--- generating server certificate"
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/fez/server-key.pem
  openssl req -new -x509 -key /etc/fez/server-key.pem \
    -out /etc/fez/server-cert.pem -days 3650 -subj "/CN=localhost" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "subjectAltName=DNS:localhost" \
    -addext "subjectKeyIdentifier=hash"
  chmod 644 /etc/fez/server-cert.pem
else
  echo "--- keeping existing server certificate"
fi

# nginx runs as nobody, so the key must be readable by that uid and nobody
# else. 65534 is nobody inside the container; the name on the host may differ.
# Every run, not just when the certificate is generated, or an upgrade leaves
# the old root-owned key behind and nginx cannot start.
chown 65534:65534 /etc/fez/server-key.pem
chmod 400 /etc/fez/server-key.pem

echo "--- writing nginx configuration"
if [ "${MULTIUSER:-0}" = "1" ]; then
  cat > /etc/fez/nginx.conf.template <<'NGINX'
@@EMBED:nginx-multiuser.conf@@
NGINX
else
  cat > /etc/fez/nginx.conf.template <<'NGINX'
@@EMBED:nginx.conf@@
NGINX
fi

if [ "${MULTIUSER:-0}" = "1" ]; then
  echo "--- installing the enrollment and admin services"
  cat > /etc/fez/enroll-queue.js <<'ENROLLQUEUEJS'
@@EMBED:enroll-queue.js@@
ENROLLQUEUEJS
  cat > /etc/fez/admin-ui.js <<'ADMINUIJS'
@@EMBED:admin-ui.js@@
ADMINUIJS

  chmod 644 /etc/fez/enroll-queue.js /etc/fez/admin-ui.js
fi

echo "--- setting up share '$SHARE'"
SHARE_CREATED=0
if [ ! -f "/etc/fez/users/$SHARE.conf" ]; then
  # Its own uid, so permissions actually separate the shares.
  UID_NEXT=1000
  for f in /etc/fez/users/*.conf; do
    [ -e "$f" ] || continue
    used="$(sed -n 's/^TM_UID=//p' "$f" | head -1)"
    [ -n "$used" ] && [ "$used" -ge "$UID_NEXT" ] && UID_NEXT=$((used + 1))
  done

  # Empty VOLUME_SIZE_LIMIT means no quota.
  cat > "/etc/fez/users/$SHARE.conf" <<CONFFILE
TM_USERNAME=$SHARE
TM_GROUPNAME=$SHARE
PASSWORD=$(openssl rand -hex 8)
SHARE_NAME=$SHARE
TM_UID=$UID_NEXT
TM_GID=$UID_NEXT
VOLUME_SIZE_LIMIT=
CONFFILE
  chmod 600 "/etc/fez/users/$SHARE.conf"

  mkdir -p "/tm/$SHARE"
  chown "$UID_NEXT:$UID_NEXT" "/tm/$SHARE"
  chmod 700 "/tm/$SHARE"
  SHARE_CREATED=1
fi

# Samba's own smb.conf sends its log to a file, so override the launcher.
cat > /etc/fez/smbd-run <<'SMBDRUN'
@@EMBED:smbd-run@@
SMBDRUN
chmod 755 /etc/fez/smbd-run

cat > /etc/fez/nginx-reload.sh <<'RELOADNGINX'
@@EMBED:nginx-reload.sh@@
RELOADNGINX
cat > /etc/fez/samba-reload <<'RELOADSAMBA'
@@EMBED:samba-reload@@
RELOADSAMBA
chmod 755 /etc/fez/nginx-reload.sh /etc/fez/samba-reload

# Fifos, not files: a write blocks until the watcher reads it, and a write with
# nothing listening fails at once instead of being lost.
mkdir -p /etc/fez/signals
chmod 700 /etc/fez/signals
[ -p /etc/fez/signals/nginx ] || { rm -f /etc/fez/signals/nginx; mkfifo /etc/fez/signals/nginx; }
[ -p /etc/fez/signals/samba ] || { rm -f /etc/fez/signals/samba; mkfifo /etc/fez/signals/samba; }
# nginx reads as nobody and needs rw for the 3<> open; root writes as other.
chown 65534:65534 /etc/fez/signals/nginx
chmod 622 /etc/fez/signals/nginx
chown root:root /etc/fez/signals/samba
chmod 600 /etc/fez/signals/samba

# s6 leaves a service alone if its directory holds a file called "down", so an
# empty file mounted into each one is enough to keep it from ever starting.
: > /etc/fez/s6-down
chmod 644 /etc/fez/s6-down

echo "--- writing docker-compose.yml"

# The shared pid namespace is only there so admin-ui can signal nginx and
# samba. A single user server has no admin-ui, so it does without both the
# namespace and the container holding it, and runs two containers as before.
TLS_DEPENDS="      - timemachine"

cat > /etc/fez/docker-compose.yml <<COMPOSE
@@EMBED:docker-compose.yml@@
COMPOSE

if [ "${MULTIUSER:-0}" = "1" ]; then
  cat >> /etc/fez/docker-compose.yml <<COMPOSE
@@EMBED:docker-compose-multiuser.yml@@
COMPOSE
  TLS_DEPENDS="$TLS_DEPENDS
      - enroll-queue
      - admin-ui"
fi

cat >> /etc/fez/docker-compose.yml <<COMPOSE
@@EMBED:docker-compose-tls.yml@@
COMPOSE

cat >> /etc/fez/docker-compose.yml <<'COMPOSE'
networks:
  smb:
  control:
COMPOSE
chmod 600 /etc/fez/docker-compose.yml

echo "--- starting containers"
cd /etc/fez
docker compose up -d

# SIGHUP to not drop existing connections.
docker compose kill -s HUP tls > /dev/null 2>&1 || true

# Samba only builds smb.conf when the container boots, so bounce just in case.
if [ "$SHARE_CREATED" = "1" ]; then
  echo "--- restarting Samba to pick up '$SHARE'"
  docker compose restart timemachine > /dev/null 2>&1 || true
  # Wait a beat to let samba bind
  sleep 3
fi

echo "--- server ready"
