# golinks

Small go-links redirector (go/<name> -> URL) running in Docker on the home server.

- Repo: git@github.com:kyb-ar/golinks.git
- Local checkout: ~/tmp/golinks
- Server checkout: (location on server not recorded yet)

## How it works

- `golinks.py` is a single-file Python HTTP server (stdlib only).
- It reads the links file on every request, so edits take effect
  immediately with no restart.
- `GET /` shows an index of all links.
- `GET /<name>` redirects (302) to the target. Unknown names get a 404 page.
- Query strings are passed through to the target.

Environment variables:

| Variable       | Default                  | Set in Docker to  |
|----------------|--------------------------|-------------------|
| GOLINKS_FILE   | /opt/golinks/links.txt   | /data/links.txt   |
| GOLINKS_HOST   | 0.0.0.0                  | (default)         |
| GOLINKS_PORT   | 80                       | 80                |

## Links file

`data/links.txt`, one link per line: `<name> <url>`

- Lines starting with `#` and blank lines are ignored.
- Names are case-insensitive.
- If the URL contains `{}`, the rest of the path is substituted in:
  `jira https://jira.local/browse/{}` makes `go/jira/ISSUE-123` ->
  `https://jira.local/browse/ISSUE-123`.
- Otherwise the rest of the path is appended:
  `wiki https://wiki.local/` makes `go/wiki/Home` -> `https://wiki.local/Home`.

## Docker setup

- `Dockerfile`: `python:3-slim`, copies `golinks.py` into `/app`, exposes 80.
- `docker-compose.yml`: builds image `golinks:latest`,
  `restart: unless-stopped`, mounts `./data:/data:ro`. Publishes no ports;
  joins the external `edge` network and is served through Envoy (see
  `envoy/README.md`) for hostnames `go` and `go.*`.

Status as of 2026-09-27: the switch from publishing `80:80` to the `edge`
network is made in the local checkout but not yet committed, pushed, or
pulled on the server.

Commands (run from the repo directory on the server):

    docker compose up -d --build   # first start, or after changing golinks.py/Dockerfile
    docker compose up -d           # after changing docker-compose.yml
    docker compose logs -f         # follow logs
    docker compose down            # stop

Editing `data/links.txt` needs no restart.

### Why the directory mount

The links file used to be mounted as a single file
(`./links.txt:/data/links.txt:ro`). Single-file bind mounts are tied to the
file's inode, and editors that save by writing a new file and renaming it
(vim by default) leave the container seeing the old file until a restart.
Mounting the `data/` directory avoids this for any editor.

Status as of 2026-09-26: this change is made in the local checkout but not
yet committed, pushed, or pulled on the server.

## Docker without sudo (server)

    sudo usermod -aG docker $USER

Then fully log out and back in (new SSH session; old tmux/screen sessions
keep old groups), or `newgrp docker`. Note: `docker` group membership is
effectively root access.

If it still says permission denied, check:

- `id` lists `docker`
- `getent group docker` lists the user
- `ls -l /var/run/docker.sock` is `root docker`, `srw-rw----`
  (if not: `sudo systemctl restart docker`)
- errors about `~/.docker`: `sudo chown -R $USER:$USER ~/.docker`

Status as of 2026-09-26: was getting "permission denied" after adding the
group; not yet resolved.

## Alternative: systemd (no Docker)

The repo also has `golinks.service`, which runs the script directly:

- Runs as user/group `golinks` from `/opt/golinks/golinks.py`
- Links file `/opt/golinks/links.txt`, port 80 via `CAP_NET_BIND_SERVICE`
- Hardened: `NoNewPrivileges`, `ProtectSystem=strict`,
  writable only `/opt/golinks`
- Not currently in use.
