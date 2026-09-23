#!/usr/bin/env python3
"""Generate RAG-ready Markdown from the ERP report-access dataset.

Input : ``rep_converted.deduped.json`` (host copy on the Desktop)
Output: ``.armin/rag/generated/reports-access/``

Files produced (all plain Markdown, no front-matter so any RAG chunker can split them):

* ``reports-access-index.md``        - compact catalog: report title -> menu path -> access count
* ``reports-access-by-menu.md``      - full data grouped by ERP menu path
* ``reports-access-by-personnel.md`` - full data grouped by employee

Only ``NameSystem``, ``ParentSystemtxt`` and ``FullNamePersonel`` are used; the decorative
kashida (U+0640) padding inside the ERP menu paths is removed for readability.

Usage::

    python scripts/generate_reports_access_md.py \
        --json "C:/Users/armin/Desktop/rep_converted.deduped.json" \
        --out ".armin/rag/generated/reports-access"
"""

from __future__ import annotations

import argparse
import json
import os
from collections import Counter, defaultdict

FIELDS = ("NameSystem", "ParentSystemtxt", "FullNamePersonel")


def clean(text: str) -> str:
    """Drop kashida padding / zero-width marks and collapse whitespace."""
    if not text:
        return ""
    out = text.replace("\u0640", "")
    out = out.replace("\u200c", " ").replace("\u200f", "").replace("\u200e", "")
    return " ".join(out.split())


def menu_path(parent: str) -> str:
    """``الف---ب---ج`` -> ``الف › ب › ج`` (readable for the LLM and for humans)."""
    parts = [clean(part) for part in clean(parent).split("---")]
    return " \u203a ".join(part for part in parts if part)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--source-label", default="rep_converted.deduped.json")
    args = parser.parse_args()

    with open(args.json, encoding="utf-8") as handle:
        records = json.load(handle)

    rows = []
    seen = set()
    for record in records:
        name = clean(str(record.get("NameSystem", "")))
        path = menu_path(str(record.get("ParentSystemtxt", "")))
        person = clean(str(record.get("FullNamePersonel", "")))
        if not (name or path or person):
            continue
        key = (name, path, person)
        if key in seen:
            continue
        seen.add(key)
        rows.append(key)

    rows.sort(key=lambda row: (row[0], row[1], row[2]))
    os.makedirs(args.out, exist_ok=True)
    header_note = (
        f"Source: `{args.source_label}` &middot; {len(records)} raw rows &middot; "
        f"{len(rows)} distinct (report, menu path, employee) rows."
    )

    # --- index: one line per report -------------------------------------------
    per_report: dict[tuple[str, str], set[str]] = defaultdict(set)
    for name, path, person in rows:
        per_report[(name, path)].add(person)

    index_lines = [
        "# ERP Report Access Index",
        "",
        header_note,
        "",
        f"Distinct reports: **{len(per_report)}** &middot; employees: "
        f"**{len({person for _, _, person in rows})}**.",
        "",
        "Each line lists a report, its ERP menu path, and how many employees can reach it.",
        "",
        "| # | Report (NameSystem) | Menu path | Employees |",
        "|---|---------------------|-----------|-----------|",
    ]
    for position, ((name, path), people) in enumerate(
        sorted(per_report.items(), key=lambda item: (-len(item[1]), item[0][0])), start=1
    ):
        index_lines.append(f"| {position} | {name} | {path} | {len(people)} |")
    index_lines.append("")

    # --- by menu path ----------------------------------------------------------
    by_menu: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for name, path, person in rows:
        by_menu[path].append((name, person))

    menu_lines = ["# ERP Report Access by Menu Path", "", header_note, ""]
    for path in sorted(by_menu, key=lambda value: (value.count("\u203a"), value)):
        entries = by_menu[path]
        menu_lines += [
            f"## {path or '(no menu path)'}",
            "",
            f"Reports: **{len({name for name, _ in entries})}** &middot; access rows: {len(entries)}.",
            "",
            "| Report (NameSystem) | Employees with access |",
            "|---------------------|-----------------------|",
        ]
        per_name: dict[str, set[str]] = defaultdict(set)
        for name, person in entries:
            per_name[name].add(person)
        for name in sorted(per_name):
            people = ", ".join(sorted(per_name[name]))
            menu_lines.append(f"| {name} | {people} |")
        menu_lines.append("")

    # --- by employee -----------------------------------------------------------
    by_person: dict[str, Counter] = defaultdict(Counter)
    for name, path, person in rows:
        by_person[person][path] += 1

    person_lines = ["# ERP Report Access by Employee", "", header_note, ""]
    for person in sorted(by_person):
        counter = by_person[person]
        person_lines += [
            f"## {person}",
            "",
            f"Reachable reports: **{sum(counter.values())}** across {len(counter)} menu paths.",
            "",
            "| Menu path | Reports |",
            "|-----------|---------|",
        ]
        for path, count in sorted(counter.items(), key=lambda item: (-item[1], item[0])):
            person_lines.append(f"| {path or '(no menu path)'} | {count} |")
        person_lines.append("")

    written = {}
    for filename, lines in (
        ("reports-access-index.md", index_lines),
        ("reports-access-by-menu.md", menu_lines),
        ("reports-access-by-personnel.md", person_lines),
    ):
        target = os.path.join(args.out, filename)
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(lines) + "\n")
        written[filename] = os.path.getsize(target)

    for filename, size in written.items():
        print(f"{filename}: {size:,} bytes -> {os.path.join(args.out, filename)}")
    print(f"rows={len(rows)} reports={len(per_report)} employees={len(by_person)} paths={len(by_menu)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
