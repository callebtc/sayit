#!/usr/bin/env python3
"""Write and validate the installer layout without relying on Finder to save it."""
import argparse
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias

BACKGROUND = ".background/dmg-background.png"
POSITIONS = {"Say It.app": (182, 210), "Applications": (542, 210)}
BOUNDS = "{{100, 100}, {720, 480}}"


def write_layout(root):
    alias = Alias.for_file(str(root / BACKGROUND))
    # The alias otherwise embeds the build machine's temporary mount path.
    # Keep the volume-relative target and canonical public volume location.
    alias.volume.posix_path = "/Volumes/Say It"
    with DSStore.open(str(root / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["icvl"] = ("type", b"icnv")
        store["."]["bwsp"] = {
            "WindowBounds": BOUNDS,
            "ShowStatusBar": False, "ShowToolbar": False,
            "ShowPathbar": False, "ShowSidebar": False,
            "ContainerShowSidebar": False, "ShowTabView": False,
            "PreviewPaneVisibility": False, "SidebarWidth": 0,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1, "backgroundType": 2,
            "backgroundImageAlias": alias.to_bytes(),
            "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
            "arrangeBy": "none", "showIconPreview": True,
            "showItemInfo": False, "labelOnBottom": True,
            "textSize": 14.0, "iconSize": 128.0,
            "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        }
        for name, position in POSITIONS.items():
            store[name]["Iloc"] = position


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_layout(root):
    require((root / "Say It.app").is_dir(), "App is missing")
    link = root / "Applications"
    require(link.is_symlink() and str(link.readlink()) == "/Applications",
            "Applications shortcut is missing or incorrect")
    expected = Path(__file__).parent / "Assets/dmg-background.png"
    require((root / BACKGROUND).read_bytes() == expected.read_bytes(),
            "Installer background differs from the source image")
    metadata = root / ".DS_Store"
    require(metadata.is_file(), "Saved Finder layout (.DS_Store) is missing")
    data = metadata.read_bytes()
    for prefix in ("/Users/", "/home/", "/private/tmp/", "/private/var/", "/tmp/"):
        require(all(prefix.encode(encoding) not in data
                    for encoding in ("utf-8", "utf-16-be", "utf-16-le")),
                "Saved layout contains a private or temporary path")
    with DSStore.open(str(metadata), "r") as store:
        require(store["."]["icvl"] == (b"type", b"icnv"), "Icon view is not selected")
        window = store["."]["bwsp"]
        require(window["WindowBounds"] == BOUNDS, "Installer window bounds are incorrect")
        for key in ("ShowStatusBar", "ShowToolbar", "ShowPathbar", "ShowSidebar"):
            require(window[key] is False, "Installer window chrome is incorrect")
        icons = store["."]["icvp"]
        require(icons["backgroundType"] == 2, "Picture background is not selected")
        require(icons["iconSize"] == 128 and icons["textSize"] == 14,
                "Installer icon or label size is incorrect")
        require(icons["arrangeBy"] == "none", "Automatic icon arrangement is enabled")
        alias = Alias.from_bytes(icons["backgroundImageAlias"])
        require(alias.target.posix_path.lstrip("/") == BACKGROUND,
                "Background alias does not reference the bundled image")
        require(alias.volume.name == "Say It" and alias.volume.posix_path == "/Volumes/Say It",
                "Background alias does not reference the public installer volume")
        for name, position in POSITIONS.items():
            require(store[name]["Iloc"] == position, "Installer icon position is incorrect")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("write", "validate"))
    parser.add_argument("mount", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "write":
            write_layout(args.mount.resolve())
        validate_layout(args.mount)
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f"DMG layout validation failed: {error}") from None
    print("DMG background, saved Finder layout, and Applications shortcut validated.")


if __name__ == "__main__":
    main()
