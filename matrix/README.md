# matrix

Single-user Matrix homeserver whose only job is to host bridges, so WhatsApp and
Android text messages (SMS/RCS via Google Messages) can be read and answered from
one place (krb-tui). LAN only, HTTPS at `https://matrix.home.kybar.win`: federation is off and nothing is public.

    phone (WhatsApp, Google Messages)
            |
    whatsapp bridge, gmessages bridge  ---\
                                           +-- postgres
    synapse:8008 (edge network) ----------/
            |
    envoy (host :443, matrix.home.kybar.win) -> krb-tui (laptop on the LAN, or on this server over SSH)

| Service     | Image                                  | Database   |
|-------------|----------------------------------------|------------|
| `postgres`  | `postgres:17`                          | -          |
| `synapse`   | `matrixdotorg/synapse`                 | `synapse`  |
| `whatsapp`  | `dock.mau.dev/mautrix/whatsapp`        | `whatsapp` |
| `gmessages` | `dock.mau.dev/mautrix/gmessages`       | `gmessages`|

Only `synapse` joins the `edge` network; Envoy serves it over HTTPS at
`matrix.home.kybar.win` (see `../envoy/README.md`; HTTPS only, plain HTTP is not
served). Nothing publishes ports.

## Files

- `docker-compose.yml`, `init-db.sql`, `.env.example`, `setup`: committed.
- `.env`, `postgres/`, `synapse/`, `whatsapp/`, `gmessages/`: git-ignored. They hold
  the database password, bridge tokens, the WhatsApp and Google Messages sessions
  and all bridged messages. Back them up; never commit them.
- The data directories are owned by container users (Synapse 991, bridges 1337),
  so reading them on the host needs `sudo`. `setup` edits them through a container.

## First-time setup (on the server)

1. Envoy, HTTPS and DNS for `*.home.kybar.win` must already be set up
   (`../envoy/README.md`, `../certs/README.md`). The `matrix.home.kybar.win` route
   is already in `../envoy/envoy.yaml`.
2. Check that the server itself resolves the name (krb-tui may run here):

        getent hosts matrix.home.kybar.win

   If it does not, add `127.0.0.1 matrix.home.kybar.win` to `/etc/hosts`.
3. Create `.env`:

        ./setup

   This writes `.env` with a random Postgres password and stops. Edit it and set:
   - `SERVER_NAME`: the part after the colon in your user id. Use `kybar.win`.
     **It is permanent**: changing it later means wiping `synapse/` and the bridges.
     It does not need to resolve anywhere, and is separate from the
     `matrix.home.kybar.win` address clients connect to.
   - `ADMIN_USER`: your username, e.g. `kybar` -> `@kybar:kybar.win`.

4. Run it again:

        ./setup

   It generates the Synapse and bridge configs, applies our settings to them,
   registers the bridges with Synapse, starts everything, and asks for a password
   for your account. At the end it checks that `PUBLIC_URL` reaches Synapse.

5. Sign in and link your phone with krb-tui (next section).

`setup` is safe to re-run: it keeps existing configs and secrets, re-applies the
settings below, and restarts the stack so they take effect.

## Linking your phone

Everything is done from krb-tui, on the laptop or on this server:

    krb-tui matrix-login                 # once; your ADMIN_USER and the password from setup
    krb-tui matrix-link whatsapp
    krb-tui matrix-link gmessages

`matrix-login` uses `https://matrix.home.kybar.win` unless given another URL. `matrix-link` opens a
chat with the bridge's bot (`@whatsappbot:<SERVER_NAME>`, `@gmessagesbot:...`),
asks it for a QR login, and draws the QR code in the terminal. Scan it:

- **WhatsApp**: WhatsApp -> Settings -> Linked devices -> Link a device.
- **Text messages**: Messages -> profile picture -> Device pairing -> QR code scanner.

It exits once the bot reports "Successfully logged in"; Ctrl-C cancels. Your chats
are then bridged over the next few minutes, with recent history. Run `matrix-link`
again whenever a bridge loses its link (e.g. WhatsApp dropped the device).

Keep in mind:

- Google Messages relays through the phone: SMS only flows while the phone is on
  and online.
- WhatsApp works without the phone, but the phone has to come online every couple
  of weeks or WhatsApp drops the linked device (run `krb-tui matrix-link whatsapp` again).
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
sessions. It uses `https://matrix.home.kybar.win` like everywhere else. For `L` (copy link) to reach the laptop's clipboard over SSH, tmux needs:

    set -g set-clipboard on

## Day to day

    docker compose ps                    # status
    docker compose logs -f whatsapp      # follow one service
    docker compose restart gmessages     # restart one service

Check from the LAN:

    curl -s https://matrix.home.kybar.win/_matrix/client/versions   # JSON from Synapse

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
- `matrix-link` says the bot does not exist: the bridge is not running or not
  registered; `docker compose ps`, then `docker compose logs <bridge>`.
- `matrix-link` hangs without a QR code: check `docker compose logs <bridge>` and
  `docker compose logs synapse` for appservice errors.
- `https://matrix.home.kybar.win` returns Envoy's 404: the route is not applied;
  run `../envoy/reload`.
- It returns 503: Synapse is down, or not on the `edge` network.
- Certificate errors: see `../certs/README.md`.
- Moving an existing setup from `http://matrix` to HTTPS: set `PUBLIC_URL` in `.env`
  to `https://matrix.home.kybar.win/`, re-run `./setup`, then
  `krb-tui matrix-login` again.
