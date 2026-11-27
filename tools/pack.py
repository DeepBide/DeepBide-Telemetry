"""Verify canonical DeepBideTelemetry source and reproduce its stable mod ZIP.

Python 3.11+ standard library; creates only an explicitly requested new ZIP.
No game access, dependency installation, network, or publication.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import stat
import zipfile

SOURCE_PREFIX = "mod/DeepBideTelemetry/"
MOD_PREFIX = "bin/x64/plugins/cyber_engine_tweaks/mods/DeepBideTelemetry/"
RUNTIME_NAMES = ("init.lua", "config.example.json", "native_candidate_25.lua",
                 "native_equipment_25.lua", "native_stash_25.lua")
COMMON_NAMES = ("README.md", "LICENSE", "PROTOCOL.md", "THIRD_PARTY.md", "CHANGELOG.md")
SOURCE_EXTRAS = (".gitignore", ".gitattributes", "examples/receiver.py",
                 "examples/test_receiver.py", "tools/pack.py",
                 "examples/expanded_contract.py", "examples/expanded_reader.py", "examples/test_expanded_reader.py",
                 "examples/cet_follow.py", "examples/test_cet_follow.py")
MANIFEST = "release-manifest.json"


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def json_bytes(doc):
    return (json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def expected_names(source):
    prefix = SOURCE_PREFIX if source else MOD_PREFIX
    return set(COMMON_NAMES) | {prefix + n for n in RUNTIME_NAMES} | (set(SOURCE_EXTRAS) if source else set())


def canonical(raw):
    # Repack exact canonical bytes, rather than silently changing a source
    # whose reviewed hash was invalidated by checkout filters or edits.
    if raw.startswith(b"\xef\xbb\xbf") or b"\r" in raw:
        raise ValueError("NONCANONICAL_TEXT")
    raw.decode("utf-8")
    return raw


def manifest(files):
    if set(files) == expected_names(True):
        prefix = SOURCE_PREFIX
    elif set(files) == expected_names(False):
        prefix = MOD_PREFIX
    else:
        raise ValueError("PACKAGE_ALLOWLIST_MISMATCH")
    hashes = {n: sha(canonical(raw)) for n, raw in sorted(files.items())}
    runtime = {n: hashes[prefix+n] for n in RUNTIME_NAMES}
    return {"product": "DeepBide-Telemetry", "version": "1.1.0",
            "scope": "PUBLIC_STABLE_SCOPED", "license": "MIT",
            "license_scope": "ORIGINAL_DEEPBIDETELEMETRY_CODE_AND_DOCUMENTATION",
            "provenance_review": "SCOPED_SOURCE_HISTORY_REVIEW",
            "qualification": "V1_0_0_PHYSICAL_REUSED_CONTEXT_RENEWAL_AND_ROTATION_FOLLOW_OFFLINE_PASS_SCOPED",
            "physical_revision": "V1_0_0_2026_11_26_INIT_CHANGED_NATIVE_MODULES_IDENTICAL",
            "context_renewal_contract": {"version": "0.1", "config_key": "context_renewal_0_1",
                                         "default": False, "profile": "expanded",
                                         "nominal_poll_seconds": 0.5},
            "cet_follow_contract": {"version": "0.1", "opt_in": True,
                                    "distribution": "SOURCE_ARCHIVE_ONLY",
                                    "current_producer_attested": False},
            "frozen_lua": {n: h for n,h in runtime.items() if n.endswith(".lua")},
            "dependency_version": "DeepBide-RedSocket 0.5.2",
            "dependency_mod_sha256": "3ff795b8ab8e0e3d56912955349c07a47e7112e056be6128f22e8a15c4e4fbb3",
            "source_format": "UTF8_LF_CANONICAL_LUA", "zip_creator_system": 3,
            "runtime_tree_sha256": sha(json_bytes(runtime)), "files": hashes}


def archive(files):
    info = manifest(files)
    all_files = {**files, MANIFEST: json_bytes(info)}
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_STORED) as z:
        for name, raw in sorted(all_files.items()):
            entry = zipfile.ZipInfo(name, (2026, 11, 27, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            z.writestr(entry, raw)
    raw = out.getvalue()
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        if z.testzip() is not None or set(z.namelist()) != set(all_files) or any(
                z.read(n) != b for n, b in all_files.items()):
            raise ValueError("PACKAGE_READBACK")
    return raw, info


def regular(root, name):
    """Reject links/reparse points within the source tree and nonregular files."""
    path = root
    parts = name.split("/")
    for part in parts:
        path = path / part
        st = path.lstat()
        if stat.S_ISLNK(st.st_mode) or getattr(st, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
            raise ValueError("NONREGULAR_SOURCE")
    if not path.is_file():
        raise ValueError("NONREGULAR_SOURCE")
    return path.read_bytes()


def verified_source(root):
    root = Path(root)
    st = root.lstat()
    if not root.is_dir() or root.is_symlink() or getattr(st, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
        raise ValueError("NONREGULAR_SOURCE_ROOT")
    files = {n: canonical(regular(root, n)) for n in sorted(expected_names(True))}
    info = manifest(files)
    if canonical(regular(root, MANIFEST)) != json_bytes(info):
        raise ValueError("SOURCE_MANIFEST_MISMATCH")
    return files, info


def mod_from_source(root):
    files, source_info = verified_source(root)
    mod = {n: files[n] for n in COMMON_NAMES}
    mod.update({MOD_PREFIX+n: files[SOURCE_PREFIX+n] for n in RUNTIME_NAMES})
    raw, info = archive(mod)
    if info["runtime_tree_sha256"] != source_info["runtime_tree_sha256"]:
        raise ValueError("RUNTIME_TREE_MISMATCH")
    return raw, info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, help="new mod-layout release ZIP; omit for verification only")
    args = parser.parse_args()
    raw, info = mod_from_source(args.source)
    if args.output:
        if args.output.suffix.lower() != ".zip":
            parser.error("output must be a new ZIP")
        with args.output.open("xb") as f:
            f.write(raw)
        if args.output.read_bytes() != raw:
            raise ValueError("ZIP_DISK_READBACK")
    print(json.dumps({"status": "VERIFIED_RELEASE_SOURCE", "runtime_tree_sha256": info["runtime_tree_sha256"],
                      "mod_zip_sha256": sha(raw), "mod_zip_bytes": len(raw)}, sort_keys=True))


if __name__ == "__main__":
    main()
