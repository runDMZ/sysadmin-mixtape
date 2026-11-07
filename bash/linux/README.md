# 🐧 Linux scripts

Small tools for the daily life of a Linux server. Each one does one thing, needs nothing beyond the usual packages, and prints `-h` help.

They all return the same exit codes, so cron or a monitoring agent can react to them:

| Code | Meaning |
|---|---|
| `0` | all good |
| `1` | warning: worth a look |
| `2` | critical: act now |
| `3` | wrong usage (bad option, missing argument) |

```bash
# Install for every user of the server
sudo install -m 755 bash/linux/*.sh /usr/local/bin/
```

---

## server-health.sh: is this server OK?

**When**: you log in to a server and want the state of things in five seconds, or you want an email only when something goes wrong.

It checks load, memory, disk space and inodes, failed systemd services, pending reboot, pending updates (security ones are critical) and clock sync.

```bash
server-health.sh          # full report
server-health.sh -q       # only the problems; nothing printed if all is well
server-health.sh -d 80    # warn from 80% disk usage instead of 85%
```

```
== web01 · 2026-11-07 17:40:25 · up 12 days, 3 hours
[OK]   load 0.03 for 2 CPU(s)
[OK]   memory 41% used (2210 MiB available)
[WARN] disk /var 91% used
[OK]   no failed systemd unit
[CRIT] 34 pending update(s), 26 security
```

Cron, every 30 minutes, email only on a problem:
`*/30 * * * * server-health.sh -q || mail -s "$(hostname) health" admin@example.com`

## check-cert-expiry.sh: which certificates expire soon?

**When**: before a website, VPN or mail server shows a certificate error to everyone because nobody renewed it.

It connects to each address (or reads certificate files) and gives the days left: warning under 30 days, critical under 7.

```bash
check-cert-expiry.sh example.com mail.example.com:465 vpn.example.com:8443
check-cert-expiry.sh -f my-sites.txt          # one address per line
check-cert-expiry.sh -F /etc/ssl/certs/mysite.pem
```

```
STATUS     DAYS  EXPIRES                  TARGET
OK          211  2027-06-06 14:00         example.com (example.com)
WARN         18  2026-11-25 09:12         vpn.example.com:8443 (vpn.example.com)
```

## check-mail-dns.sh: is this domain's email set up correctly?

**When**: after adding a domain to Microsoft 365 or Google Workspace, before a migration, or when mails land in spam.

It reads the DNS records that tell other mail servers whether to trust your mail:
- **MX**: where mail for the domain is delivered;
- **SPF**: which servers may send in the name of the domain (only one record allowed, at most 10 DNS lookups);
- **DMARC**: what receivers do with mail that fails the checks (`none` only watches, `quarantine` or `reject` protect);
- **DKIM**: the signing key (selectors `selector1`/`selector2` for Microsoft 365, `google` for Google, others with `-s`);
- **MTA-STS**: forces encryption between mail servers (optional).

```bash
check-mail-dns.sh example.com
check-mail-dns.sh -s mykey example.com      # extra DKIM selector
```

```
== example.com
  [OK]   MX: example-com.mail.protection.outlook.com.
  [OK]   SPF: strict (-all), 1 lookup(s): v=spf1 include:spf.protection.outlook.com -all
  [WARN] DMARC: p=none, monitoring only. Move to quarantine then reject once reports are clean
  [OK]   DKIM: selector(s) found: selector1 selector2
```

Needs `dig` (package `dnsutils` on Debian, `bind-utils` on RHEL).

## backup-rotate.sh: keep the last N backups of a folder

**When**: you want a nightly copy of a folder (configuration in `/etc`, a website, a database dump) without filling the disk.

Each run:
1. compresses the folders into `DEST/NAME-date-time.tar.gz`;
2. reads the archive back to check it is not corrupted (if it is, it stops and deletes nothing);
3. writes a `.sha256` checksum next to it;
4. keeps only the `-k` most recent archives of that name and deletes the older ones.

```bash
backup-rotate.sh -d /srv/backup -n etc -k 7 /etc            # 7 days of history if run nightly
backup-rotate.sh -d /srv/backup -n www -e '*.log' /var/www  # without the logs
backup-rotate.sh -d /srv/backup -n etc -k 7 -N /etc         # dry run: shows, does nothing
```

Restore (here into a temporary folder, to pick what you need):
`mkdir /tmp/restore && tar -xzf /srv/backup/etc-20261106-021500.tar.gz -C /tmp/restore`

⚠️ The archives stay on the same server: if the disk dies or ransomware encrypts it, they go with it. Copy them elsewhere too (3-2-1 rule: 3 copies, 2 media, 1 off site) and test a restore from time to time.

## audit-local-users.sh: who can log in to this machine?

**When**: on a server you inherit, after someone leaves, or for an access review (ISO 27001).

It lists every account with a login shell, whether it has sudo, the state of its password, its SSH keys and its last login, then lists what deserves attention:
- a second account with UID 0 (another root);
- an empty password;
- sudo without password (`NOPASSWD`), for a user or a group;
- an account with a password that never logged in.

```bash
sudo audit-local-users.sh       # root needed to read password states and every key
```

```
USER                UID  SUDO   PASSWORD  KEYS  LAST LOGIN     SHELL
root                  0  root   locked       0  never          /bin/bash
alice              1000  group  set          2  Oct 26 2026    /bin/bash
bob                1001  nopass EMPTY        0  never          /bin/bash

Findings:
 - bob has an empty password
 - bob can use sudo without a password (NOPASSWD)
```

`SUDO` column: `group` member of sudo/wheel, `rule` own line in sudoers, `nopass` sudo without password, `root` is root.

---

Tests: `bats bash/tests` (see the [main README](../../README.md#tests)).
