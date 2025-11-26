# piNAS Deployment System – Current State ✅

The GitHub Actions pipeline is paused because the Bruteforce-Group enterprise
account is on a billing hold, so deployments now flow through a pull-based
system that mirrors the Tesla-WebRTC approach: Cloudflare Workers coordinate the
rollout, R2 hosts release artifacts, and each piNAS polls for updates with an
API token.

## ✅ What’s Finished

1. **Cloudflare Worker stack**
   - `infra/cloudflare` contains the Worker, KV, and R2 bindings.
   - Admin API supports `/admin/clients` and `/admin/artifacts`.
   - Client API supports `/client/state` and `/artifact`.

2. **Artifact publisher**
   - `scripts/publish-artifact.sh` builds `dist/pinas-<version>.tar.gz`,
     uploads it to R2 via Wrangler, and updates Worker metadata.

3. **Client auto-update agent**
   - `sbin/pinas-update.sh` polls the Worker, downloads the artifact from R2,
     verifies SHA-256, installs it, and restarts services.
   - `docs/pinas-auto-update.{service,timer}` run the updater daily at 03:00.
   - `sbin/pinas-pull-update.sh` is now a compatibility shim that delegates to
     `pinas-update.sh`, so legacy cronjobs still work.

4. **Provisioning helpers**
   - `scripts/manage-clients.sh setup-key <host>` installs the SSH key, creates
     a client token, registers it with the Worker, and writes
     `/etc/pinas/update-endpoint.env`.
   - `scripts/setup-sdcard.sh` copies the new updater and reminds you to run the
     helper for Worker registration after first boot.

5. **Docs**
   - `docs/client-config.md`, `docs/deployment-setup.md`, `SETUP-CHECKLIST.md`,
     and `DEPLOY-KEY-SOLUTION.md` all describe the Worker/R2 flow.

## 🧰 Manual Tasks Still Needed

1. **Provision Cloudflare resources**
   - From `infra/cloudflare/`: `npm install`, create KV + R2 (`wrangler kv
     namespace create pinas-clients`, `wrangler r2 bucket create pinas-artifacts`),
     set the IDs in `wrangler.toml`, and deploy with `npm run deploy`.
   - Store an admin secret: `wrangler secret put ADMIN_TOKEN`.

2. **Set local environment variables**
   ```bash
   export WORKER_URL="https://pinas-deployer.example.workers.dev"
   export WORKER_ADMIN_TOKEN="<same value stored with wrangler>"
   export PINAS_R2_BUCKET="pinas-artifacts"
   ```

3. **Register each device**
   ```bash
   ./scripts/manage-clients.sh add 192.168.1.226 pinas-226
   ./scripts/manage-clients.sh setup-key 192.168.1.226
   ./scripts/manage-clients.sh test 192.168.1.226
   ```

4. **Publish builds**
   ```bash
   ./scripts/publish-artifact.sh --version v2025.11.26.01
   ```
   The script prints the R2 object key and checksum; clients will pick it up on
   their next poll or immediately via `sudo /usr/local/sbin/pinas-update.sh --force`.

## 🚀 Operating the System

- **Add a client**: `./scripts/manage-clients.sh add <ip> <hostname>`
- **Provision Worker credentials**: `./scripts/manage-clients.sh setup-key <ip>`
- **Check health**: `./scripts/manage-clients.sh status`
- **Force update a Pi**: `ssh pi@host sudo /usr/local/sbin/pinas-update.sh --force`
- **Publish a build**: `./scripts/publish-artifact.sh` (uploads to R2 + notifies Worker)
- **Monitor**: Worker logs (via `wrangler tail`) and `/var/log/pinas-update.log` on each Pi

## 📦 Repository Highlights

```
piNAS/
├── infra/cloudflare/          # Worker + Wrangler config
├── scripts/publish-artifact.sh
├── scripts/manage-clients.sh
├── config/update-endpoint.env.example
├── sbin/pinas-update.sh
├── docs/client-config.md
└── docs/deployment-setup.md
```

The system now runs entirely through Cloudflare Worker + R2. Once the enterprise
billing hold is cleared you can still re-enable the GitHub workflow, but no part
of the new deployment path depends on GitHub Actions. 🎉