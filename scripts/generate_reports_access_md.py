#!/usr/bin/env python3
"""Generate the canonical report catalog from the ERP source dataset.

Input : ``rep_converted.deduped.json`` (host copy on the Desktop)
Output: ``reports-access.md`` with report name, webpage address, and URL.

Employee access data is intentionally excluded. URL paths derive from
``ParentSystemtxt`` using the ERP's report-page URL format.

Usage::

    python scripts/generate_reports_access_md.py \
        --json "C:/Users/armin/Desktop/rep_converted.deduped.json" \
        --out ".armin/rag/generated/reports-access"
"""

from __future__ import annotations

import argparse
import json
import os
from urllib.parse import quote

ERP_BASE_URL = "http://erp.dpdc.co:8880/"
LEGACY_OUTPUTS = (
    "reports-access-index.md",
    "reports-access-by-menu.md",
    "reports-access-by-personnel.md",
)


def clean(text: str) -> str:
    """Drop kashida padding / zero-width marks and collapse whitespace."""
    if not text:
        return ""
    out = text.replace("\u0640", "")
    out = out.replace("\u064a", "\u06cc").replace("\u0643", "\u06a9")
    out = out.replace("\u200c", " ").replace("\u200f", "").replace("\u200e", "")
    return " ".join(out.split())


def menu_path(parent: str) -> str:
    """``الف---ب---ج`` -> ``الف › ب › ج`` (readable for the LLM and for humans)."""
    parts = [clean(part) for part in clean(parent).split("---")]
    return " \u203a ".join(part for part in parts if part)


def report_url(parent: str) -> str:
    """Build the ERP report URL from its source menu address."""
    if not parent:
        return ""
    path = quote(parent.strip().lstrip("/"), safe="/-")
    return f"{ERP_BASE_URL}{path}"


def escape_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--source-label", default="rep_converted.deduped.json")
    args = parser.parse_args()

    with open(args.json, encoding="utf-8") as handle:
        records = json.load(handle)

    reports = {}
    for record in records:
        name = clean(str(record.get("NameSystem", "")))
        parent = str(record.get("ParentSystemtxt", "")).strip()
        if not name:
            continue
        # Match Qdrant's normalized point key while keeping the source address
        # for exact URL generation. Later duplicate rows replace earlier ones.
        reports[(name, clean(parent))] = (name, parent)

    rows = sorted(reports.values(), key=lambda row: (row[0], clean(row[1])))
    os.makedirs(args.out, exist_ok=True)
    lines = [
        "# ERP Report Catalog",
        "",
        f"Source: `{args.source_label}` &middot; {len(rows)} distinct report locations.",
        "",
        "| Report name | Webpage address | URL |",
        "|---|---|---|",
    ]
    for name, parent in rows:
        lines.append(
            f"| {escape_cell(name)} | {escape_cell(menu_path(parent))} | "
            f"{report_url(parent)} |"
        )
    lines.append("")

    target = os.path.join(args.out, "reports-access.md")
    with open(target, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines))

    for filename in LEGACY_OUTPUTS:
        legacy_path = os.path.join(args.out, filename)
        if os.path.isfile(legacy_path):
            os.remove(legacy_path)

    print(f"reports={len(rows)} -> {target} ({os.path.getsize(target):,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
