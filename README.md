# IOSJB

IOSJB is an on-device research harness for **CVE-2026-112514**, a socket-buffer
use-after-free in XNU that Apple fixed in iOS 27.2.

> This is not a complete jailbreak. The current project can exercise the race
> and detect a stale write into a reallocated socket. It does not yet convert
> the bug into controlled kernel read/write, bypass SPTM/TXM/PAC, or install a
> bootstrap.

## What is implemented

- A SwiftUI app that runs on iOS 16 and later.
- A low-CPU precision race using persistent sender threads and a condition
  variable gate.
- A peer-delivery oracle: spray sockets are freshly connected and never send.
  Bytes arriving at their peers therefore come from a stale sender.
- An explicit, separate zone-reclaim probe for studying 832-byte socket
  replacement with out-of-line Mach messages.
- A stop control and periodic rate limiting to reduce watchdog pressure.
- GitHub Actions compilation into an unsigned IPA artifact.

## Target

| Item | Value |
|---|---|
| Primary target | iPhone 14 Pro Max (`iPhone15,3`, A16) |
| Vulnerable iOS | 27.0 and 27.0.1 |
| Patched iOS | 27.2 and later |
| Entitlements | None beyond normal sideloading |
| Kernel access | Not implemented |

The public hardware evidence for this race comes from another arm64e device.
The A16 path must be measured independently. Use only a device you own.

## Build

GitHub Actions builds the app on every push to `main` and through manual
dispatch:

```text
Actions -> Build unsigned IPA -> Artifacts -> IOSJB-unsigned
```

Local build on a Mac with full Xcode:

```sh
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
```

Outputs:

```text
dist/IOSJB-unsigned.ipa
dist/IOSJB-unsigned.ipa.sha256
```

The CI IPA is intentionally unsigned. Sign it with your normal sideloading
tool, or open the source in Xcode with your own team.

The C race harness also has a host smoke test:

```sh
mkdir -p build
xcrun --sdk macosx clang -O2 -Wall -Wextra -Werror \
  Tests/host_smoke.c Sources/SocketUAF.c -o build/host-smoke
./build/host-smoke
```

## Usage

1. Install the signed app on the target iPhone.
2. Confirm the device is on iOS 27.0 or 27.0.1.
3. Keep the app in the foreground.
4. Start with **Precision UAF oracle** and the default parameters.
5. Watch for:

```text
STALE WRITE CONFIRMED
```

The app may cause a kernel panic or reboot if the race corrupts active kernel
state. Save work before running it.

## Modes

### Precision UAF oracle

Runs the close-versus-send race and checks whether bytes from a stale sender
arrive at a socket that never sent. A hit proves a stale kernel write, not
controlled kernel read/write.

### Zone reclaim probe

Allocates and frees socket objects, sprays 832-byte out-of-line Mach messages,
then inspects fresh sockets for the spray marker. This is an exploratory
allocator test and does not itself trigger the race.

## Current limitations

- No public proof that the same race reaches a controlled primitive on A16.
- No KASLR or heap-address leak.
- No stable replacement of a freed `struct socket` with attacker-shaped data.
- No SPTM/TXM/PAC bypass.
- No rootless bootstrap, launchd hook, or tweak injection.

## Research notes

See [docs/CVE-2026-112514.md](docs/CVE-2026-112514.md) for the vulnerability
model, evidence boundary, and next experiments. Sources are listed in
[docs/SOURCES.md](docs/SOURCES.md).

## License

MIT. See [LICENSE](LICENSE).

