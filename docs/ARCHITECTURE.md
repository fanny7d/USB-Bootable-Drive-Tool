# Architecture

USB Bootable Drive Tool is a small native AppKit application built directly with the macOS Swift toolchain. It intentionally avoids third-party runtime dependencies.

## Components

- `Sources/USBBootableDriveTool/main.swift`: application lifecycle, AppKit UI, disk discovery, safety checks, Terminal job generation, and progress monitoring.
- `Assets/`: sidebar illustration, source app icon, and packaged ICNS icon.
- `script/build_and_run.sh`: deterministic local build, bundle assembly, ad-hoc signing, launch, and diagnostics.
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

The GUI does not write raw devices directly and never receives an administrator password.

1. The user selects an ISO or IMG file and a detected target.
2. The app rediscovers the disk and requires an exact model match.
3. A critical confirmation identifies the exact disk and image.
4. A temporary, owner-executable shell script opens in Terminal.
5. The script independently rechecks whole/external/removable/writable state and exact capacity.
6. Only then does it unmount the disk, request `sudo`, write to `/dev/rdiskN`, sync, and eject.

This separation keeps the privilege prompt in a system-controlled environment and limits the GUI to orchestration and monitoring.

## Compatibility

The deployment target is macOS 13 or newer. The app accepts `.iso` and `.img` files, but bootability depends on the selected image supporting raw USB media and the target computer's firmware.
