# omnifocus-private

Turns an Ubuntu host on your Tailscale network into a private OmniFocus WebDAV sync server.

- Apache `mod_dav` listening on `127.0.0.1:8080` only
- Published as `https://<host>.<tailnet>.ts.net/omnifocus/` with `tailscale serve` (valid, auto-renewed cert)
- Basic auth (bcrypt) in `/etc/apache2/webdav.htpasswd`, data in `/srv/webdav/omnifocus`

## Prerequisites

- Tailscale admin console > DNS: **MagicDNS** and **HTTPS Certificates** enabled
- Target host: Ubuntu, Tailscale logged in, your SSH user has sudo

## Usage

```bash
./Ubuntu/install.sh drive             # prompts for username and password on the host
./Ubuntu/install.sh drive <username>  # username given, password still prompted
```

The password is typed into the remote TTY and passed to `htpasswd` via stdin; it never appears in
process arguments or on disk in plaintext. Re-running is safe and updates the password.

## Server

- **Location:** `https://<host>.<tailnet>.ts.net/omnifocus/`

## Configuring OmniFocus

Devices must be connected to Tailscale (on iOS, enable VPN On Demand in the Tailscale app).

1. On the primary Mac: **OmniFocus > Settings > Sync**, set **Sync with** to **WebDAV Server**, enter the
   location above and your credentials, then **Sync**. The empty server receives your local database.
2. On every other device: same settings, and when asked, use the server's database (replace local).

To change the password, re-run `./Ubuntu/install.sh drive <username>` first, then update it in OmniFocus on the
primary device, then the others.

## Backups

Back up `/srv/webdav` on the host (restic, borg, rsync). The OmniFocus database is encrypted with your
sync password.
