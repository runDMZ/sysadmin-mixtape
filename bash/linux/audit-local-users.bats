#!/usr/bin/env bats
# Tests for audit-local-users.sh. Run with: bats bash/linux

load test_helper
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
