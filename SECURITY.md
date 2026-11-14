# Security and safe testing

IOSJB is a security research harness for a memory-safety bug.

- Test only on hardware you own and are willing to restart.
- Running the race may panic the kernel or reboot the device.
- Do not run it on a primary phone without a current backup.
- The app does not provide root, kernel read/write, or jailbreak persistence.
- iOS 27.2 and later are patched. The app warns and refuses to start there.
- Do not redistribute a signed build under somebody else's signing identity.

If this project is used in external research, preserve the evidence boundary:
a peer-delivery hit is a stale write into a reallocated socket, not proof of a
controlled arbitrary read or write primitive.

