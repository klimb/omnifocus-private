#!/bin/ksh
# Configure this OpenBSD host as an OmniFocus WebDAV sync server, published on the tailnet via `tailscale serve`.
# Usage (as root on the target host): setup-remote.sh [omnifocus-username]
# Author: Dmitry Kalashnikov
# Note: points the apache2 rc.d service at its own config file; don't use on a host already running apache2.
set -euo pipefail

DATA_DIR=/var/webdav
LOCK_DIR=/var/db/apache2-dav
LOG_DIR=/var/log/apache2
HTPASSWD=/etc/apache2/webdav.htpasswd
CONF=/etc/apache2/omnifocus.conf
MODS=/usr/local/lib/apache2
PORT=8080

log() { print -r -- "==> $*"; }
warn() { print -ru2 -- "warning: $*"; }
die() { print -ru2 -- "error: $*"; exit 1; }

[[ $(uname -s) == OpenBSD ]] || die "this script is for OpenBSD"
[[ $(id -u) -eq 0 ]] || die "must be run as root"
command -v tailscale >/dev/null ||
    die "tailscale is not installed. Run: pkg_add tailscale && rcctl enable tailscaled && rcctl start tailscaled && tailscale up"

# Packages
log "Installing apache-httpd, jq and curl"
pkg_add -I apache-httpd jq curl >/dev/null

# Tailscale preflight
ts_json=$(tailscale status --json) || die "tailscale is not running or not logged in"
dns_name=$(print -r -- "$ts_json" | jq -r '.Self.DNSName // "" | rtrimstr(".")')
ts_ip=$(print -r -- "$ts_json" | jq -r '.Self.TailscaleIPs[0] // ""')
cert_domains=$(print -r -- "$ts_json" | jq -r '.CertDomains // [] | length')

[[ -n $dns_name ]] || die "MagicDNS is disabled. Enable it at https://login.tailscale.com/admin/dns"
[[ $cert_domains -gt 0 ]] || die "HTTPS certificates are disabled. Enable them at https://login.tailscale.com/admin/dns"
url="https://$dns_name/omnifocus/"

# Credentials
of_user=${1:-}
if [[ -z $of_user ]]; then
    default_user=${DOAS_USER:-omnifocus}
    read -r of_user?"OmniFocus sync username [$default_user]: "
    of_user=${of_user:-$default_user}
fi
case $of_user in
'' | *[!A-Za-z0-9._-]*) die "username may only contain letters, digits, '.', '_' and '-'" ;;
esac

trap 'stty echo 2>/dev/null' EXIT INT TERM
stty -echo
IFS= read -r of_pass?"OmniFocus sync password for '$of_user': "; echo
IFS= read -r of_pass2?"Confirm password: "; echo
stty echo
[[ -n $of_pass ]] || die "password must not be empty"
[[ $of_pass == "$of_pass2" ]] || die "passwords do not match"
unset of_pass2

# Storage and credentials
log "Preparing $DATA_DIR/omnifocus"
mkdir -p "$DATA_DIR/omnifocus" "$LOCK_DIR" "$LOG_DIR"
chown -R www:www "$DATA_DIR" "$LOCK_DIR"
chmod 750 "$DATA_DIR" "$DATA_DIR/omnifocus" "$LOCK_DIR"

log "Storing credentials for '$of_user'"
touch "$HTPASSWD"
chown root:www "$HTPASSWD"
chmod 640 "$HTPASSWD"
# print is a ksh builtin, so the password never appears in a process argument list
print -r -- "$of_pass" | /usr/local/bin/htpasswd2 -i -B "$HTPASSWD" "$of_user" 2>/dev/null

# Apache: localhost only
log "Writing $CONF"
cat >"$CONF" <<EOF
ServerRoot "/var/www"
Listen 127.0.0.1:$PORT
PidFile "/var/run/httpd2-omnifocus.pid"

LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule unixd_module       $MODS/mod_unixd.so
LoadModule authn_core_module  $MODS/mod_authn_core.so
LoadModule authn_file_module  $MODS/mod_authn_file.so
LoadModule authz_core_module  $MODS/mod_authz_core.so
LoadModule authz_user_module  $MODS/mod_authz_user.so
LoadModule auth_basic_module  $MODS/mod_auth_basic.so
LoadModule dav_module         $MODS/mod_dav.so
LoadModule dav_fs_module      $MODS/mod_dav_fs.so
LoadModule log_config_module  $MODS/mod_log_config.so

User www
Group www

# TLS terminates at tailscale serve; advertise the public scheme/port so MOVE/COPY Destination headers validate
ServerName https://$dns_name:443
UseCanonicalName On
ServerTokens Prod
TraceEnable Off

ErrorLog "$LOG_DIR/omnifocus_error.log"
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog "$LOG_DIR/omnifocus_access.log" common

DavLockDB "$LOCK_DIR/DavLock"
DocumentRoot "$DATA_DIR"

<Directory />
    AllowOverride None
    Require all denied
</Directory>

<Directory "$DATA_DIR">
    DAV On
    Options -Indexes
    AllowOverride None
    AuthType Basic
    AuthName "OmniFocus"
    AuthUserFile $HTPASSWD
    Require valid-user
</Directory>
EOF

/usr/local/sbin/httpd2 -t -f "$CONF" 2>/dev/null || { /usr/local/sbin/httpd2 -t -f "$CONF"; die "Apache config test failed"; }
rcctl enable apache2
rcctl set apache2 flags -f "$CONF"
rcctl restart apache2 >/dev/null

# Tailscale serve
log "Publishing via tailscale serve"
tailscale serve --bg "$PORT" >/dev/null

# Verify
log "Verifying $url"
# --resolve avoids depending on MagicDNS being wired into this host's resolv.conf
resolve="$dns_name:443:$ts_ip"
anon=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$resolve" -X PROPFIND -H 'Depth: 0' "$url" || true)
esc=$(print -r -- "$of_pass" | sed 's/[\\"]/\\&/g')
# Credentials go through curl's stdin config so they never appear in argv
auth=$(print -r -- "user = \"$of_user:$esc\"" |
    curl -s -o /dev/null -w '%{http_code}' -K - --resolve "$resolve" -X PROPFIND -H 'Depth: 0' "$url" || true)
unset of_pass esc

if [[ $anon == 401 && $auth == 207 ]]; then
    log "WebDAV is up (anonymous: 401, authenticated: 207)"
else
    warn "unexpected responses (anonymous: $anon, authenticated: $auth); check $LOG_DIR/omnifocus_error.log"
fi

cat <<EOF

Done. In OmniFocus on each device:
  Settings > Sync > Sync With: WebDAV Server
  Server:   $url
  Username: $of_user
On the first device choose to replace the server database.
EOF
