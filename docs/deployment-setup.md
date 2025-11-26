# piNAS Deployment Setup

GitHub Actions is currently blocked by the enterprise billing hold, so piNAS now
ships updates through a Cloudflare Worker + R2 pipeline. This guide walks
through the entire flow—from provisioning Cloudflare resources to publishing
artifacts and registering clients.

---

## Architecture

1. `scripts/publish-artifact.sh` builds `dist/pinas-<version>.tar.gz`, uploads it
   to R2, and notifies the Worker with metadata (version/object key/SHA/size).
2. The Worker stores the latest artifact metadata plus client records in Workers
   KV.
3. Each piNAS runs `pinas-update.sh`, POSTs to `/client/state`, and, if a new
   version is available, downloads it via `/artifact?objectKey=...`.

```
workstation -> wrangler r2 object put -> R2 bucket
workstation -> POST /admin/artifacts -> Worker -> KV metadata
piNAS -> POST /client/state -> Worker -> JSON instructions
piNAS -> GET /artifact?... -> Worker -> R2 stream
```

---

## 1. Provision Cloudflare Resources

```bash
cd infra/cloudflare
npm install
wrangler kv namespace create pinas-clients
wrangler kv namespace create pinas-clients --preview
wrangler r2 bucket create pinas-artifacts
wrangler r2 bucket create pinas-artifacts-dev
```

Update `wrangler.toml` with the namespace IDs/bucket names and deploy:

```bash
wrangler secret put ADMIN_TOKEN
wrangler secret put --env production ADMIN_TOKEN   # optional
npm run deploy -- --env production
```

---

## 2. Set Local Environment Variables

Add these exports (or put them in `.envrc` / shell profile) before using any
helper scripts:

```bash
export WORKER_URL="https://pinas-deployer.example.workers.dev"
export WORKER_ADMIN_TOKEN="<same value stored via wrangler>"
export PINAS_R2_BUCKET="pinas-artifacts"
```

`publish-artifact.sh` and `scripts/manage-clients.sh` read these automatically.

---

## 3. Generate the Deployment SSH Key

```bash
ssh-keygen -t ed25519 -C "pinas-deployment" -f ~/.ssh/pinas_deploy
```

Keep the private key on the operator machine only. The helper scripts copy the
public key to each piNAS.

---

## 4. Register Clients

```bash
./scripts/manage-clients.sh add 192.168.1.226 pinas-226
./scripts/manage-clients.sh setup-key 192.168.1.226   # installs SSH key + Worker token
./scripts/manage-clients.sh test 192.168.1.226        # sanity check
```

`setup-key` performs the following:

1. SSH (password one time) and append the deployment key to
   `~pi/.ssh/authorized_keys`
2. Generate a random client token, call `PUT $WORKER_URL/admin/clients/<id>`, and
   store the hashed token in KV
3. Write `/etc/pinas/update-endpoint.env` with `WORKER_URL`, `CLIENT_ID`, and
   `CLIENT_TOKEN`

To rotate a token later, rerun `setup-key` or use the curl snippet in
`docs/client-config.md`.

---

## 5. Publish a Release

```bash
./scripts/publish-artifact.sh --version v2025.11.26.01
```

The helper:

1. Creates `dist/pinas-<version>/` with scripts, docs, configs, and metadata
2. Packages it into `dist/pinas-<version>.tar.gz`
3. Uploads to `r2://$PINAS_R2_BUCKET/<version>/pinas-<version>.tar.gz`
4. Calls `POST $WORKER_URL/admin/artifacts`:

   ```json
   {
     "version": "v2025.11.26.01",
     "objectKey": "v2025.11.26.01/pinas-v2025.11.26.01.tar.gz",
     "sha256": "...",
     "size": 123456789
   }
   ```

If you omit `--version`, a date-based version (e.g., `v2025.11.26.01`) is
generated automatically.

---

## 6. Client Update Flow

### Manual

```bash
ssh pi@pinas-226 sudo /usr/local/sbin/pinas-update.sh --check-only
ssh pi@pinas-226 sudo /usr/local/sbin/pinas-update.sh --force
```

### Scheduled

`docs/pinas-auto-update.timer` runs daily at 03:00 with a randomized delay. The
installer copies this service during `finalize_install`, so every piNAS checks
in automatically.

### What the Updater Does

1. Loads `/etc/pinas/update-endpoint.env`
2. POSTs `{currentVersion, desiredVersion?}` to `/client/state`
3. Downloads the tarball from `/artifact?...`
4. Validates the SHA-256 hash
5. Backs up `/usr/local/pinas` and installs the new package
6. Restarts `pinas-dashboard.service` and `pinas-usb-gadget.service`
7. Logs everything to `/var/log/pinas-update.log`

---

## Monitoring & Troubleshooting

| Component | Command |
|-----------|---------|
| Worker logs | `cd infra/cloudflare && wrangler tail --env production` |
| R2 objects | `cd infra/cloudflare && wrangler r2 object list pinas-artifacts` |
| Client logs | `ssh pi@host tail -f /var/log/pinas-update.log` |

**Common issues**

- `unauthorized` from Worker: rerun `setup-key` to rotate the client token or
  update `/etc/pinas/update-endpoint.env`.
- `artifact not found`: verify the object key printed by
  `publish-artifact.sh` exists (`wrangler r2 object get ...`).
- Network unreachable: `pinas-update.sh` warns if 1.1.1.1 can’t be reached but
  continues with the Worker call.

---

## Legacy GitHub Actions

`.github/workflows/deploy.yml` remains in the repo for reference but will not run
until the organization resolves the billing hold. The Worker pipeline described
above is now the primary path for deployments.

---

## Quick Reference

```
export WORKER_URL="https://pinas-deployer.example.workers.dev"
export WORKER_ADMIN_TOKEN="<token>"
export PINAS_R2_BUCKET="pinas-artifacts"

# Add & provision client
./scripts/manage-clients.sh add 192.168.1.226 pinas-226
./scripts/manage-clients.sh setup-key 192.168.1.226

# Publish release
./scripts/publish-artifact.sh --version v2025.11.26.01

# Force update on a Pi
ssh pi@pinas-226 sudo /usr/local/sbin/pinas-update.sh --force
```

With Cloudflare Workers handling coordination and R2 storing artifacts, piNAS
deployments are now self-serve: the worker keeps metadata, each device polls for
updates, and no GitHub Actions capacity is required.***