#!/bin/bash
# Flui management overlay (WireGuard) installation module
# Brings up this node's side of the tunnel at first boot, without waiting for
# anything to connect to it.
# Version: 1.1.0

# Define logging functions if not already defined (for standalone execution)
if ! type log &>/dev/null; then
    log() {
        echo "[$(date +'%H:%M:%S')] $1"
    }
fi

if ! type warn &>/dev/null; then
    warn() {
        echo "[$(date +'%H:%M:%S')] WARNING: $1"
    }
fi

if ! type error &>/dev/null; then
    error() {
        echo "[$(date +'%H:%M:%S')] ERROR: $1" >&2
        exit 1
    }
fi

# Not `wg0`, and not port 51820: k3s claims both when flannel runs on its
# wireguard-native backend. Flui does not use that backend today, but reserving
# them now keeps two indistinguishable WireGuard interfaces off the same host.
FLUI_WG_IFACE="${FLUI_WG_IFACE:-flui0}"
FLUI_WG_PORT="${FLUI_WG_PORT:-51821}"

# `overlay` = management only: one peer, the control cluster, dialled from here.
# `mesh` = this node also sits in a Flui-built private network, so it listens as
# well as dials and carries a peer per sibling. The difference is not cosmetic:
# in mesh mode K3s binds its node IP to this interface, so the tunnel has to be
# up and reachable both ways before K3s installs.
FLUI_WG_MODE="${FLUI_WG_MODE:-overlay}"

# 1500 underlay minus the IPv6-safe WireGuard overhead. Deliberately
# conservative: a few bytes per packet against a path that works for small
# packets and hangs on large ones.
FLUI_WG_MTU="${FLUI_WG_MTU:-1420}"

FLUI_WG_DIR="/etc/wireguard"
FLUI_WG_KEY="${FLUI_WG_DIR}/${FLUI_WG_IFACE}.key"
FLUI_WG_PUB="${FLUI_WG_DIR}/${FLUI_WG_IFACE}.pub"
FLUI_WG_CONF="${FLUI_WG_DIR}/${FLUI_WG_IFACE}.conf"

# Retry rather than pre-check. A node minutes out of provisioning is still
# running cloud-init's own package stage, which holds the dpkg lock and which
# disabling unattended-upgrades does not stop. Waiting for the lock to be free
# only proves it was free at that instant.
flui_wg_install_tools() {
    command -v wg >/dev/null 2>&1 && return 0

    export DEBIAN_FRONTEND=noninteractive
    local attempt=1
    local out
    while [ "$attempt" -le 30 ]; do
        if out=$(apt-get -o DPkg::Lock::Timeout=180 install -y -qq wireguard-tools 2>&1); then
            return 0
        fi
        if echo "$out" | grep -qiE "could not get lock|unable to acquire|dpkg frontend"; then
            [ $((attempt % 6)) -eq 0 ] && log "Waiting for another apt to finish before installing wireguard-tools (attempt ${attempt})"
            attempt=$((attempt + 1))
            sleep 5
            continue
        fi
        apt-get -o DPkg::Lock::Timeout=180 update -qq >/dev/null 2>&1 || true
        apt-get -o DPkg::Lock::Timeout=180 install -y -qq wireguard-tools >/dev/null 2>&1 || true
        break
    done

    command -v wg >/dev/null 2>&1
}

# The private key is created here and never leaves. Flui only ever learns the
# public half, which is printed below for whoever collects it.
flui_wg_ensure_keypair() {
    mkdir -p "$FLUI_WG_DIR"
    chmod 700 "$FLUI_WG_DIR"

    # Reuse an existing key rather than minting a new one: regenerating would
    # orphan every peer entry that names the old one, and the node would go
    # quiet with nothing reporting an error.
    if [ ! -s "$FLUI_WG_KEY" ]; then
        ( umask 077; wg genkey > "$FLUI_WG_KEY" )
        wg pubkey < "$FLUI_WG_KEY" > "$FLUI_WG_PUB"
    fi
    [ -s "$FLUI_WG_PUB" ] || wg pubkey < "$FLUI_WG_KEY" > "$FLUI_WG_PUB"
    chmod 600 "$FLUI_WG_KEY"
}

# Siblings known when this node was provisioned, as `pubkey|address|endpoint`
# records separated by `;`. Neither separator can occur in a base64 key, an IPv4
# address or a host:port, so no quoting is needed.
#
# Only a starting point: a node added later is written into this file by Flui's
# reconciler over SSH. What it buys is a node that can reach its siblings the
# moment it boots, instead of waiting a reconcile cycle to join its own cluster.
flui_wg_append_peers() {
    local record key address endpoint
    local IFS=';'
    for record in ${FLUI_WG_PEERS:-}; do
        [ -n "$record" ] || continue
        key="${record%%|*}"
        address="${record#*|}"
        endpoint="${address#*|}"
        address="${address%%|*}"
        [ -n "$key" ] && [ -n "$address" ] || continue
        {
            echo ""
            echo "[Peer]"
            echo "PublicKey = ${key}"
            echo "AllowedIPs = ${address}/32"
            [ -n "$endpoint" ] && [ "$endpoint" != "$address" ] && echo "Endpoint = ${endpoint}"
            echo "PersistentKeepalive = 25"
        } >> "${FLUI_WG_CONF}.new"
    done
}

flui_wg_has_control() {
    [ -n "${FLUI_WG_CONTROL_PUBKEY:-}" ] && [ -n "${FLUI_WG_CONTROL_ADDRESS:-}" ] &&
        [ -n "${FLUI_WG_CONTROL_ENDPOINT:-}" ]
}

flui_wg_write_config() {
    # AllowedIPs is the control's single /32 and nothing wider. Widening it to
    # the pool would make this node route every other member's traffic through
    # the control cluster — the transit the design forbids.
    cat > "${FLUI_WG_CONF}.new" << EOF
# Flui-managed WireGuard interface — DO NOT EDIT (reconciled by Flui).
[Interface]
Address = ${FLUI_WG_ADDRESS}/32
PrivateKey = $(cat "$FLUI_WG_KEY")
MTU = ${FLUI_WG_MTU}
EOF

    # Only a node in a mesh listens. On the management overlay the control is
    # the one that listens and members dial out, which is what lets a member
    # behind NAT work without an inbound rule of its own.
    if [ "$FLUI_WG_MODE" = "mesh" ]; then
        echo "ListenPort = ${FLUI_WG_PORT}" >> "${FLUI_WG_CONF}.new"
    fi

    if flui_wg_has_control; then
        cat >> "${FLUI_WG_CONF}.new" << EOF

# Flui control cluster
[Peer]
PublicKey = ${FLUI_WG_CONTROL_PUBKEY}
AllowedIPs = ${FLUI_WG_CONTROL_ADDRESS}/32
Endpoint = ${FLUI_WG_CONTROL_ENDPOINT}
PersistentKeepalive = 25
EOF
    fi

    flui_wg_append_peers

    chmod 600 "${FLUI_WG_CONF}.new"
    # Atomically, so a half-written file is never loaded.
    mv "${FLUI_WG_CONF}.new" "$FLUI_WG_CONF"
}

# Everything the node needs is knowable before the machine exists — Flui owns
# the addresses and the control's key — so the tunnel comes up at first boot
# instead of waiting for something to connect and configure it. Only this node's
# own key is created here.
setup_flui_overlay() {
    if [ -z "${FLUI_WG_ADDRESS:-}" ]; then
        log "Management overlay not configured for this installation - skipping"
        return 0
    fi

    # The control's details are required for a management overlay — without
    # them there is no peer at all and the interface would carry nothing. In a
    # mesh they are not: this node's private network is its siblings, and it
    # must come up even when the control has no key yet, because K3s is about
    # to bind to it. The reconciler adds the control peer later.
    if ! flui_wg_has_control && [ "$FLUI_WG_MODE" != "mesh" ]; then
        log "Management overlay not configured for this installation - skipping"
        return 0
    fi

    log "Setting up the Flui management overlay on ${FLUI_WG_IFACE}..."

    if ! flui_wg_install_tools; then
        # Never fatal. A node without the overlay is reachable over its public
        # address exactly as before; a node that refuses to finish booting is
        # not, and the overlay is not worth that trade.
        warn "wireguard-tools unavailable - this node will stay on the public path"
        return 0
    fi

    flui_wg_ensure_keypair
    flui_wg_write_config

    # Already up — a re-run of the installer, not a first boot. `wg-quick up`
    # refuses an existing interface, and in mesh mode that refusal is fatal, so
    # reconcile in place instead.
    if ip link show "$FLUI_WG_IFACE" >/dev/null 2>&1; then
        local current
        current=$(ip -4 -o addr show "$FLUI_WG_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [ "$current" != "$FLUI_WG_ADDRESS" ]; then
            # Only an address change needs the interface rebuilt: `wg syncconf`
            # reloads peers but never touches the address, so syncing alone
            # would leave the node answering on the old one.
            wg-quick down "$FLUI_WG_CONF" >/dev/null 2>&1 || true
            wg-quick up "$FLUI_WG_CONF" >/dev/null 2>&1 &&
                log "✅ Management overlay moved from ${current:-none} to ${FLUI_WG_ADDRESS}"
            return 0
        fi
        # No process substitution: this file is sourced by /bin/sh on some
        # images, where `<(...)` is a syntax error rather than a fallback.
        local stripped
        stripped=$(mktemp)
        if wg-quick strip "$FLUI_WG_CONF" > "$stripped" 2>/dev/null &&
           wg syncconf "$FLUI_WG_IFACE" "$stripped" 2>/dev/null; then
            log "✅ Management overlay already up at ${FLUI_WG_ADDRESS} - peers reloaded"
        else
            warn "Could not reload peers on ${FLUI_WG_IFACE}"
        fi
        rm -f "$stripped"
        return 0
    fi

    if wg-quick up "$FLUI_WG_CONF" >/dev/null 2>&1; then
        systemctl enable "wg-quick@${FLUI_WG_IFACE}" >/dev/null 2>&1 || true
        log "✅ Management overlay up at ${FLUI_WG_ADDRESS} (MTU ${FLUI_WG_MTU}, mode ${FLUI_WG_MODE})"
    elif [ "$FLUI_WG_MODE" = "mesh" ]; then
        # In mesh mode there is no public path to fall back to: K3s is about to
        # bind its node IP to this interface. Failing here, loudly, beats a
        # cluster that installs and then cannot talk to itself.
        error "Could not bring up ${FLUI_WG_IFACE}, which this node's private network depends on"
    else
        warn "Could not bring up ${FLUI_WG_IFACE} - staying on the public path"
        return 0
    fi

    # The control cluster cannot route to this node until it knows the key, and
    # the key exists only now. Printed with a marker so it can be read back from
    # the install log; Flui's reconciler also collects it over SSH, so a lost
    # line here costs a reconcile cycle, not the enrolment.
    log "FLUI_WG_PUBKEY=$(cat "$FLUI_WG_PUB")"
}
