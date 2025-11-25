# piNAS Deployment Solution – Secure GitHub Deploy Keys

The deployment workflow now supports two complementary paths:

1. **GitHub Actions → piNAS (push model)** – Actions connects to each client over SSH using the private key stored as a _repository secret_ (`PINAS_SSH_PRIVATE_KEY`).  
2. **piNAS → GitHub (pull model, optional)** – Each piNAS can keep its own deploy key under `/home/pi/.ssh/pinas_deploy_key` in order to run `pinas-pull-update.sh`.

In both cases the private key must stay off the SD card and outside the repository. Use the steps below to provision keys safely.

---

## 1. Generate a Key Pair (local workstation)

```bash
ssh-keygen -t ed25519 -C "pinas-deployment@github.com" -f ~/.ssh/pinas_deploy
```

- Keep `~/.ssh/pinas_deploy` (private) on your workstation only.
- The matching public key lives at `~/.ssh/pinas_deploy.pub`.

## 2. Register the Key with GitHub

1. **Deploy Key (read-only)** – Go to your repository → _Settings → Deploy keys → Add deploy key_  
   - Title: `piNAS Deployment`  
   - Key: output of `cat ~/.ssh/pinas_deploy.pub`  
   - Allow read-only access (recommended).
2. **Actions Secret** – Go to _Settings → Secrets and variables → Actions_ and create `PINAS_SSH_PRIVATE_KEY` with the contents of `~/.ssh/pinas_deploy`.  
   This allows the GitHub Actions workflow to SSH into each client without ever exposing the key publicly.

## 3. Install the Public Key on Each piNAS

Use the helper, or run the commands manually:

```bash
# Helper (preferred)
./scripts/manage-clients.sh setup-key 192.168.1.226

# Manual equivalent
ssh pi@192.168.1.226 "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat ~/.ssh/pinas_deploy.pub | ssh pi@192.168.1.226 "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

The helper also updates `clients.json`, tests connectivity, and refreshes the GitHub Actions workflow matrix (`sync-workflow`).

## 4. (Optional) Enable Pull-Based Updates on the Pi

If you want the device itself to pull updates (for example, to run `pinas-pull-update.sh` nightly), copy the **same private key** to the Pi **after** the machine is trusted:

```bash
scp ~/.ssh/pinas_deploy pi@192.168.1.226:~/.ssh/pinas_deploy_key
ssh pi@192.168.1.226 "chmod 600 ~/.ssh/pinas_deploy_key && \
  printf '\nHost github.com\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/pinas_deploy_key\n  IdentitiesOnly yes\n' >> ~/.ssh/config"
```

This step is optional; the default `pinas-update.sh` script downloads signed release tarballs and does not require SSH access.

## 5. Verify Everything

```bash
# From your workstation
./scripts/manage-clients.sh test 192.168.1.226
./scripts/manage-clients.sh sync-workflow

# Trigger a deployment
git commit -am "test: deployment pipeline"
git push origin main
```

Then watch the “Build and Deploy piNAS” workflow in the Actions tab. Each client should report a successful deployment.

---

### Key Safety Checklist

- ❌ **Never** copy the private key into this repository or onto the SD card.
- ✅ Store long‑lived keys only in: `~/.ssh/pinas_deploy` (workstation), GitHub secrets, or the target piNAS (if pull-based updates are required).
- ✅ Rotate the key from `scripts/manage-clients.sh show-public-key` whenever a device is lost or compromised.

Following this process keeps the GitHub Actions pipeline, manual deployments, and any optional pull-based updates aligned without leaking credentials.