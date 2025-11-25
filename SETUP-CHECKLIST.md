# piNAS Automatic Deployment Setup Checklist

Complete these steps to enable automatic deployment to your piNAS clients when you commit to main.

## ✅ Setup Steps

### 1. Generate SSH Deployment Key
```bash
ssh-keygen -t ed25519 -C "pinas-deployment@github.com" -f ~/.ssh/pinas_deploy
```

### 2. Add Private Key to GitHub Secrets
- Go to: https://github.com/Bruteforce-Group/piNAS/settings/secrets/actions
- Click "New repository secret"
- Name: `PINAS_SSH_PRIVATE_KEY`
- Value: Paste contents of `~/.ssh/pinas_deploy` (private key)

### 3. Add Public Key to piNAS Clients
```bash
# View the public key
cat ~/.ssh/pinas_deploy.pub

# Add to each piNAS client
ssh pi@pinas.local "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat ~/.ssh/pinas_deploy.pub | ssh pi@pinas.local "cat >> ~/.ssh/authorized_keys"
ssh pi@pinas.local "chmod 600 ~/.ssh/authorized_keys"
# Repeat for each client IP/hostname
```

### 4. Configure Client List
Edit `.github/workflows/deploy.yml` around line 119:
```yaml
client:
  - "pinas.local"              # Local network clients
  - "192.168.1.100"           # Add your local client IPs
  - "pinas-office.local"      # Add local hostnames
```

**For remote clients over internet:**
- Run `sudo /usr/local/sbin/pinas-setup-runner.sh` on the remote piNAS
- This sets up a self-hosted GitHub Actions runner
- No need to add remote clients to the SSH deployment list

### 5. Test the Setup
```bash
# Make a test change and commit
echo "# Test automatic deployment" >> README.md
git add README.md
git commit -m "test: automatic deployment"
git push origin main
```

### 6. Monitor Deployment
- Go to: https://github.com/Bruteforce-Group/piNAS/actions
- Watch the "Build and Deploy piNAS" workflow run
- Check that all clients are successfully updated

## 🔧 What Happens Next

**On every commit to main:**
1. ✅ Scripts are validated for syntax errors
2. 📦 Release package is built with checksums
3. 🚀 Package is deployed to all configured clients
4. 🛡️ Backup is created before updating
5. ✅ Installation is verified on each client

**Deployment safety features:**
- Automatic backups before each update
- Script validation prevents broken deployments  
- Service verification confirms successful updates
- Rollback capability if issues occur

## 🎯 Current Configuration

- **Trigger**: Commits to `main` branch (automatic)
- **Default client**: `pinas.local` (edit workflow to add your clients)
- **Backup location**: `/usr/local/pinas-backup-YYYYMMDD-HHMMSS/`
- **Update logs**: Check GitHub Actions for deployment status

## 🚨 Troubleshooting

### SSH Connection Issues
```bash
# Test SSH access manually
ssh -i ~/.ssh/pinas_deploy pi@pinas.local "echo 'Connection OK'"
```

### Client Not Found
- Verify client hostname resolves: `ping pinas.local`
- Try IP address instead of hostname
- Check client is powered on and connected to network

### Permission Issues
- Ensure public key is in `~/.ssh/authorized_keys` on each client
- Check private key is correctly set in GitHub repository secrets

## 📚 Additional Documentation

- **Full setup guide**: `docs/deployment-setup.md`
- **Client configuration**: `docs/client-config.md`
- **Project overview**: `WARP.md`

---

**Ready to go!** Once setup is complete, every commit you push to main will automatically update all your piNAS clients. No more manual SD card preparation or individual client updates needed!