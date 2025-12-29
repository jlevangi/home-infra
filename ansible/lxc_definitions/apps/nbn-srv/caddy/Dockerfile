FROM caddy:2.10.2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.1 \
    --with github.com/hslatman/caddy-crowdsec-bouncer@v0.9.2

FROM caddy:2.10.2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
