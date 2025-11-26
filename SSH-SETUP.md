# SSH Setup for Worker Deployments

The Worker/R2 deployment path still needs SSH so we can provision each piNAS with
the shared updater configuration. These steps assume you’re running commands
from `/Users/danielborrowman/Developer/Projects/piNAS` on your workstation.

## 1. Generate (or reuse) the deployment key

```bash
ssh-keygen -t ed25519 -C "pinas-deployment" -f ~/.ssh/pinas_deploy
```

Keep the private key on your workstation only. The helper scripts copy the
public key to each Pi.

## 2. Recommended flow (automated)

```bash
./scripts/manage-clients.sh add 192.168.1.226 pinas-226
./scripts/manage-clients.sh setup-key 192.168.1.226
```

`setup-key` will:

1. SSH in as `pi@192.168.1.226` using your password one time
2. Install the deployment public key into `~/.ssh/authorized_keys`
3. Generate a Worker client token, register it via `/admin/clients/:id`, and
   write `/etc/pinas/update-endpoint.env`

After it finishes, test:

```bash
./scripts/manage-clients.sh test 192.168.1.226
```

## 3. Manual fallback (if the helper can’t connect)

```bash
ssh pi@192.168.1.226 "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat ~/.ssh/pinas_deploy.pub | ssh pi@192.168.1.226 "cat >> ~/.ssh/authorized_keys"
ssh pi@192.168.1.226 "chmod 600 ~/.ssh/authorized_keys"
```

Then rerun `./scripts/manage-clients.sh setup-key <host>` so it can finish the
Worker registration and push the `/etc/pinas/update-endpoint.env` file.

## 4. Validate updater connectivity

```bash
ssh pi@192.168.1.226 sudo /usr/local/sbin/pinas-update.sh --check-only
ssh pi@192.168.1.226 sudo /usr/local/sbin/pinas-update.sh --force   # optional
```

If the script reports “update available” it will download directly from the
Worker-provided URL (Cloudflare R2).

## Troubleshooting

- **Permission denied**: ensure SSH is enabled (create `/boot/ssh` on the SD
  card) and the Pi is reachable.
- **Key rejected**: verify ownership/permissions (`~/.ssh` = 700,
  `authorized_keys` = 600) on the Pi.
- **Worker unauthorized**: re-run `setup-key` to rotate the token, or edit
  `/etc/pinas/update-endpoint.env` with the values shown in `docs/client-config.md`.

With SSH + Worker credentials in place, each piNAS can self-update via
`pinas-update.sh` without GitHub Actions.