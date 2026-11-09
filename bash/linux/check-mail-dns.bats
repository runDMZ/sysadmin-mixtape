#!/usr/bin/env bats
# Tests for check-mail-dns.sh. Run with: bats bash/linux

load test_helper
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
