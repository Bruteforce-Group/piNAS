# piNAS Client Configuration

This document explains how to configure automatic deployments to your piNAS clients.

## Quick Setup

### 1. Add Your Client IPs/Hostnames

Edit `.github/workflows/deploy.yml` and update the client matrix around line 119:

```yaml
client:
  - "pinas.local"              # Default hostname
  - "192.168.1.100"           # Example: specific IP
  - "pinas-office.local"      # Example: office piNAS  
  - "pinas-lab.bruteforce.group" # Example: remote piNAS
```

### 2. Setup SSH Access

Generate a deployment key:
```bash
ssh-keygen -t ed25519 -C "pinas-deployment@github.com" -f ~/.ssh/pinas_deploy
```

Add the **private key** to GitHub repository secrets:
- Go to your repo → Settings → Secrets and variables → Actions
- Click "New repository secret"
- Name: `PINAS_SSH_PRIVATE_KEY`  
- Value: Contents of `~/.ssh/pinas_deploy` (the private key file)

Add the **public key** to each piNAS client:
```bash
# Copy the public key
cat ~/.ssh/pinas_deploy.pub

# On each piNAS client, add it to authorized_keys
ssh pi@your-pinas-ip "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat ~/.ssh/pinas_deploy.pub | ssh pi@your-pinas-ip "cat >> ~/.ssh/authorized_keys"
ssh pi@your-pinas-ip "chmod 600 ~/.ssh/authorized_keys"
```

### 3. Test the Setup

Push a commit to main branch or manually trigger deployment:
```bash
git add .
git commit -m "test: automatic deployment"
git push origin main
```

Watch the deployment in GitHub Actions: `repo → Actions → Build and Deploy piNAS`

## Current Client Configuration

Based on your setup, you should have:

- **Default client**: `pinas.local` (already configured)
- **Add your clients**: Edit the workflow file to include your actual client IPs

## How Automatic Deployment Works

### Triggers
- **Commits to main**: Automatically deploys to all configured clients
- **Tagged releases**: Creates GitHub release + deploys to clients  
- **Manual trigger**: Deploy to specific clients via GitHub Actions web UI

### What Happens During Deployment
1. **Validation**: All scripts are syntax-checked
2. **Package Build**: Creates versioned release package with checksums
3. **SSH Connection**: Connects to each client using deployment key
4. **Backup**: Creates timestamped backup of current installation
5. **Update**: Copies new files and updates system scripts
6. **Verification**: Tests script syntax and service status
7. **Cleanup**: Removes temporary files

### Deployment Safety
- **Automatic backups**: Every deployment creates a backup
- **Script validation**: Syntax errors prevent deployment
- **Service verification**: Confirms services are running after update
- **Rollback ready**: Backups enable easy rollback if needed

## Managing Multiple Environments

### Development/Testing Clients
Add test clients to the matrix for development deployments:
```yaml
client:
  - "pinas-dev.local"     # Development piNAS
  - "pinas-test.local"    # Testing piNAS
```

### Production Clients
For production, consider using tags instead of automatic main deployment:
```bash
# Deploy to production with tagged release
git tag v1.2.0
git push origin v1.2.0
```

### Environment-Specific Configuration
You can create different workflows for different environments:
- `.github/workflows/deploy-dev.yml` - Deploy to dev/test on main commits
- `.github/workflows/deploy-prod.yml` - Deploy to production on tags only

## Troubleshooting

### SSH Connection Issues
```bash
# Test SSH access manually
ssh -i ~/.ssh/pinas_deploy pi@your-client-ip "echo 'Connection OK'"

# Check SSH key in GitHub secrets
# Go to repo → Settings → Secrets → PINAS_SSH_PRIVATE_KEY
```

### Client Discovery Issues
```bash
# Test hostname resolution
ping pinas.local

# Try IP address instead of hostname
# Replace "pinas.local" with specific IP in workflow
```

### Deployment Failures
- Check GitHub Actions logs for detailed error messages
- Verify client is reachable and SSH key is properly configured
- Ensure client has sufficient disk space for updates

## Security Best Practices

### SSH Key Management
- Use dedicated deployment keys (not your personal SSH key)
- Rotate keys periodically
- Limit key access to deployment operations only

### Network Security  
- Ensure clients are only accessible from trusted networks
- Use VPN for remote clients
- Monitor deployment logs for unauthorized access attempts

### Access Control
- Limit GitHub repository access to authorized users only
- Use branch protection rules for main branch
- Require pull request reviews for sensitive changes

This configuration enables fully automated deployments while maintaining security and reliability.