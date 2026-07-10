# Operating & Extending the Bonchaz Discord Bot

A practical guide to running the Discord ↔ n8n bridge day-to-day and adding new
capabilities. Companion to [README.md](README.md) — the README covers first-time
setup and reference; **this** doc covers *how it works* and *how you extend it*.

## Contents

1. [Mental model — how it actually works](#1-mental-model--how-it-actually-works)
2. [Operating the bot day-to-day](#2-operating-the-bot-day-to-day)
3. [The command API (n8n → bot): current actions](#3-the-command-api-n8n--bot-current-actions)
4. [Adding a new bot action ("tool")](#4-adding-a-new-bot-action-tool)
5. [Forwarding a new Discord event (bot → n8n)](#5-forwarding-a-new-discord-event-bot--n8n)
6. [Building the n8n side — where your real tools live](#6-building-the-n8n-side--where-your-real-tools-live)
7. [Rules to keep (security)](#7-rules-to-keep-security)
8. [Troubleshooting](#8-troubleshooting)
9. [File map](#9-file-map)

---

## 1. Mental model — how it actually works

```
   Discord            discord-bot (transport only)              n8n (all the logic)
 ┌─────────┐   event  ┌───────────────────────────┐  POST     ┌────────────────────┐
 │ #channel│ ───────► │ events.js → forward.js     │ ────────► │ Webhook node        │
 │  users  │          │  (serialise + POST)        │  /webhook │  → your workflow    │
 │         │ ◄─────── │ httpServer.js command API  │ ◄──────── │ HTTP Request node   │
 └─────────┘   action └───────────────────────────┘  Bearer   └────────────────────┘
```

**The one idea that matters:** the bot holds **no business logic**. It is a dumb,
secure pipe. All decisions — what to do with a message, when to reply, what
counts as a compliance event — live in **n8n workflows**. You will spend most of
your time in n8n, not in the bot code. You only touch the bot when you need a new
*kind* of pipe (a new action it can perform, or a new event it should forward).

Two directions, two mechanisms:

| Direction | Mechanism | Code | Auth |
| --------- | --------- | ---- | ---- |
| **Discord → n8n** | Bot POSTs an event envelope to an n8n **Webhook** node | `events.js` + `forward.js` | optional `N8N_WEBHOOK_TOKEN` |
| **n8n → Discord** | n8n **HTTP Request** node calls the bot's API | `httpServer.js` | `Authorization: Bearer <BOT_API_TOKEN>` |

The event envelope the bot sends to n8n is always:

```json
{ "type": "messageCreate", "timestamp": "2026-07-06T23:00:00.000Z", "data": { "...": "..." } }
```

Your workflow branches on `type` (a Switch node) and reads the payload from `data`.

---

## 2. Operating the bot day-to-day

All commands run from the repo root. This host (WSL2 + Docker Desktop) has a
broken credential helper, so **builds** must use a clean `DOCKER_CONFIG` — set it
once per shell:

```bash
export DOCKER_CONFIG=$(mktemp -d) && echo '{}' > "$DOCKER_CONFIG/config.json"
```

(Non-build commands — up/stop/logs/exec — don't need it.)

### Start / stop / restart

```bash
docker compose up -d discord-bot      # start (create if needed)
docker compose stop discord-bot       # stop
docker compose restart discord-bot    # restart
docker compose ps                     # status of everything
```

### Logs

```bash
docker compose logs -f discord-bot            # follow
docker compose logs --tail 50 discord-bot     # last 50 lines
```

A healthy start looks like:

```
[INFO] HTTP command API listening on :3000 (n8n → bot)
[INFO] Discord ready as BonchazCompliance#1261 (id ...)
```

Turn up verbosity by setting `LOG_LEVEL=debug` in `.env` and recreating the
container — at `debug` you'll see `forwarded <type> to n8n` lines for every
inbound event.

### Health

The bot exposes an unauthenticated `/health` (not published to the host — reach
it from inside the network):

```bash
docker compose exec -T discord-bot node -e "fetch('http://localhost:3000/health').then(r=>r.json()).then(j=>console.log(j))"
# -> { status: 'ok', ready: true }
```

### Redeploy after a code change ⚠️

The bot's source is **copied into the image at build time** — it is *not* live-
mounted. Editing files under `discord-bot/src/` does **nothing** to the running
container until you rebuild:

```bash
export DOCKER_CONFIG=$(mktemp -d) && echo '{}' > "$DOCKER_CONFIG/config.json"
docker compose build discord-bot          # rebuild the image
docker compose up -d discord-bot          # recreate the container from it
```

For fast local iteration (no Docker), run it natively with auto-reload — it reads
a local `.env`:

```bash
cd discord-bot
npm install
cp ../.env .env        # or symlink; dotenv loads .env from the current dir
npm run dev            # node --watch: restarts on save
```

### Rotating secrets

- **`BOT_API_TOKEN`** (n8n ↔ bot): set a new value in `.env`
  (`openssl rand -hex 32`), `docker compose up -d discord-bot` to recreate, **and**
  update the matching value in your n8n Header Auth credential. Both sides must
  match or every call returns `401`.
- **`DISCORD_TOKEN`**: reset it in the Developer Portal, update `.env`, recreate
  the container.

### Backups

```bash
./scripts/backup.sh                        # -> backups/<timestamp>/
./scripts/restore.sh backups/<timestamp>   # restore (needs same N8N_ENCRYPTION_KEY)
```

The bot itself is **stateless** — nothing to back up. What matters is n8n's
Postgres + data volume (workflows & credentials) and the `N8N_ENCRYPTION_KEY`.

### Restart / crash-loop behaviour

The bot runs under `restart: unless-stopped`. If `DISCORD_TOKEN` is invalid or a
required intent is disabled, it boots the HTTP server, fails login, exits, and
Docker restarts it in a loop (~1–2 s). If you see that loop, it's almost always
the token or the Message Content Intent — check the logs, fix, and it self-heals.

---

## 3. The command API (n8n → bot): current actions

Reachable only inside the compose network at `http://discord-bot:3000`. Every
route except `/health` needs `Authorization: Bearer <BOT_API_TOKEN>`.

| Method & path     | Required body                              | Returns                       |
| ----------------- | ------------------------------------------ | ----------------------------- |
| `GET  /health`    | — (no auth)                                | `{ status, ready }`           |
| `POST /messages`  | `channelId`, `content` and/or `embeds`     | `{ id, channelId }`           |
| `POST /reactions` | `channelId`, `messageId`, `emoji`          | `{ ok: true }`                |
| `POST /dms`       | `userId`, `content` and/or `embeds`        | `{ id, channelId }`           |

Optional on sends: `replyTo` (message id), `tts`, `allowedMentions` (see
[security](#7-rules-to-keep-security)).

---

## 4. Adding a new bot action ("tool")

Anything you want n8n to be able to *do on Discord* that isn't in the table above
is a new route. The pattern is deliberately tiny.

**Where:** the `routes` object in `discord-bot/src/httpServer.js`. Each handler is
an `async (body) => {...}` with the discord.js `client`, `config`, and `logger` in
scope. Throw `httpError(status, message)` for client errors (400/404); anything
else becomes a `502`. Return a plain object → it's sent as `200` JSON.

### Example A — a read action: list the servers the bot is in

```js
// add inside the `routes` object in httpServer.js
'GET /guilds': async () => {
  const guilds = [...client.guilds.cache.values()].map((g) => ({
    id: g.id,
    name: g.name,
    memberCount: g.memberCount,
  }));
  return { guilds };
},
```

Now n8n can `GET http://discord-bot:3000/guilds` (with the Bearer header) instead
of talking to Discord directly.

### Example B — a write action: edit a message

```js
// add inside the `routes` object in httpServer.js
'POST /edit': async (body) => {
  if (!body.channelId || !body.messageId) throw httpError(400, 'channelId and messageId are required');
  if (!body.content && !body.embeds) throw httpError(400, 'content or embeds is required');
  const channel = await client.channels.fetch(String(body.channelId));
  if (!channel || !channel.isTextBased()) throw httpError(400, 'channel is not text-based');
  const message = await channel.messages.fetch(String(body.messageId));
  const payload = {};
  if (body.content) payload.content = String(body.content);
  if (Array.isArray(body.embeds)) payload.embeds = body.embeds;
  payload.allowedMentions = resolveAllowedMentions(body); // keep ping-safety
  const edited = await message.edit(payload);
  return { id: edited.id, channelId: edited.channelId };
},
```

**Then:** rebuild + recreate (see [redeploy](#redeploy-after-a-code-change-)),
and test from inside the network:

```bash
docker compose exec -T discord-bot node -e "const t=process.env.BOT_API_TOKEN; fetch('http://localhost:3000/guilds',{headers:{authorization:'Bearer '+t}}).then(r=>r.json()).then(j=>console.log(j))"
```

**Checklist for any new action:** validate inputs → `String(...)` untrusted ids →
for sends, pass `resolveAllowedMentions(body)` → return the created/affected id(s)
so n8n can chain follow-up steps.

---

## 5. Forwarding a new Discord event (bot → n8n)

Anything that happens *on Discord* that you want a workflow to react to is a new
forwarded event. Two files may be involved:

1. **`discord-bot/src/events.js`** — register the handler and call `forward(type, data)`.
2. **`discord-bot/src/discordClient.js`** — add the **gateway intent** the event
   needs (and a `Partial` if the event can arrive uncached).

> **Intents 101:** most intents (e.g. `GuildMessageReactions`) just need to be
> added to the array in `discordClient.js`. **Privileged** intents
> (`MessageContent`, `GuildMembers`) must *also* be enabled in the Developer
> Portal → Bot → Privileged Gateway Intents, or login fails with
> `Used disallowed intents`.

### Example — forward reaction-adds

**`discordClient.js`** — add the intent (and the Reaction partial so you also get
reactions on messages that weren't cached):

```js
import { Client, GatewayIntentBits, Partials } from 'discord.js';
// ...
const intents = [
  GatewayIntentBits.Guilds,
  GatewayIntentBits.GuildMessages,
  GatewayIntentBits.MessageContent,
  GatewayIntentBits.GuildMessageReactions,   // <-- added (not privileged)
];
// ...
const partials = [Partials.Message, Partials.Channel, Partials.Reaction]; // <-- added
```

**`events.js`** — inside `registerEvents(...)`, add the handler using the same
`forward(type, data)` envelope everything else uses:

```js
client.on(Events.MessageReactionAdd, async (reaction, user) => {
  if (config.ignoreBots && user.bot) return;
  const r = reaction.partial ? await resolvePartial(reaction, logger) : reaction;
  await forward('messageReactionAdd', {
    emoji: r.emoji?.name ?? null,
    messageId: r.message?.id ?? null,
    channelId: r.message?.channelId ?? null,
    userId: user.id,
  });
});
```

Rebuild + recreate. n8n now receives `{ "type": "messageReactionAdd", ... }` on
the same webhook.

---

## 6. Building the n8n side — where your real tools live

This is the bulk of your work. Two node types connect a workflow to the bot.

### Inbound: receive Discord events (Webhook node)

1. New workflow → **Webhook** node → **HTTP Method** `POST`, **Path**
   `discord-events`.
2. Save, then toggle the workflow **Active**. *Active* registers the production
   `/webhook/discord-events` path the bot posts to; **test mode only registers
   `/webhook-test/...`**, which the bot does not use.
3. Add a **Switch** node on `{{ $json.body.type }}` to route `messageCreate`,
   `messageReactionAdd`, etc. to different branches — one branch per "tool".

> One webhook receives **all** event types. Fan out by `type` in the workflow;
> don't make a webhook per event.

### Outbound: act on Discord (HTTP Request node)

1. Create a **Header Auth** credential once: **Name** `Authorization`, **Value**
   `Bearer <your BOT_API_TOKEN>`.
2. **HTTP Request** node → **Method** `POST`, **URL**
   `http://discord-bot:3000/messages`, attach the Header Auth credential, body
   (JSON):

   ```json
   { "channelId": "={{ $json.body.data.message.channelId }}", "content": "Logged ✅" }
   ```

That round-trips: a Discord message hits your webhook → your logic runs → you
reply via the HTTP Request node. That closed loop *is* a compliance "tool".

### Adding a "tool" end-to-end (the recipe)

1. Decide the trigger: a Discord event (inbound) or a schedule/other n8n trigger.
2. If it needs a Discord action the bot can't do yet → add a route
   ([§4](#4-adding-a-new-bot-action-tool)). If it needs an event not yet forwarded
   → add it ([§5](#5-forwarding-a-new-discord-event-bot--n8n)).
3. Build the logic as an n8n workflow branch.
4. Call the bot with an HTTP Request node for any Discord side effects.
5. Activate and test by doing the real thing in Discord.

---

## 7. Rules to keep (security)

- **Never publish the bot's port** to the host. Only n8n (same network) should
  reach `:3000`. It has no rate limiting or per-caller identity beyond the shared
  Bearer token.
- **Keep ping-suppression.** Message content comes from untrusted users and can
  round-trip through n8n back into a send. Every send route passes
  `resolveAllowedMentions(body)`, which defaults to *no mentions*. Only send an
  explicit `allowedMentions` when a workflow genuinely needs to ping — and never
  build it from raw user input.
- **Guard `N8N_ENCRYPTION_KEY`** like a root password (it decrypts every stored
  credential) and keep the real `.env` out of git.
- **Least-privilege the bot** in Discord — grant only the channel/permission it
  needs, per server.

---

## 8. Troubleshooting

| Symptom | Cause & fix |
| ------- | ----------- |
| Bot crash-loops, `An invalid token was provided` | Bad `DISCORD_TOKEN`. Reset in the portal, update `.env`, recreate. |
| `Used disallowed intents` | A privileged intent (Message Content / Server Members) is off in the Developer Portal. Enable + **Save Changes**. |
| n8n webhook returns `404` | No **Active** workflow at path `discord-events`. Activate it (not test mode). |
| Every bot API call is `401` | `BOT_API_TOKEN` in `.env` ≠ the n8n Header Auth credential value. |
| Code edit had no effect | You didn't rebuild. `docker compose build discord-bot && docker compose up -d discord-bot`. |
| `docker-credential-desktop.exe … not found` on build | WSL credsStore issue. `export DOCKER_CONFIG=$(mktemp -d) && echo '{}' > "$DOCKER_CONFIG/config.json"` then build. |
| New event never arrives | Missing gateway intent in `discordClient.js`, or (if privileged) not enabled in the portal. |

---

## 9. File map

```
discord-bot/src/
├── index.js          # wiring: load config, build client, register events, start HTTP server, login
├── config.js         # env parsing + validation (fail-fast). Add new env vars here.
├── discordClient.js  # gateway intents & partials. Add intents here for new events.
├── events.js         # Discord -> n8n. Add client.on(...) handlers + forward(type, data) here.
├── forward.js        # the retrying POST to the n8n webhook (rarely changed)
├── httpServer.js     # n8n -> Discord command API. Add new actions to the `routes` object here.
└── logger.js         # tiny leveled logger

scripts/              # backup.sh / restore.sh (n8n state, not the bot)
docker-compose.yml    # the whole stack
.env                  # real secrets (gitignored)
README.md             # setup & reference   |   OPERATING.md  # this file
```

**Rule of thumb:** *new action n8n can perform* → `httpServer.js`. *New event n8n
should hear about* → `events.js` (+ maybe an intent in `discordClient.js`). *New
behaviour/logic* → an n8n workflow, not code.
