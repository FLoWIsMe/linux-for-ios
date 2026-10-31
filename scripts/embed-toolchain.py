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
