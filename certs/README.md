# certs

The wildcard TLS certificate for `*.home.kybar.win`, which Envoy uses for every
app on the home server (see `../envoy/README.md`).

It comes from Let's Encrypt using the DNS-01 challenge: Certbot proves we own
`kybar.win` by briefly adding a TXT record through the Cloudflare API. Nothing
on the home server has to be reachable from the internet.

- `renew`: gets the certificate the first time, renews it when due, copies it
  to `../envoy/certs/home.kybar.win/`, and reloads Envoy when it changed.
- `cloudflare.ini.example`: template for the Cloudflare API token.
- `cloudflare.ini`, `letsencrypt/`: git-ignored. The token, plus the Let's
  Encrypt account and private keys. `letsencrypt/` is owned by root (Certbot
  runs in a container); back it up with `sudo`.

## First-time setup (on the server)

1. **DNS**: `*.home.kybar.win` must resolve to the server on the LAN; see
   "DNS" in `../envoy/README.md`. (Getting the certificate does not need this,
   but using it does.)

2. **Cloudflare API token**: in the Cloudflare dashboard, My Profile ->
   API Tokens -> Create Token -> template **Edit zone DNS** ->
   Zone Resources: Include / Specific zone / `kybar.win` -> Create.
   The token can only edit DNS records of `kybar.win`.

3. **Save it**:

        cp cloudflare.ini.example cloudflare.ini
        chmod 600 cloudflare.ini
        $EDITOR cloudflare.ini            # paste after dns_cloudflare_api_token =

4. **Get the certificate**:

        ./renew

   Takes about a minute (it waits 30s for the DNS record to propagate).
   Afterwards `../envoy/certs/home.kybar.win/` holds `fullchain.pem` and
   `privkey.pem`. If Envoy is running it is reloaded; when switching Envoy to
   HTTPS for the first time, continue with "Switching an existing HTTP-only
   Envoy to HTTPS" in `../envoy/README.md`.

5. **Automatic renewal**: certificates last 90 days; `renew` only renews within
   30 days of expiry, so run it weekly. In the crontab of a user that can run
   `docker` (`crontab -e`, or `sudo crontab -e` while Docker still needs sudo):

        17 4 * * 1  /path/to/infra/certs/renew >> /var/log/cert-renew.log 2>&1

   (Use a log path that user can write, e.g. `$HOME/cert-renew.log`.)

## Checking

    sudo ls -l ../envoy/certs/home.kybar.win/
    echo | openssl s_client -connect matrix.home.kybar.win:443 \
        -servername matrix.home.kybar.win 2>/dev/null | openssl x509 -noout -subject -dates

The second command shows the certificate Envoy actually serves and its expiry.

## Notes

- Let's Encrypt no longer sends expiry emails, so the account is registered
  without an email address. Watch the cron log, or the expiry date above.
- The certificate (not the key) is public: Let's Encrypt logs every
  certificate in Certificate Transparency logs, so the name `*.home.kybar.win`
  is visible to anyone. Individual app names are not, thanks to the wildcard.
- To add a name outside `*.home.kybar.win`, add another `-d` to `renew` (and a
  filter chain in `../envoy/envoy.yaml` if it needs a separate certificate).
- Image `certbot/dns-cloudflare` is pinned in `renew`; bump it deliberately.
