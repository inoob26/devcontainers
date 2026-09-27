#!/usr/bin/env bash
# Runs as root on every container start (`postStartCommand`, via sudo): lets
# outgoing traffic reach only GitHub and the domains in
# `firewall-allowlist.txt`, rejects the rest. Covers the inner Docker daemon's
# containers too. Safe to rerun: `sudo /usr/local/sbin/init-firewall.sh`.
#
# Domains are resolved to IPs once per run: if a CDN moves a host to new
# addresses and it becomes unreachable, rerun the script.
#
# Takes no arguments and reads only root-owned files baked into the image:
# `vscode` may run it via sudo, so nothing it controls may change what it does.
set -euo pipefail

allowlist=/etc/devcontainer/firewall-allowlist.txt
set_name=allowed-hosts

ext_if="$(ip -4 route show default | awk '{print $5; exit}')"
gateway="$(ip -4 route show default | awk '{print $3; exit}')"

entries="$(mktemp)"
trap 'rm -f "$entries"' EXIT

{
    # The host, for `host.docker.internal` and a proxy running there.
    echo "$gateway"
    getent ahostsv4 host.docker.internal | awk '{print $1}' || true

    # GitHub publishes its ranges: github.com, the API and git.
    if meta="$(curl -fsS --max-time 20 https://api.github.com/meta)"; then
        python3 -c '
import json, sys
meta = json.loads(sys.argv[1])
for key in ("web", "api", "git"):
    for net in meta[key]:
        if ":" not in net:
            print(net)
' "$meta"
    else
        echo "init-firewall: can't fetch GitHub ranges, GitHub stays blocked" >&2
    fi

    while read -r line; do
        domain="${line%%#*}"
        domain="${domain//[[:space:]]/}"
        [[ -n "$domain" ]] || continue
        if ! getent ahostsv4 "$domain" | awk '{print $1}'; then
            echo "init-firewall: can't resolve $domain, skipped" >&2
        fi
    done < "$allowlist"
} | sort -u | sed "s/^/add $set_name-new /" > "$entries"

# Build the new set next to the live one and swap them: a rerun never leaves
# the container half open.
ipset create "$set_name" hash:net -exist
ipset create "$set_name-new" hash:net -exist
ipset flush "$set_name-new"
ipset restore -exist < "$entries"
ipset swap "$set_name-new" "$set_name"
ipset destroy "$set_name-new"

# The container's own traffic. DNS stays open: domains are resolved on use.
iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
# To the inner Docker daemon's containers.
iptables -A OUTPUT ! -o "$ext_if" -j ACCEPT
iptables -A OUTPUT -m set --match-set "$set_name" dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Traffic of the inner Docker daemon's containers. Docker jumps to DOCKER-USER
# from FORWARD and keeps an existing chain when it starts after this script.
iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER
iptables -A DOCKER-USER -o "$ext_if" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A DOCKER-USER -o "$ext_if" -p udp --dport 53 -j RETURN
iptables -A DOCKER-USER -o "$ext_if" -p tcp --dport 53 -j RETURN
iptables -A DOCKER-USER -o "$ext_if" -m set --match-set "$set_name" dst -j RETURN
iptables -A DOCKER-USER -o "$ext_if" -j REJECT --reject-with icmp-admin-prohibited

# No IPv6 egress at all: the allowlist is IPv4 only.
if ip6tables -L OUTPUT >/dev/null 2>&1; then
    ip6tables -F OUTPUT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -j REJECT
fi

# `--noproxy`: sudo drops the proxy variables anyway, this just makes it explicit.
if curl -fsS --noproxy '*' --max-time 5 https://example.com >/dev/null 2>&1; then
    echo "init-firewall: example.com is still reachable, the firewall doesn't work" >&2
    exit 1
fi
echo "init-firewall: egress limited to $(wc -l < "$entries") allowed addresses" >&2
