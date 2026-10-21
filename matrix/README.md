# matrix

Single-user Matrix homeserver whose only job is to host bridges, so WhatsApp and
Android text messages (SMS/RCS via Google Messages) can be read and answered from
one place (krb-tui, Element). LAN only: federation is off and nothing is public.

    phone (WhatsApp, Google Messages)
            |
    whatsapp bridge, gmessages bridge  ---\
                                           +-- postgres
    synapse:8008 (edge network) ----------/
            |
    envoy (host :80, Host: matrix) -> clients on the LAN (Element, krb-tui)

| Service     | Image                                  | Database   |
|-------------|----------------------------------------|------------|
| `postgres`  | `postgres:17`                          | -          |
| `synapse`   | `matrixdotorg/synapse`                 | `synapse`  |
| `whatsapp`  | `dock.mau.dev/mautrix/whatsapp`        | `whatsapp` |
| `gmessages` | `dock.mau.dev/mautrix/gmessages`       | `gmessages`|

Only `synapse` joins the `edge` network; Envoy routes `matrix`, `matrix.*` to it
(see `../envoy/README.md`). Nothing publishes ports.

## Files

- `docker-compose.yml`, `init-db.sql`, `.env.example`, `setup`: committed.
- `.env`, `postgres/`, `synapse/`, `whatsapp/`, `gmessages/`: git-ignored. They hold
  the database password, bridge tokens, the WhatsApp and Google Messages sessions
  and all bridged messages. Back them up; never commit them.
- The data directories are owned by container users (Synapse 991, bridges 1337),
  so reading them on the host needs `sudo`. `setup` edits them through a container.

## First-time setup (on the server)

1. Envoy and the `edge` network must already be set up (`../envoy/README.md`).
2. Apply the Envoy route for `matrix` (already in `../envoy/envoy.yaml`):

        ../envoy/reload

3. Make `matrix` resolve to the server: router DNS / Pi-hole for the LAN (same as
   `go`), and on the server itself:

        echo '127.0.0.1 matrix' | sudo tee -a /etc/hosts

4. Create `.env`:

        ./setup

   This writes `.env` with a random Postgres password and stops. Edit it and set:
   - `SERVER_NAME`: the part after the colon in your user id, e.g. `kybar.home`.
     **It is permanent**: changing it later means wiping `synapse/` and the bridges.
     It does not need to resolve anywhere.
   - `ADMIN_USER`: your username, e.g. `kybar` -> `@kybar:kybar.home`.

5. Run it again:

        ./setup

   It generates the Synapse and bridge configs, applies our settings to them,
   registers the bridges with Synapse, starts everything, and asks for a password
   for your account. At the end it checks that `http://matrix` reaches Synapse.

`setup` is safe to re-run: it keeps existing configs and secrets, re-applies the
settings below, and restarts the stack so they take effect.

## Linking your phone

Use Element Desktop on the laptop, homeserver `http://matrix`, and sign in as
`@<ADMIN_USER>:<SERVER_NAME>`. (Element in a browser needs HTTPS; see "Enabling
HTTPS" in `../envoy/README.md` if you want that.)

**WhatsApp**: start a chat with `@whatsappbot:<SERVER_NAME>` and send `login qr`.
On the phone: WhatsApp -> Settings -> Linked devices -> Link a device, scan the code.

**Text messages**: start a chat with `@gmessagesbot:<SERVER_NAME>` and send `login`,
then pick the QR option. On the phone: Messages -> profile picture -> Device
pairing -> QR code scanner, scan the code.

Your chats appear as rooms over the next few minutes, with recent history.

Keep in mind:

- Google Messages relays through the phone: SMS only flows while the phone is on
  and online.
- WhatsApp works without the phone, but the phone has to come online every couple
  of weeks or WhatsApp drops the linked device (log in again with `login qr`).
- Read receipts you send in Matrix are forwarded to your contacts. Presence
  ("online") is disabled in Synapse so the bridge never looks permanently online.

## Settings that `setup` applies

Synapse (`synapse/homeserver.yaml`):

- Postgres instead of SQLite; `public_baseurl` = `PUBLIC_URL` from `.env`.
- Federation off (`federation_domain_whitelist: []`, no trusted key servers).
- Registration off; presence off; trusts `X-Forwarded-For` from Envoy.
- `app_service_config_files`: the two bridges plus `doublepuppet.yaml`.

Each bridge (`<bridge>/config.yaml`):

- Talks to `http://synapse:8008`; listens on `0.0.0.0` inside the stack.
- Postgres database named after the bridge.
- Permissions: users of `SERVER_NAME` can use it; you are admin.
- Backfill on (recent history when a chat is first bridged); rooms not federated.
- Double puppeting via `synapse/appservices/doublepuppet.yaml`: messages you send
  from the phone show up as sent by you, not by a "ghost" of your own number.
- No end-to-bridge encryption (everything is on this server), so clients like
  krb-tui need no key handling. Logs go to stdout only (`docker compose logs`).
- WhatsApp: no status-broadcast (stories) room.

Anything else can be edited by hand (`sudo $EDITOR whatsapp/config.yaml`), then
`docker compose restart whatsapp`. Hand edits to the keys above are overwritten by
the next `./setup`.

## krb-tui on this server

Over SSH (Tailscale), run krb-tui here inside tmux so it keeps syncing between
sessions. It uses `http://matrix` like everywhere else (hence the `/etc/hosts`
line). For `L` (copy link) to reach the laptop's clipboard over SSH, tmux needs:

    set -g set-clipboard on

## Day to day

    docker compose ps                    # status
    docker compose logs -f whatsapp      # follow one service
    docker compose restart gmessages     # restart one service

Check from the LAN:

    curl -s http://matrix/_matrix/client/versions   # JSON from Synapse

## Upgrading

Images are pinned. To upgrade, change the tag in `docker-compose.yml` (check the
release notes: Synapse on GitHub `element-hq/synapse`, bridges `mautrix/whatsapp`
and `mautrix/gmessages`), then:

    docker compose pull
    docker compose up -d

Postgres is pinned to a major version; moving to a new major needs a dump and
restore, not just a tag change.

## Backups

Everything is in `postgres/`, `synapse/` (signing key, media, config) and the two
bridge directories. Simplest consistent backup:

    docker compose stop
    sudo tar czf matrix-backup-$(date +%F).tgz .env postgres synapse whatsapp gmessages
    docker compose start

## Troubleshooting

- `setup` says the server name changed: `.env` must keep the `SERVER_NAME` that
  Synapse was first generated with.
- A bridge keeps restarting: `docker compose logs <bridge>`. Usually Synapse was not
  ready yet (it retries) or its registration is out of date (re-run `./setup`).
- The bot does not answer: check `docker compose logs synapse` for appservice
  errors, and that you are messaging the bot on your own server name.
- `http://matrix` returns Envoy's 404: the route is not applied; run `../envoy/reload`.
- `http://matrix` returns 503: Synapse is down, or not on the `edge` network.
