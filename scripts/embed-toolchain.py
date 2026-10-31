#!/usr/bin/env python3
"""Embed the prebuilt command frameworks into Tern.app during an Xcode build.

Xcode runs this as the "Embed Toolchain" build phase of the Tern target (see project.yml).
It reads Toolchain/frameworks/*.xcframework (downloaded by scripts/fetch-toolchain.sh),
picks the slice that matches the platform and architectures being built, copies the
framework into Tern.app/Frameworks, strips headers, and code signs it with the same identity
Xcode uses for the app.

The ios_system framework itself is linked and embedded by Xcode (project.yml references the
xcframework directly); everything handled here is loaded by ios_system at runtime with dlopen,
so it only needs to be present in the app bundle, not linked.

Some upstream xcframeworks (vim, lg2, dash, jq, xxd) ship an x86_64 Simulator slice but no
arm64 Simulator slice. On an Apple silicon Mac those commands are skipped for Simulator builds
and a warning is printed. Device builds always contain the full toolchain. The list of what
was embedded is written to Tern.app/toolchain.json so the app can explain missing commands.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def warn(message: str) -> None:
    # Xcode surfaces lines in this format in the issue navigator.
    print(f"warning: {message}", flush=True)


def fail(message: str) -> None:
    print(f"error: {message}", flush=True)
    sys.exit(1)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    frameworks_src = root / "Toolchain" / "frameworks"
    local_src = root / "Toolchain" / "local"
    manifest = root / "Toolchain" / "manifest.tsv"

    target_build_dir = env("TARGET_BUILD_DIR")
    frameworks_folder = env("FRAMEWORKS_FOLDER_PATH")
    resources_folder = env("UNLOCALIZED_RESOURCES_FOLDER_PATH")
    platform_name = env("PLATFORM_NAME", "iphoneos")
    archs = env("ARCHS").split() or ["arm64"]
    if not target_build_dir or not frameworks_folder:
        fail("embed-toolchain.py must run inside an Xcode build phase (TARGET_BUILD_DIR missing)")

    expected = []
    for line in manifest.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) >= 4 and fields[3] == "linked":
            continue  # linked by Xcode itself, see project.yml
        expected.append(fields[0])

    missing = [name for name in expected if not (frameworks_src / f"{name}.xcframework").is_dir()]
    if missing:
        if env("TERN_SKIP_TOOLCHAIN_FETCH") == "1":
            fail(f"toolchain frameworks missing ({', '.join(missing)}); run scripts/fetch-toolchain.sh")
        print(f"Toolchain incomplete ({len(missing)} missing), running fetch-toolchain.sh", flush=True)
        subprocess.run(["bash", str(root / "scripts" / "fetch-toolchain.sh")], check=True)

    variant = "simulator" if platform_name.endswith("simulator") else None
    dest_dir = Path(target_build_dir) / frameworks_folder
    dest_dir.mkdir(parents=True, exist_ok=True)

    sign_allowed = env("CODE_SIGNING_ALLOWED") == "YES"
    identity = env("EXPANDED_CODE_SIGN_IDENTITY")
    other_flags = env("OTHER_CODE_SIGN_FLAGS")

    embedded: list[str] = []
    skipped: dict[str, str] = {}

    for name in expected:
        # A locally built xcframework (scripts/build-vim.sh and friends) wins over the prebuilt one.
        xcf = local_src / f"{name}.xcframework"
        if not xcf.is_dir():
            xcf = frameworks_src / f"{name}.xcframework"
        info = plistlib.loads((xcf / "Info.plist").read_bytes())
        chosen = None
        for lib in info.get("AvailableLibraries", []):
            if lib.get("SupportedPlatform") != "ios":
                continue
            if lib.get("SupportedPlatformVariant") != variant:
                continue
            supported = set(lib.get("SupportedArchitectures", []))
            if not set(archs).issubset(supported):
                continue
            chosen = lib
            break
        if chosen is None:
            reason = f"no {platform_name} slice for {' '.join(archs)}"
            skipped[name] = reason
            warn(f"{name}.xcframework: {reason}; the command will be unavailable in this build")
            continue

        framework_src = xcf / chosen["LibraryIdentifier"] / chosen["LibraryPath"]
        framework_name = chosen["LibraryPath"]
        framework_dst = dest_dir / framework_name
        subprocess.run(
            [
                "rsync", "-a", "--delete",
                "--exclude", "Headers", "--exclude", "Modules", "--exclude", "PrivateHeaders",
                f"{framework_src}/", f"{framework_dst}/",
            ],
            check=True,
        )

        binary = framework_dst / framework_name.replace(".framework", "")
        thin_to_requested_archs(binary, archs, set(chosen.get("SupportedArchitectures", [])))
        if name in HOME_RELATIVE_FRAMEWORKS:
            retarget_home_paths(binary, name)
        strip_bitcode(binary)
        fix_minimum_os_version(framework_dst, binary)

        if sign_allowed and identity:
            cmd = ["codesign", "--force", "--sign", identity]
            if other_flags:
                cmd.extend(other_flags.split())
            cmd.extend(["--preserve-metadata=identifier,entitlements,flags", "--timestamp=none", str(framework_dst)])
            subprocess.run(cmd, check=True)
        embedded.append(framework_name.replace(".framework", ""))

    if resources_folder:
        resources_dir = Path(target_build_dir) / resources_folder
        resources_dir.mkdir(parents=True, exist_ok=True)
        copy_vim_runtime(root, local_src, resources_dir)
        summary = {
            "platform": platform_name,
            "architectures": archs,
            "embedded": sorted(embedded),
            "skipped": skipped,
        }
        (resources_dir / "toolchain.json").write_text(json.dumps(summary, indent=2, sort_keys=True))

    print(f"Embedded {len(embedded)} toolchain frameworks into {dest_dir}", flush=True)
    if skipped:
        print(f"Skipped: {', '.join(sorted(skipped))}", flush=True)


def copy_vim_runtime(root: Path, local_src: Path, resources_dir: Path) -> None:
    """Puts the Vim runtime that matches the embedded vim binary into Tern.app/vim."""
    candidates = [local_src / "vim-runtime" / "vim", root / "Toolchain" / "vimruntime" / "vim"]
    source = next((c for c in candidates if (c / "defaults.vim").is_file()), None)
    if source is None:
        warn("no Vim runtime found; run scripts/fetch-toolchain.sh (vim will start without syntax files)")
        return
    subprocess.run(["rsync", "-a", "--delete", f"{source}/", f"{resources_dir / 'vim'}/"], check=True)


# Frameworks from the a-Shell ecosystem keep user files in $HOME/Documents, because a-Shell's HOME
# is the sandbox root. Tern's HOME is the Documents folder itself (what the Files app shows), so
# ~/.ssh, ~/.vimrc and ~/.gitconfig mean what they mean everywhere else. The string constants in
# these binaries are rewritten accordingly: "~/Documents/.ssh" -> "~/.ssh", "$HOME/Documents/.vimrc"
# -> "$HOME/.vimrc", "Documents/.gitconfig" -> ".gitconfig". Every rewrite is shorter than the
# original and stays in place, NUL padded, so no offset in the binary moves. Only the string
# literal and read-only constant sections of the __TEXT segment are touched, and only runs of
# printable text in them. scripts/build-ssh.sh fixes the same paths in the OpenSSH sources; this
# step covers the prebuilt archives and is a no-op on binaries that are already right.
HOME_RELATIVE_FRAMEWORKS = {"ssh_cmd", "ssh_cmdA", "ssh_agent", "vim", "lg2"}

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
LC_SEGMENT_64 = 0x19
S_CSTRING_LITERALS = 0x2


def string_sections(data: bytes) -> list[tuple[int, int]]:
    """Returns (offset, size) of the __TEXT string and constant sections of a thin or fat Mach-O
    file: __cstring holds literals, __const holds constant arrays such as OpenSSH's default
    identity file list (NUL terminated strings referenced through pointers)."""
    import struct

    def thin(base: int) -> list[tuple[int, int]]:
        magic = struct.unpack_from("<I", data, base)[0]
        if magic != MH_MAGIC_64:
            return []
        ncmds = struct.unpack_from("<I", data, base + 16)[0]
        cursor = base + 32
        found = []
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, cursor)
            if cmd == LC_SEGMENT_64:
                segname = data[cursor + 8:cursor + 24].rstrip(b"\0")
                nsects = struct.unpack_from("<I", data, cursor + 64)[0]
                section = cursor + 72
                for _ in range(nsects):
                    sectname = data[section:section + 16].rstrip(b"\0")
                    size = struct.unpack_from("<Q", data, section + 40)[0]
                    offset, _align, _reloff, _nreloc, flags = struct.unpack_from("<IIIII", data, section + 48)
                    wanted = flags & 0xFF == S_CSTRING_LITERALS or (segname == b"__TEXT" and sectname == b"__const")
                    if wanted and size:
                        found.append((base + offset, size))
                    section += 80
            cursor += cmdsize
        return found

    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == FAT_MAGIC:
        count = struct.unpack_from(">I", data, 4)[0]
        sections = []
        for index in range(count):
            offset = struct.unpack_from(">I", data, 8 + index * 20 + 8)[0]
            sections.extend(thin(offset))
        return sections
    return thin(0)


def rewrite_path_constant(original: bytes, name: str) -> bytes:
    updated = original
    if b"Documents" in updated:
        updated = (
            updated.replace(b"~/Documents/", b"~/")
            .replace(b"~/Documents", b"~")
            .replace(b"$HOME/Documents/", b"$HOME/")
            .replace(b"Documents/", b"")
        )
    if name in {"ssh_cmd", "ssh_cmdA"} and updated == b"/usr/bin/ssh":
        # scp and sftp start ssh through ios_system, which resolves plain names through its
        # command table. The absolute path only works where /usr/bin/ssh does not exist as a
        # file; on the Simulator it is the Mac's own ssh and the lookup fails.
        updated = b"ssh"
    return updated


def retarget_home_paths(binary: Path, name: str) -> None:
    if not binary.is_file():
        return
    data = bytearray(binary.read_bytes())
    rewritten = []
    for offset, size in string_sections(bytes(data)):
        start = offset
        end = offset + size
        while start < end:
            stop = data.find(b"\0", start, end)
            if stop < 0:
                stop = end
            original = bytes(data[start:stop])
            if len(original) < 512 and all(0x20 <= byte < 0x7F or byte in b"\n\r\t" for byte in original):
                updated = rewrite_path_constant(original, name)
                if updated != original:
                    if len(updated) > len(original):
                        fail(f"{name}: rewritten path grew ({original!r} -> {updated!r})")
                    data[start:stop] = updated.ljust(len(original), b"\0")
                    rewritten.append((original, updated))
            start = stop + 1
    if not rewritten:
        return
    binary.write_bytes(bytes(data))
    for original, updated in rewritten:
        print(f"  {name}: {original.decode(errors='replace')!r} -> {updated.decode(errors='replace')!r}", flush=True)
    if b"Documents/." in bytes(data):
        fail(f"{name}: a Documents/. path survived outside the patched sections")
    if shutil.which("codesign"):
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=False, capture_output=True)


def strip_bitcode(binary: Path) -> None:
    """App Store Connect rejects binaries that still carry a bitcode segment; several upstream
    frameworks were built before Xcode stopped emitting it."""
    if not binary.is_file():
        return
    try:
        load = subprocess.run(["otool", "-l", str(binary)], check=True, capture_output=True, text=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return
    if "__LLVM" not in load:
        return
    subprocess.run(["xcrun", "bitcode_strip", "-r", str(binary), "-o", str(binary)], check=True)
    print(f"  {binary.name}: removed bitcode", flush=True)
    if shutil.which("codesign"):
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=False, capture_output=True)


def fix_minimum_os_version(framework: Path, binary: Path) -> None:
    """One upstream Info.plist ships MinimumOSVersion as the unexpanded template value
    "ios_version_min", which App Store Connect refuses. Replace anything that is not a version
    with the binary's own minimum OS, or 14.0 if that cannot be read."""
    info = framework / "Info.plist"
    if not info.is_file():
        return
    try:
        current = plistlib.loads(info.read_bytes()).get("MinimumOSVersion")
    except Exception:
        return
    if isinstance(current, str) and current.replace(".", "").isdigit():
        return
    version = "14.0"
    try:
        shown = subprocess.run(["vtool", "-show-build", str(binary)], check=True, capture_output=True, text=True).stdout
        for line in shown.splitlines():
            if line.strip().startswith("minos"):
                version = line.split()[-1]
                break
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    subprocess.run(["plutil", "-replace", "MinimumOSVersion", "-string", version, str(info)], check=True)
    print(f"  {framework.name}: MinimumOSVersion {current!r} -> {version}", flush=True)


def thin_to_requested_archs(binary: Path, archs: list[str], available: set[str]) -> None:
    """Remove architectures the current build does not need (keeps device IPAs lean)."""
    extra = available - set(archs)
    if not extra or not binary.is_file():
        return
    try:
        current = subprocess.run(["lipo", "-archs", str(binary)], check=True, capture_output=True, text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return
    present = set(current.stdout.split())
    to_remove = [arch for arch in present if arch not in archs]
    if not to_remove or len(to_remove) == len(present):
        return
    cmd = ["lipo", str(binary)]
    for arch in to_remove:
        cmd.extend(["-remove", arch])
    cmd.extend(["-output", str(binary)])
    subprocess.run(cmd, check=True)
    if shutil.which("codesign"):
        # The binary changed; a fresh ad-hoc signature keeps the bundle loadable until Xcode signs it.
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=False, capture_output=True)


if __name__ == "__main__":
    main()
