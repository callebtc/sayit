#!/usr/bin/env python3
"""Regression checks using the saved layout from a mounted test DMG."""
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

from ds_store import DSStore
from mac_alias import Alias

spec = importlib.util.spec_from_file_location("dmg_layout", Path(__file__).with_name("dmg-layout.py"))
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
source = Path(sys.argv.pop(1))


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Say It.app").mkdir()
        (self.root / "Applications").symlink_to("/Applications")
        shutil.copytree(source / ".background", self.root / ".background")
        shutil.copyfile(source / ".DS_Store", self.root / ".DS_Store")

    def test_valid_layout(self):
        layout.validate_layout(self.root)

    def test_missing_saved_layout(self):
        (self.root / ".DS_Store").unlink()
        with self.assertRaisesRegex(ValueError, "layout.*missing"):
            layout.validate_layout(self.root)

    def test_wrong_icon_position(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            store["Applications"]["Iloc"] = (0, 0)
        with self.assertRaisesRegex(ValueError, "icon position"):
            layout.validate_layout(self.root)

    def test_background_not_selected(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            icons = store["."]["icvp"]
            icons["backgroundType"] = 0
            store["."]["icvp"] = icons
        with self.assertRaisesRegex(ValueError, "Picture background"):
            layout.validate_layout(self.root)

    def test_missing_background_color_component(self):
        for key in ("backgroundColorRed", "backgroundColorGreen", "backgroundColorBlue"):
            with self.subTest(key=key):
                with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
                    icons = store["."]["icvp"]
                    original = icons.pop(key)
                    store["."]["icvp"] = icons
                with self.assertRaisesRegex(ValueError, "Background color components"):
                    layout.validate_layout(self.root)
                with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
                    icons[key] = original
                    store["."]["icvp"] = icons

    def test_incorrect_background_alias(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            icons = store["."]["icvp"]
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            alias.target.posix_path = "/missing.png"
            icons["backgroundImageAlias"] = alias.to_bytes()
            store["."]["icvp"] = icons
        with self.assertRaisesRegex(ValueError, "bundled image"):
            layout.validate_layout(self.root)

    def test_temporary_path_in_alias(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as store:
            icons = store["."]["icvp"]
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            alias.volume.posix_path = "/tmp/installer-test"
            icons["backgroundImageAlias"] = alias.to_bytes()
            store["."]["icvp"] = icons
        with self.assertRaisesRegex(ValueError, "private or temporary"):
            layout.validate_layout(self.root)

    def test_incorrect_applications_link(self):
        (self.root / "Applications").unlink()
        (self.root / "Applications").symlink_to("/")
        with self.assertRaisesRegex(ValueError, "Applications shortcut"):
            layout.validate_layout(self.root)

    def test_changed_background(self):
        (self.root / layout.BACKGROUND).write_bytes(b"invalid image")
        with self.assertRaisesRegex(ValueError, "background differs"):
            layout.validate_layout(self.root)


unittest.main()
