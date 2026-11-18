#!/usr/bin/env bash
# new-m365-user.sh: create one Microsoft 365 / Entra ID user and assign a licence,
# with Azure CLI only (az rest -> Microsoft Graph).
#
# The UPN is built from the names: "Hélène D'Arc" -> helene.d-arc@DOMAIN. A first
# name or a last name alone is enough. Before writing anything, the script checks
# that the domain is verified in the tenant, that the licence exists and has a
# free seat, and that the user does not exist yet. The temporary password is
# printed once, never written to disk, and must be changed at first sign-in.
#
# az ad user create can neither set usageLocation nor assign a licence, hence
# az rest: POST /users, then POST /users/{id}/assignLicense.
#
# Examples:
#   new-m365-user.sh                                   # interactive, with menus
#   new-m365-user.sh -f Jean -l Dupont -d contoso.com -L SPB -D Sales -t "Account manager"
#   new-m365-user.sh -f Jean -d contoso.com -L none    # first name only, no licence
#   new-m365-user.sh -f Jean -l Dupont -d contoso.com -L SPB -N   # dry run
#
# Requires: az (az login --tenant TENANT --allow-no-subscriptions), jq, openssl.
# Minimum role: User Administrator (creates users and assigns licences).
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: new-m365-user.sh [-f FIRST] [-l LAST] [-d DOMAIN] [-L SKU] [options]
  -f FIRST    first name (givenName)
  -l LAST     last name (surname); at least one of -f and -l
  -d DOMAIN   UPN domain, must be verified in the tenant (menu if missing)
  -L SKU      licence skuPartNumber (SPB, O365_BUSINESS_PREMIUM, ENTERPRISEPACK...)
              or "none"; menu if missing
  -c COMPANY  companyName      -D DEPT  department      -t TITLE  jobTitle
  -u COUNTRY  usageLocation, ISO 3166 code (default FR), required for a licence
  -y          do not ask for confirmation
  -N          dry run: run the checks, show what would be created, write nothing
  -h          this help
Without any option, every value is asked for.
Exit codes: 0 created, 1 check or API failure, 2 user created but licence
not assigned, 3 wrong usage.
EOF
}

GRAPH=https://graph.microsoft.com/v1.0
first='' last='' domain='' sku='' company='' dept='' title='' country=FR
DRY=0 YES=0 ASK_ALL=0
(($# == 0)) && ASK_ALL=1

while getopts ':f:l:d:L:c:D:t:u:yNh' opt; do
    case $opt in
        f) first=$OPTARG ;;
        l) last=$OPTARG ;;
        d) domain=$OPTARG ;;
        L) sku=$OPTARG ;;
        c) company=$OPTARG ;;
        D) dept=$OPTARG ;;
        t) title=$OPTARG ;;
        u) country=$OPTARG ;;
        y) YES=1 ;;
        N) DRY=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 3 ;;
    esac
done
shift $((OPTIND - 1))
(($# == 0)) || { usage >&2; exit 3; }

die() { echo "error: $*" >&2; exit "${2:-1}"; }
log() { echo "-> $*"; }
ask() { local answer=; read -rp "$1" answer || true; printf '%s' "$answer"; }
interactive() { [[ -t 0 ]]; }

for cmd in az jq openssl; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
[[ $country =~ ^[A-Za-z]{2}$ ]] || die "COUNTRY must be a 2-letter ISO code" 3

if [[ -z $first && -z $last ]] && interactive; then
    first=$(ask "First name (empty if none): ")
    last=$(ask "Last name  (empty if none): ")
fi
[[ -n $first || -n $last ]] || die "a first name (-f) or a last name (-l) is required" 3
if ((ASK_ALL)) && interactive; then
    company=$(ask "Company    (optional): ")
    dept=$(ask "Department (optional): ")
    title=$(ask "Job title  (optional): ")
fi

az account show --only-show-errors >/dev/null 2>&1 \
    || die "no Azure CLI session: az login --tenant TENANT --allow-no-subscriptions"

# --- Domain -------------------------------------------------------------------
domains=$(az rest --method GET --url "$GRAPH/domains" --only-show-errors \
    | jq -r '.value[] | select(.isVerified) | .id')
if [[ -z $domain ]]; then
    interactive || die "missing domain (-d)" 3
    mapfile -t list <<<"$domains"
    echo "Verified domains:"
    select domain in "${list[@]}"; do [[ -n $domain ]] && break; done
fi
domain=${domain,,}
grep -qixF -- "$domain" <<<"$domains" || die "domain $domain is not verified in this tenant"

# --- Licence ------------------------------------------------------------------
skus=$(az rest --method GET --url "$GRAPH/subscribedSkus" --only-show-errors)
if [[ -z $sku ]]; then
    interactive || die "missing licence (-L)" 3
    mapfile -t list < <(jq -r '.value[] | select(.capabilityStatus == "Enabled")
        | "\(.skuPartNumber) (\(.prepaidUnits.enabled - .consumedUnits) free of \(.prepaidUnits.enabled))"' <<<"$skus")
    list+=("none (no licence)")
    echo "Licences:"
    select choice in "${list[@]}"; do [[ -n $choice ]] && break; done
    sku=${choice%% *}
fi
sku_id='' free=''
if [[ ${sku,,} != none ]]; then
    sku_id=$(jq -r --arg p "$sku" '.value[] | select(.skuPartNumber == $p) | .skuId' <<<"$skus")
    [[ -n $sku_id ]] || die "licence $sku not found, available: $(jq -r '[.value[].skuPartNumber] | join(", ")' <<<"$skus")"
    free=$(jq -r --arg p "$sku" '.value[] | select(.skuPartNumber == $p) | .prepaidUnits.enabled - .consumedUnits' <<<"$skus")
    ((free > 0)) || die "no free $sku licence left"
fi

# --- UPN ----------------------------------------------------------------------
# Accents removed with an explicit table, so the result does not depend on the locale
normalize() {
    printf '%s' "$1" \
        | sed -E 's/(à|â|ä|á|ã|å)/a/g; s/(À|Â|Ä|Á|Ã|Å)/A/g; s/ç/c/g; s/Ç/C/g;
                  s/(é|è|ê|ë)/e/g; s/(É|È|Ê|Ë)/E/g; s/(í|ì|î|ï)/i/g; s/(Í|Ì|Î|Ï)/I/g;
                  s/ñ/n/g; s/Ñ/N/g; s/(ó|ò|ô|ö|õ)/o/g; s/(Ó|Ò|Ô|Ö|Õ)/O/g;
                  s/(ú|ù|û|ü)/u/g; s/(Ú|Ù|Û|Ü)/U/g; s/(ý|ÿ)/y/g; s/Ý/Y/g;
                  s/æ/ae/g; s/œ/oe/g; s/Æ/AE/g; s/Œ/OE/g' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E "s/[[:space:]']+/-/g; s/[^a-z0-9-]//g; s/-+/-/g; s/^-|-$//g"
}
nick=$(printf '%s.%s' "$(normalize "$first")" "$(normalize "$last")" | sed -E 's/^\.|\.$//g')
[[ -n $nick ]] || die "cannot build an identifier from this name" 3
upn=$nick@$domain
display=$(printf '%s %s' "$first" "$last" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

if az rest --method GET --url "$GRAPH/users/$upn?\$select=id" --only-show-errors >/dev/null 2>&1; then
    die "$upn already exists"
fi

cat <<EOF

  Display name : $display
  UPN          : $upn
  Company      : ${company:--}   Department: ${dept:--}   Job title: ${title:--}
  Country      : ${country^^}
  Licence      : ${sku_id:+$sku ($free free)}${sku_id:-none}

EOF
((DRY)) && { log "dry run: nothing created"; exit 0; }
if ((!YES)) && interactive; then
    [[ $(ask "Create this user? [y/N] ") =~ ^[yYoO]$ ]] || die "cancelled"
fi

# --- Creation -----------------------------------------------------------------
password="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-14)Aa1!"
body=$(jq -n --arg dn "$display" --arg gn "$first" --arg sn "$last" --arg mn "$nick" \
    --arg upn "$upn" --arg pw "$password" --arg co "$company" --arg dep "$dept" \
    --arg jt "$title" --arg ul "${country^^}" '
    { accountEnabled: true, displayName: $dn, mailNickname: $mn,
      userPrincipalName: $upn, usageLocation: $ul,
      passwordProfile: { password: $pw, forceChangePasswordNextSignIn: true } }
    + (if $gn  != "" then { givenName: $gn }    else {} end)
    + (if $sn  != "" then { surname: $sn }      else {} end)
    + (if $co  != "" then { companyName: $co }  else {} end)
    + (if $dep != "" then { department: $dep }  else {} end)
    + (if $jt  != "" then { jobTitle: $jt }     else {} end)')

user_id=$(az rest --method POST --url "$GRAPH/users" --headers Content-Type=application/json \
    --body "$body" --query id -o tsv --only-show-errors) || die "user creation failed"
log "user created: $upn"

credentials() {
    printf '\n  Sign-in            : %s\n  Temporary password : %s   (to change at first sign-in)\n' "$upn" "$password"
}
[[ -z $sku_id ]] && { credentials; exit 0; }

# A new user can take a few seconds to be visible everywhere: retry
licence=$(jq -n --arg s "$sku_id" '{ addLicenses: [{ skuId: $s, disabledPlans: [] }], removeLicenses: [] }')
for attempt in 1 2 3 4 5; do
    if az rest --method POST --url "$GRAPH/users/$user_id/assignLicense" \
        --headers Content-Type=application/json --body "$licence" --only-show-errors >/dev/null 2>&1; then
        log "licence $sku assigned"
        credentials
        exit 0
    fi
    ((attempt < 5)) && sleep "$((attempt * ${RETRY_DELAY:-3}))"
done
credentials
die "user created but licence $sku NOT assigned: assign it by hand" 2
