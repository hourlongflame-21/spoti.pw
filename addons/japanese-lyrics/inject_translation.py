#!/usr/bin/env python3
"""Add an independent translation dylib to the supplied IPA; keep its Sing dylib intact."""
import argparse
import hashlib
import json
import os
import plistlib
import struct
import tempfile
import zipfile
from pathlib import Path

EXPECTED_CORE_SHA256 = "7466149d100aea50b9bf00c0a9c0ddeaf6cfff91f866475e48b9d255ea579c27"
INSTALL_NAME = "@executable_path/Frameworks/SGJapaneseLyrics.dylib"
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19
LC_ENCRYPTION_INFO_64 = 0x2C
ARM64 = 0x100000C

def inspect_macho(data, filetype):
    if len(data) < 32:
        raise ValueError("Truncated Mach-O header.")
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from("<IiiIIIII", data)
    if magic != 0xFEEDFACF or cpu != ARM64 or kind != filetype:
        raise ValueError("Only thin arm64 Mach-O binaries of the expected file type are supported.")
    end = 32 + size
    if end > len(data):
        raise ValueError("Load commands extend past the file.")
    pos = 32
    first_content = len(data)
    loaded = []
    for _ in range(count):
        if pos + 8 > end:
            raise ValueError("Truncated load command.")
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8 or cmdsize % 8 or pos + cmdsize > end:
            raise ValueError("Invalid load-command size.")
        if cmd == LC_SEGMENT_64:
            if cmdsize < 72:
                raise ValueError("Truncated segment.")
            fileoff = struct.unpack_from("<Q", data, pos + 40)[0]
            if fileoff:
                first_content = min(first_content, fileoff)
            nsects = struct.unpack_from("<I", data, pos + 64)[0]
            if 72 + nsects * 80 > cmdsize:
                raise ValueError("Truncated sections.")
            for index in range(nsects):
                offset = struct.unpack_from("<I", data, pos + 72 + index * 80 + 48)[0]
                if offset:
                    first_content = min(first_content, offset)
        if cmd == LC_ENCRYPTION_INFO_64:
            if cmdsize < 24 or struct.unpack_from("<I", data, pos + 16)[0]:
                raise ValueError("The binary is encrypted or its encryption command is invalid.")
        if cmd in (0xC, 0x18, 0x80000018, 0x1F, 0x8000001F):
            if cmdsize < 24:
                raise ValueError("Truncated dylib command.")
            offset = struct.unpack_from("<I", data, pos + 8)[0]
            if not 24 <= offset < cmdsize:
                raise ValueError("Invalid dylib path.")
            raw = data[pos + offset:pos + cmdsize]
            if b"\0" not in raw:
                raise ValueError("Unterminated dylib path.")
            loaded.append(raw.split(b"\0", 1)[0].decode("utf-8", "strict"))
        pos += cmdsize
    if pos != end or first_content < end:
        raise ValueError("Inconsistent Mach-O layout.")
    return {"ncmds": count, "sizeofcmds": size, "end": end,
            "first_content": first_content, "loaded": loaded}

def add_load_command(data, name=INSTALL_NAME):
    info = inspect_macho(data, 2)
    if name in info["loaded"]:
        return data, False
    encoded = name.encode("utf-8") + b"\0"
    size = (24 + len(encoded) + 7) & ~7
    end = info["end"]
    if end + size > info["first_content"]:
        raise ValueError("No room for a new load command. No output was written.")
    if any(data[end:end + size]):
        raise ValueError("Header padding is not empty. No output was written.")
    command = struct.pack("<IIIIII", LC_LOAD_DYLIB, size, 24, 0, 0, 0) + encoded
    command += b"\0" * (size - len(command))
    output = bytearray(data)
    output[end:end + size] = command
    struct.pack_into("<II", output, 16, info["ncmds"] + 1, info["sizeofcmds"] + size)
    inspect_macho(output, 2)
    return bytes(output), True

def ipa_details(archive):
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise ValueError("Duplicate ZIP paths are not supported.")
    plists = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
    if len(plists) != 1:
        raise ValueError("Expected exactly one main app.")
    info = plistlib.loads(archive.read(plists[0]))
    executable = info.get("CFBundleExecutable")
    if not executable or "/" in executable or "\\" in executable:
        raise ValueError("Invalid executable name.")
    app = plists[0].rsplit("/", 1)[0] + "/"
    core_path = app + "Frameworks/spotifyglass.dylib"
    core = archive.read(core_path)
    digest = hashlib.sha256(core).hexdigest()
    if digest != EXPECTED_CORE_SHA256:
        raise ValueError("spotifyglass.dylib does not match the inspected Sing-enabled 0.23.0-beta IPA. Refusing to guess compatibility.")
    if info.get("CFBundleShortVersionString") != "9.1.78":
        raise ValueError("Expected Spotify 9.1.78.")
    main = archive.read(app + executable)
    parsed = inspect_macho(main, 2)
    patched, changed = add_load_command(main)
    return app, executable, core_path, core, patched, {
        "spotify_version": info["CFBundleShortVersionString"],
        "core_sha256": digest,
        "header_padding_bytes": parsed["first_content"] - parsed["end"],
        "new_load_command": changed,
    }

def inject(ipa, dylib, output):
    ipa, dylib, output = Path(ipa).resolve(), Path(dylib).resolve(), Path(output).resolve()
    if ipa == output or dylib == output:
        raise ValueError("Output must be different from the input files.")
    if output.exists():
        raise ValueError("Output already exists. Choose another name.")
    module = dylib.read_bytes()
    inspect_macho(module, 6)
    if len(module) > 10 * 1024 * 1024:
        raise ValueError("Unexpectedly large add-on.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ipa) as source:
        app, executable, core_path, core, patched, summary = ipa_details(source)
        addon_path = app + "Frameworks/SGJapaneseLyrics.dylib"
        fd, temporary = tempfile.mkstemp(prefix="jp-lyrics-", suffix=".ipa", dir=output.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as target:
                for entry in source.infolist():
                    if entry.filename == addon_path or entry.filename.startswith(app + "_CodeSignature/"):
                        continue
                    content = patched if entry.filename == app + executable else source.read(entry)
                    target.writestr(entry, content)
                item = zipfile.ZipInfo(addon_path)
                item.create_system = 3
                item.external_attr = (0o100755 << 16)
                item.compress_type = zipfile.ZIP_DEFLATED
                target.writestr(item, module)
            with zipfile.ZipFile(temporary) as check:
                if check.testzip() is not None:
                    raise ValueError("Output ZIP verification failed.")
                if check.read(core_path) != core:
                    raise ValueError("Original Sing-enabled core unexpectedly changed.")
                main_info = inspect_macho(check.read(app + executable), 2)
                if INSTALL_NAME not in main_info["loaded"] or check.read(addon_path) != module:
                    raise ValueError("Add-on installation verification failed.")
            os.replace(temporary, output)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    summary.update({"output": str(output), "addon_sha256": hashlib.sha256(module).hexdigest(),
                    "original_core_preserved": True, "requires_resigning": True})
    return summary

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--dylib")
    parser.add_argument("--output")
    parser.add_argument("--check", action="store_true", help="Verify the IPA and header space without changing it.")
    args = parser.parse_args()
    if args.check:
        with zipfile.ZipFile(args.ipa) as archive:
            summary = ipa_details(archive)[-1]
        summary["check_only"] = True
    else:
        if not args.dylib or not args.output:
            parser.error("--dylib and --output are required unless --check is used.")
        summary = inject(args.ipa, args.dylib, args.output)
    print(json.dumps(summary, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
