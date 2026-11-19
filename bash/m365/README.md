# ☁️ Microsoft 365 scripts (Bash)

Microsoft 365 administration from a Linux workstation, with **Azure CLI only**: no PowerShell module to install, `az rest` talks to Microsoft Graph directly.

```bash
az login --tenant <tenant-id> --allow-no-subscriptions
```

| Code | Meaning |
|---|---|
| `0` | done |
| `1` | a check or a Graph call failed, nothing (more) was done |
| `2` | partly done: read the message |
| `3` | wrong usage (bad option, missing argument) |

---

## new-m365-user.sh: create a user with a licence

**When**: a new person arrives and needs an account with a licence, without clicking through the admin centre.

It builds the UPN from the names, checks everything that can go wrong before writing, creates the account, assigns the licence and prints a temporary password once.

```bash
new-m365-user.sh                         # interactive: asks the names, menus for domain and licence
new-m365-user.sh -f Jean -l Dupont -d contoso.com -L SPB -D Sales -t "Account manager"
new-m365-user.sh -f Jean -d contoso.com -L none            # first name only, no licence
new-m365-user.sh -f Jean -l Dupont -d contoso.com -L SPB -N  # dry run
new-m365-user.sh -f Jean -l Dupont -d contoso.com -L none -s admin  # jean.dupont.admin@, "Jean Dupont (admin)"
```

```
  Display name : Jean Dupont
  UPN          : jean.dupont@contoso.com
  Company      : -   Department: Sales   Job title: Account manager
  Country      : FR
  Licence      : SPB (3 free)

Create this user? [y/N] y
-> user created: jean.dupont@contoso.com
-> licence SPB assigned

  Sign-in            : jean.dupont@contoso.com
  Temporary password : ************Aa1!   (to change at first sign-in)
```

| Option | Graph attribute | |
|---|---|---|
| `-f` / `-l` | `givenName` / `surname` | at least one of them |
| `-d` | — | UPN domain, must be verified in the tenant |
| `-L` | — | licence `skuPartNumber`, or `none` |
| `-c` / `-D` / `-t` | `companyName` / `department` / `jobTitle` | optional |
| `-u` | `usageLocation` | 2-letter country code, `FR` by default |
| `-s` | — | suffix for a second account of the same person: `-s admin` → `jean.dupont.admin@…`, display name `Jean Dupont (admin)` |
| `-y` | — | no confirmation (for automation) |
| `-N` | — | dry run: all checks, no write |

**Checks before writing**: the domain is verified, the licence exists and has a free seat, the user does not exist yet. The UPN drops accents and turns spaces and apostrophes into `-`: `Hélène D'Arc` → `helene.d-arc@…`.

**Minimum role**: User Administrator (it can create users and assign licences).

To find the `skuPartNumber` of your licences (`SPB` is Business Premium, `O365_BUSINESS_PREMIUM` is Business Standard, `ENTERPRISEPACK` is Office 365 E3):

```bash
az rest --method GET --url https://graph.microsoft.com/v1.0/subscribedSkus \
  --query "value[].{sku:skuPartNumber, bought:prepaidUnits.enabled, used:consumedUnits}" -o table
```

- **Why `az rest`?** `az ad user create` can neither set `usageLocation` (without it, Microsoft refuses to assign a licence) nor assign a licence. The script calls `POST /users`, then `POST /users/{id}/assignLicense`.
- **Licence assignment is retried** a few times: a user just created can take some seconds to be visible everywhere. If it still fails, the account exists, the exit code is `2` and the licence must be assigned by hand.
- **The temporary password is printed once and never written to disk.** Give it to the person through a safe channel; the change at first sign-in is forced.
- **Group-based licensing** is cleaner when the tenant has it (Entra ID P1): add the user to the licensing group instead of assigning the licence directly.
