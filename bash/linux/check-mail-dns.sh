#!/usr/bin/env bash
# check-mail-dns.sh: checks the DNS records that make a domain's email trusted.
#
# For each domain: MX, SPF (syntax, single record, policy, DNS lookup count),
# DMARC (policy and reporting address), DKIM (selectors found) and MTA-STS.
# Typical uses: after adding a domain to Microsoft 365 or Google Workspace,
# before a migration, or when mail lands in spam.
#
# Exit code: 0 all OK, 1 at least one warning, 2 at least one critical.
#
# Examples:
#   check-mail-dns.sh example.com example.org
#   check-mail-dns.sh -s google -s s1 example.com      # extra DKIM selectors
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: check-mail-dns.sh [-s SELECTOR]... [-r RESOLVER] DOMAIN...
  -s SELECTOR  DKIM selector to try, can be repeated. Always tried: selector1 and
               selector2 (Microsoft 365), google, default, k1 (Mailchimp), s1, s2
  -r RESOLVER  DNS server to query, e.g. 1.1.1.1 (default: the system resolver)
  -h           this help
Requires dig (package dnsutils on Debian, bind-utils on RHEL).
EOF
}

SELECTORS=(selector1 selector2 google default k1 s1 s2)
RESOLVER=
while getopts ':s:r:h' opt; do
    case $opt in
        s) SELECTORS+=("$OPTARG") ;;
        r) RESOLVER=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 3 ;;
    esac
done
shift $((OPTIND - 1))
(($#)) || { usage >&2; exit 3; }
command -v dig >/dev/null || { echo "dig is required (dnsutils / bind-utils)" >&2; exit 3; }

STATUS=0
ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; ((STATUS < 1)) && STATUS=1; return 0; }
crit() { printf '  [CRIT] %s\n' "$*"; STATUS=2; }

# TXT records, one per line, with the quoted chunks of long records joined
txt() {
    dig +short ${RESOLVER:+"@$RESOLVER"} TXT "$1" 2>/dev/null | sed 's/" "//g; s/"//g'
}

check_mx() {
    local mx
    mx=$(dig +short ${RESOLVER:+"@$RESOLVER"} MX "$1" 2>/dev/null | sort -n | awk '{print $2}' | paste -sd ' ' -)
    if [[ -z $mx ]]; then
        crit "MX: none, the domain cannot receive mail"
    elif [[ $mx == "." ]]; then
        ok "MX: null MX (domain explicitly does not receive mail)"
    else
        ok "MX: $mx"
    fi
}

check_spf() {
    local records count spf lookups
    records=$(txt "$1" | grep -i '^v=spf1' || true)
    count=$(grep -c . <<<"$records" || true)
    if ((count == 0)); then
        crit "SPF: none, anyone can send mail as $1"
        return
    elif ((count > 1)); then
        crit "SPF: $count records, receivers treat this as an error (merge them into one)"
        return
    fi
    spf=$records
    # Mechanisms that cost a DNS lookup; the limit is 10 (RFC 7208)
    lookups=$(tr ' ' '\n' <<<"$spf" | grep -ciE '^[+~?-]?(include:|a$|a:|a/|mx$|mx:|mx/|ptr|exists:)|^redirect=' || true)
    case $spf in
        *' +all'|*' ?all') crit "SPF: ends with ${spf##* }, it authorises every sender: $spf" ;;
        *' -all')          ok "SPF: strict (-all), $lookups lookup(s): $spf" ;;
        *' ~all')          ok "SPF: softfail (~all), $lookups lookup(s): $spf" ;;
        *redirect=*)       ok "SPF: redirect, $lookups lookup(s): $spf" ;;
        *)                 warn "SPF: no final all mechanism: $spf" ;;
    esac
    ((lookups <= 10)) || crit "SPF: $lookups DNS lookups, over the limit of 10: SPF fails (flatten or remove includes)"
}

check_dmarc() {
    local rec policy
    rec=$(txt "_dmarc.$1" | grep -i '^v=DMARC1' | head -1 || true)
    if [[ -z $rec ]]; then
        warn "DMARC: none, receivers have no policy and you get no reports (start with p=none; rua=mailto:...)"
        return
    fi
    policy=$(grep -oiE '(^|;)[[:space:]]*p=[a-z]+' <<<"$rec" | sed 's/.*=//' | tr '[:upper:]' '[:lower:]')
    case $policy in
        reject|quarantine) ok "DMARC: p=$policy: $rec" ;;
        none) warn "DMARC: p=none, monitoring only. Move to quarantine then reject once reports are clean: $rec" ;;
        *)    crit "DMARC: invalid or missing p= tag: $rec" ;;
    esac
    grep -qi 'rua=' <<<"$rec" || warn "DMARC: no rua= address, you receive no aggregate reports"
}

check_dkim() {
    local found=() sel
    for sel in "${SELECTORS[@]}"; do
        # Microsoft 365 publishes a CNAME to its own zone: dig follows it
        if dig +short ${RESOLVER:+"@$RESOLVER"} TXT "$sel._domainkey.$1" 2>/dev/null | grep -qi 'p='; then
            found+=("$sel")
        fi
    done
    if ((${#found[@]})); then
        ok "DKIM: selector(s) found: ${found[*]}"
    else
        warn "DKIM: no key on the usual selectors (${SELECTORS[*]}); pass yours with -s"
    fi
}

check_mta_sts() {
    if txt "_mta-sts.$1" | grep -qi '^v=STSv1'; then
        ok "MTA-STS: published"
    else
        ok "MTA-STS: not published (optional, enforces TLS between mail servers)"
    fi
}

for domain in "$@"; do
    echo "== $domain"
    check_mx "$domain"
    check_spf "$domain"
    check_dmarc "$domain"
    check_dkim "$domain"
    check_mta_sts "$domain"
done
exit "$STATUS"
