# media-stack

Self-hosted media automation stack. This repo holds the **text config** —
`docker-compose.yml`, dnsmasq, qbit_manage, and the host-level scripts under
`host/`. Everything else (app databases, metadata, secrets) lives in the config
tarball described in [Backups](#backups).

A full rebuild needs **three** things:

| Piece | Where it lives |
|---|---|
| Compose, text config, host scripts | this repo |
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

**The `init-data` service** runs before anything else and creates the `/data`
tree if missing, then fixes ownership to `PUID:PGID`. It exists because Docker
creates missing bind-mount sources as **root:root** — so on a fresh disk,
whichever container started first would silently create `/data/media`
unwritable by the *arr apps. The
`depends_on: service_completed_successfully` on gluetun, jellyfin, plex and
navidrome is what prevents that race. It's idempotent and does nothing when the
structure is already correct.

---

## Repo layout

```
/opt/media-stack               ← this repo
├── docker-compose.yml
├── .env                       ← NOT in git; in the tarball
├── .env.example
├── host/                      ← host-level config, see below
└── config/
    ├── radarr/ sonarr/ lidarr/ prowlarr/ bazarr/    ← tarball only
    ├── jellyfin/ plex/ navidrome/ jellyseerr/       ← tarball only
    ├── qbittorrent/ gluetun/ npm/                   ← tarball only
    ├── dnsmasq/dnsmasq.conf   ← in git
    └── qbit-manage/config.yml ← in git
```

### `host/`

Things that live outside `/opt/media-stack` on a running machine, kept here so
they survive an OS disk failure — including the backup machinery itself, which
would otherwise be lost exactly when it's needed.

| File | Deploys to | Notes |
|---|---|---|
| `install.sh` | — | run with sudo on a fresh host; deploys the rest |
| `backup-media-config.sh` | `/usr/local/bin/` | weekly config tarball |
| `media-backup.service` | `/etc/systemd/system/` | oneshot unit |
| `media-backup.timer` | `/etc/systemd/system/` | Fri 22:00, `Persistent=true` |
| `restore-config.sh` | — | run manually to restore a tarball |
| `netplan.yaml` | `/etc/netplan/00-installer-config.yaml` | **review first** — interface name and IP are machine-specific |
| `fstab.line` | appended to `/etc/fstab` | **review first** — UUID is disk-specific |
| `pull-media-config.ps1` | the Windows machine | scheduled task, not used on the VM |
| `indexers.txt` | — | which Prowlarr indexers were configured, and what to avoid |

`install.sh` deliberately does **not** apply netplan automatically. A wrong
netplan locks you out of SSH, and the UUID in `fstab.line` belongs to the old
disk.

---

## Storage layout

```
/data                          ← single ext4 mount (its own disk)
├── torrents/
│   ├── movies/  tv/  anime/  music/  books/
└── media/
    ├── movies/  tv/  anime/  music/  books/
```

Created automatically by `init-data`.

---

## Rebuild from scratch

### 1. Host

Ubuntu Server 22.04 LTS. Under Hyper-V: Generation 2, **Secure Boot disabled**,
**External virtual switch** so the VM gets a real LAN IP rather than sitting
behind host NAT.

Two disks: OS, and a separate one for `/data`.

Set a **static MAC** in the hypervisor (Hyper-V: Settings → Network Adapter →
Advanced Features) before anything else, so a router DHCP reservation can't be
orphaned later.

### 2. The `/data` disk

```bash
sudo mkfs.ext4 -L media /dev/sdb
sudo blkid /dev/sdb          # note the UUID
sudo mkdir /data
```

Add to `/etc/fstab`, substituting the new UUID (`host/fstab.line` has the old
one as a template). `nofail` matters — the VM still boots if the disk is
missing:

```
UUID=<uuid>  /data  ext4  defaults,nofail  0  2
```

```bash
sudo mount -a
```

The directory tree and ownership are handled by `init-data` at first
`docker compose up`.

### 3. Docker

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

### 4. Clone and restore

```bash
sudo mkdir -p /opt/media-stack
sudo chown $USER:$USER /opt/media-stack
git clone git@github.com:USER/media-stack.git /opt/media-stack
cd /opt/media-stack

./host/restore-config.sh ~/media-config-YYYY-MM-DD.tar.gz
```

`restore-config.sh` moves any existing `config/` aside, extracts the archive,
fixes ownership, and brings the stack up.

If you have no tarball: copy `.env.example` to `.env`, fill it in,
`docker compose up -d`, and configure each app by hand — see
[First-time configuration](#first-time-configuration).

### 5. Static IP

Review `host/netplan.yaml`, correct the interface name (`ip -br a`) and gateway
(`ip route | grep default`), then:

```bash
sudo cp host/netplan.yaml /etc/netplan/00-installer-config.yaml
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan try
```

`netplan try` reverts after 120s if you lose the connection — safer than
`apply` over SSH.

IPv6 is disabled deliberately: on a Hyper-V wireless bridge it half-works, so
apps try IPv6 first and wait for a timeout before falling back.

Also add a DHCP reservation on the router for the VM's MAC. Belt and braces —
netplan asserts the address, the reservation stops the router offering it to
anything else.

Do not point the VM's resolver at its own dnsmasq container; it starts after
networking, so boot-time DNS would fail.

### 6. Host services

```bash
sudo ./host/install.sh
```

Installs the backup script, enables the systemd timer, and appends the fstab
line if absent. Then copy `host/pull-media-config.ps1` to the Windows machine
and register the scheduled task — see [Backups](#backups).

### 7. Verify

```bash
docker compose ps                             # all up, gluetun healthy
docker logs init-data                         # "data structure verified"
docker exec qbittorrent curl -s ifconfig.io   # VPN exit IP
curl -s ifconfig.io                           # your real IP — must differ
```

If those last two match, the tunnel isn't working. Stop and fix before
downloading anything.

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

Only needed if rebuilding without a config tarball. `host/indexers.txt` lists
which indexers were in use.

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

Season numbering for anime often disagrees between TMDB (Jellyseerr) and TVDB
(Sonarr) — a request covering "season 1" in Jellyseerr may leave later Sonarr
seasons unmonitored. Check monitoring in Sonarr after requesting anime.

### Maintainerr

Rule-based library retention. Collections sync to Jellyfin as a "leaving soon"
shelf, and items are deleted once they have sat there for **Take action after
days**.

Set the **Radarr/Sonarr action** to delete *and* unmonitor, and leave the
Jellyfin action as none — the media mount is `:ro`, so a media-server delete
fails, and deleting without unmonitoring means the *arr re-downloads within the
hour.

**`BEFORE` and `AFTER` are not symmetric with `custom_days`.** A value of 30
resolves to:

- `BEFORE 30` → 30 days in the **past** (item is older than that) — what you want
- `AFTER 30` → 30 days in the **future** — never true for existing media

So `AFTER` cannot express "within the last N days", and any condition using it
silently matches nothing. Two-sided date windows are therefore impossible;
overlapping collections between an aged-out rule and a low-space rule are the
accepted trade-off (the shorter grace period fires first).

Use **Test Media** on a single title to see the resolved comparison dates
before trusting any rule — it prints `firstValue` and `secondValue`, which is
how the above was found.

Field-name traps:

- `sw_` means show-scope, **not** Streamystats. Movies use
  `Jellyfin.viewCount`; seasons and shows use `Jellyfin.sw_amountOfViews`.
- `Sonarr.addDate` is show-scope only — use `Jellyfin.addDate` in season rules.
- `unaired_episodes` is show/season scope; `unaired_episodes_season` is
  episode scope.
- Add `Sonarr - Is (part of) latest aired/airing season` = false to protect the
  season you are currently watching.

Rules are exported as YAML from the UI and kept in `maintainerr/` in this repo.
`POST /api/rules/yaml/decode` is what the import uses, if you ever script it.

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

**VM** — `backup-media-config.sh`, run by `media-backup.timer` every Friday
22:00 with `Persistent=true`, so a missed run fires at next boot. It stops the
stack (SQLite copied mid-write restores corrupt), tars `config/` and `.env`,
restarts, and keeps 1 archive.

**Windows** — a scheduled task each Saturday 10:00 runs
`pull-media-config.ps1`: pulls the archive, verifies byte size, deletes the
remote copy, keeps the last 2 locally. Registered with:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$env:USERPROFILE\Backups\pull-media-config.ps1`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At 10am
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
Register-ScheduledTask -TaskName "Pull media-stack config backup" -Action $action -Trigger $trigger -Settings $settings
```

It needs a passwordless SSH key at `$env:USERPROFILE\.ssh\id_ed25519_plex`.

The archive contains `.env`, so it holds your **WireGuard private key and
qBittorrent password in plaintext**. Keep the backup folder on an encrypted
disk.

Restore:

```bash
./host/restore-config.sh /path/to/media-config-YYYY-MM-DD.tar.gz
```

### Database / disk mismatch

The two halves can drift, and the consequences aren't symmetric:

**Databases newer than `/data`** (restoring a tarball onto an empty disk) — the
*arr apps believe they have a full library, find it missing, and **re-download
everything monitored**. That's usually what you want on a genuine rebuild, but
it's a lot of bandwidth at once and will hammer your indexers into rate limits.
If the media exists elsewhere, copy it into `/data/media` *before* starting
Sonarr/Radarr/Lidarr. Note that availability decays — old releases lose
seeders, so a restore returns your configuration perfectly and your library
approximately.

**`/data` newer than the databases** — Jellyfin, Plex and Navidrome recover on
their own, since they derive everything from the filesystem. The *arr apps
won't: they don't adopt files they don't know about, and may re-download
content already on disk. Fix with **Library Import** (Add New → Import
Existing) before letting them search.

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
roughly equal to the delta, so make room first. After merging outside Hyper-V's
awareness it may refuse disk changes with "a disk merging is pending"; detach
and re-attach the disks with `Remove-VMHardDiskDrive` / `Add-VMHardDiskDrive`
to clear the stale state. Detaching does not delete the files.

**`docker compose up -d` won't apply a new image** if the container is already
running and unchanged. Use `--force-recreate` after a `pull`.

**Sonarr won't cancel redundant grabs.** If a season pack and individual
episodes both download, clear the extras from Sonarr → Activity → Queue with
"remove from download client" ticked. It won't work it out on its own.

---

## Migrating to new hardware

The single-`/data`-mount and bind-mounted-config design means this is a copy,
not a rebuild:

1. Install Ubuntu + Docker on the new box (steps 1 and 3 above)
2. **Attach the media disk and mount it at `/data` via fstab** (step 2 above)
3. `git clone` this repo to `/opt/media-stack`
4. `./host/restore-config.sh <tarball>` — extracts config and starts the stack
5. `sudo ./host/install.sh` — backup script and systemd timer
6. Review and apply `host/netplan.yaml`, then `sudo netplan try`

**Order matters at step 2.** `restore-config.sh` ends by starting the stack, and
`init-data` creates the `/data` tree on whatever `/data` currently is. If the
real disk isn't mounted yet, that tree lands on the OS disk and is then hidden
when the disk mounts over it — leaving an empty `/data` and wasted space you
can't see. Storage before containers.

Only the host-side path behind `/data` changes. Compose, app configs, quality
profiles, watch history — all carry over untouched.

Things needing attention on the new host: the interface name and UUID in the
netplan/fstab templates, the router's DHCP reservation for the new MAC, and
re-claiming the Plex server.
