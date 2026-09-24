"""
title: Qdrant ERP Report Access Search
author: Armin Dashti
version: 1.0.0
required_open_webui_version: 0.11.0
description: Vector search over the ERP report-access dataset (Qdrant collection "erp_reports").
"""

# Maya tool: search the ERP report-access dataset by meaning, not by keyword.
#
# Data: 3732 vectors in Qdrant (collection "erp_reports"), built by
# scripts/qdrant_ingest_erp_reports.py from rep_converted.deduped.json.
# Payload per point: NameSystem, ParentSystemtxt, FullNamePersonel.
#
# Runs inside the maya-openwebui container, so it reuses the container's cached
# sentence-transformers model - the same one Maya uses for RAG - which keeps query
# and document vectors in one space (384-d, cosine).
#
# No `requirements:` frontmatter on purpose: sentence-transformers and requests are
# already baked into the image, and anything listed there triggers a pip run at startup.

import logging

import requests
from pydantic import BaseModel

log = logging.getLogger(__name__)


def _normalize(text: str) -> str:
    """Same normalization the ingest script applies: drop kashida, unify letters."""
    if not text:
        return ""
    out = text.replace("\u0640", "")
    out = out.replace("\u064a", "\u06cc").replace("\u0643", "\u06a9")
    out = out.replace("\u200c", " ").replace("\u200f", "").replace("\u200e", "")
    return " ".join(out.split())


class Tools:
    class Valves(BaseModel):
        """Settings editable in Admin Panel -> Tools -> Qdrant ERP Report Access Search."""

        qdrant_url: str = "http://host.docker.internal:6333"
        collection: str = "erp_reports"
        embedding_model: str = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
        cache_folder: str = "/app/backend/data/cache/embedding/models"
        default_top_k: int = 8

    def __init__(self):
        self.valves = self.Valves()
        self._model = None

    def _get_model(self):
        if self._model is None:
            from sentence_transformers import SentenceTransformer  # heavy: import lazily

            self._model = SentenceTransformer(
                self.valves.embedding_model,
                cache_folder=self.valves.cache_folder,
                device="cpu",
            )
        return self._model

    def _embed(self, text: str) -> list:
        vector = self._get_model().encode([_normalize(text)], normalize_embeddings=True)
        return vector[0].tolist()

    def _search(self, vector: list, limit: int, person: str = "") -> list:
        body = {"vector": vector, "limit": limit, "with_payload": True}
        if person:
            body["filter"] = {
                "must": [{"key": "FullNamePersonel", "match": {"value": _normalize(person)}}]
            }
        response = requests.post(
            f"{self.valves.qdrant_url}/collections/{self.valves.collection}/points/search",
            json=body,
            timeout=30,
        )
        response.raise_for_status()
        return response.json()["result"]

    def search_erp_report_access(self, query: str, person: str = "", top_k: int = 0) -> str:
        """
        Callable name: search_erp_report_access (do not invent other names).

        Search the ERP report-access vector database when the platform exposes this
        tool. Prefer any Qdrant/knowledge context already injected into the chat turn;
        that retrieval already counts as the vector search. Use this tool for
        who-can-access questions when available, then open reports-access-*.md /
        reports-index.md / reports.md to confirm details.
        Persian and English queries both work; the search is semantic (embedding
        similarity), so partial titles and plain-language descriptions are fine.

        :param query: What to look for, e.g. "لیست دریافت و پرداخت" or "warehouse count report".
        :param person: Optional employee full name to restrict the results to that person's access rows.
        :param top_k: How many rows to return (default from tool settings).
        :return: Markdown list of matches: report title, ERP menu path, employee.
        """
        limit = int(top_k) if top_k else int(self.valves.default_top_k)
        try:
            hits = self._search(self._embed(query), max(1, min(limit, 50)), person)
        except Exception as error:  # never break the chat turn on a backend hiccup
            log.exception("qdrant search failed")
            return f"Qdrant search failed: {error}"

        if not hits:
            return "No matching report-access rows found in the vector database."

        lines = [f"Top {len(hits)} matches from the ERP report-access vector DB:"]
        for position, hit in enumerate(hits, start=1):
            payload = hit.get("payload") or {}
            lines.append(
                f"{position}. **{payload.get('NameSystem', '?')}** - menu: "
                f"{payload.get('ParentSystemtxt', '?')} - employee: "
                f"{payload.get('FullNamePersonel', '?')} (score {hit.get('score', 0):.3f})"
            )
        lines.append("Answer from these rows only; do not invent reports, paths or people.")
        return "\n".join(lines)
