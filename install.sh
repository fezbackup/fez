#!/usr/bin/env bash
#
# fez installer script. Meant to run on a mac with ssh access to a server you
# wish to setup; to set up on the server by itself, use --local.
#

set -euo pipefail

FEZ_VERSION="1.0.0"

CONF_DIR="/etc/fez"
LOOPBACK_IP="127.0.0.2"
LOCAL_PORT="445"
REMOTE_TLS_PORT="443"
SERVER_NAME="fez.internal"
PUBLIC_NAME="public.fez.internal"
ADMIN_NAME="admin.fez.internal"
SHARE_NAME="timemachine"
SMB_USER="timemachine"
REMOTE_DATA_DIR="/tm"
REMOTE_CONF_DIR="/etc/fez"
LAUNCHD_DIR="/Library/LaunchDaemons"
TUNNEL_LABEL="com.fezbackup.tunnel"
LOOPBACK_LABEL="com.fezbackup.loopback"
ADMIN_LABEL="com.fezbackup.admin"
ADMIN_LOCAL_PORT="8443"
LOG_FILE="/var/log/fez.log"

# Save some mb, avoid backing up stuff no one wants.
TM_EXCLUDE="/private/var/db/diagnostics
            /private/var/db/uuidtext
            /private/var/db/CoreDuet
            /private/var/db/DuetActivityScheduler
            /private/var/log"
OPENSSL="/usr/bin/openssl"

SSH_HOST=""
SSH_PORT="22"
SSH_USER="root"
NO_AUTOMOUNT="0"
NO_SSH="0"
RECOVERY="0"
MULTIUSER="0"
ADMIN="0"
SERVER_ONLY="0"
LOCAL="0"
UNINSTALL="0"
ENROLL_CODE=""

WORK_DIR=""
SSH_CTL=""
CLIENT_CERT_EXPORT=""
ENROLLED_PASSWORD=""

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
  BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RED=$(printf '\033[31m')
  YELLOW=$(printf '\033[33m'); GREEN=$(printf '\033[32m'); RESET=$(printf '\033[0m')
else
  BOLD=""; DIM=""; RED=""; YELLOW=""; GREEN=""; RESET=""
fi

step() { printf '\n%s==>%s %s%s\n' "$GREEN" "$RESET" "$BOLD" "$1$RESET"; }
say()  { printf '    %s\n' "$1"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '%s!!%s  %s\n' "$YELLOW" "$RESET" "$1" >&2; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

usage() {
  cat <<USAGE
fez installer ${FEZ_VERSION}

Usage: install.sh [HOST] [options]

Options:
  -h, --host HOST     SSH hostname or IP of your VPS
      --server HOST   Same thing, for when you are joining someone else's
                      server and never log in to it
  -p, --port PORT     SSH port (default: 22)
  -u, --user USER     SSH user (default: root)
      --tls-port PORT The port the tunnel listens on (default: 443)
      --share NAME    Name of the share on the server (default: timemachine)
      --enroll CODE   Join a server you have an invitation code for. No SSH
                      access needed: this Mac hands over its certificate and
                      gets its share name and password back. Combine with
                      --recovery to get back into a backup after a Mac dies,
                      once the admin has issued you a new code.
      --multiuser     Server side option. Enables admin UI and enroll endpoint
                      service, so you can add people from a browser instead of
                      over SSH. The Mac that installs this is the only one that
                      can reach the admin page.
      --no-automount  Do not mount the share when finished
      --admin         Make this Mac an administrator: adds its certificate to
                      the server's admin list and switches the admin page on.
                      Implies --multiuser, and needs SSH access to the server.
      --server-only   Update the server and nothing else: no certificate, no
                      tunnel, no mount, no sudo needed here. Pass --multiuser
                      as well if the server runs the admin page.
      --no-ssh        Set up this Mac only, without touching the server.
                      Use this when someone else runs the server: it prints a
                      certificate to hand them, and they add it for you.
      --local         Set up the server side on the machine you are running
                      this on, as root. No Mac, no ssh, no tunnel.
      --uninstall     Undo everything on this Mac: the tunnels, /etc/fez, the
                      loopback alias and the logs. Leaves the server, and the
                      backups on it, completely alone.
      --recovery      Set this mac up to read an existing backup rather than
                      to make new ones. Installs the tunnel and mounts the
                      share exactly as usual, then tells you how to open the
                      backup instead of how to turn Time Machine on. Combine
                      with --enroll or --no-ssh as normal.
      --help          Show this message

The server must be a Linux distro that you can SSH into. For non-Debian
based Linux, you must also install docker yourself first.
USAGE
}

cleanup() {
  local code=$?
  if [ -n "$SSH_CTL" ] && [ -S "$SSH_CTL" ]; then
    ssh -o ControlPath="$SSH_CTL" -O exit "$SSH_USER@$SSH_HOST" 2>/dev/null || true
  fi
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  exit $code
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------- arguments ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--host|--server) SSH_HOST="${2:-}"; shift 2 ;;
      -p|--port) SSH_PORT="${2:-}"; shift 2 ;;
      -u|--user) SSH_USER="${2:-}"; shift 2 ;;
      --no-automount) NO_AUTOMOUNT="1"; shift ;;
      --no-ssh) NO_SSH="1"; shift ;;
      --recovery) RECOVERY="1"; shift ;;
      --local) LOCAL="1"; shift ;;
      --uninstall) UNINSTALL="1"; shift ;;
      --multiuser) MULTIUSER="1"; shift ;;
      --admin) ADMIN="1"; MULTIUSER="1"; shift ;;
      --server-only) SERVER_ONLY="1"; shift ;;
      --enroll) ENROLL_CODE="${2:-}"; shift 2 ;;
      --share) SHARE_NAME="${2:-}"; shift 2 ;;
      --tls-port) REMOTE_TLS_PORT="${2:-}"; shift 2 ;;
      --help) usage; exit 0 ;;
      -*) die "unknown option: $1 (try --help)" ;;
      *) SSH_HOST="$1"; shift ;;
    esac
  done

  # Nothing below needs a server: uninstalling only touches this Mac.
  if [ "$UNINSTALL" = "1" ]; then
    return 0
  fi

  # Contradictory flags, before anything is asked for.
  if [ "$ADMIN" = "1" ]; then
    if [ "$LOCAL" = "1" ]; then
      die "--admin adds this Mac's certificate and --local has no Mac; switch the admin page on from the Mac you administer from"
    fi
    if [ "$NO_SSH" = "1" ] || [ -n "$ENROLL_CODE" ]; then
      die "--admin writes to the server's admin list, so it needs SSH access; it cannot be combined with --no-ssh or --enroll"
    fi
  fi

  if [ "$SERVER_ONLY" = "1" ]; then
    if [ "$LOCAL" = "1" ]; then
      die "--local already sets up the machine it runs on; --server-only works over ssh"
    fi
    if [ "$NO_SSH" = "1" ] || [ -n "$ENROLL_CODE" ]; then
      die "--server-only touches only the server, so it cannot be used with --no-ssh or --enroll"
    fi
    if [ "$ADMIN" = "1" ]; then
      die "--admin registers this mac's certificate, which --server-only skips; use --multiuser"
    fi
    if [ "$RECOVERY" = "1" ]; then
      die "--recovery only changes what is printed for a mac, and --server-only sets none up"
    fi
  fi

  if [ "$MULTIUSER" = "1" ] && { [ "$NO_SSH" = "1" ] || [ -n "$ENROLL_CODE" ]; }; then
    die "--multiuser sets up the server, so it cannot be used with --no-ssh or --enroll"
  fi

  if [ -z "$SSH_HOST" ]; then
    printf 'VPS hostname or IP address: '
    read -r SSH_HOST
  fi
  [ -n "$SSH_HOST" ] || die "no host given"

  case "$SSH_PORT" in
    ''|*[!0-9]*) die "port must be a number: $SSH_PORT" ;;
  esac
  case "$REMOTE_TLS_PORT" in
    ''|*[!0-9]*) die "tls port must be a number: $REMOTE_TLS_PORT" ;;
  esac

  if [ -n "$ENROLL_CODE" ]; then
    # An invitation means no account on the server, so nothing to ssh into.
    NO_SSH="1"
    case "$ENROLL_CODE" in
      *[!a-f0-9]*) die "that invitation code has characters it should not; it is 32 letters a-f and digits" ;;
    esac
    [ "${#ENROLL_CODE}" = "32" ] || die "that invitation code is ${#ENROLL_CODE} characters, it should be 32"
  fi

  # The share name is also a Unix username on the server.
  case "$SHARE_NAME" in
    [a-z0-9]*) ;;
    *) die "share name must start with a lowercase letter or digit: $SHARE_NAME" ;;
  esac
  case "$SHARE_NAME" in
    *[!a-z0-9-]*) die "share name may only contain lowercase letters, digits and dashes: $SHARE_NAME" ;;
  esac
  SMB_USER="$SHARE_NAME"
}

preflight() {
  [ "$(uname -s)" = "Darwin" ] || die "this installer runs on macOS; run it on the Mac you want to back up"

  # Mounting as root hides the share from Finder and Time Machine.
  [ "$(id -u)" != "0" ] || die "run this as yourself, not with sudo; it asks for sudo when it needs it"

  local missing=""
  for cmd in ssh openssl uuidgen nc ifconfig; do
    command -v "$cmd" > /dev/null 2>&1 || missing="$missing $cmd"
  done
  [ -z "$missing" ] || die "missing required commands:$missing"
  [ -x "$OPENSSL" ] || die "$OPENSSL not found"

  WORK_DIR="$(mktemp -d /tmp/fez.XXXXXX)"
  chmod 700 "$WORK_DIR"
}

# ------------------------------------------------------------------- ssh ----

ssh_connect() {
  step "Connecting to $SSH_USER@$SSH_HOST:$SSH_PORT"
  note "you will be asked for the server password once; the connection is then reused"

  SSH_CTL="$WORK_DIR/ssh.sock"
  if ! ssh -p "$SSH_PORT" \
       -o StrictHostKeyChecking=accept-new \
       -o ControlMaster=auto -o ControlPath="$SSH_CTL" -o ControlPersist=600 \
       -o ConnectTimeout=15 \
       "$SSH_USER@$SSH_HOST" "true"; then
    die "cannot SSH to $SSH_USER@$SSH_HOST:$SSH_PORT
    if you rebuilt this server, its key changed and you need to forget the old one:
      ssh-keygen -R $SSH_HOST"
  fi
  say "connected"
}

ssh_run() {
  # Reuses the multiplexed connection if there is one; enrollment has none.
  local conn=(-o ConnectTimeout=15)
  if [ -n "$SSH_CTL" ]; then conn=(-o ControlPath="$SSH_CTL"); fi
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
      "${conn[@]}" "$SSH_USER@$SSH_HOST" "$@"
}

# The server is either at the far end of an ssh connection or this machine.
server_run() {
  if [ "$LOCAL" = "1" ]; then eval "$1"; else ssh_run "$1"; fi
}

# --------------------------------------------------------- client certs -----

generate_client_identity() {
  step "Setting up client certificate"

  if sudo test -f "$CONF_DIR/client-cert.pem" && sudo test -f "$CONF_DIR/client-key.pem"; then
    say "already present in $CONF_DIR, keeping it"
    return 0
  fi

  # Self-signed: the server trusts this one cert, no CA to manage. CA:TRUE with
  # keyCertSign, because OpenSSL will not take it as its own issuer otherwise
  # and RFC 5280 requires the two together. pathlen:0 keeps it to leaves.
  #
  # The subject must be unique. OpenSSL indexes its trust store by subject, so
  # a bundle of certs all called CN=localhost only ever authenticates one of
  # them. A bare uuid names nobody and leaks nothing on the wire.
  # A config file, not -addext: the LibreSSL on Monterey and earlier has no
  # -addext. x509_extensions works everywhere.
  cat > "$WORK_DIR/client.cnf" <<CLIENTCNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext

[dn]
CN = $(uuidgen)

[ext]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
CLIENTCNF

  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$WORK_DIR/client-key.pem"
  "$OPENSSL" req -new -x509 -config "$WORK_DIR/client.cnf" \
    -key "$WORK_DIR/client-key.pem" -out "$WORK_DIR/client-cert.pem" -days 3650

  sudo mkdir -p "$CONF_DIR"
  sudo chmod 755 "$CONF_DIR"
  sudo install -o root -g wheel -m 600 "$WORK_DIR/client-key.pem"  "$CONF_DIR/client-key.pem"
  sudo install -o root -g wheel -m 644 "$WORK_DIR/client-cert.pem" "$CONF_DIR/client-cert.pem"
  say "created $CONF_DIR/client-cert.pem and client-key.pem"
}

register_client_cert() {
  step "Registering your certificate on the server"

  local cert_b64
  cert_b64="$(sudo cat "$CONF_DIR/client-cert.pem" | "$OPENSSL" base64 -A)"

  ssh_run "CERT_B64='$cert_b64' MULTIUSER='$MULTIUSER' ADMIN='$ADMIN' SHARE='$SHARE_NAME' bash -s" <<'REGISTER' || die "could not register the certificate on $SSH_HOST"
set -euo pipefail
mkdir -p /etc/fez

NEW="$(mktemp)"
printf '%s' "$CERT_B64" | base64 -d > "$NEW"
NEW_FP="$(openssl x509 -in "$NEW" -noout -fingerprint -sha256 | cut -d= -f2)"

# Appends this Mac's certificate to a trust bundle, and never twice.
add_to_bundle() {
  bundle="$1"; label="$2"
  touch "$bundle"
  chmod 644 "$bundle"

  SPLIT="$(mktemp -d)"
  awk -v d="$SPLIT" '/-----BEGIN CERTIFICATE-----/{n++} n>0 {print >> (d "/c" n ".pem")}' "$bundle"
  for f in "$SPLIT"/c*.pem; do
    [ -e "$f" ] || continue
    FP="$(openssl x509 -in "$f" -noout -fingerprint -sha256 2> /dev/null | cut -d= -f2 || true)"
    if [ "$FP" = "$NEW_FP" ]; then
      rm -rf "$SPLIT"
      echo "    already in $label"
      return 0
    fi
  done
  rm -rf "$SPLIT"

  # Same annotation the admin page writes, so this Mac shows up by name.
  printf '#fez user=%s added=%s\n' "$SHARE" "$(date -u +%Y-%m-%d)" >> "$bundle"
  cat "$NEW" >> "$bundle"
  echo "    added to $label ($(grep -c 'BEGIN CERTIFICATE' "$bundle") now)"
}

add_to_bundle /etc/fez/client-certs.pem "the client trust list"

if [ "${ADMIN:-0}" = "1" ]; then
  add_to_bundle /etc/fez/admin-certs.pem "the administrator list"
elif [ "${MULTIUSER:-0}" = "1" ] && [ ! -s /etc/fez/admin-certs.pem ]; then
  # Whoever sets the server up first gets it, so the page is reachable at all.
  cp "$NEW" /etc/fez/admin-certs.pem
  chmod 644 /etc/fez/admin-certs.pem
  echo "    this Mac is now the administrator for admin.fez.internal"
fi
rm -f "$NEW"

# Graceful reload if the proxy is already up, so no backup is interrupted.
if [ -f /etc/fez/docker-compose.yml ]; then
  cd /etc/fez && docker compose kill -s HUP tls > /dev/null 2>&1 || true
fi
REGISTER
}

# ----------------------------------------------------------- the server -----

setup_server() {
  step "Setting up the server (this takes a few minutes)"

  server_run "HOST_ADDR='$SSH_HOST' TLS_PORT='$REMOTE_TLS_PORT' SHARE='$SHARE_NAME' MULTIUSER='$MULTIUSER' bash -s" <<'REMOTE'
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
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

stream {
    # Ensure the upstream name/IP reloads if it changes.
    resolver ${NGINX_LOCAL_RESOLVERS} valid=10s ipv6=off;
    map $server_port $fez_samba {
        default timemachine:445;
    }

    log_format fez_auth '$proxy_protocol_addr [$time_local] samba port=$server_port '
                        'fp=$ssl_client_fingerprint sent=$bytes_sent '
                        'received=$bytes_received duration=$session_time';

    # Only sessions that got past ssl_verify_client.
    map $ssl_client_verify $fez_authed {
        SUCCESS 1;
        default 0;
    }

    # Route via SNI
    map $ssl_preread_server_name $fez_backend {
        default             "";
        fez.internal        127.0.0.1:8445;
        public.fez.internal 127.0.0.1:8446;
        admin.fez.internal  127.0.0.1:8447;
    }
    server {
        listen 8443;
        ssl_preread on;
        # Public traffic stays out of the logs.
        error_log /var/log/nginx/error.log crit;
        # Otherwise every log line below says 127.0.0.1.
        proxy_protocol on;
        proxy_pass $fez_backend;
        proxy_connect_timeout 10s;
        proxy_timeout 7d;
        access_log off;
    }

    # fez.internal: the normal samba server.
    server {
        listen 127.0.0.1:8445 ssl proxy_protocol;
        access_log /var/log/nginx/access.log fez_auth if=$fez_authed;

        ssl_certificate     /etc/fez/server-cert.pem;
        ssl_certificate_key /etc/fez/server-key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_trusted_certificate /etc/fez/client-certs.pem;
        ssl_verify_client      on;
        ssl_verify_depth       1;

        proxy_pass         $fez_samba;
        proxy_connect_timeout 10s;
        proxy_timeout      7d;
    }
}

http {
    # /var/cache/nginx is root owned and the filesystem is read only; we run
    # as nobody. nginx creates every temp dir at startup whether the module is
    # used or not, so all five have to point somewhere writable.
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path       /tmp/proxy_temp;
    fastcgi_temp_path     /tmp/fastcgi_temp;
    uwsgi_temp_path       /tmp/uwsgi_temp;
    scgi_temp_path        /tmp/scgi_temp;
    map $request_method $fez_changes {
        GET 0;
        default 1;
    }

    log_format fez_http '$remote_addr [$time_local] $ssl_server_name '
                        '"$request" $status verify=$ssl_client_verify '
                        'fp=$ssl_client_fingerprint sent=$body_bytes_sent';

    set_real_ip_from 127.0.0.1;
    real_ip_header   proxy_protocol;

    proxy_set_header Host $host;
    proxy_http_version 1.1;

    # public.fez.internal: enrollment.
    server {
        listen 127.0.0.1:8446 ssl proxy_protocol;
        access_log /var/log/nginx/access.log fez_http if=$fez_changes;

        ssl_certificate     /etc/fez/server-cert.pem;
        ssl_certificate_key /etc/fez/server-key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        # A certificate is a couple of KB; nothing here needs more.
        client_max_body_size 64k;

        location / {
            proxy_pass http://enroll-queue:8000;
            proxy_connect_timeout 10s;
            proxy_read_timeout 60s;
        }
    }

    # admin.fez.internal: for managing shares.
    server {
        listen 127.0.0.1:8447 ssl proxy_protocol;
        access_log /var/log/nginx/access.log fez_http;

        ssl_certificate     /etc/fez/server-cert.pem;
        ssl_certificate_key /etc/fez/server-key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_trusted_certificate /etc/fez/admin-certs.pem;
        ssl_verify_client      on;
        ssl_verify_depth       1;

        location / {
            proxy_pass http://admin-ui:8000;
            proxy_connect_timeout 10s;
            proxy_read_timeout 10m;
        }
    }
}
NGINX
else
  cat > /etc/fez/nginx.conf.template <<'NGINX'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

stream {
    # Ensure the upstream name/IP reloads if it changes.
    resolver ${NGINX_LOCAL_RESOLVERS} valid=10s ipv6=off;
    map $server_port $fez_samba {
        default timemachine:445;
    }

    log_format fez_auth '$remote_addr [$time_local] samba fp=$ssl_client_fingerprint '
                        'sent=$bytes_sent received=$bytes_received '
                        'duration=$session_time';

    # Only sessions that got past ssl_verify_client.
    map $ssl_client_verify $fez_authed {
        SUCCESS 1;
        default 0;
    }

    # The samba server.
    server {
        listen 8443 ssl;
        access_log /var/log/nginx/access.log fez_auth if=$fez_authed;
        ssl_certificate     /etc/fez/server-cert.pem;
        ssl_certificate_key /etc/fez/server-key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_trusted_certificate /etc/fez/client-certs.pem;
        ssl_verify_client      on;
        ssl_verify_depth       1;
        proxy_pass         $fez_samba;
        proxy_connect_timeout 10s;
        proxy_timeout      7d;
    }
}
NGINX
fi

if [ "${MULTIUSER:-0}" = "1" ]; then
  echo "--- installing the enrollment and admin services"
  cat > /etc/fez/enroll-queue.js <<'ENROLLQUEUEJS'
'use strict';
// fez enroll-queue. Lets a new Mac hand over its cert without ssh access.
// Port 8000 is internet facing via nginx and trades a code for an enrollment;
// 8001 streams events to admin-ui, which owns the pending invitations.

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');

const PUBLIC_PORT = Number(process.env.PUBLIC_PORT || 8000);
const PRIVILEGED_PORT = Number(process.env.PRIVILEGED_PORT || 8001);
const BIND = process.env.BIND || '0.0.0.0';

// A certificate is ~1-2 KB. Anything much larger is not a certificate.
const MAX_BODY = 16 * 1024;
const MAX_BACKLOG = 1000;
const CODE_PATTERN = /^[a-f0-9]{32}$/;
const ENROLL_FILE = process.env.ENROLL_FILE || '/etc/fez/enrollments.json';

let cache = { mtime: -1, byHash: new Map() }; // stat-time cache of ENROLL_FILE
const listeners = new Set(); // admin-ui connections

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function json(res, status, body) {
  const payload = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': payload.length,
    'cache-control': 'no-store',
  });
  res.end(payload);
}

// Reads a request body, refusing anything oversized rather than buffering it.
function readBody(req, limit = MAX_BODY) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// Separate digests: the stored id must not also be the encryption key.
function idOf(code) {
  return crypto.createHash('sha256').update('fez-id:' + code).digest('hex');
}

function keyOf(code) {
  return crypto.createHash('sha256').update('fez-key:' + code).digest();
}

function openPassword(code, sealed) {
  const [iv, tag, body] = String(sealed || '').split('.');
  const d = crypto.createDecipheriv('aes-256-gcm', keyOf(code), Buffer.from(iv, 'hex'));
  d.setAuthTag(Buffer.from(tag, 'hex'));
  return Buffer.concat([d.update(Buffer.from(body, 'hex')), d.final()]).toString('utf8');
}

// admin-ui owns the file and stores only hashes and share passwords encrypted
// with the hash.
function pendingByHash() {
  let stat;
  try {
    stat = fs.statSync(ENROLL_FILE);
  } catch {
    return new Map();
  }
  if (stat.mtimeMs === cache.mtime) return cache.byHash;

  const byHash = new Map();
  try {
    for (const entry of JSON.parse(fs.readFileSync(ENROLL_FILE, 'utf8'))) {
      if (entry && typeof entry.hash === 'string') byHash.set(entry.hash, entry);
    }
  } catch (err) {
    log('cannot read', ENROLL_FILE + ':', err.message);
    return cache.byHash;
  }
  cache = { mtime: stat.mtimeMs, byHash };
  return byHash;
}

// Held in case admin-ui has disconnected, so the share is still added.
const backlog = [];

// Send event to connected admin-ui container.
function publish(event) {
  const line = JSON.stringify(event) + '\n';
  if (!listeners.size) {
    backlog.push(line);
    if (backlog.length > MAX_BACKLOG) backlog.shift();
    log('nobody on the bus, holding', backlog.length, 'event(s)');
    return;
  }
  for (const res of listeners) {
    try {
      res.write(line);
    } catch { // tried to write to closed listener
      listeners.delete(res);
    }
  }
}

// ---------------------------------------------------------------- public ----

// This server listens on the public internet and implements 1 route:
// POST /enroll/<code>
const publicServer = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const match = url.pathname.match(/^\/enroll\/([^/]+)$/);

  if (req.method !== 'PUT' || !match) {
    json(res, 404, { error: 'not found' });
    return;
  }

  const code = match[1];
  if (!CODE_PATTERN.test(code)) {
    json(res, 404, { error: 'unknown code' });
    return;
  }

  const entry = pendingByHash().get(idOf(code));
  if (!entry || (entry.expires && entry.expires <= Date.now())) {
    json(res, 404, { error: 'unknown code' });
    return;
  }

  let cert;
  try {
    cert = await readBody(req);
  } catch {
    json(res, 413, { error: 'certificate too large' });
    return;
  }

  // Parsed, not pattern matched, so junk can't reach the trusted bundle.
  let parsed;
  try {
    parsed = new crypto.X509Certificate(cert);
  } catch {
    json(res, 400, { error: 'not a certificate' });
    return;
  }

  // Before publishing: a failure here must not spend the invitation.
  let password;
  try {
    password = openPassword(code, entry.sealed);
  } catch (err) {
    log('cannot unseal password for', entry.user + ':', err.message);
    json(res, 500, { error: 'could not unseal the share password' });
    return;
  }

  // The code in the clear proves a client presented it; admin-ui spends it.
  publish({
    type: 'enroll',
    user: entry.user,
    code,
    cert: parsed.toString(),
    fingerprint: parsed.fingerprint256,
  });
  log('enrolled', entry.user, parsed.fingerprint256);

  json(res, 200, { user: entry.user, password });
});

// ----------------------------------------------------------- privileged ----

// This server listens on a private port that only admin-ui can connect
// to and listen for events on.
const privilegedServer = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  if (req.method === 'GET' && url.pathname === '/bus') {
    res.writeHead(200, {
      'content-type': 'application/x-ndjson',
      'cache-control': 'no-store',
      connection: 'keep-alive',
    });
    listeners.add(res);
    log('bus listener attached, now', listeners.size);
    while (backlog.length) res.write(backlog.shift());
    req.on('close', () => {
      listeners.delete(res);
      log('bus listener gone, now', listeners.size);
    });
    return;
  }

  json(res, 404, { error: 'not found' });
});

// Don't let a slow client hold a connection open forever.
for (const server of [publicServer, privilegedServer]) {
  server.headersTimeout = 10_000;
  server.requestTimeout = 30_000;
}

// The bus is long lived, so it opts out of the request timeout.
privilegedServer.requestTimeout = 0;

publicServer.listen(PUBLIC_PORT, BIND, () =>
  log('public port', PUBLIC_PORT, '(enroll only)'));
privilegedServer.listen(PRIVILEGED_PORT, BIND, () =>
  log('privileged port', PRIVILEGED_PORT));

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    log('shutting down');
    publicServer.close();
    privilegedServer.close();
    process.exit(0);
  });
}
ENROLLQUEUEJS
  cat > /etc/fez/admin-ui.js <<'ADMINUIJS'
'use strict';

// fez admin-ui. Only accessible through nginx with an admin cert.
// Lists and creates shares, and watches enroll-queue's bus to
// trust new certs.

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');

const PORT = Number(process.env.PORT || 8000);
const BIND = process.env.BIND || '0.0.0.0';
const CONF_DIR = process.env.FEZ_DIR || '/etc/fez';
const USERS_DIR = path.join(CONF_DIR, 'users');
const CLIENT_CERTS = path.join(CONF_DIR, 'client-certs.pem');
const DATA_DIR = process.env.TM_DATA_DIR || '/tm';
const INSTALLER = process.env.FEZ_INSTALLER || '/app/install.sh';
const ENROLL_QUEUE = process.env.ENROLL_QUEUE || 'http://enroll-queue:8001';
const ENROLL_FILE = process.env.ENROLL_FILE || path.join(CONF_DIR, 'enrollments.json');
const ENROLL_TTL_MS = 14 * 24 * 60 * 60 * 1000;
const DOCKER_LOGS = process.env.DOCKER_LOG_DIR || '/var/lib/docker/containers';
const LOG_TAIL = 1024 * 1024;
// Off in tests, where there is no nginx or Samba to signal.
const SIGNAL_PROCESSES = process.env.SIGNAL_PROCESSES !== '0';
const SIGNAL_DIR = process.env.FEZ_SIGNALS || '/signals';

// Matches ADMIN_LABEL in install.sh; only used for the instructions below.
const ADMIN_LABEL = 'com.fezbackup.admin';

const USER_PATTERN = /^[a-z0-9][a-z0-9-]{0,30}$/;
const QUOTA_PATTERN = /^[0-9]{1,6} ?[GTM]$/i;

/** Shown once after a share is created, so the admin can copy the details. */
let lastInvite = null;

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// ------------------------------------------------------------- the shares ---

function readShares() {
  let files = [];
  try {
    files = fs.readdirSync(USERS_DIR).filter((f) => f.endsWith('.conf'));
  } catch {
    return [];
  }

  return files.map((file) => {
    const body = fs.readFileSync(path.join(USERS_DIR, file), 'utf8');
    const field = (name) => {
      const m = body.match(new RegExp('^' + name + '=(.*)$', 'm'));
      return m ? m[1].trim() : '';
    };
    return {
      name: field('SHARE_NAME') || path.basename(file, '.conf'),
      user: field('TM_USERNAME'),
      uid: field('TM_UID'),
      quota: field('VOLUME_SIZE_LIMIT'),
      // Kept so a replacement invitation can hand back the share password.
      password: field('PASSWORD'),
    };
  });
}

function nextUid(shares) {
  let uid = 1000;
  for (const share of shares) {
    const value = Number(share.uid);
    if (Number.isFinite(value) && value >= uid) uid = value + 1;
  }
  return uid;
}

// du is cheap enough here and avoids walking the tree in this process.
function diskUsage(share) {
  return new Promise((resolve) => {
    execFile('du', ['-sk', path.join(DATA_DIR, share)], { timeout: 20_000 },
      (err, stdout) => {
        if (err) return resolve(null);
        const kb = Number(String(stdout).split(/\s+/)[0]);
        resolve(Number.isFinite(kb) ? kb : null);
      });
  });
}

function humanSize(kb) {
  if (kb === null) return 'unknown';
  const units = [['T', 1024 ** 3], ['G', 1024 ** 2], ['M', 1024], ['K', 1]];
  for (const [suffix, size] of units) {
    if (kb >= size) return (kb / size).toFixed(kb >= size * 10 ? 0 : 1) + suffix;
  }
  return '0K';
}

function createShare(name, quota) {
  const shares = readShares();
  if (shares.some((s) => s.name === name)) {
    throw new Error(`share "${name}" already exists`);
  }

  const dir = path.join(DATA_DIR, name);
  let owner = null;
  try {
    const st = fs.statSync(dir);
    // Reusing a name keeps the old uid, or the backups inside are unreadable.
    if (st.isDirectory() && st.uid >= 1000) owner = st.uid;
  } catch {
    // nothing there yet
  }

  const uid = owner === null ? nextUid(shares) : owner;
  const password = crypto.randomBytes(8).toString('hex');

  // Same format the installer writes for the first share.
  const conf = [
    `TM_USERNAME=${name}`,
    `TM_GROUPNAME=${name}`,
    `PASSWORD=${password}`,
    `SHARE_NAME=${name}`,
    `TM_UID=${uid}`,
    `TM_GID=${uid}`,
    `VOLUME_SIZE_LIMIT=${quota || ''}`,
    '',
  ].join('\n');

  fs.writeFileSync(path.join(USERS_DIR, `${name}.conf`), conf, { mode: 0o600 });

  if (owner === null) {
    // Created 0700, not widened then narrowed, so there is no open window.
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    try {
      // chmod while root still owns it, so no CAP_FOWNER is needed.
      fs.chmodSync(dir, 0o700);
      fs.chownSync(dir, uid, uid);
    } catch (err) {
      // Worth knowing about: without this the share is readable by other shares.
      log('WARNING: could not set ownership on', dir, err.message);
    }
  } else {
    log('reusing', dir, 'and its uid', uid);
  }

  log('created share', name, 'uid', uid);
  // smb.conf and the Samba users are only built at boot, so the container has
  // to be restarted entirely.
  poke('samba');
  return { name, uid, password };
}

// --------------------------------------------------------- enroll-queue -----

// Separate digests: the stored id must not also be the encryption key.
function idOf(code) {
  return crypto.createHash('sha256').update('fez-id:' + code).digest('hex');
}

function keyOf(code) {
  return crypto.createHash('sha256').update('fez-key:' + code).digest();
}

// Only a holder of the code can read the password back out.
function sealPassword(code, password) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', keyOf(code), iv);
  const body = Buffer.concat([c.update(String(password), 'utf8'), c.final()]);
  return [iv.toString('hex'), c.getAuthTag().toString('hex'), body.toString('hex')].join('.');
}

// Pending invitations. Only the hash is kept, so a code cannot be read back.
function readEnrollments() {
  try {
    const list = JSON.parse(fs.readFileSync(ENROLL_FILE, 'utf8'));
    return Array.isArray(list) ? list.filter((e) => e && typeof e.hash === 'string') : [];
  } catch {
    return [];
  }
}

// In place: a single file bind mount would not survive a rename.
function writeEnrollments(list) {
  const now = Date.now();
  fs.writeFileSync(
    ENROLL_FILE,
    JSON.stringify(list.filter((e) => !e.expires || e.expires > now), null, 1) + '\n',
  );
}

// ------------------------------------------------------- trusting a Mac -----

// A "#fez user=alice added=2026-09-10" line is kept above each cert
const ANNOTATION = /^#fez\s+(.*)$/;

function annotate(user, added) {
  return `#fez user=${user} added=${added || new Date().toISOString().slice(0, 10)}\n`;
}

// Pairs each cert with the annotation above it. Ones without are still
// returned, so a hand-edited bundle shows up rather than vanishing.
function readTrustedCerts() {
  let text;
  try {
    text = fs.readFileSync(CLIENT_CERTS, 'utf8');
  } catch {
    return [];
  }

  const out = [];
  let pending = null;
  let block = null;

  for (const line of text.split('\n')) {
    if (block === null) {
      const note = line.match(ANNOTATION);
      if (note) {
        const fields = {};
        for (const pair of note[1].trim().split(/\s+/)) {
          const [k, v] = pair.split('=');
          if (k) fields[k] = v || '';
        }
        pending = fields;
        continue;
      }
      if (line.startsWith('-----BEGIN CERTIFICATE-----')) block = [line];
      continue;
    }

    block.push(line);
    if (!line.startsWith('-----END CERTIFICATE-----')) continue;

    const pem = block.join('\n') + '\n';
    block = null;
    const owner = pending;
    pending = null;

    try {
      const cert = new crypto.X509Certificate(pem);
      out.push({
        pem,
        user: (owner && owner.user) || null,
        added: (owner && owner.added) || null,
        fingerprint: cert.fingerprint256,
        sha1: cert.fingerprint.replace(/:/g, '').toLowerCase(),
        expires: cert.validTo,
      });
    } catch {
      log('ignoring an unparseable block in the trusted bundle');
    }
  }

  return out;
}

function certificateAlreadyTrusted(pem) {
  const incoming = new crypto.X509Certificate(pem).fingerprint256;
  return readTrustedCerts().some((c) => c.fingerprint === incoming);
}

// Rewrites the bundle without that cert (in-place since bind-mounted)
function revokeCertificate(fingerprint) {
  const kept = [];
  let removed = null;

  for (const entry of readTrustedCerts()) {
    if (entry.fingerprint === fingerprint) {
      removed = entry;
      continue;
    }
    kept.push((entry.user ? annotate(entry.user, entry.added) : '') + entry.pem);
  }

  if (!removed) throw new Error('that certificate is no longer in the bundle');

  fs.writeFileSync(CLIENT_CERTS, kept.join(''));
  try {
    fs.chmodSync(CLIENT_CERTS, 0o644);
  } catch {}
  log('revoked certificate', removed.sha1, 'for', removed.user || 'unattributed');
  return removed;
}

// Each container watches its own fifo, so no signal crosses a boundary.
// Non-blocking: with nothing reading, the open fails at once instead of hanging.
function poke(name) {
  if (!SIGNAL_PROCESSES) return null;
  let fd;
  try {
    fd = fs.openSync(path.join(SIGNAL_DIR, name),
      fs.constants.O_WRONLY | fs.constants.O_NONBLOCK);
  } catch (err) {
    log('could not signal', name + ':', err.code || err.message);
    return err.code === 'ENXIO' ? `nothing is watching the ${name} fifo` : err.message;
  }
  try {
    fs.writeSync(fd, 'go\n');
    log('poked', name);
  } finally {
    fs.closeSync(fd);
  }
  return null;
}

// Opening without writing delivers nothing, so this only reports liveness.
function listening(name) {
  if (!SIGNAL_PROCESSES) return true;
  try {
    fs.closeSync(fs.openSync(path.join(SIGNAL_DIR, name),
      fs.constants.O_WRONLY | fs.constants.O_NONBLOCK));
    return true;
  } catch {
    return false;
  }
}

// Which container holds each log, by the hostname compose gave it.
const LOG_SOURCES = {
  nginx: 'tls',
  samba: 'timemachine',
  'enroll-queue': 'enroll-queue',
  'admin-ui': 'admin-ui',
};

// Ids change on every recreate, so resolve by hostname from docker's own dir.
function containerIdFor(hostname) {
  let best = null;
  let newest = -1;
  let ids = [];
  try {
    ids = fs.readdirSync(DOCKER_LOGS);
  } catch {
    return null;
  }
  for (const id of ids) {
    if (!/^[0-9a-f]{64}$/.test(id)) continue;
    try {
      const host = fs.readFileSync(path.join(DOCKER_LOGS, id, 'hostname'), 'utf8');
      if (host.trim() !== hostname) continue;
      // A replaced but unremoved container leaves a stale dir; newest wins.
      const when = fs.statSync(path.join(DOCKER_LOGS, id, `${id}-json.log`)).mtimeMs;
      if (when > newest) {
        newest = when;
        best = id;
      }
    } catch {
      // dirs linger for containers we cannot read; skip them
    }
  }
  return best;
}

// Tail of the live log; a line that will not parse is printed as it is.
function tailLog(id) {
  const fd = fs.openSync(path.join(DOCKER_LOGS, id, `${id}-json.log`), 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const from = Math.max(0, size - LOG_TAIL);
    const buf = Buffer.alloc(size - from);
    fs.readSync(fd, buf, 0, buf.length, from);
    const lines = buf.toString('utf8').split('\n');
    if (from > 0) lines.shift();
    return lines.map((line) => {
      if (!line) return '';
      try {
        const entry = JSON.parse(line);
        return typeof entry.log === 'string' ? entry.log : `${line}\n`;
      } catch {
        return `${line}\n`;
      }
    }).join('');
  } finally {
    fs.closeSync(fd);
  }
}

function applyEnrollment(event) {
  let cert;
  try {
    cert = new crypto.X509Certificate(event.cert);
  } catch {
    log('ignoring enrollment with an unparseable certificate');
    return;
  }

  if (!USER_PATTERN.test(event.user || '')) {
    log('ignoring enrollment with a suspicious user name');
    return;
  }

  const invite = readEnrollments().find((e) => e.hash === idOf(event.code || ''));
  if (!invite) {
    log('ignoring enrollment: no outstanding invitation for that code');
    return;
  }
  if (invite.user !== event.user) {
    log('ignoring enrollment: code belongs to', invite.user, 'not', event.user);
    return;
  }

  if (certificateAlreadyTrusted(event.cert)) {
    log('certificate for', event.user, 'is already trusted');
  } else {
    fs.appendFileSync(CLIENT_CERTS, annotate(event.user) + cert.toString().trim() + '\n');
    try {
      fs.chmodSync(CLIENT_CERTS, 0o644);
    } catch {}
    log('trusted certificate for', event.user,
        cert.fingerprint.replace(/:/g, '').toLowerCase());
  }

  // Spending it here, not in enroll-queue, is what makes a code single use.
  writeEnrollments(readEnrollments().filter((e) => e.hash !== invite.hash));

  reloadNginx();
}

function reloadNginx() {
  poke('nginx');
}

function listenToBus() {
  const url = new URL('/bus', ENROLL_QUEUE);
  const req = http.request(
    { method: 'GET', hostname: url.hostname, port: url.port, path: '/bus' },
    (res) => {
      log('bus connected');
      let buffer = '';
      res.on('data', (chunk) => {
        buffer += chunk;
        let index;
        while ((index = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, index).trim();
          buffer = buffer.slice(index + 1);
          if (!line) continue;
          try {
            const event = JSON.parse(line);
            if (event.type === 'enroll') applyEnrollment(event);
          } catch (err) {
            log('bad bus event:', err.message);
          }
        }
      });
      res.on('end', () => {
        log('bus closed, reconnecting');
        setTimeout(listenToBus, 2000);
      });
    },
  );
  req.on('error', (err) => {
    log('bus error:', err.message);
    setTimeout(listenToBus, 2000);
  });
  req.end();
}

// ------------------------------------------------------------------- ui -----

const LOGO = `<svg class="logo" viewBox="0 0 24 24" fill="none" stroke-width="1.7"
  stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path class="cloud"
  d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/><circle class="clock" cx="11.5"
  cy="14.4" r="3.2"/><path class="clock" d="M11.5 12.8v1.6l1.4.9"/></svg>`;

const STYLE = `
:root {
  --bg:#ffffff; --panel:#f6f7f9; --ink:#1f2933; --bright:#0b1f33;
  --muted:#5a6673; --line:#d3d9e0; --accent:#0b3d6b; --gold:#8a6a1f;
  --warn:#8a2f2f;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
  font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }
.wrap { max-width:64rem; margin:0 auto; padding:0 1.75rem 3rem; }

header { padding:2.5rem 0 1.75rem; margin-bottom:2rem;
  border-bottom:3px double var(--accent); }
h1 { font-size:1.95rem; font-weight:700; margin:0; color:var(--accent);
  letter-spacing:-.01em; }
.logo { width:1em; height:1em; vertical-align:-.12em; margin-right:.4rem; }
.logo .cloud { stroke:var(--accent); stroke-width:1.6; }
.logo .clock { stroke:var(--gold); stroke-width:1.6; }

h2 { font-size:.82rem; font-weight:700; color:var(--accent);
  text-transform:uppercase; letter-spacing:.09em;
  margin:2.5rem 0 .9rem; padding-bottom:.45rem;
  border-bottom:1px solid var(--line); }
h3 { font-size:1rem; font-weight:700; color:var(--bright); margin:0 0 .4rem; }
p { margin:0 0 .9rem; }
a { color:var(--accent); text-decoration:underline; text-underline-offset:2px; }
strong { color:var(--bright); font-weight:700; }
code { font-family:var(--mono); font-size:.88em; color:var(--bright);
  background:var(--panel); padding:.05em .3em; border:1px solid var(--line); }
pre { background:var(--panel); border:1px solid var(--line);
  border-left:4px solid var(--accent); padding:.9rem 1.1rem; overflow-x:auto;
  margin:0 0 1.1rem; font:.82rem/1.6 var(--mono); color:var(--bright); }

table { border-collapse:collapse; width:100%; margin:0 0 1.2rem; font-size:.9rem; }
th, td { text-align:left; padding:.55rem .7rem; border:1px solid var(--line); }
th { background:var(--accent); color:#fff; font-weight:700; font-size:.72rem;
  text-transform:uppercase; letter-spacing:.07em; }
tbody tr:nth-child(even) { background:var(--panel); }
td:first-child { font-weight:700; color:var(--bright); white-space:nowrap; }
td:last-child { white-space:nowrap; }
td.fp { font-family:var(--mono); font-size:.76rem; font-weight:400;
  color:var(--muted); }

form { background:var(--panel); border:1px solid var(--line);
  border-left:4px solid var(--gold); padding:1.1rem 1.2rem; }
label { display:block; margin:.7rem 0 .25rem; color:var(--muted); font-size:.72rem;
  text-transform:uppercase; letter-spacing:.07em; font-weight:700; }
label.check { display:flex; align-items:center; gap:.5rem; margin-top:1rem;
  text-transform:none; letter-spacing:0; font-weight:400; font-size:.9rem;
  color:var(--ink); }
label.check input { width:auto; }
input { font:inherit; background:var(--bg); color:var(--ink);
  border:1px solid var(--line); padding:.45rem .55rem; width:100%; max-width:22rem; }
input:focus { outline:2px solid var(--accent); outline-offset:-1px; }
button { font:inherit; margin-top:1.1rem; background:var(--accent); color:#fff;
  border:0; padding:.55rem 1.2rem; cursor:pointer; font-weight:700;
  font-size:.74rem; text-transform:uppercase; letter-spacing:.08em; }
button:hover { background:var(--bright); }

.banner { position:relative; background:var(--panel); border:1px solid var(--line);
  border-left:4px solid var(--gold); padding:1rem 1.2rem; margin:0 0 1.4rem; }
.banner h3 { margin:0 2rem .45rem 0; color:var(--accent); }
.banner .close { position:absolute; top:.5rem; right:.85rem; line-height:1;
  font-size:1.35rem; color:var(--muted); text-decoration:none; }
.banner .close:hover { color:var(--accent); }
.err { border-left-color:var(--warn); }
.err h3 { color:var(--warn); }
.muted { color:var(--muted); font-size:.86rem; }

/* The per row action sits in a table cell, so it must not carry the panel
   styling the add form has. */
form.inline { display:inline; background:none; border:0; padding:0; margin:0 .6rem 0 0; }
button.linkish { font:inherit; font-size:.86rem; margin:0; padding:0; background:none;
  border:0; color:var(--accent); cursor:pointer; font-weight:400;
  text-transform:none; letter-spacing:0; text-decoration:underline;
  text-underline-offset:2px; }
button.linkish:hover { background:none; color:var(--bright); }
button.linkish.danger { color:var(--warn); }
button.linkish.danger:hover { color:#5e1f1f; }
`;

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function page(body) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>fez admin</title><style>${STYLE}</style></head><body><div class="wrap">
<header><h1>${LOGO}fez admin</h1></header>
${body}
</div></body></html>`;
}

async function renderHome(error) {
  const shares = readShares();
  const usage = await Promise.all(shares.map((s) => diskUsage(s.name)));

  // No code column: only its hash is stored, so it is shown once and not again.
  let pendingRows = '';
  const waiting = readEnrollments();
  if (waiting.length) {
    pendingRows = `<h2>waiting to enroll</h2><table>
      <tr><th>share</th><th>expires</th><th></th></tr>${waiting.map((e) => `<tr>
        <td>${escapeHtml(e.user)}</td>
        <td>${new Date(e.expires).toISOString().slice(0, 10)}</td>
        <td><form method="POST" action="/cancel" class="inline">
          <input type="hidden" name="hash" value="${escapeHtml(e.hash)}">
          <button type="submit" class="linkish danger">cancel</button>
        </form></td></tr>`).join('')}</table>`;
  }

  const trusted = readTrustedCerts();
  const rows = shares.map((share, i) => `<tr>
      <td>${escapeHtml(share.name)}</td>
      <td>${escapeHtml(share.user)}</td>
      <td>${escapeHtml(share.uid)}</td>
      <td>${escapeHtml(share.quota || 'none')}</td>
      <td>${humanSize(usage[i])}</td>
      <td><form method="POST" action="/invite" class="inline">
        <input type="hidden" name="name" value="${escapeHtml(share.name)}">
        <button type="submit" class="linkish">new invitation</button>
      </form>
      <form method="POST" action="/password" class="inline">
        <input type="hidden" name="name" value="${escapeHtml(share.name)}">
        <button type="submit" class="linkish">show password</button>
      </form></td>
    </tr>`).join('');

  // Grouped by owner, so revoking a lost Mac means finding the person.
  const certSection = trusted.length ? `<h2>allowed clients</h2><table>
    <tr><th>name</th><th>added</th><th>expires</th><th>fingerprint</th><th></th></tr>
    ${trusted.map((c) => `<tr>
      <td>${c.user ? escapeHtml(c.user) : '<span class="muted">unattributed</span>'}</td>
      <td>${c.added ? escapeHtml(c.added) : '<span class="muted">unknown</span>'}</td>
      <td>${escapeHtml(new Date(c.expires).toISOString().slice(0, 10))}</td>
      <td class="fp">${escapeHtml(c.sha1)}</td>
      <td><form method="POST" action="/revoke" class="inline">
        <input type="hidden" name="fingerprint" value="${escapeHtml(c.fingerprint)}">
        <button type="submit" class="linkish danger">revoke</button>
      </form></td>
    </tr>`).join('')}</table>`
    : '';

  let banner = '';
  if (lastInvite) {
    const who = escapeHtml(lastInvite.name);
    const heading = lastInvite.kind === 'password' ? `password for ${who}`
      : lastInvite.kind === 'replacement' ? `replacement invitation for ${who}`
      : lastInvite.code ? `send this to ${who}`
      : `created ${who}`;
    const note = lastInvite.kind === 'replacement'
      ? `<p class="muted">Remember to revoke any old client certificates under <strong>allowed clients</strong>.</p>`
      : '';
    const body = lastInvite.code
      ? `<pre>Share password: ${escapeHtml(lastInvite.password)}
./install.sh --server ${escapeHtml(lastInvite.server)} --enroll ${escapeHtml(lastInvite.code)}</pre>
      <p><a href="/install.sh" download>download install.sh</a> and send it with
      the line above.</p>
      ${note}
      <p class="muted">The code works only once, and expires on
      ${new Date(lastInvite.expiresAt).toISOString().slice(0, 10)}. Send the code
      and the script securely to the user.`
      : lastInvite.kind === 'password'
      ? `<pre>Share password: ${escapeHtml(lastInvite.password)}</pre>
      <p class="muted">Type this into Finder when mounting the share.`
      : `<pre>Share password: ${escapeHtml(lastInvite.password)}</pre>
      <p class="muted">No enroll code was generated, so only an existing client can
      connect to this share. Use <strong>new invitation</strong> on its row when you are
      ready to hand it out.`;
    banner = `<div class="banner">
      <a class="close" href="/?dismiss=1" title="dismiss" aria-label="dismiss">&times;</a>
      <h3>${heading}</h3>
      ${body}</p></div>`;
  }

  const errorBox = error
    ? `<div class="banner err"><h3>that did not work</h3><p>${escapeHtml(error)}</p></div>`
    : '';

  // A dead watcher means reloads silently stop, so say so up front.
  const asleep = ['nginx', 'samba'].filter((n) => !listening(n));
  const watchers = asleep.length
    ? `<div class="banner err"><h3>reloads are not getting through</h3>
       <p>Nothing is watching ${escapeHtml(asleep.join(' or '))}, so changes made
       here will not reach ${asleep.length > 1 ? 'those containers' : 'that container'}.</p></div>`
    : '';

  return page(`${banner}${errorBox}${watchers}
<h2>shares</h2>
${shares.length
    ? `<table><tr><th>share</th><th>user</th><th>uid</th><th>quota</th><th>used</th><th></th></tr>${rows}</table>`
    : '<p class="muted">no shares yet</p>'}
${certSection}
${pendingRows}
<h2>add a share</h2>
<form method="POST" action="/users">
  <label for="name">name (lowercase letters, digits and dashes)</label>
  <input id="name" name="name" required pattern="[a-z0-9][a-z0-9-]*" autocomplete="off">
  <label for="quota">quota, optional (for example 500 G, or 1 T)</label>
  <input id="quota" name="quota" placeholder="leave empty for no limit" autocomplete="off">
  <label class="check"><input type="checkbox" name="invite" value="1" checked>
    generate enroll code</label>
  <button type="submit">add share</button>
</form>

<h2>view logs</h2>
<p class="muted">
${Object.keys(LOG_SOURCES).map((n) => `<a href="/logs/${n}">${n}</a>`).join(' &middot; ')}</p>

<h2>disable admin interface</h2>
<p class="muted">To disable the local admin interface on <code>http://127.0.0.2:8443</code>:</p>
<pre>sudo launchctl bootout system/${ADMIN_LABEL}
sudo launchctl disable system/${ADMIN_LABEL}</pre>
`);
}

// Gets a code and remembers it for the banner.
// invite is null when the admin asked for a share without a code.
// kind is 'new', 'replacement' or 'password', and decides what the banner says.
function announce(name, password, invite, kind) {
  lastInvite = {
    name,
    password,
    kind,
    code: invite ? invite.enrollcode : null,
    expiresAt: invite ? invite.expiresAt : null,
    server: process.env.SERVER_ADDRESS || '<server address>',
  };
}

function issueInvite(name, password, replacement) {
  const code = crypto.randomBytes(16).toString('hex');
  const expiresAt = Date.now() + ENROLL_TTL_MS;
  // One outstanding invitation per share; a new one supersedes the old.
  const list = readEnrollments().filter((e) => e.user !== name);
  list.push({ hash: idOf(code), user: name, sealed: sealPassword(code, password), expires: expiresAt });
  writeEnrollments(list);
  announce(name, password, { enrollcode: code, expiresAt },
    replacement ? 'replacement' : 'new');
  log(replacement ? 'replacement invitation for' : 'invitation for', name);
}

function parseForm(body) {
  const out = {};
  for (const pair of body.split('&')) {
    if (!pair) continue;
    const [k, v = ''] = pair.split('=');
    out[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' '));
  }
  return out;
}

// No DNS rebinding.
const LOOPBACK_HOST = /^(127\.\d{1,3}\.\d{1,3}\.\d{1,3}|localhost|\[::1\]|::1)$/;

function hostAllowed(req) {
  const raw = req.headers.host || '';
  // Strip the port, leaving bracketed IPv6 literals intact.
  const host = raw.startsWith('[') ? raw.replace(/\](:\d+)?$/, ']') : raw.replace(/:\d+$/, '');
  return LOOPBACK_HOST.test(host);
}

// CSRF: posting here blind is enough to create shares or revoke a Mac. Browsers
// always send Origin cross-origin, so a mismatch is a no. Missing means curl.
function originAllowed(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  try {
    return LOOPBACK_HOST.test(new URL(origin).hostname);
  } catch {
    return false;
  }
}

const POSTS = {
  '/revoke': (form) => {
    const fp = (form.fingerprint || '').trim();
    if (!/^[A-F0-9]{2}(:[A-F0-9]{2}){31}$/.test(fp)) throw new Error('that is not a fingerprint');
    revokeCertificate(fp);
    if (SIGNAL_PROCESSES) reloadNginx();
  },

  '/cancel': async (form) => {
    const hash = (form.hash || '').trim();
    if (!/^[a-f0-9]{64}$/.test(hash)) throw new Error('that is not an invitation');
    const list = readEnrollments();
    if (!list.some((e) => e.hash === hash)) throw new Error('that invitation is already gone');
    writeEnrollments(list.filter((e) => e.hash !== hash));
    log('cancelled invitation for', list.find((e) => e.hash === hash).user);
  },

  // Reads a share password back out, for when someone has lost theirs.
  '/password': (form) => {
    const name = (form.name || '').trim();
    if (!USER_PATTERN.test(name)) throw new Error('that is not a share name');
    const share = readShares().find((s) => s.name === name);
    if (!share) throw new Error(`there is no share called "${name}"`);
    if (!share.password) throw new Error(`no PASSWORD= in ${name}.conf`);
    announce(name, share.password, null, 'password');
  },

  '/invite': async (form) => {
    const name = (form.name || '').trim();
    if (!USER_PATTERN.test(name)) throw new Error('that is not a share name');
    const share = readShares().find((s) => s.name === name);
    if (!share) throw new Error(`there is no share called "${name}"`);
    if (!share.password) throw new Error(`no PASSWORD= in ${name}.conf, so there is nothing to send`);
    await issueInvite(name, share.password, true);
  },

  '/users': async (form) => {
    const name = (form.name || '').trim();
    const quota = (form.quota || '').trim();
    if (!USER_PATTERN.test(name)) throw new Error('name is lowercase letters, digits and dashes');
    if (quota && !QUOTA_PATTERN.test(quota)) throw new Error('quota looks like "500 G" or "1 T", or empty');
    const share = createShare(name, quota);
    // Checkboxes only submit when ticked, so absence means they unticked it.
    if (form.invite) await issueInvite(name, share.password, false);
    else announce(name, share.password, null, 'new');
  },
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const send = (status, type, body) => {
    res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(body);
  };
  const page = async (status, error) => send(status, 'text/html; charset=utf-8', await renderHome(error));

  if (!hostAllowed(req)) {
    log('refused host', JSON.stringify(req.headers.host || ''));
    return send(403, 'text/plain', 'reach this page at 127.0.0.2, not by name\n');
  }
  if (req.method !== 'GET' && !originAllowed(req)) {
    log('refused cross origin request from', JSON.stringify(req.headers.origin || ''));
    return send(403, 'text/plain', 'cross origin requests are not accepted\n');
  }

  try {
    if (req.method === 'GET' && url.pathname === '/') {
      if (url.searchParams.get('dismiss')) lastInvite = null;
      return page(200, null);
    }

    // The copy the installer left on the server, so the admin can send both
    // halves: the script and the line to run it with.
    if (req.method === 'GET' && url.pathname === '/install.sh') {
      let body;
      try {
        body = fs.readFileSync(INSTALLER);
      } catch {
        return send(404, 'text/plain', 'no installer on this server\n');
      }
      if (!body.length) return send(404, 'text/plain', 'the installer copy is empty\n');
      res.writeHead(200, {
        'content-type': 'text/x-shellscript',
        'content-disposition': 'attachment; filename="install.sh"',
        'content-length': body.length,
        'cache-control': 'no-store',
      });
      return res.end(body);
    }

    if (req.method === 'GET' && url.pathname.startsWith('/logs/')) {
      const name = url.pathname.slice('/logs/'.length);
      if (!Object.prototype.hasOwnProperty.call(LOG_SOURCES, name)) {
        return send(404, 'text/plain', 'no such log\n');
      }
      const id = containerIdFor(LOG_SOURCES[name]);
      if (!id) return send(503, 'text/plain', `no running ${name} container found\n`);
      try {
        return send(200, 'text/plain; charset=utf-8', tailLog(id) || '(the log is empty)\n');
      } catch (err) {
        return send(503, 'text/plain', `could not read the ${name} log: ${err.message}\n`);
      }
    }

    const handler = req.method === 'POST' ? POSTS[url.pathname] : null;
    if (handler) {
      let body = '';
      for await (const chunk of req) {
        body += chunk;
        if (body.length > 8192) { req.destroy(); return; }
      }
      try {
        await handler(parseForm(body));
      } catch (err) {
        return page(400, err.message);
      }
      res.writeHead(303, { location: '/' });
      return res.end();
    }

    send(404, 'text/plain', 'not found\n');
  } catch (err) {
    log('request failed:', err.message);
    send(500, 'text/plain', 'internal error\n');
  }
});

server.headersTimeout = 15_000;
server.listen(PORT, BIND, () => log('admin ui on', BIND + ':' + PORT));
listenToBus();

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { log('shutting down'); server.close(); process.exit(0); });
}
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
#!/bin/sh

# Replaces the image's /etc/s6/smbd/run to log to the docker stack.
DEBUG_LEVEL="${DEBUG_LEVEL:-1}"
exec /usr/sbin/smbd --foreground --no-process-group --debug-stdout \
  --debuglevel="${DEBUG_LEVEL}" \
  --option="log file=/dev/stdout" \
  --option="max log size=0" < /dev/null
SMBDRUN
chmod 755 /etc/fez/smbd-run

cat > /etc/fez/nginx-reload.sh <<'RELOADNGINX'
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
RELOADNGINX
cat > /etc/fez/samba-reload <<'RELOADSAMBA'
#!/bin/sh
# Ends s6-svscan when admin-ui writes the fifo, so the container restarts and
# samba rebuilds smb.conf with the new share. s6 supervises this script.
exec 3<> /signals/samba
while read -r _ <&3; do
  s6-svscanctl -t /etc/s6
done
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
x-logging: &fez-logging
  driver: json-file
  options:
    max-size: "20m"
    max-file: "2"

services:
  timemachine:
    image: mbentley/timemachine:smb
    container_name: fez-timemachine
    hostname: timemachine
    restart: always
    logging: *fez-logging
    environment:
      - EXTERNAL_CONF=/etc/timemachine-conf
      - SET_PERMISSIONS=false
      - HIDE_SHARES=yes
    volumes:
      - /tm:/opt
      - /etc/fez/users:/etc/timemachine-conf:ro
      # Sends samba's log to stdout so docker compose logs handle them.
      - /etc/fez/smbd-run:/etc/s6/smbd/run:ro
      # Restarts the container when admin-ui pokes the fifo.
      - /etc/fez/samba-reload:/etc/s6/reload/run:ro
      - /etc/fez/signals/samba:/signals/samba
      # Disable mDNS and NetBIOS, not used by us.
      - /etc/fez/s6-down:/etc/s6/avahi/down:ro
      - /etc/fez/s6-down:/etc/s6/dbus/down:ro
      - /etc/fez/s6-down:/etc/s6/nmbd/down:ro
    tmpfs:
      - /run/samba
      # Samba log files are capped and autorotated, keep them off our disk.
      - /var/log/samba
    networks:
      - smb
COMPOSE

if [ "${MULTIUSER:-0}" = "1" ]; then
  cat >> /etc/fez/docker-compose.yml <<COMPOSE

  # Unauthenticated internet-facing endpoint for enroll codes.
  enroll-queue:
    image: node:22-alpine
    container_name: fez-enroll-queue
    hostname: enroll-queue
    restart: always
    logging: *fez-logging
    command: ["node", "/app/enroll-queue.js"]
    user: "nobody"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - /etc/fez/enroll-queue.js:/app/enroll-queue.js:ro
      - /etc/fez/enrollments.json:/etc/fez/enrollments.json:ro
    networks:
      - control

  # Requires an admin cert to access, very privileged. Writes share config
  # owns directories under /tm for other uids, and signals the other containers.
  admin-ui:
    image: node:22-alpine
    container_name: fez-admin-ui
    hostname: admin-ui
    restart: always
    logging: *fez-logging
    depends_on:
      - enroll-queue
    command: ["node", "/app/admin-ui.js"]
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN # make new share dirs the correct uid
      - DAC_READ_SEARCH # du across the 0700 dirs root does not own
    security_opt:
      - no-new-privileges:true
    environment:
      - ENROLL_QUEUE=http://enroll-queue:8001
      - SERVER_ADDRESS=${HOST_ADDR}
    volumes:
      - /etc/fez/admin-ui.js:/app/admin-ui.js:ro
      - /etc/fez/install.sh:/app/install.sh:ro
      - /etc/fez/users:/etc/fez/users
      - /etc/fez/client-certs.pem:/etc/fez/client-certs.pem
      - /etc/fez/enrollments.json:/etc/fez/enrollments.json
      - /etc/fez/signals/nginx:/signals/nginx
      - /etc/fez/signals/samba:/signals/samba
      - /tm:/tm # writable, for creating share folders
      # Container logs for the admin page
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
    networks:
      - control
COMPOSE
  TLS_DEPENDS="$TLS_DEPENDS
      - enroll-queue
      - admin-ui"
fi

cat >> /etc/fez/docker-compose.yml <<COMPOSE
  tls:
    image: nginx:alpine
    container_name: fez-tls
    hostname: tls
    restart: always
    logging: *fez-logging
    # nginx resolves what it proxies to at config load, so it starts last.
    depends_on:
${TLS_DEPENDS}
    user: "nobody"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    environment:
      # Exports NGINX_LOCAL_RESOLVERS from the container's resolv.conf.
      - NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
      # Use /tmp, as we are running as "nobody".
      - NGINX_ENVSUBST_OUTPUT_DIR=/tmp
    command: ["nginx", "-c", "/tmp/nginx.conf", "-g", "daemon off;"]
    tmpfs:
      - /tmp
    ports:
      - "${TLS_PORT}:8443"
    volumes:
      - /etc/fez/nginx.conf.template:/etc/nginx/templates/nginx.conf.template:ro
      # Reloads nginx when admin-ui pokes the fifo.
      - /etc/fez/nginx-reload.sh:/docker-entrypoint.d/99-fez-reload.sh:ro
      - /etc/fez/signals/nginx:/signals/nginx
      - /etc/fez/server-cert.pem:/etc/fez/server-cert.pem:ro
      - /etc/fez/server-key.pem:/etc/fez/server-key.pem:ro
      - /etc/fez/client-certs.pem:/etc/fez/client-certs.pem:ro
      - /etc/fez/admin-certs.pem:/etc/fez/admin-certs.pem:ro
    networks:
      - smb
      - control
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
REMOTE

  say "server configured"
}

# Leaves a copy on the server so the admin page can hand it out.
upload_installer() {
  if [ ! -f "$0" ]; then
    note "running from a pipe, so no installer to copy to the server"
    return 0
  fi
  step "Copying the installer to the server"
  server_run "mkdir -p $REMOTE_CONF_DIR && cat > $REMOTE_CONF_DIR/install.sh && chmod 644 $REMOTE_CONF_DIR/install.sh" < "$0"
  say "$REMOTE_CONF_DIR/install.sh"
}

# The server decides the password: it may already have one from an earlier Mac.
fetch_share_password() {
  local password
  password="$(ssh_run "sed -n 's/^PASSWORD=//p' $REMOTE_CONF_DIR/users/$SHARE_NAME.conf | head -1")"
  case "$password" in
    ''|*[!0-9a-f]*) die "could not read the share password back from the server" ;;
  esac
  printf '%s' "$password"
}

# ------------------------------------------------------------ enrollment ----

# Swaps an invitation code for a place on the server.
submit_enrollment() {
  step "Handing your certificate to the server"

  local cert body response
  cert="$(sudo cat "$CONF_DIR/client-cert.pem")"
  body="$cert"$'\n'

  # curl checks the hostname and our cert says localhost, ugh
  response="$( {
      printf 'PUT /enroll/%s HTTP/1.1\r\nHost: %s\r\n' "$ENROLL_CODE" "$PUBLIC_NAME"
      printf 'Content-Type: application/x-pem-file\r\nContent-Length: %s\r\n' "${#body}"
      printf 'Connection: close\r\n\r\n%s' "$body"
    } | "$OPENSSL" s_client -quiet \
      -connect "$SSH_HOST:$REMOTE_TLS_PORT" -servername "$PUBLIC_NAME" \
      -CAfile "$CONF_DIR/server-ca.pem" -verify 5 -verify_return_error 2> /dev/null || true)"

  [ -n "$response" ] || die "no answer from $SSH_HOST:$REMOTE_TLS_PORT
    the server may not be running the enrollment service."

  case "$response" in
    *'"error"'*|*' 404 '*|*' 400 '*|*' 413 '*)
      local reason
      reason="$(printf '%s' "$response" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
      [ -n "$reason" ] || reason="the server refused it"
      die "enrollment failed: $reason
    invitation codes are single use and expire; ask for a new one" ;;
  esac

  local user password
  user="$(printf '%s' "$response" | sed -n 's/.*"user":"\([^"]*\)".*/\1/p' | head -1)"
  password="$(printf '%s' "$response" | sed -n 's/.*"password":"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$user" ] || die "the server answered, but not with a share name; nothing was changed on this Mac"

  SHARE_NAME="$user"
  SMB_USER="$user"
  ENROLLED_PASSWORD="$password"
  say "enrolled as '$user'"
  note "the server is adding your certificate now"
}

# One mutual-TLS handshake. The caller decides where the output goes.
client_handshake() {
  printf 'Q\n' | sudo "$OPENSSL" s_client -connect "$SSH_HOST:$REMOTE_TLS_PORT" \
    -servername "$SERVER_NAME" -cert "$CONF_DIR/client-cert.pem" \
    -key "$CONF_DIR/client-key.pem" -CAfile "$CONF_DIR/server-ca.pem" \
    -verify 5 -verify_return_error
}

# nginx needs a second to reload before it'll accept the new cert.
wait_until_trusted() {
  step "Waiting to be let in"

  local waited=0
  while [ "$waited" -lt 30 ]; do
    if client_handshake > /dev/null 2>&1; then
      say "the server accepts this Mac"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  warn "the server has not accepted this certificate yet"
  note "it usually takes a couple of seconds; the tunnel is installed either"
  note "way, so try mounting the share again in a minute"
}

# Grabs the server cert off the wire, TOFU.
certificate_from_tls() {
  # openssl exits non-zero here because we send no client certificate
  { "$OPENSSL" s_client -connect "$SSH_HOST:$REMOTE_TLS_PORT" \
      -servername "$SERVER_NAME" -showcerts < /dev/null 2> /dev/null || true; } \
    | awk '/-----BEGIN CERTIFICATE-----/ { if (n++ == 0) p = 1 }
           p { print }
           /-----END CERTIFICATE-----/ { p = 0 }'
}

fetch_server_certificate() {
  step "Fetching the server certificate"

  local cert
  if [ "$NO_SSH" = "1" ]; then
    cert="$(certificate_from_tls)"
    [ -n "$cert" ] || die "nothing answered at $SSH_HOST:$REMOTE_TLS_PORT
    check the address, and that the server is running"
    say "read from $SSH_HOST:$REMOTE_TLS_PORT"
  else
    cert="$(ssh_run "cat $REMOTE_CONF_DIR/server-cert.pem")"
  fi
  case "$cert" in
    *"BEGIN CERTIFICATE"*) ;;
    *) die "server certificate looks wrong" ;;
  esac

  printf '%s\n' "$cert" | sudo tee "$CONF_DIR/server-ca.pem" > /dev/null
  sudo chmod 644 "$CONF_DIR/server-ca.pem"
  say "saved to $CONF_DIR/server-ca.pem"

  if [ "$NO_SSH" = "1" ]; then
    note "fingerprint: $(printf '%s\n' "$cert" | "$OPENSSL" x509 -noout -fingerprint -sha256 | cut -d= -f2)"
    note "worth confirming that with whoever runs the server"
  fi
}

# ----------------------------------------------------------- the tunnel -----

# Drops a plist in place and reloads it. Reads the plist on stdin.
# Second argument: "on" starts it, "off" installs it disabled so launchd also
# skips it at boot, "keep" rewrites the plist without touching whether it runs.
install_plist() {
  local label="$1" mode="${2:-on}" path="$LAUNCHD_DIR/$1.plist" loaded=0
  if sudo launchctl print "system/$label" > /dev/null 2>&1; then loaded=1; fi

  sudo tee "$path" > /dev/null
  sudo chown root:wheel "$path"
  sudo chmod 644 "$path"

  case "$mode" in
    off)
      sudo launchctl bootout "system/$label" 2> /dev/null || true
      sudo launchctl disable "system/$label"
      ;;
    keep)
      # Only reload if it was already running, so a re-run never switches it on
      # or off behind your back.
      if [ "$loaded" = "1" ]; then
        sudo launchctl bootout "system/$label" 2> /dev/null || true
        sudo launchctl bootstrap system "$path"
      fi
      ;;
    *)
      sudo launchctl bootout "system/$label" 2> /dev/null || true
      # In case an earlier run disabled it; bootstrap is refused otherwise.
      sudo launchctl enable "system/$label" 2> /dev/null || true
      sudo launchctl bootstrap system "$path"
      ;;
  esac
}

install_launchd_jobs() {
  step "Installing the local tunnel"

  # Sandbox for the openssl process: outbound to one port, and a handful of
  # files. Everything else is denied.
  sudo tee "$CONF_DIR/tunnel.sb" > /dev/null <<SANDBOX
(version 1)
(deny default)

(allow process-exec (literal "/usr/bin/openssl"))

; Enough to load a dynamically linked binary plus this tunnel's own files.
(allow file-read*
       (literal "/")
       ; /etc is a symlink to private/etc
       (literal "/etc")
       (subpath "/usr/lib")
       (subpath "/usr/bin")
       (subpath "/System/Library")
       (subpath "/System/Volumes")
       (literal "/private/etc/fez/client-cert.pem")
       (literal "/private/etc/fez/server-ca.pem")
       (literal "/private/etc/ssl/openssl.cnf")
       (subpath "/dev/fd")
       (literal "/dev/random")
       (literal "/dev/urandom"))

(allow network-outbound (remote ip "*:$REMOTE_TLS_PORT"))
SANDBOX
  sudo chown root:wheel "$CONF_DIR/tunnel.sb"
  sudo chmod 644 "$CONF_DIR/tunnel.sb"

  # The alias has to exist before launchd can bind 127.0.0.2:445 to it.
  sudo ifconfig lo0 alias "$LOOPBACK_IP" up 2> /dev/null || true

  install_plist "$LOOPBACK_LABEL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LOOPBACK_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <!-- add the 127.0.0.2 alias, then bounce the tunnel in case it failed.
         ordering is not otherwise guaranteed by launchctl. -->
    <string>/sbin/ifconfig lo0 alias $LOOPBACK_IP up
rebind() {
  [ -f "\$1" ] || return 0
  /bin/launchctl bootout "system/\$2" 2&gt;/dev/null || /bin/launchctl unload "\$1" 2&gt;/dev/null
  /bin/launchctl bootstrap system "\$1" 2&gt;/dev/null || /bin/launchctl load "\$1" 2&gt;/dev/null
}
rebind $LAUNCHD_DIR/$TUNNEL_LABEL.plist $TUNNEL_LABEL
rebind $LAUNCHD_DIR/$ADMIN_LABEL.plist $ADMIN_LABEL</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
PLIST

  install_plist "$TUNNEL_LABEL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$TUNNEL_LABEL</string>
  <key>Sockets</key>
  <dict>
    <key>Listener</key>
    <dict>
      <key>SockNodeName</key>
      <string>$LOOPBACK_IP</string>
      <key>SockServiceName</key>
      <string>$LOCAL_PORT</string>
      <key>SockType</key>
      <string>stream</string>
      <key>SockFamily</key>
      <string>IPv4</string>
    </dict>
  </dict>
  <key>inetdCompatibility</key>
  <dict>
    <key>Wait</key>
    <false/>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>exec 4&lt; &lt;(/bin/cat $CONF_DIR/client-key.pem); exec /usr/bin/su -m nobody -c "exec /usr/bin/sandbox-exec -f $CONF_DIR/tunnel.sb $OPENSSL s_client -quiet -verify 5 -verify_return_error -connect $SSH_HOST:$REMOTE_TLS_PORT -servername $SERVER_NAME -cert $CONF_DIR/client-cert.pem -key /dev/fd/4 -CAfile $CONF_DIR/server-ca.pem"</string>
  </array>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
PLIST

  say "listening on $LOOPBACK_IP:$LOCAL_PORT"

  if [ "$MULTIUSER" = "1" ]; then
    # --admin switches it on; otherwise a re-run leaves it as you had it.
    local admin_mode=off
    if [ "$ADMIN" = "1" ]; then
      admin_mode=on
    elif [ -f "$LAUNCHD_DIR/$ADMIN_LABEL.plist" ]; then
      admin_mode=keep
    fi
    install_plist "$ADMIN_LABEL" "$admin_mode" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$ADMIN_LABEL</string>
  <key>Sockets</key>
  <dict>
    <key>Listener</key>
    <dict>
      <key>SockNodeName</key>
      <string>$LOOPBACK_IP</string>
      <key>SockServiceName</key>
      <string>$ADMIN_LOCAL_PORT</string>
      <key>SockType</key>
      <string>stream</string>
      <key>SockFamily</key>
      <string>IPv4</string>
    </dict>
  </dict>
  <key>inetdCompatibility</key>
  <dict>
    <key>Wait</key>
    <false/>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <!-- after reading the key, openssl is run as the nobody user, in a seatbelt sandbox -->
    <string>exec 4&lt; &lt;(/bin/cat $CONF_DIR/client-key.pem); exec /usr/bin/su -m nobody -c "exec /usr/bin/sandbox-exec -f $CONF_DIR/tunnel.sb $OPENSSL s_client -quiet -verify 5 -verify_return_error -connect $SSH_HOST:$REMOTE_TLS_PORT -servername $ADMIN_NAME -cert $CONF_DIR/client-cert.pem -key /dev/fd/4 -CAfile $CONF_DIR/server-ca.pem"</string>
  </array>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
PLIST
    if sudo launchctl print "system/$ADMIN_LABEL" > /dev/null 2>&1; then
      say "admin page running at http://$LOOPBACK_IP:$ADMIN_LOCAL_PORT/"
    else
      say "admin page installed but switched off"
    fi
  fi
}

export_client_cert() {
  step "Putting your certificate on the Desktop"

  local name
  name="$(hostname -s 2> /dev/null || echo mac)"
  CLIENT_CERT_EXPORT="$HOME/Desktop/fez-client-$name.pem"

  sudo cat "$CONF_DIR/client-cert.pem" > "$CLIENT_CERT_EXPORT"
  chmod 644 "$CLIENT_CERT_EXPORT"
  say "$CLIENT_CERT_EXPORT"
  note "this is a public certificate, it is safe to email"
}

# Keeps Time Machine from shipping the system logs. On a slow link this is the
# difference between a 5 MB incremental and a 40 MB one.
exclude_log_churn() {
  step "Excluding system logs from Time Machine"
  local path
  for path in $TM_EXCLUDE; do
    sudo tmutil addexclusion -p "$path" 2> /dev/null || true
    # Ask rather than trust the exit status, which lies on some versions.
    case "$(tmutil isexcluded "$path" 2> /dev/null)" in
      *Excluded*) say "$path" ;;
      *) warn "could not exclude $path (not fatal, backups just carry more)" ;;
    esac
  done
}

# Waits up to $1 seconds for the share to show up in the mount table.
wait_for_mount() {
  local waited=0
  while [ "$waited" -lt "$1" ]; do
    if mount | grep -q "/Volumes/$SHARE_NAME"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

mount_share() {
  local password="$1" url

  # Password in the URL so Finder mounts without prompting
  url="smb://$SMB_USER:$password@$LOOPBACK_IP/$SHARE_NAME"

  if [ "$NO_AUTOMOUNT" = "1" ]; then
    step "Not mounting the share (--no-automount)"
    note "mount it yourself with: open 'smb://$SMB_USER@$LOOPBACK_IP/$SHARE_NAME'"
    return 0
  fi

  step "Mounting the share"
  open "$url" 2> /dev/null || true

  if wait_for_mount 90; then
    say "mounted at /Volumes/$SHARE_NAME"
    return 0
  fi

  # Finder may still have asked, or the tunnel may not be up yet.
  note "not mounted yet. Mount it whenever you like with:"
  note "  open 'smb://$SMB_USER@$LOOPBACK_IP/$SHARE_NAME'"
  note "and the share password is: $password"
}

verify() {
  step "Checking the connection"

  local out="$WORK_DIR/verify.log"
  if client_handshake > "$out" 2>&1; then
    say "mutual TLS to $SSH_HOST:$REMOTE_TLS_PORT works"
  else
    warn "could not complete the TLS handshake to $SSH_HOST:$REMOTE_TLS_PORT"
    note "last lines of the attempt:"
    tail -5 "$out" | sed 's/^/      /'
    note "if the server just started, wait a few seconds and try:"
    note "  nc -z $SSH_HOST $REMOTE_TLS_PORT"
    return 0
  fi

  if nc -z -G 5 "$LOOPBACK_IP" "$LOCAL_PORT" 2> /dev/null; then
    say "local tunnel is accepting connections"
  else
    warn "nothing is listening on $LOOPBACK_IP:$LOCAL_PORT yet"
    note "check $LOG_FILE"
  fi
}

# ---------------------------------------------------------------- finish ----

print_instructions() {
  local smb_password="$1" backup_password="$2"

  cat <<BANNER

${GREEN}${BOLD}Setup is complete.${RESET}

${BOLD}Write this down now.${RESET} It is not stored anywhere you can read it back,
and losing it means losing the backups.

  Backup password     ${BOLD}$backup_password${RESET}
                      (use this when Time Machine asks to encrypt the disk)

  Share            smb://$LOOPBACK_IP/$SHARE_NAME
  Share username   $SMB_USER
  Share password   $smb_password
                   (tick "Remember this password in my keychain" when Finder asks)

${BOLD}Turn on Time Machine${RESET}

  1. Open System Settings, then General, then Time Machine
  2. Click Add Backup Disk and choose $SHARE_NAME
  3. Turn on Encrypt Backup and enter the backup password above
  4. Click Done. The first backup will take a while

BANNER

  if [ "$NO_SSH" != "1" ]; then
    cat <<BANNER
  Server files: $REMOTE_CONF_DIR on $SSH_HOST
  Backups live in $REMOTE_DATA_DIR on the server
BANNER
  fi

  if [ "$MULTIUSER" = "1" ]; then
    local admin_state
    if [ "$ADMIN" = "1" ]; then
      admin_state="  The admin page is running at ${BOLD}http://$LOOPBACK_IP:$ADMIN_LOCAL_PORT/${RESET} on this Mac."
    else
      admin_state="  The admin page is off. Switch it on with:

    sudo launchctl enable system/$ADMIN_LABEL
    sudo launchctl bootstrap system $LAUNCHD_DIR/$ADMIN_LABEL.plist

  then open ${BOLD}http://$LOOPBACK_IP:$ADMIN_LOCAL_PORT/${RESET} on this Mac."
    fi

    cat <<BANNER

${BOLD}Adding other people${RESET}

$admin_state

  It lists the shares and how much each is using, and the Add button creates
  one and gives you an invitation code to send.

  To turn the page off:

    sudo launchctl bootout system/$ADMIN_LABEL
    sudo launchctl disable system/$ADMIN_LABEL

  The user then runs the installer with the enroll code:

    ./install.sh --server $SSH_HOST --enroll <code>
BANNER
  fi

  printf '\n'
}

print_instructions_no_ssh() {
  local backup_password="$1"

  cat <<BANNER

${GREEN}${BOLD}This Mac is ready. One step is left, which the server owner must do.${RESET}

Your certificate is on your Desktop:

  ${BOLD}$CLIENT_CERT_EXPORT${RESET}

${BOLD}Send that file to the server owner${RESET} and ask them to run:

  cat $(basename "$CLIENT_CERT_EXPORT") >> $REMOTE_CONF_DIR/client-certs.pem
  cd $REMOTE_CONF_DIR && docker compose kill -s HUP tls

${BOLD}Then, once they confirm${RESET}

  1. Ask them for the share password
  2. Run: open 'smb://$SMB_USER@$LOOPBACK_IP/$SHARE_NAME'
  3. Enter the share password, tick "Remember this password in my keychain"
  4. System Settings, then General, then Time Machine
  5. Add Backup Disk, choose $SHARE_NAME
  6. Turn on Encrypt Backup with the password below

  Restoring rather than starting fresh? Skip 4 to 6. Open
  <your mac>.sparsebundle inside the share and use Migration Assistant.

${BOLD}Write this down now.${RESET} It is yours alone, the server does not have it,
and losing it means losing this Mac's backups.

  Backup password  ${BOLD}$backup_password${RESET}

  Tunnel logs:     $LOG_FILE

BANNER
}

# --recovery: everything is set up, but you are here to read the backup, not to
# start a new one, so say nothing about turning Time Machine on.
print_instructions_restore() {
  local smb_password="$1"

  cat <<BANNER

${GREEN}${BOLD}Ready to restore.${RESET} The tunnel is installed and the share is mounted.

  Share password   $smb_password

${BOLD}Open the backup${RESET}

  The share is not the backup. Time Machine keeps everything inside a
  sparsebundle, and Migration Assistant will not open one for you.

  1. In Finder, open smb://$LOOPBACK_IP/$SHARE_NAME
  2. Double-click <your mac>.sparsebundle
  3. Enter the backup password if you encrypted it
  4. It mounts as "Time Machine Backups"

${BOLD}Then restore${RESET}

  Open Migration Assistant from the Utilities folder, choose to transfer from
  a Time Machine backup, and pick "Time Machine Backups".

  Time Machine has deliberately not been set up on this mac, so nothing will
  start backing up over your restore. The install itself is complete: when you
  do want this mac backing up, add $SHARE_NAME in System Settings, General,
  Time Machine, and tick Encrypt Backup.

  Tunnel logs: $LOG_FILE

BANNER
}

# ------------------------------------------------------------- uninstall ----

uninstall() {
  printf '%s%sfez uninstaller%s\n\n' "$BOLD" "$GREEN" "$RESET"
  say "This removes, on this Mac only:"
  say ""
  say "  the three launchd jobs and their plists"
  say "  $CONF_DIR, including your client key and certificate"
  say "  the $LOOPBACK_IP alias on lo0"
  say "  $LOG_FILE"
  say ""
  say "Your backups, and the server holding them, are not touched. Without the"
  say "key in $CONF_DIR this Mac can no longer connect, so keep a"
  say "note of your backup password before going further."
  say ""
  printf '    Type yes to continue: '
  local reply
  read -r reply
  [ "$reply" = "yes" ] || die "nothing was changed"

  sudo -v || die "this needs administrator access on this Mac"

  step "Stopping the tunnels"
  local label
  for label in "$TUNNEL_LABEL" "$ADMIN_LABEL" "$LOOPBACK_LABEL"; do
    sudo launchctl bootout "system/$label" 2> /dev/null || true
    # Clear the disabled flag too, or a later reinstall starts out blocked.
    sudo launchctl enable "system/$label" 2> /dev/null || true
    if [ -f "$LAUNCHD_DIR/$label.plist" ]; then
      sudo rm -f "$LAUNCHD_DIR/$label.plist"
      say "removed $label"
    fi
  done

  step "Unmounting shares"
  local point found=0
  for point in $(mount | awk -v m="@$LOOPBACK_IP/" 'index($1, m) { for (i = 1; i <= NF; i++) if ($i == "on") { print $(i + 1); break } }'); do
    if umount "$point" 2> /dev/null || sudo umount "$point" 2> /dev/null; then
      say "unmounted $point"
    else
      warn "could not unmount $point; Time Machine may still be using it"
    fi
    found=1
  done
  [ "$found" = "1" ] || say "nothing mounted from $LOOPBACK_IP"

  step "Removing files"
  sudo rm -rf "$CONF_DIR"
  sudo rm -f "$LOG_FILE"
  say "$CONF_DIR and $LOG_FILE"

  step "Removing the loopback alias"
  if /sbin/ifconfig lo0 2> /dev/null | grep -q "$LOOPBACK_IP"; then
    sudo /sbin/ifconfig lo0 -alias "$LOOPBACK_IP" 2> /dev/null || true
    say "removed $LOOPBACK_IP from lo0"
  else
    say "$LOOPBACK_IP was not there"
  fi

  # Best effort: macOS may have saved the share password when it mounted.
  local n=0
  while [ "$n" -lt 10 ] && security delete-internet-password -s "$LOOPBACK_IP" > /dev/null 2>&1; do
    n=$((n + 1))
  done
  [ "$n" = "0" ] || say "removed $n saved password(s) from your keychain"

  cat <<BANNER

${GREEN}${BOLD}Done.${RESET} This Mac is back to how it was.

${BOLD}Two things this did not do${RESET}

  Time Machine may still list the backup disk. Remove it in System Settings,
  General, Time Machine, or it will keep trying and failing.

  The server still trusts this Mac's certificate. If you are finished with it,
  revoke it on the admin page, or remove its block from
  $REMOTE_CONF_DIR/client-certs.pem and reload with:

    cd $REMOTE_CONF_DIR && docker compose kill -s HUP tls

BANNER
}

# --recovery swaps the closing instructions and changes nothing else.
finish() {
  exclude_log_churn

  if [ "$RECOVERY" = "1" ]; then
    print_instructions_restore "$1"
  else
    print_instructions "$1" "$2"
  fi
}

# ------------------------------------------------------------------ main ----

main() {
  parse_args "$@"

  if [ "$LOCAL" = "1" ]; then
    [ "$(id -u)" = "0" ] || die "--local sets this machine up, so run it as root"
    upload_installer
    setup_server
    cat <<BANNER

${GREEN}${BOLD}Server set up at $SSH_HOST:$REMOTE_TLS_PORT.${RESET}

nginx will not start until it trusts at least one client, so this is not
finished yet. On each Mac:

    ./install.sh $SSH_HOST --no-ssh

then add the certificate it leaves on the Desktop and start the containers:

    cat fez-client-*.pem >> $REMOTE_CONF_DIR/client-certs.pem
    cd $REMOTE_CONF_DIR && docker compose up -d

BANNER
    return 0
  fi

  preflight

  if [ "$UNINSTALL" = "1" ]; then
    uninstall
    return 0
  fi

  printf '%s%sfez installer %s%s\n' "$BOLD" "$GREEN" "$FEZ_VERSION" "$RESET"
  if [ -n "$ENROLL_CODE" ]; then
    note "server: $SSH_HOST:$REMOTE_TLS_PORT (joining with an invitation)"
  elif [ "$NO_SSH" = "1" ]; then
    note "server: $SSH_HOST:$REMOTE_TLS_PORT (not logging in, --no-ssh)"
  else
    note "server: $SSH_USER@$SSH_HOST:$SSH_PORT"
  fi

  # Nothing below this point is wanted: no certificate, no plists, no mount,
  # and so no sudo either.
  if [ "$SERVER_ONLY" = "1" ]; then
    ssh_connect
    upload_installer
    setup_server
    cat <<BANNER

${GREEN}${BOLD}Server updated.${RESET} Nothing on this mac was changed.

  Containers were recreated where their configuration changed. Certificates,
  share passwords and the backups in $REMOTE_DATA_DIR were left alone.

BANNER
    return 0
  fi

  step "Checking for administrator access"
  say "If you are asked for a password here, it is the login password for this"
  say "Mac, the one you use to unlock it. Not your server password."
  note "needed to install the tunnel into /etc and /Library/LaunchDaemons"
  sudo -v || die "this installer needs administrator access on this Mac"
  say "ok"

  local backup_password
  backup_password="$(uuidgen)"

  if [ -n "$ENROLL_CODE" ]; then
    generate_client_identity
    fetch_server_certificate
    submit_enrollment
    install_launchd_jobs
    wait_until_trusted
    mount_share "$ENROLLED_PASSWORD"
    finish "$ENROLLED_PASSWORD" "$backup_password"
    return 0
  fi

  if [ "$NO_SSH" = "1" ]; then
    generate_client_identity
    fetch_server_certificate
    install_launchd_jobs
    export_client_cert
    exclude_log_churn
    print_instructions_no_ssh "$backup_password"
    return 0
  fi

  ssh_connect
  generate_client_identity
  register_client_cert
  upload_installer
  setup_server
  fetch_server_certificate
  install_launchd_jobs

  local smb_password
  smb_password="$(fetch_share_password)"

  verify
  mount_share "$smb_password"
  finish "$smb_password" "$backup_password"
}

main "$@"
