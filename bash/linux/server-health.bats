#!/usr/bin/env bats
# Tests for server-health.sh. Run with: bats bash/linux

load test_helper

health_fixtures() { # health_fixtures ROOT_PCT MEM_AVAIL_KB LOAD
    stub df "if [[ \$* == *-Pi* ]]; then p=10; else p=$1; fi
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo \"/dev/sda1 100 \$p 0 \$p% /\""
    printf 'MemTotal: 1000000 kB\nMemAvailable: %s kB\n' "$2" > "$T/meminfo"
    printf '%s 0.10 0.10 1/100 1\n' "$3" > "$T/loadavg"
    # The real machine's services and clock must not change the result
    stub systemctl 'exit 0'
    stub timedatectl 'echo yes'
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
