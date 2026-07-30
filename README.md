## Architecture

```
                    Internet
                       │
                       │  (outbound)
            ┌──────────┴──────────┐
            │      tailnet        │
            └──────────┬──────────┘
                       │
╔══════════════════════╪═══════════════════════════════════════════════╗
║  DMZ  172.28.10.0/24 │                                               ║
║   ┌──────────────┐   │   ┌──────────────┐      ┌──────────────────┐  ║
║   │  tailscale   │───┘   │    nginx     │      │  AdGuard Home    │  ║
║   │ subnet router│──────▶│  TLS :80/443 │      │  DNS :53        │  ║
║   │ + serve      │       └──────┬───────┘      │  panel :3000     │  ║
║   └──────────────┘              │              └──────────────────┘  ║
╚═════════════════════════════════╪════════════════════════════════════╝
                                  │  
╔═════════════════════════════════╪════════════════════════════════════╗
║  PRIVATE  172.28.20.0/24        │                                    ║
║        ┌──────────┬─────────────┼──────────────┬──────────────┐      ║
║        ▼          ▼             ▼              ▼              ▼      ║
║  ┌──────────┐ ┌────────┐ ┌────────────┐ ┌───────────┐ ┌───────────┐  ║
║  │ authentik│ │ grafana│ │ prometheus │ │ nextcloud │ │open-webui │  ║
║  │  server  │ │        │ │ node-exp.  │ │           │ │     │     │  ║
║  │  worker  │ │        │ │            │ │           │ │     ▼     │  ║
║  └────┬─────┘ └────────┘ └────────────┘ └─────┬─────┘ │  ollama   │  ║
╚═══════╪═══════════════════════════════════════╪═══════╧══════════════╝
        │                                       │
╔═══════╪═══════════════════════════════════════╪══════════════════════╗
║  BACKEND  172.28.30.0/24   internal: true                            ║
║       ▼                                       ▼                      ║
║  ┌─────────────┐ ┌──────────────┐  ┌─────────────┐ ┌──────────────┐ ║
║  │ authentik-db│ │authentik-redis│  │ nextcloud-db│ │nextcloud-redis│║
║  │  postgres   │ │    redis      │  │   mariadb   │ │    redis     │ ║
║  └─────────────┘ └──────────────┘  └─────────────┘ └──────────────┘ ║
╚══════════════════════════════════════════════════════════════════════╝
```


### Services

| Address | Service |
|---|---|
| `https://auth.$DOMAIN` | authentik |
| `https://grafana.$DOMAIN` | Grafana |
| `https://prometheus.$DOMAIN` | Prometheus |
| `https://cloud.$DOMAIN` | Nextcloud |
| `https://chat.$DOMAIN` | Open WebUI → ollama |
| `https://chat.$DOMAIN/ollama/` | raw ollama API |
| `https://dns.$DOMAIN` | AdGuard Home |
| `$HOST:53` | AdGuard DNS |

---

## Quickstart

```bash
cp .env.example .env && chmod 600 .env
docker compose up -d
```

---

## On first service run

- **authentik** - open `https://auth.$DOMAIN/if/flow/initial-setup/` to create the `akadmin` account.
- **AdGuard Home** - open `https://dns.$DOMAIN` and run through the setup wizard to set admin credentials.
- **Grafana** - log in with `admin` / `$GRAFANA_ADMIN_PASSWORD`.
- **Nextcloud** - log in with `$NEXTCLOUD_ADMIN_USER` / `$NEXTCLOUD_ADMIN_PASSWORD`.

---

## Domain and certificates

`$DOMAIN` in `.env` gets substituted into the nginx vhosts at startup. By default it's
`home.arpa`. That's reserved for home networks, so it never appears on the public internet.
It's served over a self-signed certificate, made with `openssl` or `mkcert`. You import that
certificate once per client.

`tailscale serve` doesn't replace this. Its free certificate only covers the single tailnet
landing-page name. The actual services sit behind nginx, reached over the subnet route or
straight off the LAN. They still need their own certificate.

You can point `$DOMAIN` at a real domain instead and use Let's Encrypt with DNS-01. That's
only worth it if importing a self-signed cert on every device feels like too much hassle.
The DNS records only need to exist in your private DNS, so nothing gets exposed to the
internet either way.

nginx reads `homelab.crt` and `homelab.key` from `nginx/certs/`. AdGuard rewrites `*.home.arpa` to the host's LAN IP for local clients.
Tailnet clients get the same rewrite through a custom nameserver in the Tailscale admin
console.

---

## Backups

`backup/backup.sh` backs up the whole stack with [restic](https://restic.net/), into a repo
on the second disk, once a day via a systemd timer.

Before anything runs, Nextcloud goes into maintenance mode.
Then it dumps authentik's postgres with `pg_dump` and Nextcloud's mariadb with
`--single-transaction`, drops `.env` next to the dumps, and lets restic snapshot everything.

It runs on the host instead of in a container, because a proper dump needs `exec` access into
the database containers.

What actually gets backed up: Nextcloud's and authentik's data and dumps, `.env` (without
`AUTHENTIK_SECRET_KEY` the authentik dump is useless), a handful of small volumes
(`authentik-media`, `adguard-conf`, `grafana-data`, `openwebui-data`), and the TLS cert.
Redis volumes are skipped, same with `ollama-models`, `adguard-work` and `prometheus-data`. The raw db volumes are skipped too, since the dumps already cover
that. `tailscale-state` isn't backed up either: node identity doesn't carry over to a new
machine anyway.

Runs happen at 03:00, Monday to Saturday. Sunday's run also throws in a
`restic check --read-data-subset=5%` to catch bit rot early.

```bash
sudo ./backup/backup.sh           # backup now
./backup/restore.sh list          # snapshots
./backup/restore.sh fetch <id>    # unpack into backup/restored/ — never overwrites live data
```

