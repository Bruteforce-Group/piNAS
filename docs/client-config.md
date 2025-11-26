# piNAS Client Configuration

GitHub Actions deployments are blocked while the organization is on a billing
hold, so piNAS now uses a pull-based flow backed by Cloudflare Worker/R2.

Each client periodically calls the Worker to retrieve metadata and downloads the
release artifact through the same Worker (which streams from R2). This document
explains how to onboard clients and publish new builds.

## Prerequisites

1. Deploy the Worker in `infra/cloudflare/` (see that folder's README).
2. Create:
   - An R2 bucket for artifacts (e.g. `pinas-artifacts`)
   - A Workers KV namespace for client metadata
3. Store the Worker admin secret with `wrangler secret put ADMIN_TOKEN`.
4. Export the Worker values locally before using the helper scripts:

   ```bash
   export WORKER_URL="https://pinas-deployer.example.workers.dev"
   export WORKER_ADMIN_TOKEN="<same random string stored via wrangler>"
   ```

5. Generate (or reuse) the deployment SSH key:

   ```bash
   ssh-keygen -t ed25519 -C "pinas-deployment" -f ~/.ssh/pinas_deploy
   ```

## Adding a client

1. Register it in `clients.json`:

   ```bash
   ./scripts/manage-clients.sh add 192.168.1.226 pinas-226
   ```

   The helper automatically gives every client a `client_id` slug.

2. Provision SSH and Worker credentials:

   ```bash
   ./scripts/manage-clients.sh setup-key 192.168.1.226
   ```

   This command:

   - installs the deployment public key into `~pi/.ssh/authorized_keys`
   - generates a unique `CLIENT_TOKEN`
   - registers the client through `PUT $WORKER_URL/admin/clients/<client_id>`
   - writes `/etc/pinas/update-endpoint.env` on the Pi:

     ```bash
     WORKER_URL="https://pinas-deployer.example.workers.dev"
     CLIENT_ID="pinas-226"
     CLIENT_TOKEN="b2eb9d5a..."
     ```

3. Sanity-check access:

   ```bash
   ./scripts/manage-clients.sh test 192.168.1.226
   ```

## Publishing a release

Run the helper from repo root:

```bash
export PINAS_R2_BUCKET="pinas-artifacts"
export PINAS_WORKER_URL="$WORKER_URL"
export PINAS_WORKER_ADMIN_TOKEN="$WORKER_ADMIN_TOKEN"
./scripts/publish-artifact.sh         # pass --version vX.Y.Z to override
```

It will:

1. Build `dist/pinas-<version>.tar.gz`
2. Upload it to `r2://$PINAS_R2_BUCKET/<version>/pinas-<version>.tar.gz`
3. Call `POST $WORKER_URL/admin/artifacts` with the version, object key, SHA-256,
   and size

Once the metadata is published, every piNAS sees the update during its next poll
or when `sudo pinas-update --force` runs manually.

## Manual update trigger

SSH to a client and run:

```bash
sudo /usr/local/sbin/pinas-update --force
```

The script now:

1. Loads `/etc/pinas/update-endpoint.env`
2. POSTs to `$WORKER_URL/client/state`
3. Downloads the artifact through `GET $WORKER_URL/artifact?objectKey=...`
4. Verifies the Worker-provided checksum
5. Installs the package and restarts the piNAS services

## Rotating client tokens

1. Generate a new token:

   ```bash
   NEW_TOKEN=$(openssl rand -hex 32)
   ```

2. Update the Worker record:

   ```bash
   curl -X PUT "$WORKER_URL/admin/clients/pinas-226" \
     -H "Authorization: Bearer $WORKER_ADMIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"displayName\":\"pinas-226\",\"token\":\"$NEW_TOKEN\"}"
   ```

3. Update the file on the Pi:

   ```bash
   ssh pi@192.168.1.226 <<EOF
   sudo tee /etc/pinas/update-endpoint.env >/dev/null <<'CONF'
   WORKER_URL="$WORKER_URL"
   CLIENT_ID="pinas-226"
   CLIENT_TOKEN="$NEW_TOKEN"
   CONF
   sudo chmod 600 /etc/pinas/update-endpoint.env
   EOF
   ```

## Legacy GitHub Actions workflow

`.github/workflows/deploy.yml` is left in place for reference but is no longer
invoked while the GitHub billing hold remains. All new deployments should rely
on the Worker/R2 workflow described above.