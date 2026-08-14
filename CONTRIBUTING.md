# Contributing

Thank you for helping improve USB Bootable Drive Tool.

## Before you start

- Search existing issues before opening a new one.
- Use a disposable USB drive for any destructive test.
- Never test against an internal disk, a production disk, or media containing important data.
- Do not include passwords, private paths, serial numbers, or other sensitive data in issues and logs.

## Development workflow

1. Fork the repository and create a focused branch.
2. Make the smallest change that solves the issue.
3. Run the full non-destructive validation suite:

   ```bash
   ./script/test.sh
   ```

4. If the change affects UI behavior, launch the app and verify the real window:

   ```bash
   ./script/build_and_run.sh --verify
   ```

5. Update documentation and `CHANGELOG.md` when behavior changes.
6. Open a pull request describing the problem, solution, safety impact, and validation performed.

## Safety invariants

Changes must preserve all of these checks:

- Target is a whole physical disk.
- Target is external, removable, and writable.
- Device identifier and exact capacity are revalidated immediately before writing.
- The GUI never reads or stores the administrator password.
- A destructive confirmation names the exact target disk.
- Writing uses the raw device and finishes with `sync` and `diskutil eject`.

See [Architecture](docs/ARCHITECTURE.md) and [Testing](docs/TESTING.md) for details.
