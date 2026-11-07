#!/usr/bin/env bats
# Tests for bash/linux. Run with: bats bash/tests
# Commands the scripts call (df, dig) are replaced by stubs in a temporary PATH,
# certificates and backups use real files in a temporary directory.

setup() {
    BIN="$BATS_TEST_DIRNAME/../linux"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/stubs"
    export PATH="$T/stubs:$PATH"
}

stub() { # stub NAME BODY
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stubs/$1"
    chmod +x "$T/stubs/$1"
}

# ---------------------------------------------------------------- server-health
health_fixtures() { # health_fixtures ROOT_PCT MEM_AVAIL_KB LOAD
    stub df "if [[ \$* == *-Pi* ]]; then p=10; else p=$1; fi
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo \"/dev/sda1 100 \$p 0 \$p% /\""
    printf 'MemTotal: 1000000 kB\nMemAvailable: %s kB\n' "$2" > "$T/meminfo"
    printf '%s 0.10 0.10 1/100 1\n' "$3" > "$T/loadavg"
    export MEMINFO="$T/meminfo" LOADAVG="$T/loadavg" REBOOT_FLAG="$T/reboot-required"
}

@test "server-health: healthy server exits 0" {
    health_fixtures 40 800000 0.20
    run "$BIN/server-health.sh" -u
    [ "$status" -eq 0 ]
    [[ $output == *"[OK]   memory 20% used"* ]]
    [[ $output != *WARN* ]]
}

@test "server-health: disk over the threshold is a warning, over 95% critical" {
    health_fixtures 90 800000 0.20
    run "$BIN/server-health.sh" -u
    [ "$status" -eq 1 ]
    [[ $output == *"[WARN] disk / 90% used"* ]]

    health_fixtures 97 800000 0.20
    run "$BIN/server-health.sh" -u
    [ "$status" -eq 2 ]
    [[ $output == *"[CRIT] disk / 97% used"* ]]
}

@test "server-health: memory, load and pending reboot are reported" {
    health_fixtures 40 50000 99.5
    touch "$REBOOT_FLAG"; echo linux-image-6.1 > "$REBOOT_FLAG.pkgs"
    run "$BIN/server-health.sh" -u
    [ "$status" -eq 1 ]
    [[ $output == *"[WARN] memory 95% used"* ]]
    [[ $output == *"[WARN] load 99.5"* ]]
    [[ $output == *"[WARN] reboot required (linux-image-6.1)"* ]]
}

@test "server-health: -q prints only problems" {
    health_fixtures 90 800000 0.20
    run "$BIN/server-health.sh" -u -q
    [ "$output" = "[WARN] disk / 90% used" ]
}

# ------------------------------------------------------------ check-cert-expiry
make_cert() { # make_cert FILE DAYS CN
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/$1.key" -out "$T/$1" \
        -days "$2" -subj "/CN=$3" 2>/dev/null
}

@test "cert-expiry: files are rated OK, WARN, CRIT and EXPIRED" {
    make_cert ok.pem 200 ok.example
    make_cert warn.pem 20 warn.example
    make_cert crit.pem 3 crit.example
    make_cert tmp.pem 1 old.example
    openssl x509 -in "$T/tmp.pem" -signkey "$T/tmp.pem.key" -days -1 -out "$T/expired.pem" 2>/dev/null

    run "$BIN/check-cert-expiry.sh" -F "$T/ok.pem"
    [ "$status" -eq 0 ]
    [[ $output == *"OK"*"ok.example"* ]]

    run "$BIN/check-cert-expiry.sh" -F "$T/ok.pem" "$T/warn.pem"
    [ "$status" -eq 1 ]
    [[ $output == *"WARN"*"warn.example"* ]]

    run "$BIN/check-cert-expiry.sh" -F "$T/warn.pem" "$T/crit.pem" "$T/expired.pem"
    [ "$status" -eq 2 ]
    [[ $output == *"CRIT"*"crit.example"* ]]
    [[ $output == *"EXPIRED"*"old.example"* ]]
}

@test "cert-expiry: live endpoint with SNI, and unreachable endpoint" {
    make_cert srv.pem 20 localhost
    port=$((20000 + RANDOM % 20000))
    openssl s_server -quiet -accept "127.0.0.1:$port" -cert "$T/srv.pem" -key "$T/srv.pem.key" -www &
    pid=$!
    sleep 1
    run "$BIN/check-cert-expiry.sh" -t 5 "localhost:$port"
    kill "$pid"
    [ "$status" -eq 1 ]
    [[ $output == *"WARN"*"localhost:$port (localhost)"* ]]

    run "$BIN/check-cert-expiry.sh" -t 2 "127.0.0.1:1"
    [ "$status" -eq 2 ]
    [[ $output == *"ERROR"* ]]
}

@test "cert-expiry: targets are read from a file, comments ignored" {
    make_cert ok.pem 200 ok.example
    printf '# my certs\n%s   # main site\n\n' "$T/ok.pem" > "$T/list.txt"
    run "$BIN/check-cert-expiry.sh" -F -f "$T/list.txt"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

# ---------------------------------------------------------------- check-mail-dns
# The dig stub answers from $T/dns, lines "TYPE NAME ANSWER"
dns() { printf '%s\n' "$@" > "$T/dns"; }
dig_stub() {
    stub dig "type=\${@: -2:1}; name=\${@: -1}
awk -v t=\"\$type\" -v n=\"\$name\" '\$1 == t && \$2 == n { \$1 = \$2 = \"\"; sub(/^  /, \"\"); print }' \"$T/dns\""
}

@test "mail-dns: a well configured domain exits 0" {
    dig_stub
    dns 'MX good.test 10 mx1.good.test.' \
        'TXT good.test "v=spf1 include:spf.protection.outlook.com -all"' \
        'TXT _dmarc.good.test "v=DMARC1; p=reject; rua=mailto:dmarc@good.test"' \
        'TXT selector1._domainkey.good.test "v=DKIM1; k=rsa; p=MIGfMA0"'
    run "$BIN/check-mail-dns.sh" good.test
    [ "$status" -eq 0 ]
    [[ $output == *"SPF: strict (-all), 1 lookup(s)"* ]]
    [[ $output == *"DMARC: p=reject"* ]]
    [[ $output == *"DKIM: selector(s) found: selector1"* ]]
}

@test "mail-dns: missing SPF, DMARC p=none and no DKIM" {
    dig_stub
    dns 'MX weak.test 10 mx.weak.test.' \
        'TXT _dmarc.weak.test "v=DMARC1; p=none"'
    run "$BIN/check-mail-dns.sh" weak.test
    [ "$status" -eq 2 ]
    [[ $output == *"[CRIT] SPF: none"* ]]
    [[ $output == *"[WARN] DMARC: p=none"* ]]
    [[ $output == *"[WARN] DMARC: no rua="* ]]
    [[ $output == *"[WARN] DKIM: no key"* ]]
}

@test "mail-dns: two SPF records, +all and split TXT chunks" {
    dig_stub
    dns 'TXT two.test "v=spf1 -all"' 'TXT two.test "v=spf1 mx -all"' \
        'TXT open.test "v=spf1 a mx" " +all"'
    run "$BIN/check-mail-dns.sh" two.test
    [[ $output == *"SPF: 2 records"* ]]
    run "$BIN/check-mail-dns.sh" open.test
    [ "$status" -eq 2 ]
    [[ $output == *"ends with +all"* ]]
}

@test "mail-dns: more than 10 SPF lookups is critical" {
    dig_stub
    dns "TXT many.test \"v=spf1 $(for i in $(seq 11); do printf 'include:s%s.test ' "$i"; done)~all\""
    run "$BIN/check-mail-dns.sh" many.test
    [[ $output == *"11 DNS lookups, over the limit of 10"* ]]
}

# ----------------------------------------------------------------- backup-rotate
@test "backup: creates a verified archive with checksum and restores the files" {
    mkdir -p "$T/src/sub"; echo hello > "$T/src/sub/file.txt"; echo x > "$T/src/debug.log"
    run "$BIN/backup-rotate.sh" -d "$T/dest" -n test -e '*.log' "$T/src"
    [ "$status" -eq 0 ]
    archive=$(ls "$T"/dest/test-*.tar.gz)
    (cd "$T/dest" && sha256sum -c "$(basename "$archive").sha256")
    mkdir "$T/restore" && tar -xzf "$archive" -C "$T/restore"
    [ "$(cat "$T/restore/${T#/}/src/sub/file.txt")" = hello ]
    [ ! -e "$T/restore/${T#/}/src/debug.log" ]
}

@test "backup: keeps only the KEEP most recent archives of that name" {
    mkdir -p "$T/src" "$T/dest"; echo a > "$T/src/a"
    for d in 20260101 20260102 20260103; do
        touch "$T/dest/test-$d-020000.tar.gz" "$T/dest/test-$d-020000.tar.gz.sha256"
    done
    touch "$T/dest/other-20250101-020000.tar.gz"
    run "$BIN/backup-rotate.sh" -d "$T/dest" -n test -k 2 "$T/src"
    [ "$status" -eq 0 ]
    [ "$(ls "$T"/dest/test-*.tar.gz | wc -l)" -eq 2 ]
    [ -e "$T/dest/test-20260103-020000.tar.gz" ]
    [ ! -e "$T/dest/test-20260101-020000.tar.gz.sha256" ]
    [ -e "$T/dest/other-20250101-020000.tar.gz" ]
}

@test "backup: dry run writes and deletes nothing" {
    mkdir -p "$T/src" "$T/dest"; echo a > "$T/src/a"
    touch "$T/dest/test-20260101-020000.tar.gz"
    run "$BIN/backup-rotate.sh" -d "$T/dest" -n test -k 1 -N "$T/src"
    [ "$status" -eq 0 ]
    [[ $output == *"would delete $T/dest/test-20260101-020000.tar.gz"* ]]
    [ "$(ls "$T/dest" | wc -l)" -eq 1 ]
}

@test "backup: refuses a missing source and a bad KEEP" {
    run "$BIN/backup-rotate.sh" -d "$T/dest" "$T/nope"
    [ "$status" -eq 3 ]
    run "$BIN/backup-rotate.sh" -d "$T/dest" -k 0 "$T"
    [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------- audit-local-users
@test "audit-users: reports UID 0, empty password, NOPASSWD and keys" {
    cat > "$T/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
toor:x:0:0::/root:/bin/sh
alice:x:1000:1000::/HOME/alice:/bin/bash
bob:x:1001:1001::/HOME/bob:/bin/bash
svc:x:1002:1002::/HOME/svc:/usr/sbin/nologin
EOF
    sed -i "s#/HOME#$T/home#" "$T/passwd"
    printf 'root:!:19000::::::\nalice:$6$abc:19000::::::\nbob::19000::::::\ntoor:*:19000::::::\n' > "$T/shadow"
    printf 'sudo:x:27:alice\n' > "$T/group"
    printf 'Defaults env_reset\nbob ALL=(ALL) NOPASSWD: ALL\n%%ops ALL=(ALL) NOPASSWD: /usr/bin/systemctl\n' > "$T/sudoers"
    mkdir -p "$T/home/alice/.ssh"
    printf '# laptop\nssh-ed25519 AAAA alice@laptop\nssh-ed25519 BBBB alice@phone\n' > "$T/home/alice/.ssh/authorized_keys"
    echo 'UID_MIN 1000' > "$T/login.defs"
    export PASSWD_FILE="$T/passwd" SHADOW_FILE="$T/shadow" GROUP_FILE="$T/group" \
        SUDOERS_FILES="$T/sudoers" LOGIN_DEFS="$T/login.defs"

    run "$BIN/audit-local-users.sh"
    [ "$status" -eq 1 ]
    [[ $output =~ alice\ +1000\ +group\ +set\ +2 ]]
    [[ $output =~ bob\ +1001\ +nopass\ +EMPTY ]]
    [[ $output != *"svc "* ]]
    [[ $output == *"toor has UID 0"* ]]
    [[ $output == *"bob has an empty password"* ]]
    [[ $output == *"bob can use sudo without a password"* ]]
    [[ $output == *"group rule without password: %ops"* ]]
}
