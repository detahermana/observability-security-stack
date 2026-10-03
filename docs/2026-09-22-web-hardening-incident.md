# 2026-09-22 — Site security incident, data recovery, and hardening (sanitized)

A sanitized record of the work done on 22 September 2026. Every change in this
document was **applied and verified** on the servers — it is not a plan.
Identifiers (hosts, addresses, record counts, file hashes, participant names)
have been replaced with representative placeholders.

Hosts involved:

| Host | Role | Changes |
|---|---|---|
| Target-1 192.0.2.8 | reporting application (large dataset) | blocked the attacker, closed the webshell + data leak, recovered records, fixed the fail2ban filter |
| Target-2 192.0.2.7 | assessment application (concurrent load) | new fail2ban jails; **rate limiting deliberately NOT installed** (reason in §5) |
| VPS VPS_IP | monitoring + Wazuh manager | no config changes (alert diagnosis only) |

---

## 1. Target-1 security incident — attacker planted a webshell

### Finding

While investigating why records appeared encrypted, an **active webshell**
was found on Target-1. This was not a data problem — it was a breach.

```
Attacker IP  : 203.0.113.10  (hosting provider, registered HK)
Entry path   : brute force POST /login/dologin
               155 attempts, 131 SUCCEEDED, 24 failed
               window: 21 Sep 21:31:37 -> 22 Sep 09:09:48
Entry point  : vendor/install/install.php (framework installer, publicly open)
               updatenew.php + /app/updatemanual (write files without login)
Webshell     : /assets/<vendor>/<lib>/icons/svg/free/<name>.php
               (size and hash omitted)
               disguised as an icon file inside the assets folder
```

At last observation (09:24:13) the attacker could **run shell commands** as
`www-data`. The commands mapped the server: hunting for
`/var/cpanel/userdata/*`, each vhost's `documentroot`,
`/home/*/domains/*/public_html`, `/www/wwwroot/*`. That is a mass bot looking
for a many-sites server to backdoor everything on it.

### Damage assessment — clean

Everything was checked, all results negative:

- New cron jobs: none (`/etc/cron.d` holds anacron, certbot, e2scrub_all; user
  crontabs empty)
- New users: none (only `target-1`, `node_exporter`, `promtail` — ours)
- Foreign processes: none
- Outbound connections: only promtail, wazuh-agentd, node_exporter
- New files in the webroot: 2 — `cil-4k.php` (webshell) + `updatenew.php` overwritten

The attacker only reached the mapping stage. No second backdoor, no persistent
cron, no fake user.

### Action 1 — block the attacker IP (fail2ban)

```bash
fail2ban-client set nginx-ratelimit-access banip 203.0.113.10
```

Verified in three places:

```
fail2ban : Banned IP list: 203.0.113.10
nftables : set addr-set-nginx-ratelimit-access { elements = { 203.0.113.10 } }
chain    : f2b-chain active
```

### Action 2 — disable PHP execution in the assets folder

The `assets/` folder holds thousands of files and **exactly 1 PHP file** — the
webshell. No legitimate PHP lives there, so disabling PHP execution breaks
nothing.

PHP runs as an Apache module (`/etc/apache2/mods-enabled/php7.load` +
`libphp7.so`, PHP 7.4.33), which treats every `.php` under the DocumentRoot as
a program — including inside the assets folder.

Applied in `/etc/apache2/sites-enabled/000-default.conf` **inside the
`target-1-app` container**:

```apache
<Directory /var/www/html/assets>
    php_admin_flag engine off
    SetHandler none
    <FilesMatch "\.php$">
        Require all denied
    </FilesMatch>
</Directory>
```

Result: `GET /assets/.../cil-4k.php?v` changed from `200` (returning
`zzOK_7.4.33_www-data`) to **`403`**. This block is not IP-dependent — if the
attacker changes IP, the webshell stays dead.

### Action 3 — close publicly downloadable file leaks

Two files were previously served as **HTTP 200** to anyone:

| URL | Contents | Before | After |
|---|---|---|---|
| `/assets/token.json` | upstream API token | 200 | **403** |
| `/assets/tmp/*_records.json` | bulk record dumps: name, national ID, identifier, place/date of birth | 200 | **403** |

```apache
<LocationMatch "^/assets/(token\.json|tmp/)">
    Require all denied
</LocationMatch>
```

The application reads those files from disk, not over HTTP — so closing them
breaks no feature. Verified: normal static assets still return 200
(bundle CSS and logo image).

### Still OPEN on Target-1 (not done, needs the owner's decision)

1. **The proctor password is not confirmed changed.** 131 successful attacker
   logins were recorded. While the old password works, every closure above can
   be bypassed in a minute: log in, call `updatemanual`, write a new webshell.
2. **The upstream API token needs reissuing** — it leaked via `/assets/token.json`.
3. **The webshell `cil-4k.php` remains on disk** as evidence. It can no longer
   be executed or downloaded.
4. **`vendor/install/install.php` still returns 200** to the public.
5. **The update path (`updatenew.php`, `/app/updatemanual`)** was not
   closed — it is an official feature the operator uses to update the
   application. Tested: with no session, `POST /app/updatemanual` returns
   `303` (redirect to login), so it is not an unauthenticated hole. The
   attacker got through it after obtaining a valid operator session.

---

## 2. Record name & identifier recovery (sanitized row counts)

### Symptom

Record names and identifiers displayed as base64 ciphertext in the application.

### Root cause

Two name columns and one identifier column **must be PLAINTEXT**, just like a
third name column. The application reads those columns directly, with no decryption.

Evidence: the teacher-name column holds plaintext and displays normally, and the
application's own `dekrip()` function returns `false` for that value — meaning
the application does not call decryption for the name column.

So the ciphertext in those columns was **injected from outside**, not produced
by the application. The most likely cause: a vendor update. Two events prove
it — one cohort whose data broke, and several records whose ciphertext
changed after 18 Sep.

IMPORTANT: the running application's `dekrip()`/`enkrip()` uses a `cipher:KEY`
format (`enkrip('TES')` = `OF2ieoEM0+B3Xau4CPmtcg==:bTRkcjRzNGhiMXM0ZDBuOQ==`),
while the old data uses a bare base64 with no key. Two formats = two different
application versions. That is why `dekrip()` returns `false` for all old
ciphertext.

### Sources of the real names

| Source | Contents | Used for |
|---|---|---|
| `/root/<host>_name_sources/updates.sql` | plaintext names (18 Sep) | existing names |
| `/root/<host>_name_sources/updates2.sql` | plaintext names | records absent from the first source |
| `/root/<host>_name_sources/encrypt_names.sql` | ciphertexts (18 Sep) | **matching safety net** |
| `assets/tmp/*_records.json` | plaintext records from the upstream API | the remainder + broken names |
| `DATA_per_class_revisi.xlsx` | records (from the operator) | missing identifiers |

Copied to `/root/<host>_name_sources/` (persistent) because the originals
lived in the container's `/tmp`, which is lost on container recreate.

### Five repair steps, each verified row by row

| Step | Rows | Source | Verification |
|---|---|---|---|
| 1 | names | 18 Sep file | all correct |
| 2 | names + identifiers | upstream API | all correct |
| 3 | identifiers | revised file | all correct |
| 4 | broken names + identifiers | upstream + revised | all correct |
| 5 | names + identifiers | upstream (identity fingerprint) | all correct |

All rows written in a single transaction. **Zero failures, zero swapped values.**

Final result:

```
                       before   after
TOTAL rows             N+1       N     (1 test row removed)
NAMES readable           ~0       all   (100%)
NAMES encrypted         most         0
IDENTIFIERS readable     ~0       ~all  (>99%)
IDENTIFIERS encrypted   most         0
IDENTIFIERS empty      a few     a few  (records transferred out)
```

### Three mandatory safety measures (the anti-swap recipe)

1. **Match the old ciphertext.** Only rows whose ciphertext matched the 18 Sep
   record were written. If the ciphertext had changed, the value was treated as
   stale and the row was skipped. This prevents swapped values.
2. **`WHERE HEX(column)='<live hex>'`.** Values containing backslashes and
   apostrophes **cannot** be matched with an ordinary string comparison —
   `affected_rows` comes back 0 with no error. HEX is the only reliable way.
3. **Dry run.** `START TRANSACTION` → verify every row → `ROLLBACK`, then
   `COMMIT`. The dry run caught 2 bugs before any data was touched.

### Names broken by apostrophes

Values such as `A\\\\`, `RIF\\\\`, `MUHAMMAD RO\\\\` were found. Cause:
apostrophes were escaped incorrectly during the original write, truncating the
value at the apostrophe. The correct values, from the upstream source, were:

```
'A\\\\'            -> A'<SURNAME>
'RIF\\\\'          -> RIF'<SURNAME>
'MUHAMMAD RO\\\\'  -> MUHAMMAD RO'<SURNAME>
'EL-SYABA\\\\'     -> EL-SYABA' <SURNAME>
```

One detail matters: **the backslash count is not uniform.** One row had 1
backslash, the others had 2. So HEX must be read **row by row from the live
DB**, not computed from a pattern.

### Empty identifiers — NOT corruption

All of them are marked **transferred out**:

```
transfer_reason_code   : 99
transfer_year          : 2024
term                   : 1
academic_year_id       : NULL
```

The decisive statistic: across the whole table, an empty identifier occurs
**exclusively** on transfer-code 99 records. Among normal records, empty
identifiers are ZERO.

Those records also have **a twin row in the next grade for the following
academic year** with `transfer_reason_code = NULL` and a complete identifier.
So they were once recorded as transferred out, then re-enrolled as new. The old
row was left as history.

**Do not fill an identifier into the transfer row** — that would give one
person two rows with the same identifier.

### Additional findings

- Some duplicate rows exist (same person, different primary key). Pre-existing
  data problem, not caused by this work.
- One row is clearly test data, not a real record.
- A whole cohort has a status column NULL while the next cohort is `0`. There is
  no reference table for that code in the database. Recorded as an open
  question, not concluded.

---

## 3. Wazuh alert 31151 — why it is still noisy

### Diagnosis

```
Total 22 Sep : 257 level-10 alerts
Agent        : most from Target-1 (192.0.2.8), remainder Target-2 + VPS
HTTP code    : mostly 404, a few 429 and 400
Top IP       : one 203.0.113.x address produced most alerts
```

Rule 31151 (`Multiple web server 400 error codes from same source ip`) is a
stock rule in `0245-web_rules.xml`, `frequency=14 timeframe=90`,
`if_matched_sid 31101`, reading `/var/log/nginx/access.log`.

### A chain of root causes

**Layer 1 — the rule targets the wrong thing.** Its parent rule 31101 uses:

```xml
<rule id="31101" level="5">
  <if_sid>31100</if_sid>
  <id>^4</id>                    <!-- ALL 4xx, not just 400 -->
  <description>Web server 400 error code.</description>
</rule>
```

The description says "400" but `<id>^4</id>` catches the entire 4xx class. So
**248 of 257 alerts (96%) were triggered by 404**, not 400. A scanner only has
to hit random paths to fire a level-10 alert.

**Layer 2 — the scanner is slow but persistent.** A single 203.0.113.x address
sent thousands of requests, all 404, at 1–3 rps — below the rate limit, so it
never hit a 429. It hunted for credential files using the `%2e` trick:

```
GET /backend/config/mailjet%2eenv     %2e = dot, to slip past
GET /api/credentials%2ejson            literal-match deny regex
GET /requirements%2eses%2etxt
```

**Layer 3 — the Target-1 fail2ban filter was too narrow.**

```
Target-1 (failed)  : ^<HOST> - - .* 429 [0-9]+        <- 429 only
VPS (worked)       : ^<HOST> - - \[[^\]]*\] "[^"]*" (429|400|404) \d+ ...
```

The scanner received 404s, so it never counted on Target-1.

### Fix on Target-1

The filter `/etc/fail2ban/filter.d/nginx-ratelimit-access.conf` was replaced
with the VPS pattern that already works, plus an `ignoreregex` for static-asset
404s:

```
Failregex   : ^<HOST> - - \[[^\]]*\] "[^"]*" (429|400|404) \d+ "[^"]*" "[^"]*"\s*$
Ignoreregex : ^<HOST> - - \[[^\]]*\] "[^"]*\.(css|js|png|jpe?g|gif|svg|ico|woff2?|ttf|map|webp) HTTP/[0-9.]+" 404
```

Test: almost all lines matched, a small number excluded. The old filter would
have matched only a handful.

`ignoreip` gained `203.0.113.0/24` (the VPN pool — we connect as 203.0.113.2).
Thresholds raised: `maxretry` increased, `findtime` doubled.

Several 203.0.113.x addresses banned.

Functional test: fake 404 lines from an RFC 5737 address → **banned
automatically** → unbanned, logs cleaned.

### Important correction about ignoreip

`ignoreip` is a **ban-exemption list**, not an allowlist. Target-1 has no
allowlist — anyone from anywhere can open the application. Adding
`203.0.113.0/24` restricts nobody; it only protects the VPN IP from being banned
when someone mistypes a URL repeatedly.

---

## 4. Target-2 — internet scanner + malware payload

### Finding

```
Total alerts 22 Sep : several hundred (all from one agent)
Per rule: mostly 31101, then 31151 and a few others
HTTP codes: mostly 404, some 400 and 405
```

Two findings more serious than mere scanning:

1. **Gh0st RAT payload in the logs:**
   ```
   203.0.113.x [22/Sep 00:41:03] "<binary payload omitted>...
   ```
   Gh0st RAT is a well-known backdoor; the attacker sent its binary payload
   directly. Answered with 404/150 — unsuccessful, but this is an exploitation
   attempt, not an ordinary scanner.

2. **The scanner hunted AI coding-agent credentials:**
   ```
   /.hermes/.env          /.codex/auth.json        /.claude/.credentials.json
   /.local/share/opencode/auth.json                 /.openclaw/.env
   /.git-credentials      /.git/config             /.env.*
   ```
   A specific, modern target list. All returned 404 — nothing leaked.

### Starting condition: no web protection at all

```
                       Target-1                    Target-2
nginx rate limit       perip 20r/s            NONE
fail2ban web jail      nginx-ratelimit-access NONE (sshd only)
.env deny regex        present                NONE
```

### What was installed

```
fail2ban jail  : target-2-scan, target-2-botsearch, sshd
filter         : target-2-scan.conf (same pattern as Target-1)
                 tested 1,723/1,954 lines matched
bantime        : 86,400 seconds (24h) + bantime.increment factor=2 maxtime=86400
ignoreip       : 127.0.0.1/8, ::1, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24
IPs banned     : several 203.0.113.x addresses
```

Why a 24-hour bantime: at 900 seconds (15 minutes), scanner IPs cycled
ban-unban endlessly. Verified — shortly after a ban, requests from the same IP
were already coming back in.

Functional test: fake 404 lines from an RFC 5737 address → **banned
automatically** → unbanned, logs cleaned.

---

## 5. Target-2 — why rate limiting was deliberately NOT installed

This was a decision made after doing the arithmetic, not an oversight.

Rate limiting was installed, then **withdrawn**. The reason:

```
Users reach the DOMAIN from the SITE NETWORK
-> through the site router, NAT'd to a single public IP
-> nginx on Target-2 sees ONE IP for all users

many users at once, 1 page = ~15 assets
-> thousands of requests within seconds from one IP
rate limit 20 r/s = 1,200 requests/minute
-> most users get HTTP 429 = ASSESSMENT FAILURE
```

The owner's decision: **remove the rate limit, rely on fail2ban.** The
priority is that users must not fail their assessment.

User protection is still in place, and verified:

```bash
fail2ban-client get target-2-scan ignoreip
# -> 127.0.0.0/8, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, ::1
```

`ignoreip` contains the site network, so **however many requests users make,
they cannot be banned**. No rate limit can hit them.

Note for Target-1: the 20 r/s rate limit there **is still installed** and has
not been tested under exam load. Target-1 is not an assessment application, so the
risk differs — but this is unverified and should be checked if a large
concurrent usage ever happens.

### An unused zone

`/etc/nginx/conf.d/ratelimit.conf` on Target-2 still exists (zone definition)
but is **not referenced by any vhost**. Verified:

```bash
grep -rn "limit_req\|limit_conn" /etc/nginx/sites-enabled/
# -> nothing
```

A zone that is only defined has no effect. It was left so it can be used later
if the pattern changes.

### Backend ports still open (not closed, outside our remit)

```
docker-proxy  0.0.0.0:8080   -> target-2-app
docker-proxy  0.0.0.0:3000   -> another service
```

This means access via `192.0.2.7:8080` bypasses nginx entirely — fail2ban
and logs do not apply on that path. **Not closed**, because port binding is the
application's concern, not monitoring infrastructure's. Recorded as a
recommendation for the application owner.

---

## 6. Backup & cleanup

### Database backup (in `/root/` on Target-1)

```
<host>_db_GOOD_<ts>.sql   (size omitted)
  MD5         <omitted>
  tables      count matches the live DB exactly
  options     --single-transaction --skip-lock-tables --routines --triggers --events
  RESTORE TEST restored to a separate DB <host>_verify -> succeeded, all counts matched:
               total rows, readable names, readable identifiers all matched
               test DB dropped after verification
```

Staged backups before each step:

```
<stage1>_BEFORE_<ts>.sql   <hash omitted>
<stage2>_BEFORE_<ts>.sql   <hash omitted>
<stage3>_BEFORE_<ts>.sql   <hash omitted>
<stage4>_BEFORE_<ts>.sql   <hash omitted>
<stage5>_BEFORE_<ts>.sql   <hash omitted>
<stage6>_BEFORE_<ts>.sql   <hash omitted>
```

### Config backups

```
Target-1 : /root/nginx-ratelimit-access.conf.bak-<ts>
           /root/nginx-ratelimit.local.bak-<ts>
           /root/000-default.conf.bak.tokenblock.<ts>
Target-2 : /root/nginx.conf.bak-<ts>
           /root/target-2.vhost.bak-REMOVED-RATELIMIT-<ts>
           /root/target-2.local.bak-<ts>
```

### Cleanup

Target-1 host `/tmp` and its containers were reduced substantially. Removed:
already-executed repair scripts, verification dump snapshots, test scripts,
decryption test data.

The operator's laptop `Downloads` was reduced substantially. Removed: the old
hosting application package, raw zip archives, a restore_stage folder,
intermediate work files. **Kept** in `Downloads/<host>-dokumen-penting/`: the
handover document + credentials, the runbook, the report.

---

## 7. Lessons reused later

Six pitfalls that consumed time today. All are captured as reusable notes.

1. **A `WHERE` string comparison FAILS SILENTLY for values with backslashes or
   apostrophes.** The UPDATE runs without error, `affected_rows` = 0. Use
   `WHERE HEX(column)='<hex>'`.
2. **`docker exec` without `-i`** makes `mysql < file` exit 0 while **nothing
   changes**. It must be `docker exec -i`.
3. **A dry run is mandatory.** `START TRANSACTION` → verify → `ROLLBACK` →
   `COMMIT`. Caught 2 bugs before any data was touched.
4. **The backslash count is not uniform across rows** — do not compute it from
   a pattern; read HEX per row from the live DB.
5. **Do not conclude from scanner logs.** I initially thought the 6 "private
   IP" lines were internal users; in fact `172.202.x`/`172.236.x` are public IPs
   hosting scanners (`zgrab/0.x`). Only 172.16–172.31 are private.
6. **`<id>^4</id>` in parent rule 31101 catches all 4xx.** Do not trust a
   rule's description — read its body.

---

## 8. Change summary per host

### Target-1 192.0.2.8

| File | Change |
|---|---|
| `/etc/apache2/sites-enabled/000-default.conf` (inside the `target-1-app` container) | `<Directory assets>` block + `<LocationMatch token.json\|tmp/>` block |
| `/etc/fail2ban/filter.d/nginx-ratelimit-access.conf` | failregex 429-only → (429\|400\|404) + ignoreregex for static assets |
| `/etc/fail2ban/jail.d/nginx-ratelimit.local` | +`203.0.113.0/24` in ignoreip, maxretry 20→30, findtime 60→120 |
| name and identifier columns | all rows written; names + identifiers readable |
| `/root/target-1_sumber_nama/` | name sources rescued from container `/tmp` (persistent) |

### Target-2 192.0.2.7

| File | Change |
|---|---|
| `/etc/nginx/conf.d/ratelimit.conf` | NEW — zone definition (not referenced by any vhost) |
| `/etc/nginx/sites-available/target-2` | limit_req installed then **withdrawn** (§5) — final state clean |
| `/etc/fail2ban/filter.d/target-2-scan.conf` | NEW |
| `/etc/fail2ban/jail.d/target-2.local` | NEW — 2 jails, 24h bantime + increment |

### VPS VPS_IP

No config changes. Only alert-31151 diagnosis. The pre-existing override
`/var/ossec/etc/rules/custom-monitoring_rules.xml` (excluding Grafana's
`/api/ds/query`) **does not touch today's problem** — the trigger was a 404
scanner, not Grafana. Left unchanged.

---

## 9. Final verification

```
Target-1 : / 200 | /app 307 | app + db containers Up
           rows total | names readable all | identifiers readable ~all
           related tables intact
           webshell 403 | token.json 403 | IPs actively banned
Target-2 : / 200 | backend 200 | app healthy | containers Up
           jails active | IPs actively banned | ignoreip contains the site network
```
