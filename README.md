# Bonchaz Compliance — n8n Automation Stack

A self-hosted [n8n](https://n8n.io/) automation stack for Bonchaz compliance
workflows, plus a transport-only **Discord ↔ n8n bridge**. All business logic
lives in n8n workflows; this repository is the **deployment definition** and the
supporting services around it.

> **The running containers are disposable.** The system *is* this repo +
> a Postgres dump + the `N8N_ENCRYPTION_KEY`. Keep the repo in git, keep the
> real `.env` **out** of git, and keep the encryption key in a vault. Lose the
> key and every stored credential becomes undecryptable.

---

## Architecture

```
                 ┌─────────────────────────────────────────────┐
   Discord  ───► │  discord-bot  ──(webhook)──►  n8n  ──► postgres│
   gateway  ◄─── │  (transport)  ◄──(HTTP API)──  workflows       │
                 │                               └──► n8n-runners  │
                 └─────────────────────────────────────────────┘
                        one docker compose network
```

| Service        | Image / Build                     | Role                                                                 |
| -------------- | --------------------------------- | -------------------------------------------------------------------- |
| `postgres`     | `postgres:16`                     | n8n's datastore: workflows, credentials, execution history.          |
| `n8n`          | `docker.n8n.io/n8nio/n8n:2.14.1`  | The automation engine. Bound to `127.0.0.1:5678` **only**.           |
| `n8n-runners`  | `n8nio/runners:2.14.1`            | Sandboxed external task runner for Code nodes. Shares n8n's netns.   |
| `discord-bot`  | build `./discord-bot`             | Discord ↔ n8n bridge (Node 20 / discord.js). No ports published.     |
| `extractor`    | *(commented out, optional)*       | Python OCR/extraction sidecar, called by n8n over HTTP.              |

**Security posture** (deliberate — see comments in `docker-compose.yml`):

- n8n is **never** exposed to the internet directly. Put a reverse proxy / VPN
  in front for outside access. Unauthenticated RCE chains only work on
  internet-reachable instances.
- Task runners run in **external** (sandboxed) mode — legacy in-process mode was
  implicated in CVE-2025-68697.
- The n8n version is **pinned**. Do not use `:latest`. Check
  <https://github.com/n8n-io/n8n/security> before deploying and treat a CVE
  advisory as a 48-hour patch window.
- The Discord bot publishes **no host ports** — only n8n (same network) reaches
  it. It suppresses all `@everyone`/`@here`/role pings by default.

---

## Prerequisites

- **Docker** and the **Docker Compose v2** plugin (`docker compose`, not
  `docker-compose`). Verified with Docker 29.x / Compose v5.x.
- A **Discord application + bot token** (for the bridge). See
  [Discord setup](#discord-setup) below.
- `openssl` (for generating secrets) and `bash` (for the backup/restore scripts).

---

## Quick start

### 1. Configure `.env`

```bash
cp .env.example .env
```

Then fill in the required secrets. Generate strong random values:

```bash
# Postgres password
openssl rand -hex 24

# n8n master encryption key  — SET BEFORE FIRST RUN, store in a vault
openssl rand -hex 32

# n8n <-> runner shared auth token
openssl rand -hex 32

# n8n <-> Discord-bot shared API token (BOT_API_TOKEN)
openssl rand -hex 32
```

Required keys in `.env`:

| Key                      | Required | Notes                                                        |
| ------------------------ | -------- | ------------------------------------------------------------ |
| `POSTGRES_PASSWORD`      | ✅       | `openssl rand -hex 24`                                       |
| `N8N_ENCRYPTION_KEY`     | ✅       | **Master key.** Set before first run; store in a vault.      |
| `N8N_RUNNERS_AUTH_TOKEN` | ✅       | Same value shared by `n8n` and `n8n-runners`.                |
| `DISCORD_TOKEN`          | ✅¹      | Bot token from the Discord Developer Portal.                 |
| `BOT_API_TOKEN`          | ✅¹      | Shared secret n8n presents (Bearer) to the bot's HTTP API.   |

¹ Required only if you run the `discord-bot` service. The core n8n stack runs
without them.

> ⚠️ **`N8N_ENCRYPTION_KEY`** decrypts every stored credential. Set it *before*
> the first run — if n8n auto-generates its own and you later set a different
> one, it refuses to start. Store the value in a password manager independent of
> your backups; a dump without the matching key is undecryptable.

### 2. Discord setup

Only needed for the `discord-bot` service.

1. Go to <https://discord.com/developers/applications> → **New Application**.
2. **Bot** tab → **Reset Token** → copy it into `DISCORD_TOKEN` in `.env`.
3. On the same tab, enable **Message Content Intent** under *Privileged Gateway
   Intents*. Without it, login fails with a `disallowed intents` error — the #1
   setup gotcha. (Enable **Server Members Intent** too only if you set
   `FORWARD_MEMBER_EVENTS=true`.)
4. **OAuth2 → URL Generator**: scope `bot`, permissions *Send Messages*, *Read
   Message History*, *Add Reactions*. Open the generated URL to invite the bot
   to your server.

### 3. Bring up the stack

```bash
docker compose up -d          # build + start everything
docker compose ps             # check status
docker compose logs -f n8n    # follow logs
```

- n8n UI: <http://localhost:5678>
- The `discord-bot` logs `Discord ready as <name>` once connected.

To run **without** the Discord bridge (core n8n only):

```bash
docker compose up -d postgres n8n n8n-runners
```

---

## The Discord bridge

A transport-only bot (in `./discord-bot`). It holds **no business logic** — that
lives in your n8n workflows. Two directions:

### bot → n8n (event forwarding)

The bot forwards Discord gateway events to an n8n **Webhook** node as a POST with
this envelope:

```json
{ "type": "messageCreate", "timestamp": "2026-07-06T22:00:00.000Z", "data": { "message": { "...": "..." } } }
```

Forwarded event `type`s: `messageCreate`, `messageUpdate`, `messageDelete`,
`messageDeleteBulk`, and (when `FORWARD_MEMBER_EVENTS=true`) `guildMemberAdd` /
`guildMemberRemove`. Forwards are retried (`N8N_FORWARD_RETRIES`, default 2) with
a bounded timeout so a momentary n8n hiccup never drops a compliance event or
crashes the gateway connection.

- Default target: `http://n8n:5678/webhook/discord-events` (`n8n` resolves on the
  compose network).
- While building a workflow use the `/webhook-test/...` URL; switch to
  `/webhook/...` once the workflow is **Active**.
- To authenticate the call to n8n, set `N8N_WEBHOOK_TOKEN` and add a matching
  *Header Auth* credential (header name = `N8N_WEBHOOK_HEADER`) to the Webhook node.

### n8n → bot (command HTTP API)

n8n calls the bot to act on Discord. Reachable **only** from inside the compose
network at `http://discord-bot:3000` (service name; the container is also aliased
`discord-bonchaz-bot`). Every request needs `Authorization: Bearer <BOT_API_TOKEN>`.

| Method & path     | Body (JSON)                                              | Returns                     |
| ----------------- | ------------------------------------------------------- | --------------------------- |
| `GET /health`     | — (unauthenticated)                                     | `{ "status": "ok", "ready": true }` |
| `POST /messages`  | `channelId`, `content` and/or `embeds`, opt `replyTo`, `tts`, `allowedMentions` | `{ "id", "channelId" }` |
| `POST /reactions` | `channelId`, `messageId`, `emoji`                       | `{ "ok": true }`            |
| `POST /dms`       | `userId`, `content` and/or `embeds`                     | `{ "id", "channelId" }`     |

Example (as an n8n **HTTP Request** node would send it):

```
POST http://discord-bot:3000/messages
Authorization: Bearer <BOT_API_TOKEN>
Content-Type: application/json

{ "channelId": "123456789012345678", "content": "Compliance check passed ✅" }
```

**Ping safety:** message content originates from untrusted Discord users and can
round-trip through n8n back into an outbound send. The bot therefore **suppresses
all mentions by default** (`allowedMentions: { parse: [] }`). To intentionally
ping, pass an explicit `allowedMentions`, e.g. `{ "parse": ["roles"] }`.

---

## Operations

### Backup

```bash
./scripts/backup.sh
```

Writes `backups/<timestamp>/` containing a Postgres logical dump
(`n8n-postgres.dump`) and a tarball of the n8n data volume (`n8n-data.tar.gz`).
The script derives the volume name from the Compose project (honouring
`COMPOSE_PROJECT_NAME`, else the lower-cased project directory) and aborts if
that volume doesn't exist.

> The `N8N_ENCRYPTION_KEY` is **not** in the backup by design — store it in your
> vault. A dump without the matching key is undecryptable.

### Restore

```bash
./scripts/restore.sh backups/<timestamp>
```

**Precondition:** the `.env` on the target host must contain the **same**
`N8N_ENCRYPTION_KEY` used when the backup was taken, or restored credentials
decrypt to garbage. The script checks the key is at least set, brings up Postgres,
restores the dump, restores the data volume, then starts the full stack.

### Upgrading n8n

Bump the pinned tags in `docker-compose.yml` (keep `n8n` and `n8n-runners` on the
**exact same version** — a docs requirement), take a backup first, then
`docker compose pull && docker compose up -d`.

---

## Configuration reference

Core stack (`docker-compose.yml`):

| Variable                 | Default / example                         | Purpose                              |
| ------------------------ | ----------------------------------------- | ------------------------------------ |
| `POSTGRES_USER` / `_DB`  | `n8n` / `n8n`                             | Postgres role & database.            |
| `POSTGRES_PASSWORD`      | —                                         | Postgres password.                   |
| `N8N_ENCRYPTION_KEY`     | —                                         | Master credential-encryption key.    |
| `N8N_RUNNERS_AUTH_TOKEN` | —                                         | Shared n8n ↔ runner secret.          |
| `N8N_HOST` / `_PROTOCOL` | `localhost` / `http`                     | Public host & protocol for webhooks. |
| `WEBHOOK_URL`            | `http://localhost:5678/`                 | Base URL n8n registers for webhooks. |
| `GENERIC_TIMEZONE`       | `America/Vancouver`                      | n8n + container timezone.            |

Discord bridge (`discord-bot` service):

| Variable                 | Default                                        | Purpose                          |
| ------------------------ | ---------------------------------------------- | -------------------------------- |
| `DISCORD_TOKEN`          | —                                              | Bot token (**required**).        |
| `BOT_API_TOKEN`          | —                                              | Bearer secret for the bot API (**required**). |
| `DISCORD_CLIENT_ID`      | —                                              | App ID (optional; for slash cmds). |
| `DISCORD_GUILD_ID`       | —                                              | Pin to one guild (optional).     |
| `N8N_WEBHOOK_URL`        | `http://n8n:5678/webhook/discord-events`       | Where events are forwarded.      |
| `N8N_WEBHOOK_TOKEN` / `_HEADER` | — / `authorization`                     | Optional auth sent to n8n.       |
| `N8N_FORWARD_TIMEOUT_MS` / `_RETRIES` | `10000` / `2`                     | Forward timeout & retries.       |
| `BOT_HTTP_PORT`          | `3000`                                         | Bot API port (internal only).    |
| `FORWARD_MEMBER_EVENTS`  | `false`                                        | Forward joins/leaves (needs privileged intent). |
| `IGNORE_BOT_MESSAGES`    | `true`                                         | Skip bot-authored messages.      |
| `LOG_LEVEL`              | `info`                                         | `error` \| `warn` \| `info` \| `debug`. |

---

## Troubleshooting

- **Bot exits immediately / crash-loops** — an invalid `DISCORD_TOKEN`. The bot
  boots its HTTP server, then exits ~200 ms later with
  `Discord login failed: An invalid token was provided.` Under
  `restart: unless-stopped` it will loop and the healthcheck never passes. Fix the
  token.
- **`disallowed intents` on login** — enable **Message Content Intent** (and
  **Server Members Intent** if `FORWARD_MEMBER_EVENTS=true`) in the Developer
  Portal.
- **Runner won't register / Code nodes fail** — `N8N_RUNNERS_AUTH_TOKEN` is empty
  or differs between `n8n` and `n8n-runners`. Set the same value in `.env`.
- **Build fails: `docker-credential-desktop.exe … not found`** (WSL2 + Docker
  Desktop) — your `~/.docker/config.json` has `"credsStore": "desktop.exe"`, a
  Windows helper not on the Linux `PATH`. The base image is public, so either
  remove that line or build with a clean config:
  `DOCKER_CONFIG=$(mktemp -d) docker compose build` (write `{}` to
  `$DOCKER_CONFIG/config.json` first).
- **n8n won't start after changing the encryption key** — n8n refuses to boot if
  the key differs from the one that encrypted the stored data. Restore the
  original key from your vault.

---

## Repository layout

```
.
├── docker-compose.yml     # the deployment definition (services, volumes)
├── .env.example           # template — copy to .env and fill in (real .env is gitignored)
├── discord-bot/           # Discord ↔ n8n bridge (Node 20 / discord.js)
│   ├── Dockerfile
│   └── src/               # config, discord client, events, forwarder, HTTP API
└── scripts/
    ├── backup.sh          # snapshot Postgres + n8n data volume
    └── restore.sh         # rehydrate from a backup
```

---

## Security model in one paragraph

n8n and Postgres never face the internet (n8n binds to `127.0.0.1` only; put a
proxy/VPN in front for remote access). Code execution is sandboxed in the
external runner. The Discord bot is transport-only, publishes no host ports,
authenticates n8n's calls with a constant-time Bearer check, caps request bodies
at 1 MB, and suppresses mass-mention injection by default. The one irreplaceable
secret is `N8N_ENCRYPTION_KEY` — guard it like a root password.
