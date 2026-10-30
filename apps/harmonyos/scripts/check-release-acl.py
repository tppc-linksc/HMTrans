#!/usr/bin/env python3
"""Check the ACL permissions in the market APP against its signing Profile."""

import io
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
APP = PROJECT / "build/outputs/default/harmonyos-default-signed.app"
PROFILE_CONFIG = PROJECT / "build-profile.json5"
REQUIRED_ACLS = {
    "ohos.permission.FILE_ACCESS_PERSIST",
    "ohos.permission.READ_LOCAL_DEVICE_NAME",
    "ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY",
}


def release_profile_path() -> Path:
    config = PROFILE_CONFIG.read_text()
    block = re.search(r'\{\s*"name"\s*:\s*"marketRelease"([\s\S]*?)\n\s*\}', config)
    if block is None:
        raise ValueError("marketRelease signing configuration not found")
    match = re.search(r'"profile"\s*:\s*"([^"]+)"', block.group(1))
    if match is None:
        raise ValueError("marketRelease Profile path not found")
    path = Path(match.group(1)).expanduser()
    return path if path.is_absolute() else PROJECT / path


def profile_acls(path: Path) -> set[str]:
    result = subprocess.run(
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
        capture_output=True,
        check=True,
    )
    profile = json.loads(result.stdout)
    if profile.get("type") != "release":
        raise ValueError("marketRelease Profile is not a release Profile")
    return set(profile.get("acls", {}).get("allowed-acls", []))


def package_permissions(path: Path) -> set[str]:
    with zipfile.ZipFile(path) as app:
        hap_names = [name for name in app.namelist() if name.endswith(".hap")]
        if not hap_names:
            raise ValueError("APP package contains no HAP")
        permissions: set[str] = set()
        for hap_name in hap_names:
            with zipfile.ZipFile(io.BytesIO(app.read(hap_name))) as hap:
                module = json.loads(hap.read("module.json"))["module"]
                permissions.update(item["name"] for item in module.get("requestPermissions", []))
        return permissions


def main() -> int:
    profile = profile_acls(release_profile_path())
    package = package_permissions(APP)
    declared = package & REQUIRED_ACLS
    missing_from_package = REQUIRED_ACLS - declared
    missing_from_profile = declared - profile
    extra_in_profile = profile - declared
    print("Package ACLs:", ", ".join(sorted(declared)) or "none")
    print("Profile ACLs:", ", ".join(sorted(profile)) or "none")
    for label, values in (
        ("Missing from package", missing_from_package),
        ("Missing from Profile", missing_from_profile),
        ("Extra in Profile", extra_in_profile),
    ):
        if values:
            print(f"{label}: {', '.join(sorted(values))}", file=sys.stderr)
    if missing_from_package or missing_from_profile or extra_in_profile:
        return 1
    print("Release ACL permissions match.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"Unable to check release ACL permissions: {error}", file=sys.stderr)
        sys.exit(2)
