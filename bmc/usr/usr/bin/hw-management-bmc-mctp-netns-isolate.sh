#!/bin/bash
# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#
# hw-management-bmc-mctp-netns-isolate.sh
#
# Move the kernel-managed MCTP iROT interface into a dedicated network namespace
# ("mctp") and (re)assign its EID there, so that ifupdown2 -- which runs in the
# default netns and dumps all addresses on every invocation -- never decodes the
# AF_MCTP (family 45) address and aborts. This is the BMC-local fix for
# Redmine #5016565 that avoids modifying the shared ifupdown2 component.
#
# Single owner of MCTP link/EID setup. Started by 99-hw-management-bmc-mctp.rules
# on the netdev "add" event, only once /usr/bin/mctp is installed (so the EID can
# always be re-established after the move). Idempotent; failures are reported via
# the journal (SyslogIdentifier) and a status file so the original DHCP bug cannot
# be silently masked.
#
# Usage:
#   hw-management-bmc-mctp-netns-isolate.sh <iface>              # isolate
#   hw-management-bmc-mctp-netns-isolate.sh --deisolate <iface>  # rollback (ExecStop)

set -u

TAG="hw-management-bmc-mctp-netns-isolate"
NS="mctp"
EID="230"                 # NVIDIA BMC iROT local EID (single source of truth).
STATUS_FILE="/run/hw-management-bmc-mctp-netns-isolate.status"

log() { logger -t "$TAG" -- "$*" 2>/dev/null; echo "[$TAG] $*"; }
emit_status() { # isolated eid_present [extra]
    echo "iface=${IFACE} ns=${NS} isolated=$1 eid_present=$2 ${3:-}" >"$STATUS_FILE" 2>/dev/null || true
}
# Is an MCTP EID configured for interface $1 inside the mctp netns? Use an anchored
# match so a longer sibling name (mctpirot10) does NOT satisfy the check for a
# shorter one (mctpirot1); a plain substring grep would (issue #5016565).
eid_present_in_ns() {
    ip netns exec "$NS" mctp addr 2>/dev/null | grep -qE "dev $1( |\$)"
}

# --- argument parsing ------------------------------------------------------
DEISOLATE=0
if [ "${1:-}" = "--deisolate" ]; then
    DEISOLATE=1
    shift
fi
IFACE="${1:-mctpirot0}"

# --- ExecStop --------------------------------------------------------------
# Isolation is the desired steady state, so stopping the unit does NOT move the
# device back to the default netns. A move-back would be self-reverting (the net
# "add" event re-fires 99-hw-management-bmc-mctp.rules, which restarts this unit
# and re-isolates) and is pointless at shutdown. We only drop the netns once no
# MCTP device remains in it; we never delete a populated netns, since deleting it
# would relocate the device to the default netns and flush its EID. /run/netns/$NS
# disappears on reboot regardless.
if [ "$DEISOLATE" = 1 ]; then
    if ip netns exec "$NS" ip link show "$IFACE" &>/dev/null; then
        log "$IFACE still isolated in netns $NS; leaving it in place (no rollback on stop)"
        exit 0
    fi
    if ip netns exec "$NS" ip -o link show 2>/dev/null | grep -q 'mctpirot'; then
        log "$IFACE gone but other MCTP devices remain in netns $NS; keeping it"
        exit 0
    fi
    ip netns del "$NS" 2>/dev/null || true
    log "no MCTP devices remain in netns $NS; removed it"
    exit 0
fi

# --- preconditions ---------------------------------------------------------
command -v ip   >/dev/null 2>&1 || { log "ERROR: 'ip' not found";   emit_status no na "err=noip";   exit 1; }
# The udev guard should ensure mctp exists; double-check so we never move the
# device into the netns without being able to re-establish its EID afterwards.
command -v mctp >/dev/null 2>&1 || { log "ERROR: 'mctp' not found (will retry on next udev trigger)"; emit_status no na "err=nomctp"; exit 1; }

# Create the target namespace (idempotent; persists as /run/netns/$NS).
ip netns add "$NS" 2>/dev/null || true

# --- already isolated? (idempotent re-run) ---------------------------------
if ip netns exec "$NS" ip link show "$IFACE" &>/dev/null; then
    ip netns exec "$NS" mctp link set "$IFACE" up 2>/dev/null \
        || ip netns exec "$NS" ip link set "$IFACE" up 2>/dev/null || true
    if ! eid_present_in_ns "$IFACE"; then
        ip netns exec "$NS" mctp addr add "$EID" dev "$IFACE" 2>/dev/null || true
    fi
    if eid_present_in_ns "$IFACE"; then
        log "$IFACE already isolated in netns $NS (eid present)"; emit_status yes yes
    else
        log "WARN: $IFACE in netns $NS but EID missing"; emit_status yes no
    fi
    exit 0
fi

# --- device must exist in the default netns to move it ---------------------
if ! ip link show "$IFACE" &>/dev/null; then
    log "WARN: $IFACE not present in the default netns; nothing to isolate"
    emit_status no na "err=nodev"
    exit 1
fi

# --- move the device into the namespace ------------------------------------
# (Addresses are flushed on a netns move; we re-add the EID below. Safe because
# 'mctp' is confirmed present, so the EID will be re-established.)
if ! ip link set "$IFACE" netns "$NS"; then
    log "ERROR: failed to move $IFACE into netns $NS -- eth0 DHCP NOT fixed this boot"
    emit_status no na "err=movefail"
    exit 1
fi

# --- bring it up + (re)add the EID inside the namespace --------------------
ip netns exec "$NS" mctp link set "$IFACE" up 2>/dev/null \
    || ip netns exec "$NS" ip link set "$IFACE" up 2>/dev/null || true

eid_present=no
if ip netns exec "$NS" mctp addr add "$EID" dev "$IFACE" 2>/dev/null; then
    eid_present=yes
elif eid_present_in_ns "$IFACE"; then
    eid_present=yes   # already present == success
else
    log "WARN: failed to add EID $EID for $IFACE in netns $NS"
fi

# --- postcondition: the family-45 address must be gone from the default netns
if ip -d addr show "$IFACE" 2>/dev/null | grep -q 'family 45'; then
    log "ERROR: family-45 address still present on $IFACE in the default netns after move"
    emit_status no "$eid_present" "err=stilldefault"
    exit 1
fi

log "isolated $IFACE into netns $NS (eid_present=$eid_present)"
emit_status yes "$eid_present"
exit 0
