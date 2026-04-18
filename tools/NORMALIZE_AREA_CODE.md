## One-time: Normalize `properties.areaCode`

### Prerequisites

- Install deps:

```bash
cd /Users/macbookprom1/Desktop/aqarai_app
npm i -D firebase-admin
```

### Auth

Use a service account key (recommended for one-time maintenance):

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/absolute/path/to/service-account.json"
```

### Dry-run (safe)

```bash
node tools/normalize_area_code.js --project aqarai-caf5d --dry-run
```

### Commit (writes only `areaCode`)

```bash
node tools/normalize_area_code.js --project aqarai-caf5d --commit
```

Optional:
- Add `--update-updatedAt` if you want to bump `updatedAt` too.
- Use `--max-docs 1000` to limit scope.
- Use `--page-size 200` if you hit timeouts.

### Reversibility

Each run creates a JSONL log in `tools/areaCode-normalization-<project>-<timestamp>.jsonl`.
You can use this file to revert by applying `before.areaCode` back to each `docId`.

