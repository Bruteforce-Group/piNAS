# Legacy GitHub Actions Deployment

This directory contains the legacy GitHub Actions-based deployment workflow that was used before transitioning to Cloudflare Workers/R2.

## Why Archived?

The project transitioned from GitHub Actions to Cloudflare Workers for deployment because:

1. **Enterprise Billing Hold** - GitHub Actions was temporarily unavailable due to enterprise billing issues
2. **Better Architecture** - Pull-based updates (clients poll Worker) vs push-based (GitHub Actions SSH into clients)
3. **No Inbound Access Needed** - Clients don't need to expose SSH to the internet
4. **Cost** - Cloudflare Workers and R2 have generous free tiers
5. **Reliability** - No dependency on GitHub's billing or Actions status

## Contents

- `.github/workflows/deploy.yml` - GitHub Actions workflow (447 lines)
  - SSH key management
  - Client connection testing
  - Artifact deployment via scp
  - Service management via SSH

## Related Deleted Scripts

These scripts were part of the GitHub Actions workflow and have been deleted from the main codebase:

- `complete-setup.sh` - GitHub Actions runner setup
- `quick-deploy-setup.sh` - Quick deployment helper
- `setup-deploy-key.sh` - Replaced by `scripts/manage-clients.sh setup-key`
- `sbin/pinas-setup-runner.sh` - Runner configuration

## Migration to Cloudflare

The new deployment system uses:

- **`infra/cloudflare/`** - Cloudflare Worker implementation
- **`scripts/publish-artifact.sh`** - Publishes releases to R2
- **`scripts/manage-clients.sh`** - Client management (replaces SSH from Actions)
- **`sbin/pinas-update.sh`** - Client-side update polling

See [docs/deployment-setup.md](../../docs/deployment-setup.md) for the current deployment architecture.

## Could This Be Restored?

Yes, if needed. The workflow file is preserved here for reference. However, the current Cloudflare-based system is preferred for production use.
