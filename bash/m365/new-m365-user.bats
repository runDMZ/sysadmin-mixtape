#!/usr/bin/env bats
# Tests for new-m365-user.sh. Run with: bats bash/m365
# az is replaced by a stub that answers Graph calls from files in $T and records
# the bodies it receives: no tenant is touched.

load ../linux/test_helper

az_stub() {
    stub az "T='$T'
[[ \$1 == account ]] && exit 0
while ((\$#)); do
    case \$1 in
        --method) method=\$2; shift ;;
        --url) url=\$2; shift ;;
        --body) body=\$2; shift ;;
    esac
    shift
done
echo \"\$method \$url\" >> \"\$T/calls\"
case \"\$method \$url\" in
    'GET '*/domains) cat \"\$T/domains.json\" ;;
    'GET '*/subscribedSkus) cat \"\$T/skus.json\" ;;
    'GET '*/users/*) [[ -f \$T/user-exists ]] ;;
    'POST '*/users) printf '%s' \"\$body\" > \"\$T/user.json\"; echo 00000000-aaaa ;;
    'POST '*/assignLicense) [[ ! -f \$T/licence-fails ]] && printf '%s' \"\$body\" > \"\$T/licence.json\" ;;
    *) exit 1 ;;
esac"
    cat > "$T/domains.json" <<'EOF'
{"value":[{"id":"contoso.com","isVerified":true},{"id":"pending.com","isVerified":false}]}
EOF
    cat > "$T/skus.json" <<'EOF'
{"value":[
 {"skuPartNumber":"SPB","skuId":"sku-spb","capabilityStatus":"Enabled","consumedUnits":4,"prepaidUnits":{"enabled":5}},
 {"skuPartNumber":"O365_BUSINESS_PREMIUM","skuId":"sku-bs","capabilityStatus":"Enabled","consumedUnits":10,"prepaidUnits":{"enabled":10}}
]}
EOF
}

@test "m365-user: creates the user with the right attributes and assigns the licence" {
    az_stub
    run "$BIN/new-m365-user.sh" -f 'Hélène' -l "D'Arc Lefèvre" -d Contoso.com -L SPB -D Sales -t 'Account manager' -y
    [ "$status" -eq 0 ]
    [[ $output == *"user created: helene.d-arc-lefevre@contoso.com"* ]]
    [[ $output == *"licence SPB assigned"* ]]
    [ "$(jq -r .userPrincipalName "$T/user.json")" = helene.d-arc-lefevre@contoso.com ]
    [ "$(jq -r .displayName "$T/user.json")" = "Hélène D'Arc Lefèvre" ]
    [ "$(jq -r .department "$T/user.json")" = Sales ]
    [ "$(jq -r .usageLocation "$T/user.json")" = FR ]
    [ "$(jq -r .passwordProfile.forceChangePasswordNextSignIn "$T/user.json")" = true ]
    [ "$(jq -r '.addLicenses[0].skuId' "$T/licence.json")" = sku-spb ]
}

@test "m365-user: a first name alone works and empty attributes are not sent" {
    az_stub
    run "$BIN/new-m365-user.sh" -f Jean -d contoso.com -L none -y
    [ "$status" -eq 0 ]
    [ "$(jq -r .userPrincipalName "$T/user.json")" = jean@contoso.com ]
    [ "$(jq -r 'has("surname") or has("department") or has("companyName")' "$T/user.json")" = false ]
    [ ! -f "$T/licence.json" ]
}

@test "m365-user: dry run checks everything and writes nothing" {
    az_stub
    run "$BIN/new-m365-user.sh" -f Jean -l Dupont -d contoso.com -L SPB -N
    [ "$status" -eq 0 ]
    [[ $output == *"jean.dupont@contoso.com"* ]]
    [[ $output == *"SPB (1 free)"* ]]
    ! grep -q '^POST' "$T/calls"
}

@test "m365-user: refuses an existing user, an unverified domain, a full or unknown licence" {
    az_stub
    touch "$T/user-exists"
    run "$BIN/new-m365-user.sh" -f Jean -d contoso.com -L SPB -y
    [ "$status" -eq 1 ]
    [[ $output == *"already exists"* ]]
    rm "$T/user-exists"
    run "$BIN/new-m365-user.sh" -f Jean -d pending.com -L SPB -y
    [[ $output == *"not verified"* ]]
    run "$BIN/new-m365-user.sh" -f Jean -d contoso.com -L O365_BUSINESS_PREMIUM -y
    [[ $output == *"no free O365_BUSINESS_PREMIUM licence"* ]]
    run "$BIN/new-m365-user.sh" -f Jean -d contoso.com -L NOPE -y
    [[ $output == *"available: SPB, O365_BUSINESS_PREMIUM"* ]]
    ! grep -q '^POST' "$T/calls"
}

@test "m365-user: licence failure after creation exits 2 and still prints the sign-in" {
    az_stub
    touch "$T/licence-fails"
    RETRY_DELAY=0 run "$BIN/new-m365-user.sh" -f Jean -d contoso.com -L SPB -y
    [ "$status" -eq 2 ]
    [[ $output == *"Temporary password"* ]]
    [[ $output == *"NOT assigned"* ]]
    [ "$(grep -c assignLicense "$T/calls")" -eq 5 ]
}

@test "m365-user: wrong usage exits 3" {
    az_stub
    run "$BIN/new-m365-user.sh" -d contoso.com -L SPB </dev/null
    [ "$status" -eq 3 ]
    run "$BIN/new-m365-user.sh" -f Jean -d contoso.com -L SPB -u FRA
    [ "$status" -eq 3 ]
    run "$BIN/new-m365-user.sh" -Z
    [ "$status" -eq 3 ]
}
