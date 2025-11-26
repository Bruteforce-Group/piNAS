# piNAS Cloudflare Worker

This Worker replaces the GitHub Actions deploy pipeline. It stores piNAS release
artifacts in R2, keeps per-device credentials in Workers KV, and exposes a
minimal API that each client polls for updates.

## Components

- **R2 bucket** (`ARTIFACTS_BUCKET` binding) – stores tarballs produced by
  `scripts/publish-artifact.sh`.
- **Workers KV** (`CLIENTS_KV` binding) – tracks client metadata, hashed tokens,
  and the latest artifact metadata.
- **Worker secrets** – provisioning and download tokens are stored via
  `wrangler secret put ADMIN_TOKEN` (admin API) and per-client shared secrets.

## Setup

1. Install dependencies:

   ```bash
   cd infra/cloudflare
   npm install
   ```

2. Provision the KV namespace and R2 bucket (replace the IDs in
   `wrangler.toml` with the output):

   ```bash
   wrangler kv namespace create pinas-clients
   wrangler kv namespace create pinas-clients --preview
   wrangler r2 bucket create pinas-artifacts
   wrangler r2 bucket create pinas-artifacts-dev
   ```

3. Configure secrets:

   ```bash
   wrangler secret put ADMIN_TOKEN
   # Optional per-environment overrides:
   wrangler secret put --env production ADMIN_TOKEN
   ```

4. Deploy:

   ```bash
   npm run deploy -- --env production
   ```

## Admin API

All admin endpoints require `Authorization: Bearer <ADMIN_TOKEN>`.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/admin/clients` | GET | List registered clients (token hash omitted). |
| `/admin/clients/:id` | PUT | Register/update a client. Body requires `token`. |
| `/admin/clients/:id` | DELETE | Remove a client. |
| `/admin/artifacts` | GET | Show the latest artifact metadata. |
| `/admin/artifacts` | POST | Publish new metadata after uploading to R2. |

Example client registration payload:

```json
{
  "displayName": "pinas-office",
  "token": "<generated secret>",
  "notes": "Rack 2"
}
```

## Client API

Clients authenticate with `X-Client-Id` and `X-Client-Token` headers.

- `POST /client/state` – send current version/metrics and receive update
  instructions (JSON response includes `updateAvailable`, `latest`, and the
  `downloadPath`).
- `GET /artifact?objectKey=<key>` – download the tarball referenced in
  `latest.objectKey`.

The `scripts/manage-clients.sh setup-key` flow provisions tokens, registers the
client via the admin API, and writes `/etc/pinas/update-endpoint.env` on the Pi.

## Artifact publishing

Use `scripts/publish-artifact.sh` from the repo root. It builds the tarball,
computes checksums, uploads to R2 via `wrangler r2 object put`, and notifies the
Worker with the new metadata.

Environment variables consumed by the helper script:

- `PINAS_R2_BUCKET` – the R2 bucket name (default `pinas-artifacts`).
- `PINAS_WORKER_URL` – base URL of the deployed Worker (e.g.
  `https://pinas-deployer.example.workers.dev`).
- `PINAS_WORKER_ADMIN_TOKEN` – same value stored in `ADMIN_TOKEN` secret.

## Local testing

```bash
npm run dev
curl -H "Authorization: Bearer $ADMIN_TOKEN" http://localhost:8787/admin/artifacts
```

See `scripts/manage-clients.sh` and `docs/client-config.md` for the operational
runbook.
