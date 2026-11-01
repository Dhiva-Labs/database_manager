# Flatpak

`com.dhivalabs.database_manager.yml` builds the Flatpak from the installed
tree of the .deb, so it ships the same binary as every other Linux package.

## How CI builds it

The `distros` job in `.github/workflows/desktop.yml` unpacks the .deb, cleans
the tree (`packaging/linux-distros/pack.sh`, which drops the Debian-only files
and `libdartjni.so`, see `distro.conf`) and adds Ubuntu 24.04's
`liblmdb.so.0` (the GNOME runtime has no LMDB). The `flatpak` job unpacks it
into `packaging/flatpak/tree/` and runs flatpak-builder in the
`ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image, on x86_64 and
aarch64. It then installs the bundle, checks every ELF file with ldd against
the GNOME 51 runtime, loads `liblmdb.so.0` by name inside the sandbox (as
the LMDB driver does), and starts the app under Xvfb until its window is up
(`x11_window.py`; the image has no xdotool) and Dart has created its data
folder.

The bundle, `database-manager-<version>-<arch>.flatpak`, refers to Flathub
for its runtime:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./database-manager-<version>-x86_64.flatpak
flatpak run com.dhivalabs.database_manager
```

## Sandbox

- `--share=network`: MySQL/MariaDB, PostgreSQL and MongoDB servers.
- `--filesystem=home`: SQLite creates its `-journal`/`-wal` files next to the
  database, and LMDB opens a whole environment directory; the file chooser
  portal grants neither. Saved connections and backup folders are reopened
  by path. Databases outside your home folder (for example under `/srv` or
  `/mnt`) need `flatpak override --user --filesystem=/srv com.dhivalabs.database_manager`.

## Releases

Add a `<release>` line to `com.dhivalabs.database_manager.metainfo.xml` with
each version bump; the CI fails when the version in `pubspec.yaml` is
missing there. The metainfo has no `<project_license>` because the
repository does not state a licence yet; add one when it does.

## Flathub

A Flathub submission would differ: the `tree` directory source becomes an
`archive` source (the release's `database-manager_<version>_amd64.deb` /
`_arm64.deb`, with `only-arches` and a sha256 each, unpacked with `ar` and
`tar`, and `libdartjni.so` removed), LMDB is built from source as a manifest
module instead of copied from Ubuntu, and the manifest goes to a new
`flathub/com.dhivalabs.database_manager` repository through Flathub's review
(which also needs a licence). Nothing is published from this repository.
