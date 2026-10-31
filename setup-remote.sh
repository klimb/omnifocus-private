#!/usr/bin/env bash
# Configure this host as an OmniFocus WebDAV sync server, published on the tailnet via `tailscale serve`.
# Usage (as root on the target host): setup-remote.sh [omnifocus-username]
# Author: Dmitry Kalashnikov
set -euo pipefail

DATA_DIR=/srv/webdav
HTPASSWD=/etc/apache2/webdav.htpasswd
SITE=/etc/apache2/sites-available/omnifocus.conf
PORTS_CONF=/etc/apache2/ports.conf
PORT=8080

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must be run as root"
command -v tailscale >/dev/null || die "tailscale is not installed on this host"
command -v python3 >/dev/null || die "python3 is required"

# Tailscale preflight
ts_json=$(tailscale status --json) || die "tailscale is not running or not logged in"
read -r dns_name cert_ok < <(python3 -c '
import json, sys
s = json.load(sys.stdin)
print(s["Self"].get("DNSName", "").rstrip(".") or "-", "yes" if s.get("CertDomains") else "no")
' <<<"$ts_json")

[[ $dns_name != "-" ]] || die "MagicDNS is disabled. Enable it at https://login.tailscale.com/admin/dns"
[[ $cert_ok == yes ]] || die "HTTPS certificates are disabled. Enable them at https://login.tailscale.com/admin/dns"
url="https://$dns_name/omnifocus/"

# Credentials
of_user=${1:-}
if [[ -z $of_user ]]; then
    default_user=${SUDO_USER:-omnifocus}
    read -rp "OmniFocus sync username [$default_user]: " of_user
    of_user=${of_user:-$default_user}
fi
[[ $of_user =~ ^[A-Za-z0-9._-]+$ ]] || die "username may only contain letters, digits, '.', '_' and '-'"

IFS= read -rsp "OmniFocus sync password for '$of_user': " of_pass; echo
[[ -n $of_pass ]] || die "password must not be empty"
IFS= read -rsp "Confirm password: " of_pass2; echo
[[ $of_pass == "$of_pass2" ]] || die "passwords do not match"
unset of_pass2

# Packages
log "Installing Apache"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apache2 apache2-utils curl >/dev/null
a2enmod -q dav dav_fs auth_basic >/dev/null

# Apache: localhost only
log "Binding Apache to 127.0.0.1:$PORT"
sed -i -E 's/^([[:space:]]*Listen[[:space:]]+80)[[:space:]]*$/# \1  # disabled by omnifocus-private/' "$PORTS_CONF"
grep -qxF "Listen 127.0.0.1:$PORT" "$PORTS_CONF" || echo "Listen 127.0.0.1:$PORT" >>"$PORTS_CONF"

# Storage and credentials
log "Preparing $DATA_DIR/omnifocus"
mkdir -p "$DATA_DIR/omnifocus"
chown -R www-data:www-data "$DATA_DIR"
chmod 750 "$DATA_DIR" "$DATA_DIR/omnifocus"

log "Storing credentials for '$of_user'"
touch "$HTPASSWD"
chown root:www-data "$HTPASSWD"
chmod 640 "$HTPASSWD"
printf '%s\n' "$of_pass" | htpasswd -i -B "$HTPASSWD" "$of_user" 2>/dev/null

# Site
log "Writing $SITE"
cat >"$SITE" <<EOF
<VirtualHost 127.0.0.1:$PORT>
    # TLS terminates at tailscale serve; advertise the public scheme/port so MOVE/COPY Destination headers validate
    ServerName https://$dns_name:443
    UseCanonicalName On

    DocumentRoot $DATA_DIR
    <Directory $DATA_DIR>
        DAV On
        Options -Indexes
        AllowOverride None
        AuthType Basic
        AuthName "OmniFocus"
        AuthUserFile $HTPASSWD
        Require valid-user
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/omnifocus_error.log
    CustomLog \${APACHE_LOG_DIR}/omnifocus_access.log combined
</VirtualHost>
EOF

a2dissite -q 000-default >/dev/null 2>&1 || true
a2ensite -q omnifocus >/dev/null
apachectl configtest 2>/dev/null || { apachectl configtest; die "Apache config test failed"; }
systemctl enable -q apache2
systemctl restart apache2

# Tailscale serve
log "Publishing via tailscale serve"
tailscale serve --bg "$PORT" >/dev/null

# Verify
log "Verifying $url"
anon=$(curl -s -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$url" || true)
esc=${of_pass//\\/\\\\}
esc=${esc//\"/\\\"}
# Credentials go through curl's stdin config so they never appear in argv
auth=$(printf 'user = "%s:%s"\n' "$of_user" "$esc" |
    curl -s -o /dev/null -w '%{http_code}' -K - -X PROPFIND -H 'Depth: 0' "$url" || true)
unset of_pass esc

if [[ $anon == 401 && $auth == 207 ]]; then
    log "WebDAV is up (anonymous: 401, authenticated: 207)"
else
    warn "unexpected responses (anonymous: $anon, authenticated: $auth); check /var/log/apache2/omnifocus_error.log"
fi

cat <<EOF

Done. In OmniFocus on each device:
  Settings > Sync > Sync With: WebDAV Server
  Server:   $url
  Username: $of_user
On the first device choose to replace the server database.
EOF
