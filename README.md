# omnifocus-private

Private OmniFocus sync server on Ubuntu or OpenBSD, reachable only over Tailscale.

Full guide: [linkedin-article/README.md](linkedin-article/README.md)

## Requirements

- Tailscale admin console > DNS: **MagicDNS** and **HTTPS Certificates** on
- Server on your tailnet with SSH and `sudo` (Ubuntu) or `doas` (OpenBSD)

## Install

```bash
./Ubuntu/install.sh <host> [username]
./OpenBSD/install.sh <host> [username]
```

## OmniFocus

**Settings > Sync > WebDAV Server**, then enter `https://<host>.<tailnet>.ts.net/omnifocus/` and your credentials.

## Backup

SSH into the server and run `omnifocus-backup`. Snapshots go to `/var/backups/omnifocus/`.

## Author

Dmitry Kalashnikov
