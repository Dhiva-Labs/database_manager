#!/usr/bin/env bash
# Build a .deb for Database Manager from the Flutter Linux release bundle.
# Usage: packaging/make_deb.sh [--build]
#   --build   run `flutter build linux --release` first
#
# The package architecture comes from the machine this runs on (amd64 or
# arm64), because Flutter builds for the host. The output is
# dist/database-manager_<version>_<arch>.deb.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(grep '^version:' "$ROOT/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
PKGNAME="database-manager"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture '$ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac

BUNDLE="$ROOT/build/linux/$FLUTTER_ARCH/release/bundle"
OUT="${OUT_DIR:-$ROOT/dist}"
STAGE="$(mktemp -d)"
PKG="$STAGE/${PKGNAME}_${VERSION}_${ARCH}"
trap 'rm -rf "$STAGE"' EXIT

if [[ "${1:-}" == "--build" ]]; then
  (cd "$ROOT" && flutter build linux --release)
fi
[[ -x "$BUNDLE/database_manager" ]] || {
  echo "Release bundle not found. Run with --build or 'flutter build linux --release' first." >&2
  exit 1
}

# ---- staging tree ----
mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/lib/$PKGNAME" \
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/256x256/apps" \
         "$PKG/usr/share/icons/hicolor/128x128/apps" \
         "$PKG/usr/share/icons/hicolor/64x64/apps"

cp -r "$BUNDLE"/* "$PKG/usr/lib/$PKGNAME/"
cp "$ROOT/packaging/icons/${PKGNAME}_256.png" "$PKG/usr/share/icons/hicolor/256x256/apps/$PKGNAME.png"
cp "$ROOT/packaging/icons/${PKGNAME}_128.png" "$PKG/usr/share/icons/hicolor/128x128/apps/$PKGNAME.png"
cp "$ROOT/packaging/icons/${PKGNAME}_64.png"  "$PKG/usr/share/icons/hicolor/64x64/apps/$PKGNAME.png"

# launcher: Flutter resolves its real path to locate data/ and lib/ siblings
ln -s "../lib/$PKGNAME/database_manager" "$PKG/usr/bin/$PKGNAME"

cat > "$PKG/usr/share/applications/$PKGNAME.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Database Manager
Comment=Browse, query, edit, export and back up SQLite, MySQL, PostgreSQL, MongoDB and LMDB databases
Exec=$PKGNAME
Icon=$PKGNAME
Terminal=false
Categories=Development;Database;Utility;
Keywords=database;sql;sqlite;mysql;postgres;postgresql;mongodb;lmdb;
StartupWMClass=database_manager
DESKTOP

SIZE="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: $PKGNAME
Version: $VERSION
Section: database
Priority: optional
Architecture: $ARCH
Maintainer: Dhiva Labs <dhivakar1010@gmail.com>
Installed-Size: $SIZE
Depends: libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libstdc++6, zlib1g
Recommends: liblmdb0
Description: Multi-engine desktop database manager
 Database Manager is a desktop client to open, browse, query, edit,
 export (CSV) and back up databases across five engines from one UI:
 SQLite (incl. SQLCipher-encrypted files), MySQL/MariaDB, PostgreSQL,
 MongoDB and LMDB.
 .
 It offers a plain-English row finder for non-technical users plus a raw
 SQL / command editor for developers, password-protected database support,
 and one-click backups.
CONTROL

cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
exit 0
POSTINST
cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
exit 0
POSTRM
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"

find "$PKG/usr" -type d -exec chmod 0755 {} \;
chmod 0755 "$PKG/usr/lib/$PKGNAME/database_manager"

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/${PKGNAME}_${VERSION}_${ARCH}.deb"
echo "Built: $OUT/${PKGNAME}_${VERSION}_${ARCH}.deb"
