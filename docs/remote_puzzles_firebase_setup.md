# Remote Puzzle Firebase Setup (Firestore + Cloud Storage)

This doc explains exactly what you need to configure in Firebase so the new remote puzzle pipeline works in this Godot project.

---

## 1) What the game now expects

The current implementation reads:

- Firestore collection: `puzzles`
- only documents where `enabled == true`
- ordered by `updated_at` (descending)

Then for each puzzle, it expects:

- `thumb_path` (Cloud Storage path to a thumbnail image)
- `manifest_path` (Cloud Storage path to `manifest.json`)
- `asset_version` (cache version)
- optional `size_options` (array of piece-count labels, e.g. `[100, 500, 1000, 1500]`)

Remote assets are downloaded to:

- temp: `user://puzzles/{puzzle_id}/_tmp_v{asset_version}/`
- final: `user://puzzles/{puzzle_id}/v{asset_version}/`

with a local `manifest.json` copied into the final cache folder after verification.

---

## 2) Firestore schema to create

Create collection: `puzzles`

Each document should include:

- `id` (string; optional if doc id is already your stable id)
- `title` (string)
- `difficulty` (string or number)
- `thumb_path` (string; Storage path)
- `manifest_path` (string; Storage path)
- `asset_version` (number; increment when any asset changes)
- `enabled` (boolean)
- `updated_at` (timestamp)
- `size_options` (array<number>; optional but recommended)

### Example document

Document id: `sunset_01`

```json
{
  "id": "sunset_01",
  "title": "Sunset Bay",
  "difficulty": "Hard",
  "thumb_path": "puzzles/sunset_01/thumb.jpg",
  "manifest_path": "puzzles/sunset_01/manifest.json",
  "asset_version": 3,
  "enabled": true,
  "updated_at": "<server timestamp>",
  "size_options": [100, 500, 1000, 1500]
}
```

> Note: `size_options` are used as labels (`~100 pieces`, etc). They do **not** need to exactly match final cut piece counts.

---

## 3) Cloud Storage layout to upload

Use this structure:

```text
puzzles/{puzzle_id}/thumb.jpg
puzzles/{puzzle_id}/manifest.json
puzzles/{puzzle_id}/adjacent.json
puzzles/{puzzle_id}/pieces/pieces.json
puzzles/{puzzle_id}/pieces/raster/0.png
puzzles/{puzzle_id}/pieces/raster/1.png
...
```

The gameplay loader requires `adjacent.json`, `pieces/pieces.json`, and the `pieces/raster/*.png` files.

---

## 4) Manifest format required

Upload `manifest.json` at `manifest_path` with this shape:

```json
{
  "puzzle_id": "sunset_01",
  "asset_version": 3,
  "files": [
    {
      "path": "adjacent.json",
      "storage_path": "puzzles/sunset_01/adjacent.json",
      "sha256": "...",
      "bytes": 1234
    },
    {
      "path": "pieces/pieces.json",
      "storage_path": "puzzles/sunset_01/pieces/pieces.json",
      "sha256": "...",
      "bytes": 5678
    },
    {
      "path": "pieces/raster/0.png",
      "storage_path": "puzzles/sunset_01/pieces/raster/0.png",
      "sha256": "...",
      "bytes": 45678
    }
  ]
}
```

Rules:

- `path` is the relative path under the local cache root
- `storage_path` is the Cloud Storage object path
- `sha256` is optional but strongly recommended
- `bytes` is optional, but recommended if `sha256` is omitted

---

## 5) Firebase Security Rules you likely need

## Firestore rules (read-only catalog example)

```txt
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /puzzles/{puzzleId} {
      allow read: if true; // or require auth if you prefer
      allow write: if false; // production: lock writes to admin paths only
    }
  }
}
```

## Storage rules (read-only puzzle assets example)

```txt
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /puzzles/{puzzleId}/{allPaths=**} {
      allow read: if true; // or request.auth != null
      allow write: if false;
    }
  }
}
```

If your game should require login before access, replace `if true` with `if request.auth != null`.

---

## 6) Firestore index note

The query is:

- `where(enabled == true)`
- `orderBy(updated_at desc)`

Depending on your Firestore mode/config, this may need a composite index. If Firestore returns an index error, create the suggested index:

- Collection: `puzzles`
- Fields:
  - `enabled` Ascending
  - `updated_at` Descending

---

## 7) Firebase CLI commands (project setup / deploy)

If you use Firebase CLI:

```bash
firebase login
firebase use <your-project-id>
```

Deploy rules:

```bash
firebase deploy --only firestore:rules
firebase deploy --only storage
```

If you maintain indexes in `firestore.indexes.json`:

```bash
firebase deploy --only firestore:indexes
```

> Collections are created automatically once first documents are written; there is no separate "create collection" command.

---

## 8) Publishing a new remote puzzle (repeatable checklist)

1. Prepare puzzle output files (`adjacent.json`, `pieces/pieces.json`, `pieces/raster/*.png`).
2. Upload all files to `puzzles/{id}/...` in Cloud Storage.
3. Generate `manifest.json` listing every required file with `storage_path` and integrity fields.
4. Upload `manifest.json` and `thumb.jpg`.
5. Create/update Firestore document in `puzzles/{id}` with:
   - `thumb_path`
   - `manifest_path`
   - incremented `asset_version`
   - `enabled: true`
   - `updated_at` refreshed
   - `size_options` updated (include 1000/1500 as needed)
6. Verify in game that puzzle appears and downloads.
7. Toggle `enabled` to false to hide puzzle without deleting assets.

---

## 9) Common failure modes + fixes

- **Puzzle appears but won't start**
  - Manifest missing gameplay files (`adjacent.json`, `pieces/pieces.json`, raster files).
- **Download fails immediately**
  - Bad Storage rules or wrong `storage_path`.
- **Integrity failure**
  - `sha256`/`bytes` mismatch; regenerate manifest from actual uploaded files.
- **Puzzle does not refresh after update**
  - `asset_version` not incremented.
- **No catalog entries**
  - `enabled` is false or query blocked by Firestore rules/index.

---

## 10) Local fallback behavior

Local `res://` puzzles still work. Remote puzzles are additive:

- local puzzles continue using existing folders
- remote puzzles are downloaded and loaded from `user://` cache

This supports gradual migration.

---


## 11) Automating bulk publish from local puzzles

This repo includes a batch helper script:

- `utility_scripts/publish_puzzles_to_firebase.py`

It uploads puzzle files to Cloud Storage, generates/uploads `manifest.json`, and upserts Firestore docs in `puzzles/{id}`.

Install deps:

```bash
pip install firebase-admin
```

Dry-run example:

```bash
python utility_scripts/publish_puzzles_to_firebase.py   --service-account /abs/path/service-account.json   --bucket your-project.appspot.com   --source-root /abs/path/local-puzzles   --puzzle-ids sunset_01 mountain_02   --asset-version 3   --size-options 100 500 1000 1500   --dry-run
```

Real publish example:

```bash
python utility_scripts/publish_puzzles_to_firebase.py   --service-account /abs/path/service-account.json   --bucket your-project.appspot.com   --source-root /abs/path/local-puzzles   --puzzle-ids sunset_01 mountain_02   --asset-version 3   --size-options 100 500 1000 1500
```

Expected local folder shape per puzzle id:

```text
{source_root}/{puzzle_id}/thumb.jpg
{source_root}/{puzzle_id}/adjacent.json
{source_root}/{puzzle_id}/pieces/pieces.json
{source_root}/{puzzle_id}/pieces/raster/*.png
```

