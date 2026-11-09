# Database Manager

[![ARM64 builds](https://github.com/Dhiva-Labs/database_manager/actions/workflows/desktop.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/database_manager/actions/workflows/desktop.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Windows x64 | arm64](https://img.shields.io/badge/Windows-x64%20%7C%20arm64-informational?logo=windows&logoColor=white)
![Linux: deb | rpm | Arch | AppImage | Flatpak](https://img.shields.io/badge/Linux-deb%20%7C%20rpm%20%7C%20Arch%20%7C%20AppImage%20%7C%20Flatpak-informational?logo=linux&logoColor=white)

A desktop-first Flutter database client for browsing, editing, exporting and
backing up databases across five engines from one UI.

**Documentation:** step-by-step guides at [learn.dhivalabs.com](https://learn.dhivalabs.com/apps/database-manager/): [install](https://learn.dhivalabs.com/apps/database-manager/install) · [beginner guide](https://learn.dhivalabs.com/apps/database-manager/getting-started) · [troubleshooting](https://learn.dhivalabs.com/apps/database-manager/faq). New to the topic? Try the [Databases](https://learn.dhivalabs.com/tracks/databases/) learning track.

## Supported engines

| Engine | Connect via | Query tab | Row editing | Backup format |
|---|---|---|---|---|
| SQLite | file picker | SQL | ✅ (rowid) | `VACUUM INTO` copy (.db) |
| MySQL / MariaDB | host/port/user/pass | SQL | ✅ (primary key) | SQL dump (`SHOW CREATE TABLE` + INSERTs) |
| PostgreSQL | host/port/user/pass | SQL | ✅ (ctid) | SQL dump (CREATE TABLE + INSERTs) |
| MongoDB | host/port/user/pass | JSON command (`runCommand`) | ✅ (_id) | JSON-lines per collection |
| LMDB | directory picker | key-prefix scan | ✅ (key/value) | `mdb_env_copy2` compacting copy |

## Features

- **Connection manager** — save multiple connections (stored as JSON in the
  app-support dir; passwords are plain text, so treat the machine as trusted).
- **Password-protected databases** — the app bundles SQLCipher, so encrypted
  SQLite files open with a password. Encrypted files are detected
  automatically and a password prompt appears; wrong server passwords
  (MySQL/PostgreSQL/MongoDB) also re-prompt. Each connection has an
  *"Ask for the password every time"* option that keeps the password out of
  the saved profile entirely.
- **Manage encryption** — the padlock button in an open SQLite database lets
  you **encrypt a plain file**, **change its password**, or **remove
  encryption**. The whole file is safely rewritten (rekey in place, or a full
  SQLCipher export + swap), then reconnected with the new key. A backup of an
  encrypted database stays encrypted with the same key — it never leaks.
- **Find rows without SQL** — the filter button on the Data tab opens a
  plain-English builder: *"Where city is Chennai and age is more than 60,
  sort by name"* — all dropdowns, no query language needed. Built for
  non-technical users who understand tables but not SQL.
- **Learn / customize the query** — the builder shows the exact query it
  runs ("Show the query this runs") with one-click copy or *open in the
  Query tab* to hand-edit — a bridge from clicking to writing.
- **Data browser** — paged grid (100 rows/page), row count, filterable
  table/collection list.
- **Run queries directly** — SQL editor with Ctrl+Enter, timing and
  affected-row counts; JSON commands for MongoDB; prefix scans for LMDB.
- **Edit rows** — click a row to edit any cell (with NULL support), insert
  new rows, delete with confirmation. Works on filtered results too.
- **Export CSV** — whole table (respecting the active filter) or current
  query result, proper RFC-style quoting.
- **Backup** — one click, pick a destination folder, get a timestamped copy
  (see table above for the per-engine format).

## Notes

- SQLCipher is compiled in via the `hooks: user_defines: sqlite3: source:
  sqlcipher` entry in pubspec.yaml — it reads unencrypted SQLite files
  normally, so nothing changes for plain databases.
- LMDB support loads the system `liblmdb` at runtime:
  `sudo apt install liblmdb0` (Ubuntu/Debian). Linux/Windows desktop only.
- MongoDB "run" examples:
  `{"find": "users", "filter": {"age": {"$gt": 21}}, "limit": 50}`,
  `{"count": "users"}`,
  `{"aggregate": "users", "pipeline": [...], "cursor": {}}`
- LMDB keys/values are shown as UTF-8 when printable, otherwise `0x…` hex;
  hex is accepted as input too.

## Install

Every release carries the desktop builds for x64 and arm64:

| Platform | Architecture | Asset |
|---|---|---|
| Linux (Debian, Ubuntu) | x64 | `database-manager_<version>_amd64.deb` |
| Linux (Debian, Ubuntu) | arm64 | `database-manager_<version>_arm64.deb` |
| Linux (Fedora, RHEL, openSUSE) | x64 / arm64 | `database-manager-<version>-1.x86_64.rpm` / `.aarch64.rpm` |
| Linux (Arch, Manjaro, EndeavourOS) | x64 / arm64 | `database-manager-<version>-1-x86_64.pkg.tar.zst` / `-aarch64.pkg.tar.zst` |
| Linux (any distribution) | x64 / arm64 | `DatabaseManager-<version>-x86_64.AppImage` / `-aarch64.AppImage` |
| Linux (Flatpak) | x64 / arm64 | `database-manager-<version>-x86_64.flatpak` / `-aarch64.flatpak` |
| Windows | x64 | `DatabaseManager-<version>-windows-x64.zip` |
| Windows | arm64 | `DatabaseManager-<version>-windows-arm64.zip` |

```bash
sudo apt install ./database-manager_<version>_arm64.deb   # or _amd64.deb
sudo dnf install ./database-manager-<version>-1.x86_64.rpm                          # Fedora, RHEL
sudo zypper install --allow-unsigned-rpm ./database-manager-<version>-1.x86_64.rpm  # openSUSE
sudo pacman -U ./database-manager-<version>-1-x86_64.pkg.tar.zst                    # Arch
chmod +x DatabaseManager-<version>-x86_64.AppImage && ./DatabaseManager-<version>-x86_64.AppImage
flatpak install --user ./database-manager-<version>-x86_64.flatpak                 # then: flatpak run com.dhivalabs.database_manager
```

The .rpm, Arch package, AppImage and Flatpak hold the same build as the .deb
and are attached to releases from 1.0.1 on. The .rpm, Arch package and
AppImage are built on Ubuntu 24.04 and need glibc 2.38 or newer (Fedora 40+,
RHEL 10, openSUSE Tumbleweed / Leap 16, current Arch). The .rpm is not signed.
For LMDB, the .rpm recommends `lmdb-devel` (Fedora and openSUSE ship
liblmdb only under a versioned name; the -devel package adds the
`liblmdb.so` the driver loads), the Arch package depends on `lmdb`, and the
AppImage and Flatpak carry `liblmdb.so.0` themselves. The Flatpak can reach
database servers and your home folder (SQLite needs its journal files next
to the database); see [packaging/flatpak/README.md](packaging/flatpak/README.md).
An AUR recipe for `database-manager-bin` (PKGBUILD and .SRCINFO) is attached
as `database-manager-bin-<version>-aur.tar.gz`.

On Windows, unzip and run `database_manager.exe`. SQLCipher is bundled on every
platform (the `sqlcipher.dll` / `libsqlcipher.so` next to the executable), so
SQLite and SQLCipher files work out of the box. LMDB needs a system library:
`liblmdb0` on Linux (a recommended dependency of the .deb), `lmdb.dll` on Windows
for the architecture you run.

The [Desktop builds](.github/workflows/desktop.yml) workflow builds, tests and
starts the packaged app on Linux and Windows, x64 and arm64, on every push.

## Build

```bash
flutter pub get
flutter build linux --release   # or: flutter build apk / windows
packaging/make_deb.sh           # .deb for the architecture you built on (amd64 or arm64)
```

Run tests:

```bash
flutter test
```

This covers the SQLite (incl. SQLCipher encryption), LMDB, filter-builder,
and CSV logic end-to-end. The MySQL/PostgreSQL/MongoDB integration tests in
`test/live_server_test.dart` **skip automatically** unless the servers are
reachable on these local ports:

| Server | Port | Credentials | Database |
|---|---|---|---|
| PostgreSQL | 55432 | `dbadmin` / `testpass123` | `shopdb` |
| MySQL / MariaDB | 53306 | `testuser` / `testpass123` | `shopdb` |
| MongoDB | 57017 | (no auth) | `shopdb` |

Point them at your own instances (or the seed data in the test file) and the
groups run: full CRUD, the plain-English filters, raw SQL/commands,
primary-key / ctid row addressing, and per-engine backups.

## Sponsors

Dhiva Labs is an independent, self-funded lab. [Sponsorships](https://github.com/sponsors/Dhiva-Labs) help bring this project and the rest of Dhiva Labs to every platform, iPhone and Mac included.

[![Sponsor Dhiva Labs](https://img.shields.io/badge/Sponsor-Dhiva%20Labs-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/Dhiva-Labs)

Monthly sponsors at $10 and up are listed here:

<!-- sponsors -->
*Be the first: [sponsor Dhiva Labs](https://github.com/sponsors/Dhiva-Labs).*
<!-- sponsors -->
