#!/usr/bin/env python3
"""Push the ERP report-access dataset (``rep_converted.deduped.json``) into Qdrant as vectors.

The script is meant to run *inside the Maya container* (``maya-openwebui``) because that
image already ships ``sentence-transformers`` plus the cached embedding model that Maya
uses for RAG, so documents and queries share one vector space (384-d, cosine).

Only these three fields are embedded and stored as payload:

* ``NameSystem``       - report / system title (Persian)
* ``ParentSystemtxt``  - full menu path of the report inside the ERP tree
* ``FullNamePersonel`` - employee the access row belongs to

Usage (from the repo root on the Windows host)::

    docker cp "C:/Users/armin/Desktop/rep_converted.deduped.json" maya-openwebui:/tmp/rep.json
    docker cp scripts/qdrant_ingest_erp_reports.py maya-openwebui:/tmp/qdrant_ingest.py
    docker exec maya-openwebui python /tmp/qdrant_ingest.py \
        --json /tmp/rep.json --url http://host.docker.internal:6333 --recreate

Qdrant is driven over plain REST (``requests``) on purpose: the image ships a much newer
``qdrant-client`` (1.18) than the running Qdrant server (1.9), and the client's Query API
would hit endpoints that server does not expose yet.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid

import requests

FIELDS = ("NameSystem", "ParentSystemtxt", "FullNamePersonel")
# Default must be the model Maya embeds queries with (exported inside the container);
# a different model puts docs and queries in different vector spaces and silently
# degrades every search (all-MiniLM-L6-v2 is English-only and was the old wrong default).
DEFAULT_MODEL_PATH = os.environ.get(
    "RAG_EMBEDDING_MODEL",
    "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
)
DEFAULT_CACHE = os.environ.get(
    "SENTENCE_TRANSFORMERS_HOME", "/app/backend/data/cache/embedding/models"
)

# --------------------------------------------------------------------------- text


def normalize(text: str) -> str:
    """Make Persian ERP titles comparable: drop kashida padding, unify letters."""
    if not text:
        return ""
    out = text.replace("\u0640", "")  # kashida / tatweel padding used in menu paths
    out = out.replace("\u064a", "\u06cc").replace("\u0643", "\u06a9")  # ي->ی , ك->ک
    out = out.replace("\u200c", " ").replace("\u200f", "").replace("\u200e", "")
    return " ".join(out.split())


def build_text(record: dict) -> str:
    """Embedding text = the three fields, normalized and joined."""
    return " | ".join(normalize(str(record.get(field, ""))) for field in FIELDS)


def build_payload(record: dict) -> dict:
    """Payload = the same three fields, verbatim except for the dump's stray padding."""
    return {field: str(record.get(field) or "").strip() for field in FIELDS}


def point_id(text: str) -> str:
    """Deterministic id so re-runs overwrite instead of duplicating."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "erp-reports-access:" + text))


# --------------------------------------------------------------------------- qdrant


class Qdrant:
    def __init__(self, url: str, collection: str, timeout: int = 120):
        self.url = url.rstrip("/")
        self.collection = collection
        self.timeout = timeout

    def _request(self, method: str, path: str, payload=None, ok=(200,)):
        response = requests.request(
            method, f"{self.url}{path}", json=payload, timeout=self.timeout
        )
        if response.status_code not in ok:
            raise RuntimeError(f"{method} {path} -> {response.status_code}: {response.text[:400]}")
        return response.json() if response.content else {}

    def exists(self) -> bool:
        response = requests.get(f"{self.url}/collections/{self.collection}", timeout=self.timeout)
        return response.status_code == 200

    def delete(self):
        self._request("DELETE", f"/collections/{self.collection}")

    def create(self, size: int, distance: str = "Cosine", on_disk: bool = False):
        self._request(
            "PUT",
            f"/collections/{self.collection}",
            {"vectors": {"size": size, "distance": distance, "on_disk": on_disk}},
        )

    def create_keyword_index(self, field: str):
        self._request(
            "PUT",
            f"/collections/{self.collection}/index?wait=true",
            {"field_name": field, "field_schema": "keyword"},
        )

    def upsert(self, points: list[dict], batch: int = 256):
        sent = 0
        for start in range(0, len(points), batch):
            chunk = points[start : start + batch]
            for attempt in range(3):
                try:
                    self._request(
                        "PUT", f"/collections/{self.collection}/points?wait=true", {"points": chunk}
                    )
                    break
                except Exception as error:  # transient socket/5xx -> retry
                    if attempt == 2:
                        raise
                    print(f"  retry {attempt + 1} ({error})", flush=True)
                    time.sleep(2 * (attempt + 1))
            sent += len(chunk)
            print(f"  upserted {sent}/{len(points)}", flush=True)
        return sent

    def info(self) -> dict:
        return self._request("GET", f"/collections/{self.collection}")["result"]

    def search(self, vector: list[float], limit: int = 5) -> list[dict]:
        """Query API when the server has it (>=1.10), legacy search endpoint otherwise."""
        body = {"vector": vector, "limit": limit, "with_payload": True}
        response = requests.post(
            f"{self.url}/collections/{self.collection}/points/query",
            json={"query": vector, "limit": limit, "with_payload": True},
            timeout=self.timeout,
        )
        if response.status_code == 200:
            return response.json()["result"]["points"]
        response = requests.post(
            f"{self.url}/collections/{self.collection}/points/search",
            json=body,
            timeout=self.timeout,
        )
        response.raise_for_status()
        return response.json()["result"]


# --------------------------------------------------------------------------- main


def load_records(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as handle:
        records = json.load(handle)
    if not isinstance(records, list):
        raise SystemExit("expected a JSON array")
    return records


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", required=True, help="path to rep_converted.deduped.json")
    parser.add_argument("--url", default="http://host.docker.internal:6333")
    parser.add_argument("--collection", default="erp_reports")
    parser.add_argument("--model", default=DEFAULT_MODEL_PATH)
    parser.add_argument("--cache", default=DEFAULT_CACHE)
    parser.add_argument("--batch", type=int, default=64, help="embedding batch size")
    parser.add_argument("--recreate", action="store_true", help="drop the collection first")
    parser.add_argument("--no-verify-search", action="store_true")
    args = parser.parse_args()

    records = load_records(args.json)

    # Guard: the query tool embeds with RAG_EMBEDDING_MODEL; ingesting with anything
    # else makes every score meaningless (both are 384-d, so it fails silently).
    active_model = os.environ.get("RAG_EMBEDDING_MODEL")
    if active_model and args.model != active_model:
        raise SystemExit(
            f"--model {args.model} does not match container RAG_EMBEDDING_MODEL "
            f"{active_model}; searches would run in a different vector space. "
            f"Re-run without --model (or pass --model {active_model})."
        )

    # One point per distinct (NameSystem, ParentSystemtxt, FullNamePersonel) triple.
    unique: dict[str, dict] = {}
    for record in records:
        text = build_text(record)
        if not text.strip(" |"):
            continue
        unique[point_id(text)] = {"text": text, "payload": build_payload(record)}
    print(f"records={len(records)} unique_points={len(unique)}", flush=True)

    from sentence_transformers import SentenceTransformer  # imported late: heavy

    print(f"embedding model={args.model} cache={args.cache}", flush=True)
    model = SentenceTransformer(args.model, cache_folder=args.cache, device="cpu")

    ids = list(unique)
    texts = [unique[key]["text"] for key in ids]
    vectors: list[list[float]] = []
    started = time.time()
    for start in range(0, len(texts), args.batch):
        chunk = texts[start : start + args.batch]
        vectors.extend(
            model.encode(chunk, normalize_embeddings=True, show_progress_bar=False).tolist()
        )
        print(f"  embedded {len(vectors)}/{len(texts)}", flush=True)
    size = len(vectors[0])
    print(f"embedded {len(vectors)} texts dim={size} in {time.time() - started:.1f}s", flush=True)

    client = Qdrant(args.url, args.collection)
    if client.exists():
        if args.recreate:
            print(f"dropping existing collection {args.collection}", flush=True)
            client.delete()
        else:
            print(f"collection {args.collection} already exists (use --recreate to reset)", flush=True)
    if not client.exists():
        client.create(size)
        print(f"created collection {args.collection} (size={size}, Cosine)", flush=True)

    client.create_keyword_index("FullNamePersonel")
    print("payload index: FullNamePersonel (keyword)", flush=True)

    points = [
        {"id": key, "vector": vector, "payload": unique[key]["payload"]}
        for key, vector in zip(ids, vectors)
    ]
    sent = client.upsert(points)

    info = client.info()
    print(
        f"collection={args.collection} points_count={info.get('points_count')} "
        f"(uploaded {sent}) status={info.get('status')}",
        flush=True,
    )

    if not args.no_verify_search:
        for query in (
            "\u0644\u06cc\u0633\u062a \u062f\u0631\u06cc\u0627\u0641\u062a \u0648 \u067e\u0631\u062f\u0627\u062e\u062a",  # لیست دریافت و پرداخت
            "\u062a\u0627\u0626\u06cc\u062f \u067e\u0631\u062f\u0627\u062e\u062a \u0627\u0646\u0628\u0627\u0631",  # تائید پرداخت انبار
            "\u0645\u06cc\u062a\u0631\u0627 \u06a9\u0631\u06cc\u0645\u06cc",  # میترا کریمی
        ):
            vector = model.encode([normalize(query)], normalize_embeddings=True)[0].tolist()
            hits = client.search(vector, limit=3)
            print(f"\nquery: {query}")
            for hit in hits:
                payload = hit.get("payload", {})
                print(f"  score={hit.get('score', 0):.4f} :: {payload.get('FullNamePersonel')}"
                      f" :: {payload.get('NameSystem')}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
