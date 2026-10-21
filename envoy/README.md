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
server's LAN IP, `192.168.1.246`. One wildcard record covers all current and
future apps. Set up as follows:

1. **Cloudflare (done):** DNS -> Records: type `A`, name `*.home`, IPv4
   `192.168.1.246`, proxy status **DNS only** (grey cloud). This publishes the
   LAN IP, which is harmless: nothing is reachable through it from outside.

2. **pfSense (the router, 192.168.1.1):** its DNS Resolver (Unbound) has DNS
   rebinding protection, which throws away public answers that point at
   private addresses like 192.168.x.x. Clients then get SERVFAIL, and waiting
   does not help. Allow private answers for `home.kybar.win` only:

   1. pfSense web UI -> Services -> DNS Resolver -> General Settings.
   2. Scroll to "Custom options" (click **Display Custom Options** if hidden).
   3. Add these lines. If the box already has a `server:` line, add only the
      `private-domain` line under the existing one:

          server:
          private-domain: "home.kybar.win"

   4. **Save**, then **Apply Changes**. Unbound restarts, which also empties
      its cache.

   Rebinding protection stays on for every other domain.

   (If pfSense uses the DNS Forwarder (dnsmasq) instead of the Resolver:
   Services -> DNS Forwarder -> Advanced Options:
   `rebind-domain-ok=/home.kybar.win/`, then Save and Apply.)

3. **Check**, on the laptop and on the server. Both commands should print
   `192.168.1.246`:

       dig +short go.home.kybar.win @192.168.1.1   # pfSense itself
       getent hosts go.home.kybar.win               # what apps see

   If `dig` works but `getent` does not, the machine cached the failure:
   `resolvectl flush-caches` (systemd-resolved) and try again.

**Alternative: answer locally instead of asking Cloudflare.** Same Custom
options box in pfSense:

    server:
    local-zone: "home.kybar.win." redirect
    local-data: "home.kybar.win. IN A 192.168.1.246"

This keeps working when the internet is down and does not need the
Cloudflare record, but the IP then lives in two places if you keep both.
(Other dnsmasq-based routers and Pi-hole: `address=/home.kybar.win/192.168.1.246`.)

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
