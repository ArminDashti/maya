"""
title: Qdrant ERP Report Access Search
author: Armin Dashti
version: 1.0.0
required_open_webui_version: 0.11.0
description: Vector search over the ERP report-access rows in Maya's single Qdrant collection "maya" (tenant erp_reports).
"""

# Maya tool: search the ERP report-access dataset by meaning, not by keyword.
#
# One vector per distinct report name and webpage address, in collection "maya"
# (payload tenant_id = "erp_reports"). Knowledge chunks, files, and report rows
# share the collection and are isolated by tenant_id.
# Payload fields: NameSystem, ParentSystemtxt, URL.
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


def _escape_markdown_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


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
        collection: str = "maya"
        tenant: str = "erp_reports"
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

    def _search(self, vector: list, limit: int) -> list:
        body = {"vector": vector, "limit": limit, "with_payload": True}
        # One shared collection: pin the search to the ERP tenant so knowledge
        # .md chunks are never reported as report-access rows.
        body["filter"] = {
            "must": [{"key": "tenant_id", "match": {"value": self.valves.tenant}}]
        }
        response = requests.post(
            f"{self.valves.qdrant_url}/collections/{self.valves.collection}/points/search",
            json=body,
            timeout=30,
        )
        response.raise_for_status()
        return response.json()["result"]

    def search_erp_report_access(self, query: str, top_k: int = 0) -> str:
        """
        Callable name: search_erp_report_access (do not invent other names).

        Search the ERP report-access vector database when the platform exposes this
        tool. Prefer any Qdrant/knowledge context already injected into the chat turn;
        that retrieval already counts as the vector search. Use this tool to
        find report names and their webpage addresses.
        Persian and English queries both work; the search is semantic (embedding
        similarity), so partial titles and plain-language descriptions are fine.

        :param query: What to look for, e.g. "لیست دریافت و پرداخت" or "warehouse count report".
        :param top_k: How many rows to return (default from tool settings).
        :return: Persian Markdown table with report name, webpage address, and URL.
        """
        limit = int(top_k) if top_k else int(self.valves.default_top_k)
        try:
            hits = self._search(self._embed(query), max(1, min(limit, 50)))
        except Exception as error:  # never break the chat turn on a backend hiccup
            log.exception("qdrant search failed")
            return f"Qdrant search failed: {error}"

        if not hits:
            return "No matching report-access rows found in the vector database."

        lines = [
            "| نام گزارش | آدرس در صفحه وب | URL |",
            "| --- | --- | --- |",
        ]
        for hit in hits:
            payload = hit.get("payload") or {}
            name = _escape_markdown_cell(str(payload.get("NameSystem") or "؟").strip())
            parent = str(payload.get("ParentSystemtxt") or "").strip()
            url = _escape_markdown_cell(str(payload.get("URL") or "").strip())
            lines.append(f"| {name} | {_escape_markdown_cell(parent)} | {url} |")
        return "\n".join(lines)
