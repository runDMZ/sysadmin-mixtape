#!/usr/bin/env bats
# Tests for check-cert-expiry.sh. Run with: bats bash/linux

load test_helper
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
