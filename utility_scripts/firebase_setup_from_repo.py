#!/usr/bin/env python3
"""One-stop Firebase setup for repo-hosted puzzles (bundle-first).

What this script does:
1) Discovers puzzle variant folders from repo structure (e.g. cat_10, cat_100, cat_1000)
2) Groups variants by base puzzle id (e.g. cat)
3) Builds ZIP bundle per size variant
4) Uploads thumb + bundles to Cloud Storage (with --apply)
5) Upserts one Firestore puzzle doc per base puzzle (with --apply)
6) Ensures required Firestore composite index (with --apply unless --skip-index)
7) Optionally prunes old Cloud Storage versions per puzzle (with --prune-storage-old-versions)

Default mode is --dry-run and performs NO Firebase writes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

REPO_PUZZLES_ROOT = Path("assets/puzzles/jigsawpuzzleimages")
DEFAULT_BUNDLE_OUTPUT = Path(".tmp/firebase_bundles")
DEFAULT_STORAGE_PREFIX = "puzzles"
EXPECTED_SIZES = {10, 100, 500}
DATASTORE_SCOPE = "https://www.googleapis.com/auth/datastore"


@dataclass
class FileEntry:
    local_path: Path
    relative_path: str


@dataclass
class PuzzleVariant:
    size: int
    variant_dir: Path
    files: list[FileEntry]


@dataclass
class PuzzleBase:
    base_id: str
    thumb_file: Path
    variants: dict[int, PuzzleVariant]


@dataclass
class BundleArtifact:
    size: int
    zip_local_path: Path
    zip_storage_path: str
    bytes: int
    sha256: str
    included_files: list[str]


def parse_godot_firebase_env(env_path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith(";") or line.startswith("["):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip().strip('"').strip("'")] = value.strip().strip('"').strip("'")
    return data


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def find_thumb(root: Path, base_id: str) -> Path | None:
    candidates = [
        root / f"{base_id}.jpg",
        root / f"{base_id}.jpeg",
        root / f"{base_id}.png",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def build_variant_file_list(variant_dir: Path, thumb_file: Path) -> list[FileEntry]:
    adjacent = variant_dir / "adjacent.json"
    pieces_json = variant_dir / "pieces" / "pieces.json"
    raster_dir = variant_dir / "pieces" / "raster"

    if not adjacent.exists():
        raise FileNotFoundError(f"Missing adjacent.json: {adjacent}")
    if not pieces_json.exists():
        raise FileNotFoundError(f"Missing pieces/pieces.json: {pieces_json}")
    if not raster_dir.exists():
        raise FileNotFoundError(f"Missing pieces/raster: {raster_dir}")

    raster_files = sorted(raster_dir.glob("*.png"))
    if not raster_files:
        raise FileNotFoundError(f"No raster png files in {raster_dir}")

    entries: list[FileEntry] = [
        FileEntry(adjacent, "adjacent.json"),
        FileEntry(pieces_json, "pieces/pieces.json"),
    ]

    for rf in raster_files:
        entries.append(FileEntry(rf, f"pieces/raster/{rf.name}"))

    # Optional reference image files for convenience.
    optional_files = [
        (variant_dir / "reference.jpg", "reference.jpg"),
        (variant_dir / "images" / "full.jpg", "images/full.jpg"),
    ]
    for local_path, rel_path in optional_files:
        if local_path.exists():
            entries.append(FileEntry(local_path, rel_path))

    # Always include a thumb fallback inside bundle root.
    entries.append(FileEntry(thumb_file, "thumb.jpg"))
    return entries


def discover_puzzle_bases(root: Path, fail_on_missing_size: bool) -> list[PuzzleBase]:
    if not root.exists():
        raise FileNotFoundError(f"Puzzle root does not exist: {root}")

    grouped: dict[str, dict[int, Path]] = {}
    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue
        m = re.match(r"^(.+)_([0-9]+)$", child.name)
        if not m:
            continue
        base_id = m.group(1)
        size = int(m.group(2))
        grouped.setdefault(base_id, {})[size] = child

    bases: list[PuzzleBase] = []
    for base_id in sorted(grouped.keys()):
        thumb = find_thumb(root, base_id)
        if thumb is None:
            print(f"SKIP {base_id}: missing thumb {base_id}.jpg/.jpeg/.png")
            continue

        variant_map: dict[int, PuzzleVariant] = {}
        for size, variant_dir in sorted(grouped[base_id].items()):
            files = build_variant_file_list(variant_dir, thumb)
            variant_map[size] = PuzzleVariant(size=size, variant_dir=variant_dir, files=files)

        if fail_on_missing_size:
            missing = sorted(EXPECTED_SIZES - set(variant_map.keys()))
            if missing:
                raise ValueError(f"{base_id}: missing expected sizes {missing}")

        bases.append(PuzzleBase(base_id=base_id, thumb_file=thumb, variants=variant_map))

    return bases


def build_bundle_for_variant(
    base: PuzzleBase,
    variant: PuzzleVariant,
    *,
    output_root: Path,
    asset_version: int,
    storage_prefix: str,
) -> BundleArtifact:
    out_dir = output_root / base.base_id / f"v{asset_version}"
    out_dir.mkdir(parents=True, exist_ok=True)

    zip_local = out_dir / f"{variant.size}.zip"
    with zipfile.ZipFile(zip_local, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for entry in variant.files:
            zf.write(entry.local_path, entry.relative_path)

    storage_path = f"{storage_prefix}/{base.base_id}/v{asset_version}/bundle/{variant.size}.zip"
    return BundleArtifact(
        size=variant.size,
        zip_local_path=zip_local,
        zip_storage_path=storage_path,
        bytes=zip_local.stat().st_size,
        sha256=sha256_file(zip_local),
        included_files=[e.relative_path for e in variant.files],
    )


def infer_difficulty(max_size: int) -> str:
    if max_size >= 1000:
        return "hard"
    if max_size >= 500:
        return "medium"
    return "easy"


def firestore_payload(
    base: PuzzleBase,
    *,
    asset_version: int,
    enabled: bool,
    storage_prefix: str,
    bundles: Iterable[BundleArtifact],
) -> dict:
    bundle_list = sorted(bundles, key=lambda b: b.size)
    size_options = [b.size for b in bundle_list]
    bundle_paths = {str(b.size): b.zip_storage_path for b in bundle_list}
    bundle_bytes = {str(b.size): b.bytes for b in bundle_list}
    bundle_sha256 = {str(b.size): b.sha256 for b in bundle_list}

    max_size = max(size_options) if size_options else 0
    title = f"{base.base_id.title()}"

    return {
        "id": base.base_id,
        "base_name": base.base_id,
        "title": title,
        "enabled": enabled,
        "asset_version": asset_version,
        "updated_at": "SERVER_TIMESTAMP",
        "published_at_iso": datetime.now(timezone.utc).isoformat(),
        "thumb_path": f"{storage_prefix}/{base.base_id}/v{asset_version}/thumb.jpg",
        "size_options": size_options,
        "difficulty": infer_difficulty(max_size),
        "approx_pieces": max_size,
        "bundle_paths": bundle_paths,
        "bundle_bytes": bundle_bytes,
        "bundle_sha256": bundle_sha256,
    }


def upload_blob(bucket, src: Path, dst: str) -> None:
    blob = bucket.blob(dst)
    blob.upload_from_filename(str(src))


def prune_old_storage_versions(bucket, storage_prefix: str, base_id: str, keep_version: int) -> int:
    """Delete blobs for older puzzle versions under puzzles/<base_id>/v*/... ."""
    prefix = f"{storage_prefix}/{base_id}/"
    keep_segment = f"/v{keep_version}/"
    deleted = 0
    for blob in bucket.list_blobs(prefix=prefix):
        name = str(blob.name)
        if keep_segment in name:
            continue
        match = re.search(r"/v(\d+)/", name)
        if not match:
            continue
        blob.delete()
        deleted += 1
    return deleted


def upsert_firestore_doc(db, base_id: str, payload: dict) -> None:
    write_payload = dict(payload)
    write_payload["updated_at"] = _firestore().SERVER_TIMESTAMP
    db.collection("puzzles").document(base_id).set(write_payload, merge=True)


def load_project_id(service_account_path: Path) -> str:
    data = json.loads(service_account_path.read_text(encoding="utf-8"))
    return str(data.get("project_id", "")).strip()


def build_auth_token(service_account_path: Path) -> str:
    from firebase_admin import credentials
    from google.auth.transport.requests import Request

    cred_obj = credentials.Certificate(str(service_account_path)).get_credential()
    if hasattr(cred_obj, "with_scopes"):
        cred_obj = cred_obj.with_scopes([DATASTORE_SCOPE])
    cred_obj.refresh(Request())
    token = getattr(cred_obj, "token", None)
    if not token:
        raise RuntimeError("Unable to mint access token from service account.")
    return token


def ensure_puzzles_index(project_id: str, token: str) -> tuple[int, str]:
    url = (
        "https://firestore.googleapis.com/v1/"
        f"projects/{project_id}/databases/(default)/collectionGroups/puzzles/indexes"
    )
    payload = {
        "queryScope": "COLLECTION",
        "fields": [
            {"fieldPath": "enabled", "order": "ASCENDING"},
            {"fieldPath": "updated_at", "order": "DESCENDING"},
            {"fieldPath": "__name__", "order": "DESCENDING"},
        ],
    }

    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), method="POST")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.status, response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        return exc.code, body


def _firebase_admin():
    import firebase_admin

    return firebase_admin


def _credentials():
    from firebase_admin import credentials

    return credentials


def _firestore():
    from firebase_admin import firestore

    return firestore


def _storage():
    from firebase_admin import storage

    return storage


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="One-stop Firebase setup from repo puzzle directories")
    p.add_argument("--firebase-env", default="addons/godot-firebase/firebase.env")
    p.add_argument("--service-account", help="Required with --apply")
    p.add_argument("--source-root", default=str(REPO_PUZZLES_ROOT))
    p.add_argument("--asset-version", type=int, default=1)
    p.add_argument("--storage-prefix", default=DEFAULT_STORAGE_PREFIX)
    p.add_argument("--bundle-output-dir", default=str(DEFAULT_BUNDLE_OUTPUT))
    p.add_argument("--only", nargs="*", help="Only publish these base puzzle ids (e.g. cat dog bunny)")
    p.add_argument("--disable", action="store_true", help="Write docs with enabled=false")
    p.add_argument("--skip-index", action="store_true", help="Skip ensuring Firestore index")
    p.add_argument("--index-only", action="store_true", help="Only ensure Firestore index and exit")
    p.add_argument("--fail-on-missing-size", action="store_true", help="Fail when a base puzzle is missing expected sizes (10,100,500)")
    p.add_argument(
        "--prune-storage-old-versions",
        action="store_true",
        help="Delete older Storage versions (v*) per published base id, keeping only --asset-version",
    )
    p.add_argument("--apply", action="store_true", help="Actually upload/write Firebase (default is dry-run)")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    env_path = Path(args.firebase_env)
    if not env_path.exists():
        raise FileNotFoundError(f"firebase.env not found: {env_path}")
    env_data = parse_godot_firebase_env(env_path)
    env_project_id = env_data.get("projectId", "").strip()
    bucket_name = env_data.get("storageBucket", "").strip()

    service_account_path: Path | None = None
    service_project_id = ""
    if args.service_account:
        service_account_path = Path(args.service_account)
        if not service_account_path.exists():
            raise FileNotFoundError(f"Service account file not found: {service_account_path}")
        service_project_id = load_project_id(service_account_path)

    project_id = env_project_id or service_project_id

    print(f"projectId: {project_id}")
    print(f"bucket: {bucket_name}")
    print("mode:", "APPLY" if args.apply else "DRY-RUN")
    if args.prune_storage_old_versions:
        print("prune_storage_old_versions: enabled")

    if args.index_only:
        if args.skip_index:
            print("index-only requested, but --skip-index was set. Nothing to do.")
            return 0
        if not args.apply:
            print("dry-run: would ensure Firestore composite index for puzzles(enabled, updated_at desc)")
            return 0
        if service_account_path is None:
            raise ValueError("--service-account is required with --apply")
        if not project_id:
            raise ValueError("projectId missing from firebase.env and service account")
        token = build_auth_token(service_account_path)
        status, body = ensure_puzzles_index(project_id, token)
        print(f"index ensure status={status}")
        print(body)
        if status in (200, 201) or (status == 409 and "ALREADY_EXISTS" in body):
            return 0
        return 1

    root = Path(args.source_root)
    bases = discover_puzzle_bases(root, fail_on_missing_size=args.fail_on_missing_size)
    if args.only:
        only = set(args.only)
        bases = [b for b in bases if b.base_id in only]

    if not bases:
        print("No base puzzles found to process.")
        return 0

    enabled = not args.disable
    output_root = Path(args.bundle_output_dir)

    db = None
    bucket = None
    if args.apply:
        if service_account_path is None:
            raise ValueError("--service-account is required with --apply")
        if not bucket_name:
            raise ValueError("storageBucket missing from firebase.env")

        firebase_admin = _firebase_admin()
        cred = _credentials().Certificate(str(service_account_path))
        firebase_admin.initialize_app(cred, {"storageBucket": bucket_name})
        db = _firestore().client()
        bucket = _storage().bucket()

        if not args.skip_index:
            if not project_id:
                raise ValueError("projectId missing from firebase.env and service account")
            token = build_auth_token(service_account_path)
            status, body = ensure_puzzles_index(project_id, token)
            print(f"index ensure status={status}")
            if status not in (200, 201) and not (status == 409 and "ALREADY_EXISTS" in body):
                print(body)
                return 1

    print(f"base puzzles found: {len(bases)}")
    failures: list[str] = []

    for base in bases:
        print(f"\n[{base.base_id}] sizes={sorted(base.variants.keys())}")
        print(f"  thumb: {base.thumb_file}")

        bundle_artifacts: list[BundleArtifact] = []
        for size in sorted(base.variants.keys()):
            artifact = build_bundle_for_variant(
                base,
                base.variants[size],
                output_root=output_root,
                asset_version=args.asset_version,
                storage_prefix=args.storage_prefix,
            )
            bundle_artifacts.append(artifact)
            print(
                f"  bundle size={size} local={artifact.zip_local_path} "
                f"bytes={artifact.bytes} sha256={artifact.sha256[:12]}... "
                f"storage={artifact.zip_storage_path}"
            )
            print(f"    includes {len(artifact.included_files)} files")

        payload = firestore_payload(
            base,
            asset_version=args.asset_version,
            enabled=enabled,
            storage_prefix=args.storage_prefix,
            bundles=bundle_artifacts,
        )
        print("  firestore payload preview:")
        print("    " + json.dumps(payload, default=str))

        if not args.apply:
            if args.prune_storage_old_versions:
                print(
                    f"  dry-run: would prune Storage blobs under "
                    f"{args.storage_prefix}/{base.base_id}/ except /v{args.asset_version}/"
                )
            continue

        try:
            thumb_storage = f"{args.storage_prefix}/{base.base_id}/v{args.asset_version}/thumb.jpg"
            upload_blob(bucket, base.thumb_file, thumb_storage)
            for artifact in bundle_artifacts:
                upload_blob(bucket, artifact.zip_local_path, artifact.zip_storage_path)
            upsert_firestore_doc(db, base.base_id, payload)
            if args.prune_storage_old_versions:
                pruned = prune_old_storage_versions(
                    bucket,
                    storage_prefix=args.storage_prefix,
                    base_id=base.base_id,
                    keep_version=args.asset_version,
                )
                print(f"  pruned {pruned} old Storage blobs")
            print("  uploaded and upserted Firestore doc")
        except Exception as exc:  # noqa: BLE001
            msg = f"{base.base_id}: {exc}"
            failures.append(msg)
            print(f"  ERROR {msg}", file=sys.stderr)

    if failures:
        print("\nFailed puzzles:")
        for msg in failures:
            print(f"  - {msg}")
        return 1

    print("\nDone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
