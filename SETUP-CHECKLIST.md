# piNAS Worker Deployment Setup Checklist

Follow these steps to enable the new Cloudflare Worker + R2 deployment flow. You
can complete them in a single terminal session on your workstation.

## 1. Generate / reuse the deployment SSH key

```bash
ssh-keygen -t ed25519 -C "pinas-deployment" -f ~/.ssh/pinas_deploy
```

The private key stays on your workstation. The `setup-key` helper copies the
public key to each Pi automatically.

## 2. Deploy the Worker stack

```bash
cd infra/cloudflare
npm install
wrangler kv namespace create pinas-clients
wrangler kv namespace create pinas-clients --preview
wrangler r2 bucket create pinas-artifacts
wrangler r2 bucket create pinas-artifacts-dev
# Update wrangler.toml with the IDs above, then:
wrangler secret put ADMIN_TOKEN
npm run deploy -- --env production
```

## 3. Export the Worker credentials locally

```bash
export WORKER_URL="https://pinas-deployer.example.workers.dev"
export WORKER_ADMIN_TOKEN="<matching ADMIN_TOKEN>"
export PINAS_R2_BUCKET="pinas-artifacts"
```

Keep these exports in your shell (or add them to your shell profile) before
using the helper scripts.

## 4. Register each client

```bash
./scripts/manage-clients.sh add 192.168.1.226 pinas-226
./scripts/manage-clients.sh setup-key 192.168.1.226
./scripts/manage-clients.sh test 192.168.1.226
```

`setup-key` will:

1. Install the SSH deployment key on the Pi
2. Generate a Worker token and register `client_id`
3. Write `/etc/pinas/update-endpoint.env`

## 5. Publish an artifact

```bash
./scripts/publish-artifact.sh --version v2025.11.26.01
```

The helper builds `dist/pinas-<version>.tar.gz`, uploads it to R2, and calls the
Worker admin API so that every client can see the new metadata.

## 6. Trigger/verify updates

- **Automatic**: `pinas-auto-update.timer` runs nightly at 03:00.
- **Manual**: `ssh pi@host sudo /usr/local/sbin/pinas-update.sh --force`.
- **Logs**: `/var/log/pinas-update.log` on each Pi + `wrangler tail` for Worker
  requests.

## Quick reference

| Task | Command |
|------|---------|
| List clients | `./scripts/manage-clients.sh list` |
| Add client | `./scripts/manage-clients.sh add <ip> <host>` |
| Provision key + Worker token | `./scripts/manage-clients.sh setup-key <ip>` |
| Publish release | `./scripts/publish-artifact.sh [--version vX.Y.Z]` |
| Check Worker health | `curl "$WORKER_URL/healthz"` |
| Force update on Pi | `ssh pi@host sudo /usr/local/sbin/pinas-update.sh --force` |

## Troubleshooting

- **Worker auth errors**: confirm `WORKER_URL` and `WORKER_ADMIN_TOKEN` are set
  locally and in the Worker secrets.
- **Client unauthorized**: rerun `setup-key` to mint a fresh token or update
  `/etc/pinas/update-endpoint.env` manually.
- **Artifact missing**: run `wrangler r2 object list pinas-artifacts` to confirm
  the upload succeeded, then call the admin API again:
  ```bash
  curl -X POST "$WORKER_URL/admin/artifacts" \
    -H "Authorization: Bearer $WORKER_ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"version":"v2025.11.26.01","objectKey":"v2025.11.26.01/pinas-v2025.11.26.01.tar.gz","sha256":"...","size":1234}'
  ```

Once the steps above are complete, every piNAS automatically checks in with the
Worker, downloads the correct artifact from R2, and installs it without relying
on GitHub Actions. 🎉