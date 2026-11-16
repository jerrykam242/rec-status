# rec-status

**English** · [简体中文](README.zh-CN.md)

> *"The stream is over… but the VOD lives on."*

A small, self-hosted setup built around a live-stream recorder ([BililiveRecorder](https://github.com/BililiveRecorder/BililiveRecorder),
fondly known as **录播姬**, "the Recording Princess") and a file server ([OpenList](https://github.com/OpenListTeam/OpenList)).
Your oshi goes live, the Princess records every frame, and this repo is the castle around her:
a status board, a quest desk for archive requests, and a gatekeeper at every door.

## The party

| Member | Class | What it does |
|---|---|---|
| **Status site** | Bard 🎶 | A public page showing which rooms are live and being recorded, plus recent events. Visitors can file a recording request through a form. Bilingual (zh/en) privacy policy and cookie notice, written for GDPR and PIPL. |
| **Request flow** | Guild Receptionist 📜 | The admin gets an email with signed approve/deny links. The visitor waits on the page for up to 5 minutes. If the quest is accepted in time, the page shows the share link the worker created in OpenList. If not, the page says the request will be reviewed by hand. |
| **Edge gate** | Gatekeeper 🛡️ | OpenResty/Lua [Cloudflare Turnstile](https://developers.cloudflare.com/turnstile/) checks in front of the OpenList sign-in, OpenList share links and the recorder WebUI. It also brings an IBM Carbon sign-in page and a Carbon skin for the recorder. |
| **Agent + worker** | Familiars 🐈 | Live on the recorder host. One reports the Princess's state to the status site; the other carries out accepted quests (copy files, create the share, send the mail). |

Every page is dressed in [IBM Carbon](https://carbondesignsystem.com/) with IBM Plex fonts. One outfit, all routes.

## World map

```
status-site/          status site (OpenResty + Lua), served from /www/sites/live in the container
  index/              static pages: index.html (status + request form), privacy.html, assets/
  gate/               Lua: sign-in gate, ingest, status API, requests, review links, store
  proxy/ server/      nginx location and server blocks
  conf.d/             http-level shared dicts
agent/                runs on the recorder host
  rec-status-agent.py     pushes recorder state to the status site (HMAC-signed)
  rec-request-worker.py   pulls approved requests, copies files, creates OpenList shares, sends mail
  *.service, *.env.example
edge-gate/            Turnstile gate for the file server and recorder sites (OpenResty + Lua)
  sites/              nginx snippets to include in each site
  templates/ public/  sign-in / share check pages and assets
  tools/rec-theme-check/  checks that the recorder skin still fits after a recorder upgrade
ops/                  Cloudflare-only origin firewall (nftables), systemd units, logrotate
tools/                build-carbon-css.py (trims Carbon's compiled CSS)
```

Each area has its own lore book:
- `status-site/gate/README` ([中文](status-site/gate/README.zh-CN))
- `edge-gate/README` ([中文](edge-gate/README.zh-CN))

## How a quest runs

```
  visitor ──Turnstile──▶ status page ──form──▶ /api/request      (quest posted)
                                                   │
  recorder host: rec-request-worker ◀──/__agent/sync┘            (familiar picks it up)
        │  emails admin: [批准 approve] [拒绝 deny]  (signed links, valid 7 days)
        ▼
  admin approves ──▶ worker copies the day folder to GDrive ──▶ OpenList share (code, expiry, access limit)
        │
        ▼
  visitor's page (still waiting, up to 5 min) shows the link ✨ ── otherwise: "reviewed manually"
```

## Setup (the tutorial level)

1. **Status site.** Copy `status-site/` into an OpenResty site directory and include
   `proxy/live.conf` and `conf.d/00-live.conf`. Create the root-only key files under `gate/`
   with random hex values: `cookie_key`, `ingest_key`, `admin_key` (signs the review links), and
   optionally `edge_key`. Set `public_url` and the captcha values in `gate/live_config.lua`.
2. **Edge gate.** Copy `edge-gate/` to `/www/common/turnstile` and include `sites/*.conf` in
   the matching sites. Store the Turnstile secret with `set-secret.sh` and create `cookie_key`
   and `rs_key` (`rs_key` must equal the status site's `ingest_key`).
3. **Agent and worker.** Copy `agent/*.env.example` to `/etc/rec-status/*.env` (mode 0640),
   fill them in, and install the systemd units.
4. **Replace every placeholder** (no NPC names left behind):

| Placeholder | Meaning |
|---|---|
| `example.com` | your domain (`rec-status.`, `file.`, `rec.` subdomains) |
| `admin@example.com` | contact / admin mailbox |
| `YOUR_TURNSTILE_SITEKEY` | Cloudflare Turnstile sitekey |
| `203.0.113.10`, `198.51.100.20` | recorder host and status-site origin IPs |
| `esa-xxxxxxxxxx`, `SCENE_ID`, `<rule-id>` | captcha values from the CDN edge (optional; Turnstile is used now) |
| `1Panel-openresty-XXXX` | name of your OpenResty container |

> [!IMPORTANT]
> Secrets never enter the repository. Every key file is created on the server, owned by root
> with mode 600; see `.gitignore`. Treat them like your save file: no backup in public places.

> [!NOTE]
> The privacy policy (`status-site/index/privacy.html`) is a template. Before you use it, have
> it reviewed for your own processing, providers and jurisdiction.

## Third-party assets (credits roll)

- IBM Plex fonts: SIL Open Font License (`assets/fonts/IBM-Plex-OFL.txt`).
- `carbon.css`: trimmed from `@carbon/styles` (Apache-2.0).
- The background images and logo are placeholders. Swap in your own key visual.

*Thanks for watching! Remember to like, follow and 一键三连.* ( •̀ ω •́ )✧
