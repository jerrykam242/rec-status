#!/usr/bin/env bash
# Only Cloudflare (plus loopback and Docker bridges) may reach ports 80/443 on this host.
# Everything on example.com is proxied by Cloudflare, so a direct hit on 203.0.113.10 is
# either a scanner or someone skipping Cloudflare Access. Lives in its own nftables
# table (inet cf_origin), independent of 1Panel's and Docker's iptables-nft tables.
#   cf-origin-firewall.sh          refresh Cloudflare ranges (cached copy if offline) and apply
#   cf-origin-firewall.sh off      remove the table (open 80/443 to everyone again)
set -euo pipefail
NFT=/usr/sbin/nft
DIR=/etc/cf-origin

if [ "${1:-}" = off ]; then
  $NFT delete table inet cf_origin 2>/dev/null || true
  echo "cf_origin removed: 80/443 open to everyone."; exit 0
fi

fetch() {  # $1 = ips-v4|ips-v6; keep the cached list unless the download looks sane
  local tmp; tmp=$(mktemp)
  if curl -fsS --max-time 15 "https://www.cloudflare.com/$1" -o "$tmp" \
     && [ "$(grep -cE '^[0-9a-f.:]+/[0-9]+$' "$tmp")" -ge 5 ] \
     && ! grep -qvE '^[0-9a-f.:]+/[0-9]+$|^$' "$tmp"; then
    install -m 644 "$tmp" "$DIR/$1"
  else
    echo "cf-origin: could not refresh $1, using cached copy" >&2
  fi
  rm -f "$tmp"
  [ -s "$DIR/$1" ] || { echo "cf-origin: no $DIR/$1, refusing to apply" >&2; exit 1; }
}
fetch ips-v4; fetch ips-v6
v4=$(grep -E . "$DIR/ips-v4" | paste -sd, -); v6=$(grep -E . "$DIR/ips-v6" | paste -sd, -)

$NFT -f - <<NFT
table inet cf_origin
delete table inet cf_origin
table inet cf_origin {
  set cf4 { type ipv4_addr; flags interval; elements = { $v4 } }
  set cf6 { type ipv6_addr; flags interval; elements = { $v6 } }
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport { 80, 443 } jump web
    udp dport 443 jump web
  }
  chain web {
    iif "lo" accept
    ip saddr 172.16.0.0/12 accept    # Docker bridge networks
    ip saddr @cf4 accept
    ip6 saddr @cf6 accept
    counter drop
  }
}
NFT
echo "cf_origin applied: 80/443 limited to Cloudflare ($(wc -l < "$DIR/ips-v4") v4, $(wc -l < "$DIR/ips-v6") v6 ranges)."
