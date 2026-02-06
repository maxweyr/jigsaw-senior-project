#!/usr/bin/env python3
"""Batch-publish local puzzle assets to Firebase Storage + Firestore.

Usage example:
python utility_scripts/publish_puzzles_to_firebase.py \
  --service-account /path/service-account.json \
  --bucket your-project.appspot.com \
  --source-root /data/puzzles \
  --puzzle-ids sunset_01 mountain_02 \
  --size-options 100 500 1000 1500

Expected per-puzzle local layout inside --source-root:
  {puzzle_id}/thumb.jpg
  {puzzle_id}/adjacent.json
  {puzzle_id}/pieces/pieces.json
  {puzzle_id}/pieces/raster/*.png

The script will:
1) Upload required files to storage path `puzzles/{puzzle_id}/...`
2) Build and upload `manifest.json` with bytes + sha256 for each file
3) Upsert Firestore doc `puzzles/{puzzle_id}`
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List

import firebase_admin
from firebase_admin import credentials, firestore, storage


@dataclass
class FileEntry:
    local_path: Path
    relative_path: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def ensure_required_files(puzzle_dir: Path) -> List[FileEntry]:
    required = [
        FileEntry(puzzle_dir / "adjacent.json", "adjacent.json"),
        FileEntry(puzzle_dir / "pieces" / "pieces.json", "pieces/pieces.json"),
    ]

    raster_dir = puzzle_dir / "pieces" / "raster"
    raster_files = sorted(raster_dir.glob("*.png"))
    if not raster_files:
        raise FileNotFoundError(f"No raster pieces found in {raster_dir}")

    for r in raster_files:
        rel = f"pieces/raster/{r.name}"
        required.append(FileEntry(r, rel))

    missing = [entry.local_path for entry in required if not entry.local_path.exists()]
    if missing:
        raise FileNotFoundError(f"Missing required files: {missing}")

    return required


def upload_blob(bucket: storage.bucket, local_path: Path, remote_path: str) -> None:
    blob = bucket.blob(remote_path)
    blob.upload_from_filename(str(local_path))


def build_manifest(puzzle_id: str, asset_version: int, files: Iterable[FileEntry]) -> dict:
    manifest_files = []
    for entry in files:
        size = entry.local_path.stat().st_size
        digest = sha256_file(entry.local_path)
        manifest_files.append(
            {
                "path": entry.relative_path,
                "storage_path": f"puzzles/{puzzle_id}/{entry.relative_path}",
                "sha256": digest,
                "bytes": size,
            }
        )

    return {
        "puzzle_id": puzzle_id,
        "asset_version": asset_version,
        "files": manifest_files,
    }


def upsert_firestore_doc(db: firestore.Client, *, puzzle_id: str, title: str, difficulty: str,
                        asset_version: int, size_options: List[int], enabled: bool) -> None:
    doc_ref = db.collection("puzzles").document(puzzle_id)
    payload = {
        "id": puzzle_id,
        "title": title,
        "difficulty": difficulty,
        "thumb_path": f"puzzles/{puzzle_id}/thumb.jpg",
        "manifest_path": f"puzzles/{puzzle_id}/manifest.json",
        "asset_version": asset_version,
        "enabled": enabled,
        "updated_at": firestore.SERVER_TIMESTAMP,
        "size_options": size_options,
        "published_at_iso": datetime.now(timezone.utc).isoformat(),
    }
    doc_ref.set(payload, merge=True)


def publish_one(
    *,
    bucket: storage.bucket,
    db: firestore.Client,
    source_root: Path,
    puzzle_id: str,
    asset_version: int,
    title: str,
    difficulty: str,
    size_options: List[int],
    enabled: bool,
    dry_run: bool,
) -> None:
    puzzle_dir = source_root / puzzle_id
    thumb = puzzle_dir / "thumb.jpg"
    if not thumb.exists():
        raise FileNotFoundError(f"Missing thumbnail: {thumb}")

    entries = ensure_required_files(puzzle_dir)

    manifest = build_manifest(puzzle_id, asset_version, entries)
    manifest_tmp = puzzle_dir / "manifest.generated.json"
    manifest_tmp.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    print(f"\n== Publishing {puzzle_id} ==")
    print(f"Files: {len(entries)} + thumb + manifest")

    if dry_run:
        print("DRY RUN: skipping upload and Firestore write")
        return

    upload_blob(bucket, thumb, f"puzzles/{puzzle_id}/thumb.jpg")
    for entry in entries:
        upload_blob(bucket, entry.local_path, f"puzzles/{puzzle_id}/{entry.relative_path}")
    upload_blob(bucket, manifest_tmp, f"puzzles/{puzzle_id}/manifest.json")

    upsert_firestore_doc(
        db,
        puzzle_id=puzzle_id,
        title=title or puzzle_id,
        difficulty=difficulty,
        asset_version=asset_version,
        size_options=size_options,
        enabled=enabled,
    )
    print("Published successfully")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Batch publish puzzles to Firebase")
    p.add_argument("--service-account", required=True, help="Path to Firebase service-account JSON")
    p.add_argument("--bucket", required=True, help="Firebase storage bucket (e.g. myproj.appspot.com)")
    p.add_argument("--source-root", required=True, help="Root folder containing per-puzzle directories")
    p.add_argument("--puzzle-ids", nargs="+", required=True, help="Puzzle ids/folder names to publish")
    p.add_argument("--asset-version", type=int, default=1, help="Asset version to write into doc+manifest")
    p.add_argument("--size-options", nargs="+", type=int, default=[100, 500, 1000], help="UI size labels")
    p.add_argument("--difficulty", default="Unknown")
    p.add_argument("--title-prefix", default="")
    p.add_argument("--disabled", action="store_true", help="Publish doc with enabled=false")
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    cred = credentials.Certificate(args.service_account)
    firebase_admin.initialize_app(cred, {"storageBucket": args.bucket})

    bucket = storage.bucket()
    db = firestore.client()
    source_root = Path(args.source_root)

    enabled = not args.disabled
    for pid in args.puzzle_ids:
        publish_one(
            bucket=bucket,
            db=db,
            source_root=source_root,
            puzzle_id=pid,
            asset_version=args.asset_version,
            title=(f"{args.title_prefix}{pid}" if args.title_prefix else pid),
            difficulty=args.difficulty,
            size_options=args.size_options,
            enabled=enabled,
            dry_run=args.dry_run,
        )

    print("\nDone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
