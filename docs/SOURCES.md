# Sources and attribution

## Primary vulnerability record

- Apple Security Releases: iOS 27.2 and iPadOS 27.2
  - https://support.apple.com/en-us/149230
  - CVE-2026-112514 is listed under Kernel with the impact "corrupt kernel
    memory" and a use-after-free description.

## Public research reviewed

- Tims Cooked — iOS 27 socket UAF research
  - https://github.com/ramonburf/Tims-Cooked
  - Includes the public stale-write evidence, race-harness notes, and the open
    allocator/RW problem.
- Tims Cooked — stale-write hardware record
  - https://github.com/ramonburf/Tims-Cooked/blob/main/analysis/socket-uaf-stale-write-2026-11-13.md
- Tims Cooked — jailbreak path assessment
  - https://github.com/ramonburf/Tims-Cooked/blob/main/JAILBREAK-PATHS.md

## Boundary

IOSJB implements an independent oracle and allocator probe. It does not copy
the public project's private build material or device identifiers.

The public sources establish a stale kernel write. They do not establish
controlled kernel read/write, SPTM/TXM/PAC bypass, or a complete jailbreak.

