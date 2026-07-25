# media-stack

Self-hosted media automation stack. This repo holds the **text config** —
`docker-compose.yml`, dnsmasq, qbit_manage. Everything else (app databases,
metadata, secrets) lives in the config tarball described in
[Backups](#backups).

A full rebuild needs **three** things:

| Piece | Where it lives |
|---|---|
| Compose + text config | this repo |
| App databases + `.env` | `media-config-YYYY-MM-DD.tar.gz` |
| Media files | the `/data` disk |

Repo alone gives you a working but empty stack.

---

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │  gluetun (WireGuard → AirVPN NL)    │
                    │  network namespace shared by:       │
  LAN ──────────────┤   qbittorrent  prowlarr  radarr     │
                    │   sonarr  lidarr  bazarr            │
                    │   flaresolverr  qbit-manage         │
                    └─────────────────────────────────────┘

                    ┌─────────────────────────────────────┐
                    │  bridge network                     │
  LAN ──────────────┤   jellyfin  navidrome  jellyseerr   │
                    │   npm  dnsmasq                      │
                    └─────────────────────────────────────┘

                    ┌─────────────────────────────────────┐
  LAN ──────────────┤  plex (network_mode: host)          │
                    └─────────────────────────────────────┘
```

**Why the namespace split.** Anything that talks to indexers or peers runs
inside gluetun's network namespace (`network_mode: "service:gluetun"`). They
have no network interface of their own — only gluetun's `tun0`. If the tunnel
drops, they have no route out. That's a structural killswitch, not a firewall
rule.

Consequences to remember:

- Those containers address each other over **`localhost`**, not container
  names. Radarr's download client is `localhost:8080`. Prowlarr's app URLs are
  `http://localhost:7878` etc.
- Their ports are published on the **gluetun** service, not on themselves.
  Adding a port for one of them means editing gluetun's `ports:` list.
- Never recreate gluetun alone. Its container ID is what the others attach to,
  so a solo recreate orphans them. Always
  `docker compose up -d --force-recreate`.

**Why one `/data` mount.** Hardlinks only work within a single filesystem. Every
container mounts `/data` whole — never `/data/media` and `/data/torrents`
separately — so Sonarr/Radarr can hardlink from torrents into the library
instead of copying. That's what lets qbit_manage delete finished public
torrents without touching the library.

---

## Storage layout

```
/data                          ← single ext4 mount (its own disk)
├── torrents/
│   ├── movies/  tv/  anime/  music/  books/
└── media/
    ├── movies/  tv/  anime/  music/  books/

/opt/media-stack               ← this repo
├── docker-compose.yml
├── .env                       ← NOT in git; in the tarball
└── config/
    ├── radarr/ sonarr/ lidarr/ prowlarr/ bazarr/
    ├── jellyfin/ plex/ navidrome/ jellyseerr/
    ├── qbittorrent/ gluetun/ npm/
    ├── dnsmasq/dnsmasq.conf   ← in git
    └── qbit-manage/config.yml ← in git
```

Everything under `config/` except those two files is app state — SQLite
databases, artwork caches, metadata. Binary and churny, so it goes in the
tarball rather than git.

---

## Rebuild from scratch

### 1. Host

Ubuntu Server 22.04 LTS. Under Hyper-V: Generation 2, **Secure Boot disabled**,
**External virtual switch** so the VM gets a real LAN IP rather than sitting
behind host NAT.

Two disks: OS, and a separate one for `/data`.

### 2. Static IP

`/etc/netplan/00-installer-config.yaml` — IPv6 is disabled deliberately; on a
Hyper-V wireless bridge it half-works, so apps try IPv6 first and wait for a
timeout before falling back.

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      dhcp6: no
      accept-ra: no
      link-local: [ ]
      addresses: [192.168.1.16/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [1.1.1.1, 9.9.9.9]
```

```bash
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan try
```

Also add a DHCP reservation on the router for the VM's MAC, so nothing else is
ever offered that address. Set a **static MAC** in Hyper-V first (Settings →
Network Adapter → Advanced Features), otherwise the reservation is orphaned if
the VM is ever recreated.

Do not point the VM's resolver at its own dnsmasq container — it starts after
networking, so boot-time DNS would fail.

### 3. The `/data` disk

```bash
sudo mkfs.ext4 -L media /dev/sdb
sudo blkid /dev/sdb          # note the UUID
sudo mkdir /data
```

`/etc/fstab` — `nofail` matters, so the VM still boots if the disk is missing:

```
UUID=<uuid>  /data  ext4  defaults,nofail  0  2
```

```bash
sudo mount -a
sudo mkdir -p /data/{torrents,media}/{movies,tv,anime,music,books}
sudo chown -R 1000:1000 /data
```

### 4. Docker

From Docker's official repo — not snap, not `apt install docker.io`.

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER   # log out and back in
```

### 5. Restore

```bash
sudo mkdir -p /opt/media-stack
sudo chown $USER:$USER /opt/media-stack
git clone git@github.com:USER/media-stack.git /opt/media-stack
cd /opt/media-stack
tar xzf ~/media-config-YYYY-MM-DD.tar.gz    # restores config/ and .env
docker compose up -d
```

If you have no tarball, copy `.env.example` to `.env`, fill it in, and
configure each app by hand — see [First-time configuration](#first-time-configuration).

### 6. Verify

```bash
docker compose ps                          # all up, gluetun healthy
docker exec qbittorrent curl -s ifconfig.io   # VPN exit IP
curl -s ifconfig.io                        # your real IP — must differ
```

If those two match, the tunnel isn't working. Stop and fix before downloading
anything.

---

## `.env`

Never committed. Values live in the tarball.

```
PUID=1000
PGID=1000
TZ=Europe/Paris
DATA=/data
CONFIG=/opt/media-stack/config

WIREGUARD_PRIVATE_KEY=
WIREGUARD_ADDRESSES=
WIREGUARD_PRESHARED_KEY=
SERVER_COUNTRIES=Netherlands
VPN_PORT=

QBIT_USER=
QBIT_PASS=
```

`SERVER_COUNTRIES` deliberately isn't France. `VPN_PORT` is the AirVPN
forwarded port for peer connectivity — it has nothing to do with remote access
to the stack.

---

## Ports

| Service | Port | Published on |
|---|---|---|
| qBittorrent | 8080 | gluetun |
| Prowlarr | 9696 | gluetun |
| Radarr | 7878 | gluetun |
| Sonarr | 8989 | gluetun |
| Lidarr | 8686 | gluetun |
| Bazarr | 6767 | gluetun |
| FlareSolverr | 8191 | gluetun (internal) |
| Jellyfin | 8096 | itself |
| Jellyseerr | 5055 | itself |
| Navidrome | 4533 | itself |
| Plex | 32400 | host network |
| NPM | 80 / 81 / 443 | itself |
| dnsmasq | 53 | itself |

---

## First-time configuration

Only needed if rebuilding without a config tarball.

### qBittorrent

Default login `admin` / temp password in `docker logs qbittorrent`.

Two things that bite:

- Connection reset in the browser → set `WebUI\HostHeaderValidation=false` in
  `config/qbittorrent/qBittorrent/qBittorrent.conf`. **Stop the container
  first**; it rewrites the file on exit.
- Default save path must be `/data/torrents/`.

Categories, each with its save path:

| Category | Save path |
|---|---|
| `radarr` | `/data/torrents/movies` |
| `tv-sonarr` | `/data/torrents/tv` |
| `anime-sonarr` | `/data/torrents/anime` |
| `lidarr` | `/data/torrents/music` |

Create these before pointing the *arr apps at them — a missing category makes
qBittorrent reject the add with **409 Conflict**, and the *arr app just reports
a failed grab.

### Prowlarr

Add indexers, then Settings → Apps → add each *arr:

- Prowlarr Server: `http://localhost:9696`
- App Server: `http://localhost:7878` / `:8989` / `:8686`
- API key from each app's Settings → General

Then **Sync App Indexers**. FlareSolverr goes in at `http://localhost:8191`
for Cloudflare-protected indexers.

Adding an indexer later does **not** retroactively search past failures. Go to
Sonarr → Wanted → Missing → Search to retry with the new indexer.

### Radarr / Sonarr / Lidarr

- Media Management → **Use Hardlinks instead of Copy** ON
- Root folders: `/data/media/movies`, `/data/media/tv`, `/data/media/anime`,
  `/data/media/music`
- Download client: qBittorrent at `localhost:8080`, matching category
- Sonarr min free space: 10000 MB
- Jellyfin connection: Settings → Connect → Emby/Jellyfin →
  `192.168.1.16:8096`, API key from Jellyfin, **Update Library** ON

**Anime: set Series Type to `Anime`.** Sonarr defaults every series to
`Standard`, and anime releases use absolute numbering (`EP1170`) that Standard
can't parse. Symptom: Prowlarr's own search finds releases, Sonarr's finds
nothing. Fix on the series → Edit → Series Type → Anime.

Lidarr's `Standard` metadata profile is studio albums only — no singles, EPs,
live, or compilations. Widen it per-artist if needed. Music releases are often
tagged `Unknown` quality, which the `Standard` quality profile rejects; use
`Any` for music.

### Jellyfin

- Libraries point at `/data/media/{movies,tv,anime,music}`, mounted `:ro`
- Scheduled library scan: **1 hour**. Real-time monitoring and the Sonarr
  notification both rely on inotify, which hardlinks don't reliably fire — so
  the scheduled scan is what actually catches new content.
- Audio: preferred language English, **"Play default track regardless of
  language" UNCHECKED** (otherwise dual-audio files default to the wrong track)

Because the media mount is read-only, **deleting from Jellyfin fails by
design**. Delete in Sonarr/Radarr instead, so their databases stay in sync and
they don't immediately re-download what you removed.

### Bazarr

Languages French + English. Connect to Sonarr/Radarr on `localhost`.

TRaSH scoring: Sonarr minimum score 90, Radarr 80; sync thresholds Series 96,
Movies 86.

### Navidrome

`ND_MUSICFOLDER=/data/media/music`, `ND_SCANSCHEDULE=1h`. Its `/data` volume is
config, and the music mount is `:ro`.

No push notification from Lidarr exists, so new music appears on the hourly
scan.

iPhone: **Amperfy** or **play:Sub**, Subsonic server `http://192.168.1.16:4533`.
Offline download actually works here, unlike Jellyfin video on iOS.

### Jellyseerr

Setup wizard → Jellyfin:

- URL `192.168.1.16`, port `8096`, SSL off
- **URL Base must be EMPTY.** A bare `/` fails validation; `/ ` with a trailing
  space produces a 404 on the auth endpoint that looks like a version
  incompatibility but isn't.

Services → Radarr and Sonarr at `192.168.1.16:7878` / `:8989`.

- **Tag Requests OFF.** It tries to create a Radarr tag, gets a **400**, and the
  whole request fails. Requester identity is tracked in Jellyseerr's own
  Requests page regardless.
- Sonarr entry has separate anime fields — set **Anime Series Type: Anime** and
  **Anime Root Folder: `/data/media/anime`**, so anime requests arrive with the
  right series type instead of defaulting to Standard.

### qbit_manage

Seeds private trackers indefinitely; deletes public torrents once downloaded.
The library survives via hardlink.

```yaml
environment:
  - QBT_RUN=false        # true means run-once-and-exit
  - QBT_SCHEDULE=30      # minutes
restart: on-failure:2
```

**`QBT_RUN=true` plus `restart: unless-stopped` is an infinite loop** — the
container exits, Docker restarts it, and cleanup runs continuously. It will
delete downloads before Lidarr has imported them. The log line to check is
`Run Mode: Script will exit after completion` versus
`30 minutes until the next run`.

`config/qbit-manage/config.yml` notes:

- `directory.root_dir: /data/torrents` is required even for tagging
- `recyclebin.enabled: false` — enabling it tries to create `/data/.RecycleBin`
  and fails on permissions
- `min_seeding_time` is rejected alongside `max_ratio: -1`; drop it, since
  `cleanup: false` already protects private torrents
- credentials via `!ENV QBIT_USER` / `!ENV QBIT_PASS`, passed through from
  compose

Set `dry_run: true`, confirm the tagging is right, then flip it.

---

## Local DNS and reverse proxy

Cosmetic, not required — everything works on `192.168.1.16:PORT`.

**dnsmasq** answers `*.home.arpa` with the VM's IP and forwards the rest
upstream. `.home.arpa` is the RFC 8375 reserved name for this; `.local` would
collide with mDNS.

**NPM** listens on :80 and routes by hostname to each published port. Tick
**Websockets Support** on every proxy host — Jellyfin and the *arr UIs need it.

| Hostname | Port |
|---|---|
| `jellyfin.home.arpa` | 8096 |
| `requests.home.arpa` | 5055 |
| `music.home.arpa` | 4533 |
| `sonarr.home.arpa` | 8989 |
| `radarr.home.arpa` | 7878 |
| `lidarr.home.arpa` | 8686 |
| `prowlarr.home.arpa` | 9696 |
| `bazarr.home.arpa` | 6767 |
| `qbit.home.arpa` | 8080 |
| `npm.home.arpa` | 81 |

Plex is deliberately absent — host networking and its own URL expectations mean
proxying breaks client discovery. Use `192.168.1.16:32400`.

**Client side**, split DNS so only `.home.arpa` goes to the VM. Otherwise the
VM becomes a single point of failure for all name resolution.

Windows:

```powershell
Add-DnsClientNrptRule -Namespace ".home.arpa" -NameServers "192.168.1.16"
```

Linux — `/etc/systemd/resolved.conf.d/homearpa.conf`:

```ini
[Resolve]
DNS=192.168.1.16
Domains=~home.arpa
```

The `~` prefix makes it routing-only. Android and iOS can't do split DNS, so
use IP:port in those apps — a one-time entry.

Don't route container-to-container traffic through the proxy. Same-namespace
apps on `localhost` are as direct as it gets; adding DNS and nginx to that path
only creates failure modes.

---

## Backups

**VM** — `/usr/local/bin/backup-media-config.sh`, run by
`media-backup.timer` every Friday 22:00 with `Persistent=true`, so a missed run
fires at next boot. It stops the stack (SQLite copied mid-write restores
corrupt), tars `config/` and `.env`, restarts, and keeps 1 archive.

**Windows** — a scheduled task each Saturday 10:00 pulls the archive, verifies
byte size, deletes the remote copy, and keeps the last 2.

The archive contains `.env`, so it holds your **WireGuard private key and
qBittorrent password in plaintext**. Keep the backup folder on an encrypted
disk.

Restore:

```bash
cd /opt/media-stack
docker compose down
tar xzf media-config-YYYY-MM-DD.tar.gz
docker compose up -d
```

---

## Gotchas

**Never recreate gluetun alone.** Use
`docker compose up -d --force-recreate` for everything.

**Adding a port for a namespaced app** means adding it to gluetun's `ports:`,
not the app's.

**Environment variable changes need a recreate**, not a restart — env is set at
container creation.

**Hyper-V automatic checkpoints are on by default** on Windows client. They
create differencing disks that grow indefinitely and can fill the host drive,
at which point Hyper-V pauses the VM (`Paused-Critical`). Disable them:

```powershell
Set-VM -Name "VM Name" -AutomaticCheckpointsEnabled $false
```

If a chain already exists, merge it with `Merge-VHD` — a merge needs free space
roughly equal to the delta, so make room first.

**`docker compose up -d` won't apply a new image** if the container is already
running and unchanged. Use `--force-recreate` after a `pull`.

**Sonarr won't cancel redundant grabs.** If a season pack and individual
episodes both download, clear the extras from Sonarr → Activity → Queue with
"remove from download client" ticked. It won't work it out on its own.

---

## Migrating to new hardware

The single-`/data`-mount and bind-mounted-config design means this is a copy,
not a rebuild:

1. Install Ubuntu + Docker on the new box (steps 1–4 above)
2. `git clone` this repo to `/opt/media-stack`
3. Extract the config tarball into it
4. Attach the media disk, mount at `/data` via fstab
5. `docker compose up -d`

Only the host-side path behind `/data` changes. Compose, app configs, quality
profiles, watch history — all carry over untouched.

Things that need attention on the new host: the static IP (netplan), the
router's DHCP reservation for the new MAC, and re-claiming the Plex server.
