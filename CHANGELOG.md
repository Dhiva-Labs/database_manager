# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-10-16

The version is now the same everywhere. The `0.0.1` release tag carried a
`database-manager_1.0.0_amd64.deb`; this release is tagged `1.0.1`, and its
packages are named `1.0.1`, matching `pubspec.yaml`.

### Added
- Linux arm64 and Windows arm64 builds, next to the x64 ones. Releases carry
  `database-manager_<version>_amd64.deb`, `database-manager_<version>_arm64.deb`,
  `DatabaseManager-<version>-windows-x64.zip` and
  `DatabaseManager-<version>-windows-arm64.zip`. Every package is built, tested
  and started on a runner of its own architecture.
- Windows zip packages (x64 and arm64) with SQLCipher bundled.
- Releases are completed by CI: publishing a release attaches the packages,
  leaving alone any file name already on the release.

### Fixed
- The LMDB driver also looks for `liblmdb` in the aarch64 multiarch directory,
  so LMDB databases open on Linux arm64.

### Changed
- `jni` is updated to 1.0.3, which compiles on Linux arm64.

## [1.0.0] - 2026-07-14

- Initial release: SQLite (with SQLCipher), MySQL/MariaDB, PostgreSQL, MongoDB
  and LMDB browsing, editing, CSV export and backup. Shipped as the
  `database-manager_1.0.0_amd64.deb` on the `0.0.1` pre-release.
