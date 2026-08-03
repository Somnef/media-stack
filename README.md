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
  LAN ──────────────┤   qbittorrent  qbit-manage          │
                    │   prowlarr  radarr  sonarr  lidarr  │
                    │   bazarr  flaresolverr  cleanuparr  │
                    │   chaptarr                          │
                    └─────────────────────────────────────┘

                    ┌─────────────────────────────────────┐
                    │  bridge network (media-stack_default)│
  LAN ──────────────┤   jellyfin  navidrome  jellyseerr   │
                    │   maintainerr  homepage             │
                    │   npm  dnsmasq                      │
                    └─────────────────────────────────────┘
```

Plex is gone — Jellyfin is the only media server.

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
- **Every container in the namespace that touches files needs `/data` mounted
  explicitly.** Sharing a network namespace shares no filesystem. See the
  qbit_manage section for what happens when this is forgotten.

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
`depends_on: service_completed_successfully` on gluetun, jellyfin and navidrome
is what prevents that race. It's idempotent and does nothing when the structure
is already correct.

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
    ├── jellyfin/ navidrome/ jellyseerr/             ← tarball only
    ├── chaptarr/ cleanuparr/ maintainerr/           ← tarball only
    ├── homepage/                                    ← tarball only
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
│   │                          └── ebooks/  audiobooks/
│   └── orphaned_data/         ← qbit_manage quarantine, auto-created
└── media/
    ├── movies/  tv/  anime/  music/
    └── books/  └── ebooks/  audiobooks/
```

Created automatically by `init-data`, except `orphaned_data/` which qbit_manage
makes on first `rem_orphaned` run.

Current disk is a 250 GiB VHDX, raw ext4 on the whole device with no partition
table — so the fstab UUID is the filesystem UUID directly. A move to an
external disk with LVM on top is planned but not done.

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
networking, so boot-time DNS would fail. The VM resolves via upstream
(`1.1.1.1`, `9.9.9.9`) and therefore **cannot itself resolve `*.home.arpa`** —
only clients with the split-DNS rule can. Fine in practice, but worth knowing
before writing a script on the VM that expects `jellyfin.home.arpa` to work.

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
docker exec gluetun wget -qO- https://ipinfo.io/ip   # VPN exit IP
curl -s ifconfig.io                           # your real IP — must differ
```

If those last two match, the tunnel isn't working. Stop and fix before
downloading anything.

Then verify peer connectivity, which is a **separate** thing from the tunnel
working — see [qBittorrent](#qbittorrent):

```bash
docker exec gluetun sh -c 'netstat -ln | grep 49113'   # expect 10.x.x.x, not 172.18.x.x
curl -s -b /tmp/qbc 'http://localhost:8080/api/v2/sync/maindata' \
  | jq '.server_state | {dht_nodes, connection_status}'
```

Expect `dht_nodes` in the hundreds and `connection_status: connected`.

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
SERVER_NAMES=
VPN_PORT=

QBIT_USER=
QBIT_PASS=
```

`SERVER_COUNTRIES` deliberately isn't France. `VPN_PORT` is the AirVPN
forwarded port for peer connectivity — it has nothing to do with remote access
to the stack.

**`SERVER_NAMES` is currently set in `.env` but not passed to the gluetun
container.** With only `SERVER_COUNTRIES` in the environment block, gluetun
picks any AirVPN server in that country and may pick a different one on each
reconnect. AirVPN port forwards are account-wide rather than server-specific, so
this doesn't break connectivity — but if you want a stable exit IP, add
`- SERVER_NAMES=${SERVER_NAMES}` to gluetun's environment. Otherwise drop the
variable from `.env` so it stops looking load-bearing.

---

## Image pinning

All images are pinned by digest (`repo@sha256:...`) with a trailing comment
recording the version and pin date. **gluetun is deliberately left at
`:latest`** — its VPN provider configs shift server-side and a stale image is
more likely to break the tunnel than a fresh one.

Consequence: `docker compose pull` is a no-op. Updating is deliberate —
temporarily replace a digest with a tag, `pull`, then re-pin. Regenerate all
pins from what's currently running:

```bash
docker ps --format '{{.Names}}' | while read n; do
  img=$(docker inspect "$n" --format '{{.Config.Image}}')
  docker image inspect "$img" --format '{{index .RepoDigests 0}}'
done
```

The version comments come from `org.opencontainers.image.version`, which is
unreliable for some images — chaptarr and cleanuparr report their Ubuntu base
(`24.04`), maintainerr reports a branch name, and npm/jellyseerr/dnsmasq report
nothing. Those carry `?` rather than a false version.

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
| Chaptarr | 8789 | gluetun |
| Cleanuparr | 11011 | gluetun |
| FlareSolverr | 8191 | gluetun (internal, not published) |
| BitTorrent peer port | `${VPN_PORT}` | gluetun (TCP+UDP) |
| Jellyfin | 8096 | itself |
| Jellyseerr | 5055 | itself |
| Navidrome | 4533 | itself |
| Maintainerr | 6246 | itself |
| Homepage | 3000 | itself |
| NPM | 80 / 81 / 443 | itself |
| dnsmasq | 53 | itself |

---

## First-time configuration

Only needed if rebuilding without a config tarball. `host/indexers.txt` lists
which indexers were in use.

### qBittorrent

Default login `admin` / temp password in `docker logs qbittorrent`.

Four things that bite:

**1. Connection reset in the browser** → set
`WebUI\HostHeaderValidation=false` in
`config/qbittorrent/qBittorrent/qBittorrent.conf`. **Stop the container
first**; it rewrites the file on exit.

**2. Network Interface must be set to `tun0`** (Options → Advanced), not left
empty. Empty means "any", but qBittorrent enumerates interfaces at bind time
and gluetun's `tun0` doesn't exist yet — so it binds `eth0` + loopback only.
Outbound works, so nothing looks broken. But AirVPN's forwarded port arrives on
the tun0 address with nothing listening, the kernel returns RST, and you get
`connection_status: firewalled`, `dht_nodes: 0`, and every magnet stuck in
`metaDL` indefinitely — which looks like dead releases rather than a config
fault. Stored as `Session\Interface=tun0` and `Session\InterfaceName=tun0`.

This is also a killswitch improvement: bound to `tun0`, qBittorrent physically
cannot send traffic if the tunnel drops, rather than relying on gluetun's
firewall alone.

Verify after any rebuild or unclean shutdown:

```bash
docker exec gluetun sh -c 'netstat -ln | grep 49113'   # expect 10.x.x.x, not 172.18.x.x
```

**3. Automatic Torrent Management must be enabled.** Options → Downloads →
"Use Automatic Torrent Management" ON, "When Torrent Category changed" →
Relocate, "When Default Save Path changed" → Relocate. Without ATM, **category
save paths are ignored entirely** — a category is just a label and everything
lands in the Default Save Path. Symptom is every torrent piling up at
`/data/torrents/` root regardless of category, which makes orphan detection
hard to read and gets worse as categories multiply.

ATM applies to new torrents only. Existing ones stay in Manual mode until
switched individually (right-click → Automatic Torrent Management), at which
point qBittorrent relocates them. Harmless either way — moves within `/data`
are renames and don't affect hardlinks.

**4. Default save path** must be `/data/torrents/`.

Categories, each with its save path:

| Category | Save path |
|---|---|
| `radarr` | `/data/torrents/movies` |
| `tv-sonarr` | `/data/torrents/tv` |
| `anime-sonarr` | `/data/torrents/anime` |
| `lidarr` | `/data/torrents/music` |
| `books` | `/data/torrents/books` |

Create these before pointing the *arr apps at them — a missing category makes
qBittorrent reject the add with **409 Conflict**, and the *arr app just reports
a failed grab.

**Never point a category at `/data/media/`.** Torrents would download directly
into the Jellyfin library: no hardlink separation, release-group junk and
partial files in the library, and deleting the torrent with "also delete files"
takes the library copy with it. The `books` category was misconfigured this way
and it would have corrupted the Readarr migration.

Verify all five:

```bash
curl -s -b /tmp/qbc 'http://localhost:8080/api/v2/torrents/categories' \
  | jq -r 'to_entries[] | [.key, .value.savePath] | @tsv'
```

### Prowlarr

Add indexers, then Settings → Apps → add each *arr:

- Prowlarr Server: `http://localhost:9696`
- App Server: `http://localhost:7878` / `:8989` / `:8686` / `:8789`
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
- Leave the download client's optional **Directory** field EMPTY. A value there
  is passed per-torrent and overrides the category save path.
- Sonarr min free space: 10000 MB
- Jellyfin connection: Settings → Connect → Emby/Jellyfin →
  `192.168.1.16:8096`, API key from Jellyfin, **Update Library** ON

**Anime: set Series Type to `Anime`.** Sonarr defaults every series to
`Standard`, and anime releases use absolute numbering (`EP1170`) that Standard
can't parse. Symptom: Prowlarr's own search finds releases, Sonarr's finds
nothing. Fix on the series → Edit → Series Type → Anime.

**Lidarr builds the album folder inside the track format** — there is no
separate Album Folder Format field like Sonarr and Radarr have. Working values:

- Standard Track Format:
  `{Album Title} ({Release Year})/{Artist Name} - {Album Title} - {track:00} - {Track Title}`
- Multi Disc Track Format:
  `{Album Title} ({Release Year})/{Medium Format} {medium:00}/{Artist Name} - {Album Title} - {track:00} - {Track Title}`
- Artist Folder Format: `{Artist Name}`

**Rename Tracks must be ON** (Advanced toggle) or none of that applies and
imports keep their original torrent filenames — producing a flat artist folder
where two albums with a `01 Intro.flac` collide. To fix an existing flat
library: Artists → Mass Editor → select all → Rename Files, then restart
Navidrome so it rescans the new paths.

Lidarr's `Standard` metadata profile is studio albums only — no singles, EPs,
live, or compilations. Widen it per-artist if needed. Music releases are often
tagged `Unknown` quality, which the `Standard` quality profile rejects; use
`Any` for music.

### Books (Chaptarr → Readarr)

Chaptarr is the currently deployed books app, on port 8789. Its add-book path
is broken in the dev build, which is why the migration to **Readarr +
rreading-glasses** is planned — plain Readarr needs the third-party metadata
service because the official one was retired.

Chaptarr sends only a category name (`books` for both ebooks and audiobooks)
and lets qBittorrent resolve the path — no directory override. Its
`musicCategory` field is a vestige of the Readarr fork lineage and points at a
category that doesn't exist; harmless, but clear it if it bothers you.

Root folders: `/data/media/books/ebooks` and `/data/media/books/audiobooks`.
Both share one torrent save path and separate at import time by root folder.
Readarr works the same way, so this carries over.

**Nothing reads `/data/media/books` yet.** The books side is still being built —
acquisition and organisation are in place, the reading/listening end isn't. Not
an omission; just unfinished. Books are deliberately not a Jellyfin library.

**Before adding `books` to qbit_manage's `nohardlinks` list**, verify a book
import actually produces 2 links. If the books app copies instead of
hardlinking, every book torrent would be tagged `noHL` incorrectly.

### Jellyfin

- Libraries point at `/data/media/{movies,tv,anime,music}`, mounted `:ro`.
  Books are deliberately not a Jellyfin library — see [Books](#books-chaptarr--readarr).
- Scheduled library scan: **1 hour**. Real-time monitoring and the Sonarr
  notification both rely on inotify, which hardlinks don't reliably fire — so
  the scheduled scan is what actually catches new content.
- Audio: preferred language English, **"Play default track regardless of
  language" UNCHECKED** (otherwise dual-audio files default to the wrong track)

Because the media mount is read-only, **deleting from Jellyfin fails by
design**. Delete in Sonarr/Radarr instead, so their databases stay in sync and
they don't immediately re-download what you removed.

Playback on the Samsung TV goes through an Android TV / Google TV device.
Sideloading Jellyfin onto Tizen directly is a dead end — certificate failure.

### Bazarr

Languages French + English. Connect to Sonarr/Radarr on `localhost`.

TRaSH scoring: Sonarr minimum score 90, Radarr 80; sync thresholds Series 96,
Movies 86.

### Navidrome

`ND_MUSICFOLDER=/data/media/music`, `ND_SCANSCHEDULE=1h`. Its `/data` volume is
config, and the music mount is `:ro`.

No push notification from Lidarr exists, so new music appears on the hourly
scan. After a Lidarr mass rename, restart Navidrome — its database holds the
old paths and the library looks broken until it rescans.

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

### Cleanuparr

Runs inside gluetun's namespace, reaching each *arr on `localhost`. Jobs:
QueueCleaner every 5 minutes, Seeker every 10.

Each *arr is registered individually with its own API key. It health-checks
them on startup and logs `Unhealthy` for anything not yet up — expected noise
during a cold start, and it recovers on its own.

Its main job is removing downloads that stall with no connections, blocklisting
the release in the *arr, and triggering a re-search so a different release gets
grabbed. That only works if peer connectivity is actually functional — see the
qBittorrent `tun0` note, since a broken bind makes *everything* look stalled
and Cleanuparr will dutifully blocklist perfectly good releases.

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

### Homepage

Dashboard on :3000, bridge network. Config is hand-written YAML under
`config/homepage/` — worth considering for the git allowlist alongside dnsmasq
and qbit_manage, since it's text you edit rather than state an app manages.

### qbit_manage

Seeds private trackers indefinitely; deletes public torrents once downloaded.
The library survives via hardlink.

```yaml
environment:
  - QBT_RUN=false        # true means run-once-and-exit
  - QBT_SCHEDULE=30      # minutes
volumes:
  - ${CONFIG}/qbit-manage:/config
  - ${DATA}:/data        # REQUIRED — see below
restart: on-failure:2
```

**The `/data` mount is not optional.** Sharing gluetun's network namespace
shares no filesystem. With only `/config` mounted, `tag_update` and
`share_limits` work fine — they're pure qBittorrent API calls — while every
filesystem-dependent command silently does nothing. This went undetected for
47+ hours. The first symptom was `rem_orphaned` crashing with
`PermissionError: '/data'` when it tried to create the orphaned directory,
because `os.makedirs` walked up to a `/data` that didn't exist in the container.

The mount point must be **identical** to qBittorrent's. qbit_manage compares
the paths qBittorrent reports against paths it resolves itself; a mismatch makes
every torrent look orphaned. That's what `remote_dir` exists to patch, and you
don't want to need it.

**`QBT_RUN=true` plus `restart: unless-stopped` is an infinite loop** — the
container exits, Docker restarts it, and cleanup runs continuously. It will
delete downloads before Lidarr has imported them. The log line to check is
`Run Mode: Script will exit after completion` versus
`30 minutes until the next run`.

#### `config/qbit-manage/config.yml`

Commands currently enabled: `tag_update`, `share_limits`, `rem_orphaned`,
`tag_nohardlinks`. `dry_run: false`.

**`dry_run` is global, not per-command.** Leaving it `true` as a safety measure
disables tagging and share limits too. Control risk with the individual command
flags instead.

```yaml
directory:
  root_dir: /data/torrents          # required even for tagging
  orphaned_dir: /data/torrents/orphaned_data

orphaned:
  empty_after_x_days: 14
  max_orphaned_files_to_delete: 50
  min_file_age_minutes: 60
  exclude_patterns:

nohardlinks:                        # top-level key, NOT under commands
  radarr:
  tv-sonarr:
  anime-sonarr:
  lidarr:
```

Notes:

- **`root_dir` must be `/data/torrents`, never `/data`.** Pointed at `/data`,
  every file in the library gets flagged as orphaned — none of them are torrent
  contents in qBittorrent's view.
- **`orphaned_dir` inside `root_dir`** keeps the move a same-filesystem rename
  instead of a copy. qbit_manage auto-appends the quarantine folder to
  `exclude_patterns` so it can't rescan its own output.
- **`max_orphaned_files_to_delete` aborts the whole sweep** if exceeded — it
  does not move the first N. The abort logs the count and full file list and
  moves nothing. That guard is what catches a misconfigured `root_dir`. Raise it
  temporarily for a genuine large cleanup, then put it back.
- **The abort is silent unless you read logs.** Nothing in Jellyfin, Homepage or
  qBittorrent surfaces it. Configure the `webhooks:` block.
- **`min_file_age_minutes: 60`** stops a sweep catching files mid-import, when
  they exist on disk but aren't yet claimed by a torrent.
- **`empty_after_x_days: 14`** deletes from quarantine on that schedule — it
  runs independently of the move, so files already quarantined still age out
  even on a run that aborts.
- **`tag_nohardlinks` needs a top-level `nohardlinks:` list of categories.**
  Enabling the command without it produces
  `Config Error: nohardlinks must be a list of categories` and **exits the
  entire run** — so `rem_orphaned` and `share_limits` stop working too.
- `recyclebin.enabled: false` — enabling it tries to create `/data/.RecycleBin`
  and fails on permissions
- `min_seeding_time` is rejected alongside `max_ratio: -1`; drop it, since
  `cleanup: false` already protects private torrents
- credentials via `!ENV QBIT_USER` / `!ENV QBIT_PASS`, passed through from
  compose

**What `noHL` actually means.** A torrent with one link has no library
counterpart — usually because you deleted the film from the library and the
torrent kept seeding. It is *not* primarily a failed-import detector. It answers
"what am I still seeding that I no longer keep?", which is the drift that
accumulates when you curate and delete.

#### Share limits and tracker classification

```yaml
share_limits:
  public:
    priority: 1
    include_all_tags: [public]
    max_ratio: 0
    max_seeding_time: 0
    cleanup: true            # ← the only delete path in the whole config
  private:
    priority: 2
    include_all_tags: [private]
    max_ratio: -1            # -1 = unlimited
    max_seeding_time: -1
    cleanup: false
```

Classification comes from the `tracker:` block. **A torrent from a tracker not
listed there falls into `public` and gets deleted on completion.** So adding a
new private tracker means adding it to `tracker:` *first*, or you take a
hit-and-run on a tracker that counts them.

MyAnonaMouse is already listed ahead of joining. Joining also needs the
`mam_id` session token and the Dynamic Seedbox API call made **from inside
gluetun's namespace**, so the IP matches.

Being tagged `private` is a choice, not a fact about the tracker — open
trackers with no ratio requirement will seed forever for no benefit if listed.

---

## Local DNS and reverse proxy

Cosmetic, not required — everything works on `192.168.1.16:PORT`.

**dnsmasq** answers `*.home.arpa` with the VM's IP and forwards the rest
upstream. `.home.arpa` is the RFC 8375 reserved name for this; `.local` would
collide with mDNS.

**NPM** listens on :80 and routes by hostname to each published port. Tick
**Websockets Support** on every proxy host — Jellyfin and the *arr UIs need it.

| Hostname | Target | Service |
|---|---|---|
| `jellyfin.home.arpa` | 8096 | Jellyfin |
| `requests.home.arpa` | 5055 | Jellyseerr |
| `music.home.arpa` | 4533 | Navidrome |
| `home.home.arpa` | 3000 | Homepage |
| `sonarr.home.arpa` | 8989 | Sonarr |
| `radarr.home.arpa` | 7878 | Radarr |
| `lidarr.home.arpa` | 8686 | Lidarr |
| `prowlarr.home.arpa` | 9696 | Prowlarr |
| `bazarr.home.arpa` | 6767 | Bazarr |
| `qbit.home.arpa` | 8080 | qBittorrent |
| `cleanuparr.home.arpa` | 11011 | Cleanuparr |
| `maintainerr.home.arpa` | 6246 | Maintainerr |
| `nginx.home.arpa` | 81 | NPM itself |

All forward to `192.168.1.16` — the LAN IP, not container names, because the
namespaced apps have no addressable names of their own.

**Chaptarr (8789) has no proxy host** — reach it on `192.168.1.16:8789`. Add one
when Readarr replaces it.

Read the live list without the UI (NPM ships no `sqlite3` binary, so use the
host's Python):

```bash
python3 - <<'EOF'
import sqlite3, json
db = '/opt/media-stack/config/npm/data/database.sqlite'
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
for names, host, port, en in con.execute(
    "select domain_names, forward_host, forward_port, enabled from proxy_host where is_deleted=0"):
    for d in json.loads(names):
        print(f"{d:<32} -> {host}:{port}{'' if en else '   (disabled)'}")
EOF
```

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

### DNS baseline (relevant to any future Tailscale work)

```
resolv.conf mode: uplink        # systemd-resolved is NOT stub-listening
:53 held by                     # docker-proxy only, fronting the dnsmasq container
eth0 DNS servers                # 1.1.1.1, 9.9.9.9
```

No conflict to untangle. Any split-DNS arrangement for `home.arpa` starts from a
clean state.

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

**`/data` newer than the databases** — Jellyfin and Navidrome recover on their
own, since they derive everything from the filesystem. The *arr apps won't:
they don't adopt files they don't know about, and may re-download content
already on disk. Fix with **Library Import** (Add New → Import Existing) before
letting them search.

---

## Gotchas

**Never recreate gluetun alone.** Use
`docker compose up -d --force-recreate` for everything.

**Adding a port for a namespaced app** means adding it to gluetun's `ports:`,
not the app's.

**Volume changes need `up -d`, not `restart`.** A restart reuses the existing
container with its existing mounts. Same for environment variables — env is set
at container creation.

**Silent failures are the recurring hazard here.** Three found in one session,
none of which surfaced anywhere: the missing `/data` mount in qbit_manage,
qBittorrent binding `eth0` instead of `tun0`, and qbit_manage aborting on an
orphan count above threshold. All three looked like healthy containers. Where a
feature appears to do nothing, check mounts and interface bindings before
assuming the feature is wrong.

**qBittorrent silently binds the wrong interface** if `Session\Interface` is
missing. Symptom is stalled magnets and zero DHT nodes, which reads as dead
releases. See [qBittorrent](#qbittorrent).

**Category save paths do nothing without ATM enabled.** See
[qBittorrent](#qbittorrent).

**`du -sh` on a directory of hardlinks overstates it wildly.** Each invocation
counts an inode once, so a quarantine folder full of hardlinked files can report
more than the entire filesystem holds. Use `df` to judge actual free space, and
`find -links 1` to find data that genuinely occupies space once.

**Deleting a hardlink frees nothing if another name remains.** Removing the
`torrents/` copy of an imported file is safe and reclaims zero bytes; the
library name still resolves to the same inode.

**Orphan sweeps delete content you may have wanted.** "Orphaned" means "no
torrent in the session", not "worthless". Music downloaded outside Lidarr and
never imported looks identical to genuine junk. Check the dry-run list against
what each *arr thinks it has before a large sweep.

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
running and unchanged. Use `--force-recreate` after a `pull`. With digest pins,
`pull` is a no-op — see [Image pinning](#image-pinning).

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
7. **Verify the qBittorrent `tun0` bind and DHT node count** — see step 7 of
   the rebuild. This setting lives only in the config tarball, not in compose.

**Order matters at step 2.** `restore-config.sh` ends by starting the stack, and
`init-data` creates the `/data` tree on whatever `/data` currently is. If the
real disk isn't mounted yet, that tree lands on the OS disk and is then hidden
when the disk mounts over it — leaving an empty `/data` and wasted space you
can't see. Storage before containers.

Only the host-side path behind `/data` changes. Compose, app configs, quality
profiles, watch history — all carry over untouched.

Things needing attention on the new host: the interface name and UUID in the
netplan/fstab templates, and the router's DHCP reservation for the new MAC.

### Planned: external disk with LVM

Not yet purchased. Intended shape: mains-powered 3.5" desktop external, 2–4 TB,
Windows disk set Offline and the whole physical disk passed through to the VM.
LVM on top (`vg mediavg`, `lv medialv`) + ext4, so a later disk is
`pvcreate` + `vgextend` + `lvextend -r`.

Migration: stack down, `rsync -aHvP`, verify hardlinks survived, repoint fstab
at the new UUID. Keep `nofail`.

**Clean up before migrating, not after.** `rsync -aH` preserves hardlinks that
already exist but never creates new ones, so unshared duplicates get copied
across verbatim and cost you twice.

**A linear VG spanning two external disks doubles the failure surface** — one
disk dies and the whole volume group goes, including data physically on the
survivor. Prefer one larger disk. LVM's value here is growing onto a
replacement, not spanning.
