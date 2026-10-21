# envoy

Edge proxy for the home server. All HTTP(S) traffic comes in through Envoy,
which routes by hostname to containers on the shared `edge` Docker network.
Backend containers do not publish ports themselves.

Every app is served over HTTPS at `<app>.home.kybar.win`, using one wildcard
certificate from Let's Encrypt (see `../certs/README.md`). Plain HTTP serves
nothing except the `go/` redirect.

    client -> :443 (host) -> envoy -> edge network -> golinks:80
                                                   -> flashcards:8000
                                                   -> synapse:8008
                                                   -> <next service>
    client -> :80  (host) -> envoy -> go/<name>: redirect to https://go.home.kybar.win/<name>
                                     anything else: 404 (HTTPS required)

## Current routes

HTTPS (port 443):

| Hostname                    | Backend           |
|-----------------------------|-------------------|
| `go.home.kybar.win`         | `golinks:80`      |
| `flash.home.kybar.win`, `flashcards.home.kybar.win` | `flashcards:8000` |
| `matrix.home.kybar.win`     | `synapse:8008` (see `../matrix/README.md`) |
| anything else               | 404               |

HTTP (port 80):

| Hostname                    | Result                                          |
|-----------------------------|-------------------------------------------------|
| `go`, `go.*`                | 307 redirect to `https://go.home.kybar.win`, path and query kept |
| anything else               | 404 "Only HTTPS is served here"                 |

The `go` redirect keeps go-links working: typing `go/jira/X-1` in a browser
requests `http://go/jira/X-1` and lands on `https://go.home.kybar.win/jira/X-1`.
It uses 307 so browsers do not cache it forever, and POSTs stay POSTs.

Nothing else is served or redirected over HTTP, on purpose: a client
configured with an `http://` URL fails loudly instead of sending a request
(and possibly a password or token) in the clear before being redirected.
Old names like `http://matrix` and `http://flash` therefore stop working;
use the `https://<app>.home.kybar.win` names.

## DNS

Every device, the server included, must resolve `*.home.kybar.win` to the
server's LAN IP. One wildcard record covers all current and future apps.

**Option A (simplest): a public record in Cloudflare.** DNS -> Records -> Add:
type `A`, name `*.home`, IPv4 = the server's LAN IP (e.g. `192.168.1.10`),
proxy status **DNS only** (grey cloud). Works for every device with no router
changes. Downsides: it publishes your LAN IP (nothing is reachable through it
from outside), and some routers' "DNS rebinding protection" drops public
answers that point at private IPs. If the names do not resolve at home, allow
`home.kybar.win` in the router's rebinding settings, or use option B.

**Option B: a wildcard in your LAN DNS.** dnsmasq-based (most routers, Pi-hole):

    address=/home.kybar.win/192.168.1.10

In Pi-hole v6 this goes in Settings -> All settings -> Miscellaneous ->
`misc.dnsmasq_lines` (the "Local DNS Records" page does not do wildcards).
The server itself also needs it, e.g. `/etc/hosts` entries per app if it does
not use that DNS server.

Check from any device:

    getent hosts matrix.home.kybar.win        # -> the server's LAN IP

## First-time setup (on the server)

    docker network create edge          # once; shared by all stacks
    cd <infra checkout>/envoy
    docker compose up -d

Then in the golinks checkout (its compose file no longer publishes port 80
and joins `edge`):

    docker compose up -d

Order: stop the old golinks (or bring it up with the new compose file)
before starting Envoy, since the old one holds host port 80.

Check it:

    curl -si http://go/                             # 307 to https://go.home.kybar.win/
    curl -si https://go.home.kybar.win/             # golinks index
    curl -si http://matrix.home.kybar.win/          # 404: HTTPS only
    curl -si https://nope.home.kybar.win/           # 404 from Envoy
    docker compose logs -f                          # access log

### Switching an existing HTTP-only Envoy to HTTPS (one time)

1. DNS for `*.home.kybar.win` (above).
2. Get the certificate: follow `../certs/README.md` (Cloudflare token, then
   `../certs/renew`). It installs `certs/home.kybar.win/` for Envoy.
3. Validate the new config and restart, then recreate the container so it
   publishes 443 and runs with the pinned uid:

        ./reload && docker compose up -d

4. Run the checks above. `go/...` keeps working through the redirect;
   bookmarks to any other `http://` name must be updated to
   `https://<app>.home.kybar.win`.

## Adding a service

1. In the service's compose file: remove `ports:`, add it to the `edge`
   network (declared `external: true`, same as golinks).
2. In `envoy.yaml`:
   - a cluster pointing at `<compose service name>:<port>`;
   - a virtual host for `<app>.home.kybar.win` on the **HTTPS** listener.
   Do not add anything to the HTTP listener; only `go` belongs there.
3. Apply it with `./reload` (see below). DNS and the certificate already
   cover any `<app>.home.kybar.win`.

## Changing the config

Edit `envoy.yaml`, then run:

    ./reload

It validates the config using the same image as the running Envoy and only
restarts if the config is valid, then shows recent logs and status. Works
from any directory (`~/infra/envoy/reload`, etc.).

`docker compose up -d` does NOT apply `envoy.yaml` edits (Compose only sees
changes to `docker-compose.yml` or the image). Use `docker compose up -d`
only after editing `docker-compose.yml`, e.g. bumping the image.

## Certificates

- One wildcard certificate, `*.home.kybar.win`, in `certs/home.kybar.win/`
  (`fullchain.pem`, `privkey.pem`). `certs/` is git-ignored except for its
  `.gitignore`.
- `../certs/renew` issues and renews it (weekly cron) and runs `./reload` when
  it changes; Envoy only reads certificate files at startup.
- The key is owned by uid 101 with mode 600. `docker-compose.yml` pins the
  envoy user to that uid (`ENVOY_UID`/`ENVOY_GID`) so it can read it.
- A certificate for a different domain needs its own filter chain with
  `filter_chain_match: { server_names: [...] }` and a `tls_inspector`
  listener filter (see the comment in `envoy.yaml`).

## Notes

- Envoy runs as non-root in the official image, so it listens on 8080/8443
  inside the container and Docker maps 80/443 to them.
- HTTPS supports HTTP/2 (ALPN `h2`) as well as HTTP/1.1.
- Admin interface is bound to 127.0.0.1 in the container only:
  `docker compose exec envoy curl -s localhost:9901/clusters`
  (install curl in the container, or use `wget` if present).
- Image is pinned to a minor version (`v1.34-latest`); bump it deliberately.
