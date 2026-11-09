# Shared setup for the bats tests, which sit next to each script (name.bats).
# Commands the scripts call (df, dig) are replaced by stubs in a temporary PATH;
# certificates, backups and account files are real files in a temporary directory.

setup() {
    BIN="$BATS_TEST_DIRNAME"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/stubs"
    export PATH="$T/stubs:$PATH"
}

stub() { # stub NAME BODY
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/stubs/$1"
    chmod +x "$T/stubs/$1"
}
