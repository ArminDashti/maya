#!/usr/bin/env python3
"""Wire Maya's BM25 report retrieval: catalog + global filter + retired Qdrant tool.

Companion to

* ``scripts/generate_reports_access_md.py`` - writes the catalog the filter ranks
  (``.armin/rag/generated/reports-access/reports-access.bm25.json``)
* ``.armin/rag/sync-maya.ps1`` - system prompt, skill, models, users

What this script does, in order:

1. signs in to Maya (Open WebUI admin),
2. checks that the BM25 catalog exists (the filter reads it through the compose
   bind mount ``.armin/rag/generated/reports-access`` -> ``/app/backend/data/maya-catalog``),
3. creates/updates the global filter ``erp_reports_inject`` from
   ``.armin/rag/filters/erp_reports_inject.py`` and keeps it active + global,
4. retires the Qdrant-era tool: deletes tool ``qdrant_erp_search`` and drops its id
   from every model (a deleted tool id left on a model breaks its turns).

No knowledge upload happens any more: the old flow embedded the .md catalog into
Qdrant, which the BM25 path replaced.

Usage::

    python scripts/sync_maya_reports_access.py            # push the filter
    python scripts/sync_maya_reports_access.py --dry-run  # report what would change
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

CATALOG_PATH = os.path.join(
    ".armin", "rag", "generated", "reports-access", "reports-access.bm25.json"
)
RETIRED_TOOL_IDS = ("qdrant_erp_search",)


class Maya:
    def __init__(self, base: str, email: str, password: str):
        self.base = base.rstrip("/")
        self.email = email
        self.password = password
        self.token = None

    def call(self, method: str, path: str, payload=None, timeout: int = 120):
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode()[:300]
            raise RuntimeError(f"{method} {path} -> HTTP {error.code}: {detail}") from None

    def login(self):
        result = self.call("POST", "/api/v1/auths/signin",
                           {"email": self.email, "password": self.password}, timeout=60)
        self.token = result["token"]
        print(f"signed in as {self.email} ({result.get('role')})")


def push_filter(maya: Maya, filter_id: str, filter_path: str, dry_run: bool) -> dict:
    """Create/update the global BM25 filter and return its row."""
    if not os.path.exists(filter_path):
        raise SystemExit(f"missing filter source: {filter_path}")
    row = {
        "id": filter_id,
        "name": "ERP Reports BM25 Inject",
        "content": open(filter_path, encoding="utf-8").read(),
        "meta": {
            "description": (
                "Global inlet: rewrite the user text, rank the report catalog with BM25 and "
                "inject name/address/link candidates (no vector DB, no tool call)."
            )
        },
    }
    if dry_run:
        print(f"[dry-run] would upsert filter {filter_id} ({len(row['content'])} bytes)")
        return {"id": filter_id, "is_active": True, "is_global": True}

    try:
        current = maya.call("GET", f"/api/v1/functions/id/{filter_id}", timeout=60)
    except RuntimeError:
        current = None
    if current and current.get("id"):
        maya.call("POST", f"/api/v1/functions/id/{filter_id}/update", row)
        print(f"updated filter {filter_id}")
    else:
        maya.call("POST", "/api/v1/functions/create", row)
        print(f"created filter {filter_id}")

    # Update resets nothing, but a freshly created filter starts inactive / non-global.
    current = maya.call("GET", f"/api/v1/functions/id/{filter_id}", timeout=60)
    if not current.get("is_active"):
        current = maya.call("POST", f"/api/v1/functions/id/{filter_id}/toggle", timeout=60)
        print(f"activated filter {filter_id}")
    if not current.get("is_global"):
        current = maya.call("POST", f"/api/v1/functions/id/{filter_id}/toggle/global", timeout=60)
        print(f"set filter {filter_id} global")
    return current


def retire_tools(maya: Maya, tool_ids: tuple[str, ...], dry_run: bool) -> None:
    """Delete the retired tools and unlink their ids from every model."""
    for tool_id in tool_ids:
        try:
            maya.call("GET", f"/api/v1/tools/id/{tool_id}", timeout=60)
        except RuntimeError:
            print(f"tool {tool_id} already gone")
            continue
        if dry_run:
            print(f"[dry-run] would delete tool {tool_id}")
            continue
        maya.call("DELETE", f"/api/v1/tools/id/{tool_id}/delete", timeout=60)
        print(f"deleted tool {tool_id}")

    if dry_run:
        return
    touched = 0
    for entry in maya.call("GET", "/api/models", timeout=600).get("data", []):
        model_id = entry["id"]
        try:
            detail = maya.call("GET", "/api/v1/models/model?id=" + urllib.parse.quote(model_id), timeout=120)
        except RuntimeError:
            continue
        if not detail or not detail.get("id"):
            continue
        meta = dict(detail.get("meta") or {})
        tool_ids_now = list(meta.get("toolIds") or [])
        cleaned = [tid for tid in tool_ids_now if tid not in tool_ids]
        if cleaned == tool_ids_now:
            continue
        meta["toolIds"] = cleaned
        maya.call("POST", "/api/v1/models/model/update", {
            "id": detail["id"],
            "name": detail["name"],
            "base_model_id": detail.get("base_model_id"),
            "meta": meta,
            "params": detail.get("params") or {},
            "access_grants": [{"principal_type": "user", "principal_id": "*", "permission": "read"}],
            "is_active": detail.get("is_active", True),
        }, timeout=120)
        touched += 1
    print(f"models unlinked from retired tools: {touched}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--webui-url", default=os.environ.get("MAYA_URL", "http://127.0.0.1:3080"))
    parser.add_argument("--admin-email", default="armin@local")
    parser.add_argument("--admin-password", default=os.environ.get("MAYA_ADMIN_PASSWORD", "123456"))
    parser.add_argument("--filter-path", default=os.path.join(".armin", "rag", "filters", "erp_reports_inject.py"))
    parser.add_argument("--filter-id", default="erp_reports_inject",
                        help="alphanumerics and underscores only - Open WebUI rejects anything else")
    parser.add_argument("--catalog", default=CATALOG_PATH)
    parser.add_argument("--dry-run", action="store_true", help="print the changes without applying them")
    args = parser.parse_args()

    if not os.path.exists(args.catalog):
        raise SystemExit(
            f"missing BM25 catalog: {args.catalog}\n"
            "run: python scripts/generate_reports_access_md.py "
            '--json "<rep_converted.deduped.json>" --out ".armin/rag/generated/reports-access"'
        )
    corpus = json.load(open(args.catalog, encoding="utf-8"))
    print(f"catalog: {args.catalog} rows={corpus.get('count')} source={corpus.get('generated_from')}")

    maya = Maya(args.webui_url, args.admin_email, args.admin_password)
    maya.login()

    row = push_filter(maya, args.filter_id, args.filter_path, args.dry_run)
    retire_tools(maya, RETIRED_TOOL_IDS, args.dry_run)

    print("verify:")
    print(f"  filter {row.get('id')}: active={row.get('is_active')} global={row.get('is_global')} "
          f"type={row.get('type')}")
    print(f"  catalog rows      : {corpus.get('count')}")
    if not args.dry_run and (not row.get("is_active") or not row.get("is_global")):
        raise SystemExit(
            f"filter {args.filter_id} must be active+global "
            f"(active={row.get('is_active')} global={row.get('is_global')})"
        )
    if not args.dry_run:
        print("  next: .armin/rag/sync-maya.ps1 pushes the prompt + skill to the four models")
    return 0


if __name__ == "__main__":
    sys.exit(main())
