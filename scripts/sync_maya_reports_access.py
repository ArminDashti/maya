#!/usr/bin/env python3
"""Wire the ERP report-access RAG into Maya: markdown knowledge + Qdrant search tool.

Companion to

* ``scripts/generate_reports_access_md.py``  (markdown from rep_converted.deduped.json)
* ``scripts/qdrant_ingest_erp_reports.py``   (vectors into the Qdrant ``erp_reports`` collection)

What this script does, in order:

1. signs in to Maya (Open WebUI admin),
2. ensures the knowledge collection ``ERP Reports Access`` exists,
3. uploads/refreshes ``.armin/rag/generated/reports-access/*.md`` and links them to it
   (re-uploading is what re-embeds them into Qdrant, so never skip it after regenerating),
4. creates/updates the tool ``qdrant_erp_search`` from ``.armin/rag/tools/qdrant_erp_search.py``,
5. attaches both to every model that already carries the shared ``ERP Reports`` knowledge.

Usage::

    python scripts/sync_maya_reports_access.py                 # full sync
    python scripts/sync_maya_reports_access.py --skip-uploads  # only tool + model wiring
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

MD_FILES = (
    "reports-access-index.md",
    "reports-access-by-menu.md",
    "reports-access-by-personnel.md",
)


class Maya:
    def __init__(self, base: str, email: str, password: str):
        self.base = base.rstrip("/")
        self.email = email
        self.password = password
        self.token = None

    # --- plumbing -----------------------------------------------------------
    def call(self, method: str, path: str, payload=None, timeout: int = 300, raw: bytes = None, content_type: str = None):
        data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if content_type:
            headers["Content-Type"] = content_type
        elif data is not None:
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
        result = self.call("POST", "/api/v1/auths/signin", {"email": self.email, "password": self.password}, timeout=60)
        self.token = result["token"]
        print(f"signed in as {self.email} ({result.get('role')})")

    # --- knowledge ----------------------------------------------------------
    def ensure_knowledge(self, name: str, description: str) -> str:
        for item in self.call("GET", "/api/v1/knowledge/", timeout=120).get("items", []):
            if item["name"] == name:
                print(f"knowledge '{name}' -> {item['id']}")
                return item["id"]
        created = self.call("POST", "/api/v1/knowledge/create", {"name": name, "description": description}, timeout=120)
        print(f"created knowledge '{name}' -> {created['id']}")
        return created["id"]

    def find_file(self, name: str):
        for item in self.call("GET", "/api/v1/files/", timeout=120).get("items", []):
            if item.get("filename") == name or (item.get("meta") or {}).get("name") == name:
                return item
        return None

    def upload_markdown(self, path: str) -> str:
        name = os.path.basename(path)
        boundary = "----maya" + uuid.uuid4().hex
        content = open(path, "rb").read()
        body = b"".join(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'.encode(),
                b"Content-Type: text/markdown\r\n\r\n",
                content,
                b"\r\n",
                f"--{boundary}--\r\n".encode(),
            ]
        )
        uploaded = self.call(
            "POST", "/api/v1/files/", timeout=600, raw=body,
            content_type=f"multipart/form-data; boundary={boundary}",
        )
        if not uploaded or not uploaded.get("id"):
            raise RuntimeError(f"upload failed for {name}: {uploaded}")
        file_id = uploaded["id"]
        for _ in range(900):
            status = self.call("GET", f"/api/v1/files/{file_id}/process/status", timeout=120)
            if status.get("status") == "completed":
                break
            if status.get("status") == "failed":
                raise RuntimeError(f"processing failed for {name}")
            time.sleep(2)
        print(f"uploaded + processed {name} -> {file_id}")
        return file_id

    def link_file(self, knowledge_id: str, file_id: str, name: str):
        try:
            self.call("POST", f"/api/v1/knowledge/{knowledge_id}/file/add", {"file_id": file_id}, timeout=300)
            print(f"linked {name}")
        except RuntimeError as error:
            if "Duplicate content" in str(error):
                print(f"already in knowledge: {name}")
            else:
                raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--webui-url", default=os.environ.get("MAYA_URL", "http://127.0.0.1:3080"))
    parser.add_argument("--admin-email", default="armin@local")
    parser.add_argument("--admin-password", default=os.environ.get("MAYA_ADMIN_PASSWORD", "123456"))
    parser.add_argument("--md-dir", default=os.path.join(".armin", "rag", "generated", "reports-access"))
    parser.add_argument("--knowledge-name", default="ERP Reports Access")
    parser.add_argument("--knowledge-description",
                        default="ERP report access matrix (who can reach which report/menu) generated from rep_converted.deduped.json")
    parser.add_argument("--tool-path", default=os.path.join(".armin", "rag", "tools", "qdrant_erp_search.py"))
    parser.add_argument("--tool-id", default="qdrant_erp_search",
                        help="alphanumerics and underscores only - Open WebUI rejects anything else")
    parser.add_argument("--parent-knowledge-name", default="ERP Reports",
                        help="models carrying this knowledge also get the new knowledge + tool")
    parser.add_argument("--skip-uploads", action="store_true",
                        help="keep the already-uploaded markdown and only refresh tool + model wiring")
    parser.add_argument("--models", nargs="*", default=None,
                        help="limit the model wiring to these model ids (default: every shared-RAG model)")
    args = parser.parse_args()

    maya = Maya(args.webui_url, args.admin_email, args.admin_password)
    maya.login()

    knowledge_id = maya.ensure_knowledge(args.knowledge_name, args.knowledge_description)
    # This Open WebUI build returns files=null on the detail route; the /files route is authoritative.
    linked_items = maya.call("GET", f"/api/v1/knowledge/{knowledge_id}/files", timeout=120).get("items") or []
    already = {(item.get("meta") or {}).get("name") or item.get("filename") for item in linked_items}

    file_ids = []
    for filename in MD_FILES:
        path = os.path.join(args.md_dir, filename)
        if not os.path.exists(path):
            raise SystemExit(f"missing markdown: {path} (run scripts/generate_reports_access_md.py first)")
        current = maya.find_file(filename)
        if args.skip_uploads and current and filename in already:
            print(f"keeping existing upload {filename} ({current['id']})")
            file_ids.append(current["id"])
            continue
        if current:
            maya.call("DELETE", f"/api/v1/files/{current['id']}", timeout=120)
            print(f"removed stale upload {filename}")
        file_ids.append(maya.upload_markdown(path))
        maya.link_file(knowledge_id, file_ids[-1], filename)

    maya.call("POST", f"/api/v1/knowledge/{knowledge_id}/update",
              {"name": args.knowledge_name, "description": args.knowledge_description,
               "data": {"file_ids": file_ids}}, timeout=120)
    maya.call("POST", f"/api/v1/knowledge/{knowledge_id}/access/update",
              {"id": knowledge_id,
               "access_grants": [{"principal_type": "user", "principal_id": "*", "permission": "read"}]}, timeout=120)
    linked = len(maya.call("GET", f"/api/v1/knowledge/{knowledge_id}/files", timeout=120).get("items", []))
    print(f"knowledge files: {linked}")
    if linked < len(MD_FILES):
        raise SystemExit(f"knowledge '{args.knowledge_name}' has {linked} files, expected {len(MD_FILES)}")

    # --- tool ---------------------------------------------------------------
    if not os.path.exists(args.tool_path):
        raise SystemExit(f"missing tool source: {args.tool_path}")
    tool_body = {
        "id": args.tool_id,
        "name": "Qdrant ERP Report Access Search",
        "content": open(args.tool_path, encoding="utf-8").read(),
        "meta": {"description": "Semantic search over the ERP report-access vectors in Qdrant (collection erp_reports)."},
        "access_grants": [{"principal_type": "user", "principal_id": "*", "permission": "read"}],
    }
    existing_tool = None
    try:
        existing_tool = maya.call("GET", f"/api/v1/tools/id/{args.tool_id}", timeout=60)
    except RuntimeError:
        pass
    if existing_tool and existing_tool.get("id"):
        maya.call("POST", f"/api/v1/tools/id/{args.tool_id}/update", tool_body, timeout=120)
        print(f"updated tool {args.tool_id}")
    else:
        maya.call("POST", "/api/v1/tools/create", tool_body, timeout=120)
        print(f"created tool {args.tool_id}")

    # --- attach to shared-RAG models ---------------------------------------
    # The /api/models listing has no meta, so each candidate is read in full first.
    listing = maya.call("GET", "/api/models", timeout=600).get("data", [])
    touched = 0
    for entry in listing:
        model_id = entry["id"]
        if args.models and model_id not in args.models:
            continue
        try:
            detail = maya.call("GET", "/api/v1/models/model?id=" + urllib.parse.quote(model_id), timeout=120)
        except RuntimeError:
            continue
        if not detail or not detail.get("id"):
            continue
        meta = dict(detail.get("meta") or {})
        knowledge = list(meta.get("knowledge") or [])
        names = [item.get("name") for item in knowledge]
        if args.parent_knowledge_name not in names:
            continue
        if args.knowledge_name not in names:
            knowledge.append({"id": knowledge_id, "name": args.knowledge_name, "type": "collection"})
        meta["knowledge"] = knowledge
        tool_ids = list(meta.get("toolIds") or [])
        if args.tool_id not in tool_ids:
            tool_ids.append(args.tool_id)
        meta["toolIds"] = tool_ids
        maya.call("POST", "/api/v1/models/model/update", {
            "id": detail["id"],
            "name": detail["name"],
            "base_model_id": detail.get("base_model_id"),
            "meta": meta,
            "params": detail.get("params") or {},
            "access_grants": [{"principal_type": "user", "principal_id": "*", "permission": "read"}],
            "is_active": True,
        }, timeout=120)
        touched += 1
    print(f"models wired with knowledge + tool: {touched}")

    # --- report -------------------------------------------------------------
    verify = maya.call("GET", f"/api/v1/tools/id/{args.tool_id}", timeout=60)
    sample = None
    try:
        sample = maya.call("GET", "/api/v1/models/model?id=server-qwen-2.5-2b", timeout=120)
    except RuntimeError:
        pass
    meta = (sample or {}).get("meta") or {}
    print("verify:")
    print(f"  tool id           : {verify.get('id')}")
    print(f"  knowledge         : {knowledge_id} ({linked} files)")
    print(f"  server-qwen-2.5-2b: knowledge={[k.get('name') for k in meta.get('knowledge', [])]} tools={meta.get('toolIds')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
