# piNAS Deployment Solution – Secure Keys for Worker Deployments

The Cloudflare Worker pipeline relies on two credential types:

1. **Operator SSH key** – used by `scripts/manage-clients.sh setup-key` to log in
   once, install `authorized_keys`, and push `/etc/pinas/update-endpoint.env`.
2. **Worker client tokens** – generated per device and stored hashed inside the
   Worker’s KV namespace.

This guide covers how to create, store, and rotate those credentials safely.

---

## 1. Generate a Deployment SSH Key (workstation)

```bash
ssh-keygen -t ed25519 -C "pinas-deployment" -f ~/.ssh/pinas_deploy
```

- Private key: `~/.ssh/pinas_deploy` (keep on the workstation only)
- Public key: `~/.ssh/pinas_deploy.pub`

No SD card copies, no repo commits.

---

## 2. Install the Key on Each piNAS

Preferred workflow:

```bash
./scripts/manage-clients.sh setup-key 192.168.1.226
```

What this does:

1. SSH with your password one time
2. Appends the public key to `~pi/.ssh/authorized_keys`
3. Generates a Worker token, registers it via `PUT /admin/clients/<id>`, and
   writes `/etc/pinas/update-endpoint.env`

Manual fallback:

```bash
ssh pi@192.168.1.226 "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat ~/.ssh/pinas_deploy.pub | ssh pi@192.168.1.226 "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

After the manual install, rerun `setup-key` so the Worker token and config file
are still provisioned.

---

## 3. Worker Admin Secret & Client Tokens

- Store the Worker admin secret via `wrangler secret put ADMIN_TOKEN` (and the
  production override if needed).
- Export the same value locally as `WORKER_ADMIN_TOKEN` so `publish-artifact.sh`
  and `manage-clients.sh` can authenticate to `/admin/*`.
- Client tokens live only on the Pi (`/etc/pinas/update-endpoint.env`) and in the
  Worker’s KV store (hashed). To rotate:

  ```bash
  NEW_TOKEN=$(openssl rand -hex 32)
  curl -X PUT "$WORKER_URL/admin/clients/pinas-226" \
    -H "Authorization: Bearer $WORKER_ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"displayName\":\"pinas-226\",\"token\":\"$NEW_TOKEN\"}"
  ssh pi@192.168.1.226 "sudo tee /etc/pinas/update-endpoint.env >/dev/null <<'EOF'
  WORKER_URL=\"$WORKER_URL\"
  CLIENT_ID=\"pinas-226\"
  CLIENT_TOKEN=\"$NEW_TOKEN\"
  EOF
  sudo chmod 600 /etc/pinas/update-endpoint.env"
  ```

---

## 4. Optional: Legacy Pull-Based Updates

`pinas-pull-update.sh` now forwards to `pinas-update.sh`, so SSH access to
GitHub is no longer required. Only copy the private key to a client if you
explicitly need to clone the repo over SSH:

```bash
scp ~/.ssh/pinas_deploy pi@host:~/.ssh/pinas_deploy_key
ssh pi@host "chmod 600 ~/.ssh/pinas_deploy_key && \
  printf '\nHost github.com\n  IdentityFile ~/.ssh/pinas_deploy_key\n  IdentitiesOnly yes\n' >> ~/.ssh/config"
```

This is optional; the Worker + R2 flow does not rely on git.

---

## 5. Verification Checklist

```bash
./scripts/manage-clients.sh test 192.168.1.226
ssh pi@192.168.1.226 sudo /usr/local/sbin/pinas-update.sh --check-only
./scripts/publish-artifact.sh --dry-run
```

Ensure the Pi can reach the Worker, the update script reports the correct
version, and the publish helper can talk to R2 (dry-run skips uploads).

---

## Key Safety Rules

- ❌ Never commit `pinas_deploy` (private key) or the Worker admin token.
- ✅ Use `scripts/manage-clients.sh show-public-key` if you need to copy the key
  into another terminal.
- ✅ Remove tokens immediately when decommissioning a device (`curl -X DELETE
  $WORKER_URL/admin/clients/<id>`).
- ✅ Keep `/etc/pinas/update-endpoint.env` at `chmod 600`.

By keeping the SSH key on the operator machine and letting the Worker issue
per-client tokens, the new deployment flow stays secure even without GitHub
Actions.***