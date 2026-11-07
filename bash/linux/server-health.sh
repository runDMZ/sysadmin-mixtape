#!/usr/bin/env bash
# server-health.sh: one-screen health check of a Linux server.
#
# Checks load, memory, disk space and inodes, failed systemd units, pending
# reboot, pending updates and clock sync. Read-only, no root needed (except for
# a complete update count on some distributions).
#
# Exit code: 0 everything OK, 1 at least one warning, 2 at least one critical.
# That makes it usable from cron or a monitoring agent:
#   */30 * * * * /usr/local/bin/server-health.sh -q || mail -s "$(hostname) health" admin@example.com
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: server-health.sh [-d PCT] [-m PCT] [-u] [-q] [-h]
  -d PCT  disk and inode usage warning threshold (default 85, critical at 95)
  -m PCT  memory usage warning threshold (default 90)
  -u      skip the pending updates check (it can take a few seconds)
  -q      quiet: only print warnings and criticals
  -h      this help
EOF
}

DISK_WARN=85
DISK_CRIT=95
MEM_WARN=90
CHECK_UPDATES=1
QUIET=0
# Overridable for tests
MEMINFO=${MEMINFO:-/proc/meminfo}
LOADAVG=${LOADAVG:-/proc/loadavg}
REBOOT_FLAG=${REBOOT_FLAG:-/var/run/reboot-required}

while getopts ':d:m:uqh' opt; do
    case $opt in
        d) DISK_WARN=$OPTARG ;;
        m) MEM_WARN=$OPTARG ;;
        u) CHECK_UPDATES=0 ;;
        q) QUIET=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 3 ;;
    esac
done
for v in "$DISK_WARN" "$MEM_WARN"; do
    [[ $v =~ ^[0-9]+$ ]] || { echo "Thresholds must be integers" >&2; exit 3; }
done
((DISK_CRIT > DISK_WARN)) || DISK_CRIT=$DISK_WARN

STATUS=0
ok()   { ((QUIET)) || printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; ((STATUS < 1)) && STATUS=1; return 0; }
crit() { printf '[CRIT] %s\n' "$*"; STATUS=2; }
have() { command -v "$1" >/dev/null 2>&1; }

check_load() {
    local load1 cpus
    read -r load1 _ < "$LOADAVG"
    cpus=$(nproc 2>/dev/null || echo 1)
    # bash has no floating point: let awk compare
    if awk -v l="$load1" -v c="$cpus" 'BEGIN { exit !(l > c) }'; then
        warn "load $load1 for $cpus CPU(s)"
    else
        ok "load $load1 for $cpus CPU(s)"
    fi
}

check_memory() {
    local total avail used
    total=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO")
    avail=$(awk '/^MemAvailable:/ {print $2}' "$MEMINFO")
    if [[ -z $total || -z $avail ]]; then
        warn "memory: cannot read $MEMINFO"
        return
    fi
    used=$(( (total - avail) * 100 / total ))
    if ((used >= MEM_WARN)); then
        warn "memory ${used}% used ($((avail / 1024)) MiB available)"
    else
        ok "memory ${used}% used ($((avail / 1024)) MiB available)"
    fi
}

# $1: df option for blocks (-P) or inodes (-Pi), $2: label
check_filesystems() {
    local opt=$1 label=$2 line pct mount any=0
    while read -r line; do
        pct=$(awk '{print $5}' <<<"$line"); pct=${pct%\%}
        mount=$(awk '{print $6}' <<<"$line")
        [[ $pct =~ ^[0-9]+$ ]] || continue
        if ((pct >= DISK_CRIT)); then
            crit "$label $mount ${pct}% used"; any=1
        elif ((pct >= DISK_WARN)); then
            warn "$label $mount ${pct}% used"; any=1
        fi
    done < <(df "$opt" -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)
    ((any)) || ok "$label: every filesystem under ${DISK_WARN}%"
}

check_systemd() {
    if [[ ! -d /run/systemd/system ]] || ! have systemctl; then
        ok "systemd not running, failed units not checked"
        return
    fi
    local failed
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd ' ' -)
    if [[ -n $failed ]]; then
        warn "failed units: $failed"
    else
        ok "no failed systemd unit"
    fi
}

check_reboot() {
    if [[ -f $REBOOT_FLAG ]]; then
        warn "reboot required$( [[ -f ${REBOOT_FLAG}.pkgs ]] && printf ' (%s)' "$(paste -sd ' ' "${REBOOT_FLAG}.pkgs")")"
    elif have needs-restarting && ! needs-restarting -r >/dev/null 2>&1; then
        warn "reboot required (needs-restarting)"
    else
        ok "no reboot pending"
    fi
}

check_updates() {
    ((CHECK_UPDATES)) || return 0
    local list total security
    if have apt-get; then
        # Simulation only: reads the local package lists, changes nothing
        list=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep '^Inst' || true)
        total=$(grep -c . <<<"$list" || true)
        security=$(grep -ci 'security' <<<"$list" || true)
    elif have dnf; then
        list=$(dnf -q check-update 2>/dev/null | grep -E '^[[:alnum:]_.+-]+\.[[:alnum:]_]+[[:space:]]' || true)
        total=$(grep -c . <<<"$list" || true)
        security=$(dnf -q updateinfo list --security 2>/dev/null | grep -c . || true)
    else
        ok "updates: no apt or dnf, not checked"
        return
    fi
    if ((security > 0)); then
        crit "$total pending update(s), $security security"
    elif ((total > 0)); then
        warn "$total pending update(s)"
    else
        ok "system up to date (as of the last package list refresh)"
    fi
}

check_time() {
    have timedatectl || return 0
    local sync
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    case $sync in
        yes) ok "clock synchronised" ;;
        no)  warn "clock not synchronised (NTP)" ;;
        *)   : ;;
    esac
}

((QUIET)) || echo "== $(hostname) · $(date '+%F %T') · up $(uptime -p 2>/dev/null | sed 's/^up //' || echo '?')"
check_load
check_memory
check_filesystems -P disk
check_filesystems -Pi inodes
check_systemd
check_reboot
check_updates
check_time
exit "$STATUS"
