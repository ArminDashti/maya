"""
title: ERP Reports Vector Inject
author: Armin Dashti
version: 1.0.0
required_open_webui_version: 0.11.0
description: Global inlet — rewrite user text, search Qdrant erp_reports, inject candidates (no tool call).
"""

# Runs on every chat when this filter is active + global. Models never need
# function calling: candidates land in messages before the LLM sees the turn.
#
# Collection erp_reports is standalone (no maya_ prefix). Embedding must match
# scripts/qdrant_ingest_erp_reports.py / the chat RAG model (384-d cosine).

from __future__ import annotations

import logging
import re
from typing import Optional

import requests
from pydantic import BaseModel, Field

log = logging.getLogger(__name__)

_MARKER = "### ERP vector candidates (collection erp_reports)"

# Leading chitchat / politeness that hurts embedding match.
_LEADING_FILLER = re.compile(
    r"^(?:"
    r"hi|hello|hey|please|pls|thanks|thank you|"
    r"سلام|درود|لطفا|لطفاً|مرسی|ممنون|"
    r"می\s*خواهم|میخواهم|می\s*خوام|میخوام|"
    r"can you|could you|i (?:want|need)|help me"
    r")[\s,.:;!؟?]*",
    re.IGNORECASE,
)
_TRAILING_FILLER = re.compile(
    r"[\s,.:;!؟?]*(?:please|pls|thanks|thank you|مرسی|ممنون)\.?$",
    re.IGNORECASE,
)


def _normalize(text: str) -> str:
    """Same normalization the ingest script applies: drop kashida, unify letters."""
    if not text:
        return ""
    out = text.replace("\u0640", "")
    out = out.replace("\u064a", "\u06cc").replace("\u0643", "\u06a9")
    out = out.replace("\u200c", " ").replace("\u200f", "").replace("\u200e", "")
    return " ".join(out.split())


def _to_vector_query(text: str) -> str:
    """Step 1: make the user prompt vector-friendly without an extra LLM call."""
    cleaned = _normalize(text)
    # Strip stacked greetings / politeness (سلام لطفا …).
    while cleaned:
        next_text = _LEADING_FILLER.sub("", cleaned, count=1)
        next_text = _normalize(next_text)
        if next_text == cleaned:
            break
        cleaned = next_text
    cleaned = _TRAILING_FILLER.sub("", cleaned)
    return _normalize(cleaned) or _normalize(text)


def _last_user_text(messages: list) -> str:
    for message in reversed(messages or []):
        if (message or {}).get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for part in content:
                if isinstance(part, str):
                    parts.append(part)
                elif isinstance(part, dict) and part.get("type") == "text":
                    parts.append(str(part.get("text") or ""))
            return " ".join(parts)
    return ""


def _dedupe_hits(hits: list) -> list[tuple[str, str, float]]:
    seen: set[tuple[str, str]] = set()
    rows: list[tuple[str, str, float]] = []
    for hit in hits:
        payload = hit.get("payload") or {}
        name = str(payload.get("NameSystem") or "").strip() or "?"
        parent = str(payload.get("ParentSystemtxt") or "").strip() or "?"
        key = (name, parent)
        if key in seen:
            continue
        seen.add(key)
        rows.append((name, parent, float(hit.get("score") or 0)))
    return rows


def _escape_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def _candidate_block(vector_query: str, rows: list[tuple[str, str, float]], note: str = "") -> str:
    lines = [
        _MARKER,
        f'Vector query: "{vector_query}"',
    ]
    if note:
        lines.append(note)
    if rows:
        lines.append("| NameSystem | ParentSystemtxt | score |")
        lines.append("| --- | --- | --- |")
        for name, parent, score in rows:
            lines.append(
                f"| {_escape_cell(name)} | {_escape_cell(parent)} | {score:.3f} |"
            )
    else:
        lines.append("No matching rows in erp_reports.")
    lines.append(
        "Use only these rows. Select all relevant. "
        "Final answer = markdown table with columns NameSystem, ParentSystemtxt only."
    )
    return "\n".join(lines)


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0, description="Lower runs earlier among filters.")
        qdrant_url: str = "http://host.docker.internal:6333"
        collection: str = "erp_reports"
        embedding_model: str = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
        cache_folder: str = "/app/backend/data/cache/embedding/models"
        default_top_k: int = 12

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
        response = requests.post(
            f"{self.valves.qdrant_url.rstrip('/')}/collections/{self.valves.collection}/points/search",
            json={"vector": vector, "limit": limit, "with_payload": True},
            timeout=30,
        )
        response.raise_for_status()
        return response.json()["result"]

    def _inject(self, body: dict, block: str) -> dict:
        messages = list(body.get("messages") or [])
        # Drop a prior inject from this filter (retries / multi-pass).
        messages = [
            m
            for m in messages
            if not (
                (m or {}).get("role") == "system"
                and _MARKER in str((m or {}).get("content") or "")
            )
        ]
        insert_at = 1 if messages and (messages[0] or {}).get("role") == "system" else 0
        messages.insert(insert_at, {"role": "system", "content": block})
        body["messages"] = messages
        return body

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        messages = body.get("messages") or []
        user_text = _last_user_text(messages)
        if not user_text.strip():
            return body

        vector_query = _to_vector_query(user_text)
        if not vector_query:
            return body

        limit = max(1, min(int(self.valves.default_top_k), 50))
        try:
            hits = self._search(self._embed(vector_query), limit)
            rows = _dedupe_hits(hits)
            block = _candidate_block(vector_query, rows)
        except Exception as error:  # never break the chat turn
            log.exception("erp_reports inject failed")
            block = _candidate_block(
                vector_query,
                [],
                note=f"Search failed: {error}. Answer that no vector candidates are available.",
            )

        return self._inject(body, block)


# lean-ctx: no Qdrant in __main__; upgrade when adding live integration test
if __name__ == "__main__":
    assert _to_vector_query("سلام لطفا لیست دریافت و پرداخت") == _normalize(
        "لیست دریافت و پرداخت"
    ), "rewrite should drop Persian filler"
    assert _dedupe_hits(
        [
            {"payload": {"NameSystem": "A", "ParentSystemtxt": "P"}, "score": 0.9},
            {"payload": {"NameSystem": "A", "ParentSystemtxt": "P"}, "score": 0.8},
            {"payload": {"NameSystem": "B", "ParentSystemtxt": "Q"}, "score": 0.7},
        ]
    ) == [("A", "P", 0.9), ("B", "Q", 0.7)], "dedupe by name+path"
    print("erp_reports_inject self-check ok")
