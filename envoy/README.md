# envoy

Edge proxy for the home server. All HTTP(S) traffic comes in through Envoy,
which routes by hostname to containers on the shared `edge` Docker network.
Backend containers do not publish ports themselves.

    client -> :80 / :443 (host) -> envoy -> edge network -> golinks:80
                                                         -> <next service>

## Current routes

| Hostnames       | Backend        | TLS |
|-----------------|----------------|-----|
| `go`, `go.*`    | `golinks:80`   | no  |
| anything else   | 404            |     |

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

    curl -si -H 'Host: go' http://localhost/        # golinks index
    curl -si -H 'Host: nope' http://localhost/      # 404 from Envoy
    docker compose logs -f                          # access log

## Adding a service

1. In the service's compose file: remove `ports:`, add it to the `edge`
   network (declared `external: true`, same as golinks).
2. In `envoy.yaml`: add a cluster pointing at `<compose service name>:<port>`
   and a virtual host mapping its hostnames to that cluster.
3. Apply it with `./reload` (see below).

## Changing the config

Edit `envoy.yaml`, then run:

    ./reload

It validates the config using the same image as the running Envoy and only
restarts if the config is valid, then shows recent logs and status. Works
from any directory (`~/infra/envoy/reload`, etc.).

`docker compose up -d` does NOT apply `envoy.yaml` edits (Compose only sees
changes to `docker-compose.yml` or the image). Use `docker compose up -d`
only after editing `docker-compose.yml`, e.g. opening 443 or bumping the
image.

Clients also need the hostname to resolve to the server (router DNS,
Pi-hole, `/etc/hosts`, etc.).

## Enabling HTTPS

The HTTPS listener is written but commented out in `envoy.yaml`.

1. Get certs. Put each under `certs/<hostname>/fullchain.pem` and
   `privkey.pem`. `certs/` is git-ignored except for its `.gitignore`.
   Options: Let's Encrypt via DNS-01 (works for LAN-only hosts if you own a
   public domain), or a local CA such as `mkcert` with its root installed on
   your devices.
2. Uncomment the `https` listener in `envoy.yaml` and the `443:8443` port in
   `docker-compose.yml`. Add one filter chain per certificate
   (`server_names` = the hostnames it covers) with a matching virtual host.
3. For services that should be HTTPS-only, add `require_tls: ALL` to their
   virtual host on the HTTP listener; Envoy then redirects HTTP to HTTPS.
4. Envoy reads cert files at startup, so run `./reload` after renewing certs.

Bare names like `go` can't get publicly trusted certs, so golinks can stay
HTTP while other services use HTTPS.

## Notes

- Envoy runs as non-root in the official image, so it listens on 8080/8443
  inside the container and Docker maps 80/443 to them.
- Admin interface is bound to 127.0.0.1 in the container only:
  `docker compose exec envoy curl -s localhost:9901/clusters`
  (install curl in the container, or use `wget` if present).
- Image is pinned to a minor version (`v1.34-latest`); bump it deliberately.
