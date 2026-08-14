# Architecture

USB Bootable Drive Tool is a small native AppKit application built directly with the macOS Swift toolchain. It intentionally avoids third-party runtime dependencies.

## Components

- `Sources/USBBootableDriveTool/main.swift`: application lifecycle, AppKit UI, disk discovery, safety checks, system authorization, privileged write orchestration, and in-app output monitoring.
- `Assets/`: sidebar illustration, source app icon, and packaged ICNS icon.
- `script/build_and_run.sh`: deterministic local build, bundle assembly, ad-hoc signing, launch, and diagnostics.
- `script/package_dmg.sh`: reproducible arm64 DMG assembly, signature validation, disk-image verification, and SHA-256 generation.
- `script/test.sh`: non-destructive repository validation used locally and in CI.
- `script/generate_app_icon.sh`: optional icon regeneration; requires ImageMagick.

## Disk discovery

The app runs:

```text
diskutil list -plist external physical
diskutil info -plist /dev/diskN
```

A candidate is shown only when it is a whole disk, external, removable, and writable. The UI stores the identifier, exact byte size, name, and bus protocol.

## Destructive write boundary

The app never receives an administrator password. It asks macOS Authorization Services to present the system-owned authentication UI; the available password, Touch ID, or Apple Watch mechanism is selected by macOS policy.

1. The user selects an ISO or IMG file and a detected target.
2. The app rediscovers the disk and requires an exact model match.
3. A critical confirmation identifies the exact disk and image.
4. The app requests the `system.privilege.admin` right through macOS Authorization Services.
5. After authorization, a fixed `/bin/zsh` task independently rechecks the image size and the disk's whole/external/removable/writable state and exact capacity.
6. Only then does it unmount the disk, write to `/dev/rdiskN`, sync, and eject.
7. The task's stdout and stderr stream through the Authorization Services communications pipe into the in-app **制作日志** view.

This separation keeps credentials in a system-controlled environment and limits the GUI to orchestration and monitoring. The current certificate-free build uses the legacy Authorization Services execution bridge because an unauthenticated persistent root helper would be unsafe. The intended distribution architecture is a Developer ID-signed `SMAppService` helper with authenticated XPC once signing credentials are available.

## Compatibility

The deployment target is macOS 13 or newer. The app accepts `.iso` and `.img` files, but bootability depends on the selected image supporting raw USB media and the target computer's firmware.
