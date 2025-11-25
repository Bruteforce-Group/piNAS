# SSH Setup for piNAS Automatic Deployment

## Quick Setup for 192.168.1.226

1. **Connect to your piNAS:**
   ```bash
   ssh pi@192.168.1.226
   ```

2. **Add the deployment public key:**
   ```bash
   # From your workstation
   ssh pi@192.168.1.226 "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
   cat ~/.ssh/pinas_deploy.pub | ssh pi@192.168.1.226 "cat >> ~/.ssh/authorized_keys"
   ssh pi@192.168.1.226 "chmod 600 ~/.ssh/authorized_keys"
   ```

3. **Test the connection from your dev machine:**
   ```bash
   cd /Users/danielborrowman/Developer/Projects/piNAS
   ./scripts/manage-clients.sh test 192.168.1.226
   ```

## Next Steps

Once SSH is working:

1. **Sync workflow** to update GitHub Actions:
   ```bash
   ./scripts/manage-clients.sh sync-workflow
   ```

2. **Add private key to GitHub Secrets:**
   - Go to: https://github.com/your-username/piNAS/settings/secrets/actions
   - Add new secret: `PINAS_SSH_PRIVATE_KEY`
   - Copy the contents of: `/Users/danielborrowman/.ssh/pinas_deploy`

3. **Test automatic deployment:**
   ```bash
   # Make a small change and commit
   echo "# Test deployment $(date)" >> README.md
   git add .
   git commit -m "test: trigger automatic deployment"
   git push origin main
   ```

## Alternative: Use ssh-copy-id

If you have `ssh-copy-id` available:
```bash
ssh-copy-id -i ~/.ssh/pinas_deploy.pub pi@192.168.1.226
```

## Troubleshooting

- **Permission denied**: Check SSH service is running on piNAS
- **Connection refused**: Verify piNAS is accessible and SSH is enabled
- **Key not working**: Ensure proper file permissions (600 for authorized_keys, 700 for .ssh)

The deployment system will automatically update your piNAS whenever you push changes to the main branch!