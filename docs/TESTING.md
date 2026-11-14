# Device testing

## Preconditions

- iPhone 14 Pro Max or another arm64e device you own.
- iOS 27.0 or 27.0.1.
- Developer Mode enabled for sideloading.
- A current backup.

## Install

The CI artifact is unsigned. Sign it with your normal sideloading tool or
build from Xcode with your own team.

## First run

1. Open IOSJB in the foreground.
2. Confirm the status card says `CVE window: open`.
3. Run **Zone reclaim probe** once to confirm the app and allocator paths work.
4. Switch to **Precision UAF oracle**.
5. Use the defaults first.
6. Stop after a confirmed hit and record the log.

## Interpreting results

`STALE WRITE CONFIRMED` means the peer-delivery oracle observed data from a
sender whose socket was closed while the send was in flight.

It does not mean:

- arbitrary kernel read;
- arbitrary kernel write;
- root;
- code signing bypass;
- tweak injection;
- jailbreak.

If the device panics, capture the panic log before rebooting again.

