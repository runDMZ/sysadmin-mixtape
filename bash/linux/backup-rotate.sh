#!/usr/bin/env bash
# backup-rotate.sh: compressed backup of directories, verified, with rotation.
#
# Creates DEST/NAME-YYYYmmdd-HHMMSS.tar.gz, checks that the archive can be read
# back, writes a SHA-256 checksum next to it, then keeps only the KEEP most
# recent archives of that NAME. A lock prevents two runs at the same time.
# Nothing is deleted if the new archive fails its check.
#
# This is a local copy, not a full backup strategy: copy DEST to another
# machine or storage (3-2-1 rule) and test a restore from time to time.
#
# Examples:
#   backup-rotate.sh -d /srv/backup -n etc /etc
#   backup-rotate.sh -d /srv/backup -n www -k 14 -e '*.log' -e cache /var/www
#   backup-rotate.sh -d /srv/backup -n www -k 14 -N /var/www      # dry run
# Cron, every night at 2:15:
#   15 2 * * * /usr/local/bin/backup-rotate.sh -d /srv/backup -n etc /etc
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: backup-rotate.sh -d DEST [-n NAME] [-k KEEP] [-e PATTERN]... [-N] SOURCE...
  -d DEST     directory where archives are written (created if missing)
  -n NAME     archive name prefix (default: the host name)
  -k KEEP     number of archives to keep for this NAME (default 7)
  -e PATTERN  exclude files matching PATTERN (tar --exclude), can be repeated
  -N          dry run: show what would be done, write and delete nothing
  -h          this help
EOF
}

DEST=
NAME=$(hostname -s 2>/dev/null || hostname)
KEEP=7
DRY=0
excludes=()

while getopts ':d:n:k:e:Nh' opt; do
    case $opt in
        d) DEST=$OPTARG ;;
        n) NAME=$OPTARG ;;
        k) KEEP=$OPTARG ;;
        e) excludes+=("--exclude=$OPTARG") ;;
        N) DRY=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 3 ;;
    esac
done
shift $((OPTIND - 1))
[[ -n $DEST && $# -gt 0 ]] || { usage >&2; exit 3; }
[[ $KEEP =~ ^[1-9][0-9]*$ ]] || { echo "KEEP must be a positive integer" >&2; exit 3; }
[[ $NAME =~ ^[A-Za-z0-9._-]+$ ]] || { echo "NAME may only contain letters, digits, . _ -" >&2; exit 3; }
for src in "$@"; do
    [[ -e $src ]] || { echo "Source not found: $src" >&2; exit 3; }
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

archive="$DEST/$NAME-$(date +%Y%m%d-%H%M%S).tar.gz"

if ((DRY)); then
    log "[dry run] would create $archive from: $*"
else
    mkdir -p -- "$DEST"
    # One run at a time per destination
    exec 9>"$DEST/.backup-rotate.lock"
    flock -n 9 || { log "another backup is running on $DEST, exiting"; exit 1; }

    tmp="$archive.part"
    trap 'rm -f -- "$tmp"' EXIT
    log "creating $archive"
    # Absolute paths are stored without the leading /, restore with: tar -xzf ARCHIVE -C /
    tar -czf "$tmp" "${excludes[@]}" -- "$@"
    tar -tzf "$tmp" >/dev/null || { log "archive check failed, nothing rotated"; exit 2; }
    mv -- "$tmp" "$archive"
    trap - EXIT
    (cd -- "$DEST" && sha256sum -- "$(basename -- "$archive")" > "$(basename -- "$archive").sha256")
    log "done: $(du -h -- "$archive" | cut -f1)"
fi

# Rotation: archive names sort by date, oldest first
mapfile -t existing < <(find "$DEST" -maxdepth 1 -type f -name "$NAME-[0-9]*-[0-9]*.tar.gz" -printf '%f\n' 2>/dev/null | sort)
((DRY)) && existing+=("$(basename -- "$archive")")
excess=$(( ${#existing[@]} - KEEP ))
for ((i = 0; i < excess; i++)); do
    old="$DEST/${existing[i]}"
    if ((DRY)); then
        log "[dry run] would delete $old"
    else
        log "deleting $old"
        rm -f -- "$old" "$old.sha256"
    fi
done
