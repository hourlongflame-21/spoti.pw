import hashlib
import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("inject_translation", ROOT / "inject_translation.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def macho(kind=2, first=1024, encrypted=False):
    section = bytearray(80)
    struct.pack_into("<I", section, 48, first)
    segment = bytearray(72)
    struct.pack_into("<II", segment, 0, 0x19, 152)
    struct.pack_into("<I", segment, 64, 1)
    commands = bytes(segment) + bytes(section)
    if encrypted:
        commands += struct.pack("<IIIIII", 0x2c, 24, 0, 0, 1, 0)
    header = struct.pack("<IiiIIIII", 0xfeedfacf, mod.ARM64, 0, kind, 1 + int(encrypted), len(commands), 0, 0)
    payload = header + commands
    return payload + bytes(max(0, first - len(payload))) + b"payload"

class InjectionTests(unittest.TestCase):
    def test_idempotent_and_payload_untouched(self):
        original = macho()
        changed, added = mod.add_load_command(original)
        self.assertTrue(added)
        self.assertEqual(changed[1024:], original[1024:])
        second, added = mod.add_load_command(changed)
        self.assertFalse(added)
        self.assertEqual(changed, second)

    def test_reject_encrypted(self):
        with self.assertRaisesRegex(ValueError, "encrypted"):
            mod.add_load_command(macho(encrypted=True))

    def test_reject_no_padding(self):
        with self.assertRaisesRegex(ValueError, "No room"):
            mod.add_load_command(macho(first=184))

    def test_reject_nonzero_padding(self):
        data = bytearray(macho())
        data[185] = 1
        with self.assertRaisesRegex(ValueError, "not empty"):
            mod.add_load_command(bytes(data))

    def test_reject_truncated_command(self):
        data = bytearray(macho())
        struct.pack_into("<I", data, 36, 4096)
        with self.assertRaisesRegex(ValueError, "size"):
            mod.add_load_command(bytes(data))

    def make_ipa(self, path):
        app = "Payload/Spotify.app/"
        info = {"CFBundleExecutable": "Spotify", "CFBundleShortVersionString": "9.1.78"}
        with zipfile.ZipFile(path, "w") as z:
            z.writestr(app + "Info.plist", plistlib.dumps(info))
            z.writestr(app + "Spotify", macho())
            z.writestr(app + "Frameworks/spotifyglass.dylib", b"original-sing-core")
            z.writestr(app + "resource.bin", b"keep-me")
            z.writestr(app + "_CodeSignature/CodeResources", b"old-signature")
            z.writestr(app + "PlugIns/Widget.appex/resource", b"keep-widget")

    def test_wrong_ipa_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as tmp:
            ipa = Path(tmp) / "input.ipa"
            self.make_ipa(ipa)
            with zipfile.ZipFile(ipa) as z:
                with self.assertRaisesRegex(ValueError, "does not match"):
                    mod.ipa_details(z)

    def test_roundtrip_preserves_core_resources_and_input(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as tmp:
            root = Path(tmp)
            ipa, dylib, output = root / "input.ipa", root / "addon.dylib", root / "out.ipa"
            self.make_ipa(ipa)
            before = ipa.read_bytes()
            dylib.write_bytes(macho(kind=6))
            expected = mod.EXPECTED_CORE_SHA256
            try:
                mod.EXPECTED_CORE_SHA256 = hashlib.sha256(b"original-sing-core").hexdigest()
                result = mod.inject(ipa, dylib, output)
                self.assertTrue(result["original_core_preserved"])
                self.assertEqual(ipa.read_bytes(), before)
                with zipfile.ZipFile(output) as z:
                    app = "Payload/Spotify.app/"
                    self.assertEqual(z.read(app + "resource.bin"), b"keep-me")
                    self.assertEqual(z.read(app + "Frameworks/spotifyglass.dylib"), b"original-sing-core")
                    self.assertEqual(z.read(app + "PlugIns/Widget.appex/resource"), b"keep-widget")
                    self.assertNotIn(app + "_CodeSignature/CodeResources", z.namelist())
                    self.assertEqual(z.read(app + "Frameworks/SGJapaneseLyrics.dylib"), dylib.read_bytes())
                with self.assertRaisesRegex(ValueError, "already exists"):
                    mod.inject(ipa, dylib, output)
            finally:
                mod.EXPECTED_CORE_SHA256 = expected

if __name__ == "__main__":
    unittest.main()
