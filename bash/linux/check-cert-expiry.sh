#!/usr/bin/env bash
# check-cert-expiry.sh: days left before TLS certificates expire.
#
# Checks live endpoints (host or host:port, SNI sent) and/or certificate files
# on disk. Prints one line per certificate and returns an exit code for cron or
# monitoring: 0 all OK, 1 at least one warning, 2 at least one critical, expired
# or unreachable.
#
# Examples:
#   check-cert-expiry.sh example.com mail.example.com:465 intranet.local:8443
#   check-cert-expiry.sh -f hosts.txt -w 21 -c 7
#   check-cert-expiry.sh -F /etc/ssl/private/*.pem
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: check-cert-expiry.sh [-w DAYS] [-c DAYS] [-t SEC] [-f FILE] [-F] TARGET...
  TARGET   host, host:port (default port 443), or a PEM file with -F
  -f FILE  read targets from FILE, one per line (# comments allowed)
  -F       targets are certificate files on disk, not endpoints
  -w DAYS  warning threshold (default 30)
  -c DAYS  critical threshold (default 7)
  -t SEC   connection timeout (default 10)
  -h       this help
EOF
}

WARN_DAYS=30
CRIT_DAYS=7
TIMEOUT=10
FILES=0
targets=()

while getopts ':w:c:t:f:Fh' opt; do
    case $opt in
        w) WARN_DAYS=$OPTARG ;;
        c) CRIT_DAYS=$OPTARG ;;
        t) TIMEOUT=$OPTARG ;;
        f) while IFS= read -r line; do
               line=${line%%#*}; line=${line//[[:space:]]/}
               [[ -n $line ]] && targets+=("$line")
           done < "$OPTARG" ;;
        F) FILES=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 3 ;;
    esac
done
shift $((OPTIND - 1))
targets+=("$@")
((${#targets[@]})) || { usage >&2; exit 3; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 3; }

STATUS=0
raise() { (($1 > STATUS)) && STATUS=$1; return 0; }

# Prints the PEM certificate of a target on stdout
fetch_cert() {
    local target=$1 host port
    if ((FILES)); then
        cat -- "$target"
        return
    fi
    host=${target%:*}; port=${target##*:}
    [[ $target == *:* ]] || port=443
    # -servername sends SNI, otherwise shared hosting returns its default certificate
    timeout "$TIMEOUT" openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null
}

printf '%-8s %6s  %-24s %s\n' STATUS DAYS EXPIRES TARGET
now=$(date +%s)
for target in "${targets[@]}"; do
    if ! pem=$(fetch_cert "$target") || ! end=$(openssl x509 -noout -enddate <<<"$pem" 2>/dev/null); then
        printf '%-8s %6s  %-24s %s\n' ERROR - - "$target (unreachable or no certificate)"
        raise 2
        continue
    fi
    end=${end#notAfter=}
    days=$(( ($(date -d "$end" +%s) - now) / 86400 ))
    subject=$(openssl x509 -noout -subject -nameopt multiline <<<"$pem" 2>/dev/null | awk -F' = ' '/commonName/ {print $2; exit}')
    if ((days < 0)); then
        status=EXPIRED; raise 2
    elif ((days <= CRIT_DAYS)); then
        status=CRIT; raise 2
    elif ((days <= WARN_DAYS)); then
        status=WARN; raise 1
    else
        status=OK
    fi
    printf '%-8s %6s  %-24s %s\n' "$status" "$days" "$(date -d "$end" '+%F %R')" "$target${subject:+ ($subject)}"
done
exit "$STATUS"
