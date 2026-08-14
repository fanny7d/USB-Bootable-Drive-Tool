# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- In-app production log for validation, unmount, raw write progress, synchronization, completion, and failures.
- macOS system authorization flow, allowing the authentication method permitted by system policy.
- Native completion sheet summarizing the image, target device, elapsed time, eject state, and copyable log.

### Changed

- Removed the Terminal and `sudo` handoff from the write workflow.
- Prevented normal app termination while a privileged write is active, avoiding accidental pipe closure during destructive work.
- Replaced mixed numbered/checkmark sidebar steps with semantic image, device, and write-state icons.
- Removed the persistent warning card from the workspace; destructive guidance now appears only in the final confirmation sheet.

### Security

- The app never receives or stores an administrator password.
- The privileged task revalidates the image size plus whole/external/removable/writable disk identity and exact capacity after authorization.
- A persistent privileged helper remains deferred until Developer ID signing can authenticate its XPC client.

## [1.1.0] - 2026-08-14

### Added

- Native AppKit interface with macOS glass materials.
- Custom Dock and Finder icon with a complete ICNS size set.
- Standard application, file, and window menus.
- Automatic disk refresh after volume mount, unmount, rename, and system wake.
- Unified build, run, debug, log, telemetry, and verification script.
- GitHub Actions CI and open-source community documentation.

### Fixed

- External USB disks being filtered out on current macOS because `diskutil` now reports `WholeDisk` and `WritableMedia` keys.
- The same plist-key mismatch in the destructive preflight check.

### Security

- Only whole, external, removable, writable physical disks are accepted.
- Disk identity and exact size are checked again before unmounting or writing.
- Administrator credentials remain exclusively in the system Terminal and `sudo` flow.

[Unreleased]: https://github.com/fanny7d/USB-Bootable-Drive-Tool/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/fanny7d/USB-Bootable-Drive-Tool/releases/tag/v1.1.0
