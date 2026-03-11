#!/usr/bin/env python3
"""Create the Firestore composite index required by puzzle catalog queries.

Creates index for:
  where(enabled == true)
  orderBy(updated_at desc)
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

from firebase_admin import credentials
from google.auth.transport.requests import Request


DATASTORE_SCOPE = "https://www.googleapis.com/auth/datastore"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create Firestore puzzles composite index")
    parser.add_argument("--service-account", required=True, help="Path to Firebase service account JSON")
    parser.add_argument("--project-id", help="Firebase project id (defaults to project_id from service account)")
    parser.add_argument("--collection-group", default="puzzles", help="Collection group name (default: puzzles)")
    return parser.parse_args()


def load_project_id(service_account_path: Path) -> str:
    data = json.loads(service_account_path.read_text(encoding="utf-8"))
    return str(data.get("project_id", "")).strip()


def build_auth_token(service_account_path: Path) -> str:
    cred_obj = credentials.Certificate(str(service_account_path)).get_credential()
    if hasattr(cred_obj, "with_scopes"):
        cred_obj = cred_obj.with_scopes([DATASTORE_SCOPE])
    cred_obj.refresh(Request())
    token = getattr(cred_obj, "token", None)
    if not token:
        raise RuntimeError("Unable to mint access token from service account.")
    return token


def create_index(project_id: str, collection_group: str, token: str) -> tuple[int, str]:
    url = (
        "https://firestore.googleapis.com/v1/"
        f"projects/{project_id}/databases/(default)/collectionGroups/{collection_group}/indexes"
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


def main() -> int:
    print(
        "DEPRECATED: Prefer utility_scripts/firebase_setup_from_repo.py "
        "(it now supports one-stop index ensure + storage + firestore setup)."
    )
    args = parse_args()
    service_account_path = Path(args.service_account)
    if not service_account_path.exists():
        raise FileNotFoundError(f"Service account file not found: {service_account_path}")

    project_id = (args.project_id or load_project_id(service_account_path)).strip()
    if not project_id:
        raise ValueError("Project id is missing. Pass --project-id or use a valid service account JSON.")

    token = build_auth_token(service_account_path)
    status, body = create_index(project_id, args.collection_group, token)

    print(f"project_id: {project_id}")
    print(f"collection_group: {args.collection_group}")
    print(f"http_status: {status}")
    print(body)

    if status in (200, 201):
        print("Index creation request accepted.")
        return 0

    if status == 409 and "ALREADY_EXISTS" in body:
        print("Index already exists.")
        return 0

    print("Failed to create index.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
