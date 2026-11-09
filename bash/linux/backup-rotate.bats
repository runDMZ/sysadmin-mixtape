#!/usr/bin/env bats
# Tests for backup-rotate.sh. Run with: bats bash/linux

load test_helper
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
