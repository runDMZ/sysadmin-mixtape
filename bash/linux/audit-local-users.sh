#!/usr/bin/env bash
# audit-local-users.sh: who can log in to this machine, and with which rights.
#
# Lists the accounts that have a login shell, with sudo rights, password state,
# SSH keys and last login, then the findings worth a look: extra UID 0 accounts,
# empty passwords, NOPASSWD sudo, accounts that never logged in. Read-only. Run
# it as root for the password columns (/etc/shadow) and every authorized_keys.
#
# Typical uses: a server you inherit, a departure, an ISO 27001 access review.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: audit-local-users.sh [-a] [-h]
  -a  include system accounts (UID below UID_MIN) that have a login shell
  -h  this help
Exit code: 0 no finding, 1 at least one finding.
EOF
}

ALL=0
while getopts ':ah' opt; do
    case $opt in
        a) ALL=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 3 ;;
    esac
done

# Overridable for tests
PASSWD_FILE=${PASSWD_FILE:-/etc/passwd}
SHADOW_FILE=${SHADOW_FILE:-/etc/shadow}
GROUP_FILE=${GROUP_FILE:-/etc/group}
SUDOERS_FILES=${SUDOERS_FILES:-/etc/sudoers /etc/sudoers.d/*}
LOGIN_DEFS=${LOGIN_DEFS:-/etc/login.defs}

UID_MIN=$(awk '/^UID_MIN/ {print $2}' "$LOGIN_DEFS" 2>/dev/null || true)
UID_MIN=${UID_MIN:-1000}
findings=()
finding() { findings+=("$*"); }

can_read_shadow=0
[[ -r $SHADOW_FILE ]] && can_read_shadow=1

# Members of the groups that give sudo (Debian: sudo, RHEL: wheel), plus admin
sudo_members=" $(awk -F: '$1 == "sudo" || $1 == "wheel" || $1 == "admin" {gsub(",", " ", $4); printf "%s ", $4}' "$GROUP_FILE") "
# shellcheck disable=SC2086 # word splitting wanted: list of files and globs
sudoers_lines=$(cat $SUDOERS_FILES 2>/dev/null | grep -vE '^[[:space:]]*(#|Defaults|$)' || true)

password_state() {
    local user=$1 hash
    ((can_read_shadow)) || { echo "?"; return; }
    hash=$(awk -F: -v u="$user" '$1 == u {print $2}' "$SHADOW_FILE")
    case $hash in
        '')        echo "EMPTY" ;;
        '!'*|'*'*) echo "locked" ;;
        *)         echo "set" ;;
    esac
}

last_login() {
    local out
    if command -v lastlog >/dev/null 2>&1; then
        out=$(lastlog -u "$1" 2>/dev/null | tail -n +2)
    elif command -v lastlog2 >/dev/null 2>&1; then
        out=$(lastlog2 -u "$1" 2>/dev/null | tail -n +2)
    else
        echo "?"; return
    fi
    if [[ -z $out || $out == *'Never logged in'* || $out == *'never logged in'* ]]; then
        echo "never"
    else
        # The date is the last 6 fields: "Mon Oct 26 14:02:11 +0100 2026"
        awk '{print $(NF-4), $(NF-3), $NF}' <<<"$out"
    fi
}

printf '%-16s %6s  %-6s %-9s %4s  %-14s %s\n' USER UID SUDO PASSWORD KEYS "LAST LOGIN" SHELL
while IFS=: read -r user _ uid _ _ home shell; do
    if ((uid == 0)) && [[ $user != root ]]; then
        finding "$user has UID 0: it is a second root account"
    fi
    case $shell in */nologin|*/false|'') continue ;; esac
    ((ALL || uid >= UID_MIN || uid == 0)) || continue
    ((uid == 65534)) && continue   # nobody

    sudo=no
    [[ $sudo_members == *" $user "* ]] && sudo=group
    if grep -qE "^[[:space:]]*${user}[[:space:]]" <<<"$sudoers_lines"; then
        sudo=rule
        if grep -E "^[[:space:]]*${user}[[:space:]]" <<<"$sudoers_lines" | grep -q 'NOPASSWD'; then
            sudo=nopass
            finding "$user can use sudo without a password (NOPASSWD)"
        fi
    fi
    ((uid == 0)) && sudo=root

    pw=$(password_state "$user")
    [[ $pw == EMPTY ]] && finding "$user has an empty password"

    keys=0
    if [[ -r $home/.ssh/authorized_keys ]]; then
        keys=$(grep -cE '^[^#[:space:]]' "$home/.ssh/authorized_keys" || true)
    fi

    last=$(last_login "$user")
    [[ $last == never && $pw == set ]] && finding "$user never logged in but has a password: still needed?"

    printf '%-16s %6s  %-6s %-9s %4s  %-14s %s\n' "$user" "$uid" "$sudo" "$pw" "$keys" "$last" "$shell"
done < "$PASSWD_FILE"

# NOPASSWD granted to groups (%group ...)
while read -r line; do
    [[ -n $line ]] && finding "group rule without password: $line"
done < <(grep -E '^[[:space:]]*%' <<<"$sudoers_lines" | grep 'NOPASSWD' || true)

((can_read_shadow)) || echo "(not root: password states not checked)"
echo
if ((${#findings[@]})); then
    echo "Findings:"
    printf ' - %s\n' "${findings[@]}"
    exit 1
fi
echo "No finding."
