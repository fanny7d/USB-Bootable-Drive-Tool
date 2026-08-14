# Testing

## Non-destructive validation

Run before every pull request:

```bash
./script/test.sh
```

This checks shell syntax, Swift compilation, app bundle assembly, Info.plist validity, code signature integrity, and the ICNS icon set. It does not unmount or write any disk.

For a real-window smoke test:

```bash
./script/build_and_run.sh --verify
```

Confirm that the expected external USB disk appears with the correct name, byte capacity, device identifier, and bus protocol. Do not click **Make Bootable Drive** during a non-destructive test.

## Destructive acceptance test

Only use a disposable physical USB drive with no important data.

1. Record `diskutil list external physical` and `diskutil info /dev/diskN` before launch.
2. Select a known-good hybrid ISO/IMG and the disposable target.
3. Confirm that the destructive alert names the same target.
4. Complete the macOS system authorization prompt and confirm that validation, `dd` progress, `sync`, and eject output remain inside the app.
5. Reinsert the media and verify its expected partition/image signature.
6. Boot-test it on compatible hardware.

A successful build or UI scan is not evidence that destructive writing or booting has passed.

## Release artifact validation

Build the Apple Silicon release artifacts with:

```bash
./script/package_dmg.sh
```

The command succeeds only after confirming that the executable is arm64, validating the app's ad-hoc signature, verifying the DMG structure, and writing a matching SHA-256 file under `dist/`. These packaging checks do not constitute Apple Developer ID signing or notarization.
