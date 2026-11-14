#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    plist_path = ROOT / "Resources" / "Info.plist"
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)

    require(plist["CFBundleExecutable"] == "IOSJB", "bad executable name")
    require(plist["CFBundleIdentifier"] == "com.wenlong.iosjb", "bad bundle id")
    require(plist["MinimumOSVersion"] == "16.0", "bad minimum iOS version")
    require(plist["CFBundleSupportedPlatforms"] == ["iPhoneOS"], "bad platform")
    require(plist["CFBundleShortVersionString"] == "0.1.1", "bad app version")
    require(plist["UIFileSharingEnabled"] is True, "file sharing missing")
    require(plist["LSSupportsOpeningDocumentsInPlace"] is True, "document sharing missing")

    header = (ROOT / "Sources" / "IOSJB-Bridging-Header.h").read_text()
    source = (ROOT / "Sources" / "SocketUAF.c").read_text()
    workflow = (ROOT / ".github" / "workflows" / "build.yml").read_text()

    require("iosjb_start" in header, "start bridge missing")
    require("run_oracle" in source, "oracle missing")
    require("STALE WRITE CONFIRMED" in source, "oracle result marker missing")
    require("IOSJB.log" in (ROOT / "Sources" / "ContentView.swift").read_text(),
            "persistent log missing")
    require("macos-latest" in workflow, "macOS runner missing")
    require((ROOT / "docs" / "SOURCES.md").is_file(), "sources missing")
    print("build inputs: PASS")


if __name__ == "__main__":
    main()

