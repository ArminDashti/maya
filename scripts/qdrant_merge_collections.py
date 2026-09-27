#!/usr/bin/env python3
"""Merge several Qdrant collections into ONE single collection.

Maya keeps exactly one Qdrant collection (default: ``maya``). Everything - Open
WebUI knowledge chunks, Open WebUI file chunks, and the standalone ERP report
rows - lives there and is kept apart by the ``tenant_id`` payload field, which is
the same isolation Open WebUI's multi-tenant client uses.

Run it from any machine that can reach Qdrant, e.g. inside the Open WebUI
container::

    docker cp scripts/qdrant_merge_collections.py maya-openwebui:/tmp/merge.py
    docker exec maya-openwebui python3 /tmp/merge.py \
        --sources maya_knowledge,maya_files,erp_reports \
        --tenant-override erp_reports=erp_reports

The script is idempotent: re-running upserts the same point IDs (Qdrant dedupes
by ID), so it is safe to run again after a partial failure. Sources are only
dropped with ``--delete-sources``, after the target count was verified.
"""

from __future__ import annotations

import argparse
import sys
from urllib.parse import quote

import requests

DEFAULT_TARGET = 'maya'
DEFAULT_SOURCES = 'maya_knowledge,maya_files,erp_reports'
# Open WebUI reads payload['text'] / payload['metadata'] from every point.
TEXT_FIELDS = ('NameSystem', 'ParentSystemtxt')
ERP_BASE_URL = 'http://erp.dpdc.co:8880/'


def api(url: str, method: str = 'GET', json_body: dict | None = None, allow_missing: bool = False) -> dict:
    response = requests.request(method, url, json=json_body, timeout=120)
    if allow_missing and response.status_code == 404:
        # Qdrant answers 404 for "collection does not exist" - callers treat
        # {'result': None} as "missing". Only opt-in: a 404 on a write must fail.
        return {'result': None}
    response.raise_for_status()
    return response.json()


def ensure_collection(base: str, target: str, dimension: int) -> None:
    if api(f'{base}/collections/{target}', allow_missing=True).get('result'):
        print(f'collection {target}: already exists')
        return

    print(f'collection {target}: creating ({dimension}-d cosine)')
    api(
        f'{base}/collections/{target}',
        'PUT',
        {
            'vectors': {'size': dimension, 'distance': 'Cosine', 'on_disk': False},
            # Same shape as open_webui.retrieval.vector.dbs.qdrant_multitenancy:
            # global HNSW off (m=0), partitioned via the tenant_id payload index.
            'hnsw_config': {
                'm': 0,
                'ef_construct': 100,
                'full_scan_threshold': 10000,
                'payload_m': 16,
                'on_disk': False,
            },
            'on_disk_payload': True,
        },
    )
    for field, schema in (
        ('tenant_id', {'type': 'keyword', 'is_tenant': True, 'on_disk': False}),
        ('metadata.hash', {'type': 'keyword', 'on_disk': False}),
        ('metadata.file_id', {'type': 'keyword', 'on_disk': False}),
    ):
        api(
            f'{base}/collections/{target}/index',
            'PUT',
            {'field_name': field, 'field_schema': schema},
        )
        print(f'collection {target}: indexed {field}')


def augment(payload: dict, default_tenant: str | None) -> dict:
    """Make a point readable by both Open WebUI and the ERP filter."""
    payload = dict(payload or {})
    tenant = payload.get('tenant_id') or default_tenant
    if not tenant:
        raise SystemExit(f'point has no tenant_id and no --tenant-override given: {payload}')
    payload['tenant_id'] = tenant
    if tenant == 'erp_reports':
        payload.pop('FullNamePersonel', None)
        parent = str(payload.get('ParentSystemtxt') or '').strip()
        path = quote(parent.lstrip('/'), safe='/-') if parent else ''
        payload['URL'] = payload.get('URL') or (f'{ERP_BASE_URL}{path}' if path else '')
        payload['text'] = ' | '.join(
            str(payload.get(field) or '') for field in TEXT_FIELDS
            if payload.get(field)
        )
        payload['metadata'] = {'source': 'erp_reports', 'kind': 'erp_row'}
        return payload
    if 'text' not in payload or not payload['text']:
        payload['text'] = ' | '.join(str(payload.get(f) or '') for f in TEXT_FIELDS)
    if 'metadata' not in payload or not isinstance(payload['metadata'], dict):
        payload['metadata'] = {k: v for k, v in payload.items() if k in TEXT_FIELDS}
    return payload


def merge(base: str, source: str, target: str, default_tenant: str | None, limit: int) -> int:
    info = api(f'{base}/collections/{source}', allow_missing=True).get('result')
    if not info:
        print(f'{source}: missing - skipped')
        return 0
    total = info['points_count']
    dimension = info['config']['params']['vectors']['size']

    offset = None
    moved = 0
    while True:
        body = {'limit': limit, 'with_payload': True, 'with_vector': True}
        if offset is not None:
            body['offset'] = offset
        page = api(f'{base}/collections/{source}/points/scroll', 'POST', body)['result']
        points = page.get('points') or []
        if not points:
            break
        api(
            # Qdrant 1.19 exposes upsert as PUT /collections/{name}/points
            # (the /points/upsert alias 404s); wait=true so counts are exact.
            f'{base}/collections/{target}/points?wait=true',
            'PUT',
            {
                'points': [
                    {
                        'id': p['id'],
                        'vector': p['vector'],
                        'payload': augment(p.get('payload'), default_tenant),
                    }
                    for p in points
                ]
            },
        )
        moved += len(points)
        offset = page.get('next_page_offset')
        if offset is None:
            break

    print(f'{source}: {moved}/{total} points -> {target} (dim={dimension})')
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qdrant-url', default='http://host.docker.internal:6333')
    parser.add_argument('--target', default=DEFAULT_TARGET)
    parser.add_argument('--sources', default=DEFAULT_SOURCES, help='comma separated')
    parser.add_argument(
        '--tenant-override',
        action='append',
        default=[],
        metavar='SOURCE=TENANT',
        help='tenant_id for source points that do not carry one (repeatable)',
    )
    parser.add_argument('--batch', type=int, default=256)
    parser.add_argument('--delete-sources', action='store_true')
    args = parser.parse_args()

    base = args.qdrant_url.rstrip('/')
    overrides = dict(item.split('=', 1) for item in args.tenant_override)

    existing = {c['name'] for c in api(f'{base}/collections')['result']['collections']}
    if args.target not in existing and not any(
        s in existing for s in args.sources.split(',')
    ):
        print('nothing to merge', file=sys.stderr)
        return 1

    # Dimension comes from the first source that exists.
    dimension = 384
    for source in args.sources.split(','):
        info = api(f'{base}/collections/{source}', allow_missing=True).get('result')
        if info:
            dimension = info['config']['params']['vectors']['size']
            break
    ensure_collection(base, args.target, dimension)

    expected = 0
    for source in args.sources.split(','):
        if source == args.target:
            continue
        expected += merge(base, source, args.target, overrides.get(source), args.batch)

    target_count = api(f'{base}/collections/{args.target}')['result']['points_count']
    source_total = sum(
        (api(f'{base}/collections/{s}', allow_missing=True).get('result') or {'points_count': 0})[
            'points_count'
        ]
        for s in args.sources.split(',')
        if s != args.target
    )
    print(f'{args.target}: {target_count} points (sources still hold {source_total})')
    if source_total and target_count < expected:
        print(f'expected at least {expected} points - NOT deleting sources', file=sys.stderr)
        return 2

    if args.delete_sources:
        for source in args.sources.split(','):
            if source == args.target:
                continue
            api(f'{base}/collections/{source}', 'DELETE')
            print(f'deleted source collection {source}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
