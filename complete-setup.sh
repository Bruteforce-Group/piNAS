#!/bin/bash
set -euo pipefail

# piNAS Deployment Setup Completion Script
# This script helps complete the SSH and GitHub secrets setup

echo "🚀 piNAS Deployment Setup - Final Steps"
echo "========================================"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEPLOY_KEY_PUB="$HOME/.ssh/pinas_deploy.pub"
DEPLOY_KEY_PRIVATE="$HOME/.ssh/pinas_deploy"

echo "Step 1: SSH Key Setup for piNAS Client"
echo "======================================"

if [ ! -f "$DEPLOY_KEY_PUB" ]; then
    echo -e "${RED}ERROR:${NC} Deployment public key not found at $DEPLOY_KEY_PUB"
    exit 1
fi

PUBLIC_KEY=$(cat "$DEPLOY_KEY_PUB")
echo "Public key to add: $PUBLIC_KEY"
echo

echo -e "${BLUE}Choose your method:${NC}"
echo "1) Try ssh-copy-id (automatic, requires password)"
echo "2) Manual setup (copy commands to run on piNAS)"
echo "3) Skip SSH setup for now"
echo
read -p "Enter choice (1-3): " choice

case $choice in
    1)
        echo "Attempting ssh-copy-id to 192.168.1.226..."
        if ssh-copy-id -i "$DEPLOY_KEY_PUB" pi@192.168.1.226; then
            echo -e "${GREEN}✅ SSH key successfully added!${NC}"
        else
            echo -e "${YELLOW}⚠️  ssh-copy-id failed. Try method 2 (manual setup).${NC}"
        fi
        ;;
    2)
        echo -e "${BLUE}Manual SSH Setup Instructions:${NC}"
        echo "Run these commands on your piNAS (192.168.1.226):"
        echo
        echo -e "${YELLOW}# Connect to piNAS${NC}"
        echo "ssh pi@192.168.1.226"
        echo
        echo -e "${YELLOW}# Add deployment key${NC}"
        echo "mkdir -p ~/.ssh"
        echo "chmod 700 ~/.ssh"
        echo "echo '$PUBLIC_KEY' >> ~/.ssh/authorized_keys"
        echo "chmod 600 ~/.ssh/authorized_keys"
        echo "exit"
        echo
        read -p "Press Enter when you've completed the SSH setup..."
        ;;
    3)
        echo "Skipping SSH setup. You can run this script again later."
        ;;
esac

echo
echo "Step 2: Test SSH Connection"
echo "=========================="

if ssh -i "$DEPLOY_KEY_PRIVATE" -o ConnectTimeout=10 pi@192.168.1.226 "echo 'SSH connection successful!'" 2>/dev/null; then
    echo -e "${GREEN}✅ SSH connection working!${NC}"
    
    # Update client status
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "$SCRIPT_DIR/scripts/manage-clients.sh" ]; then
        "$SCRIPT_DIR/scripts/manage-clients.sh" test 192.168.1.226
    fi
else
    echo -e "${RED}❌ SSH connection failed${NC}"
    echo "Please complete SSH setup before proceeding to GitHub secrets."
    echo "You can run this script again after fixing SSH."
    exit 1
fi

echo
echo "Step 3: GitHub Repository Secret"
echo "==============================="

if [ ! -f "$DEPLOY_KEY_PRIVATE" ]; then
    echo -e "${RED}ERROR:${NC} Private key not found at $DEPLOY_KEY_PRIVATE"
    exit 1
fi

echo "Adding PINAS_SSH_PRIVATE_KEY to GitHub repository secrets..."
echo

# Try using GitHub CLI if available
if command -v gh &> /dev/null; then
    echo "Using GitHub CLI to add secret..."
    if gh secret set PINAS_SSH_PRIVATE_KEY < "$DEPLOY_KEY_PRIVATE"; then
        echo -e "${GREEN}✅ GitHub secret added successfully via CLI!${NC}"
    else
        echo -e "${YELLOW}⚠️  GitHub CLI failed. Using manual method.${NC}"
        manual_github_setup=true
    fi
else
    manual_github_setup=true
fi

if [ "${manual_github_setup:-false}" = true ]; then
    echo -e "${BLUE}Manual GitHub Secret Setup:${NC}"
    echo
    echo "1. Go to: https://github.com/Bruteforce-Group/piNAS/settings/secrets/actions"
    echo "2. Click 'New repository secret'"
    echo "3. Name: PINAS_SSH_PRIVATE_KEY"
    echo "4. Value: Copy the private key below"
    echo
    echo -e "${YELLOW}--- PRIVATE KEY (copy everything between the lines) ---${NC}"
    cat "$DEPLOY_KEY_PRIVATE"
    echo -e "${YELLOW}--- END PRIVATE KEY ---${NC}"
    echo
    read -p "Press Enter when you've added the GitHub secret..."
fi

echo
echo "Step 4: Test Deployment System"
echo "============================="

echo "Testing the complete deployment system..."
echo "This will trigger a deployment to verify everything works."
echo

read -p "Create a test commit to trigger deployment? (y/n): " deploy_test

if [ "$deploy_test" = "y" ] || [ "$deploy_test" = "Y" ]; then
    TEST_FILE="deployment-test.txt"
    echo "Deployment test - $(date)" > "$TEST_FILE"
    
    git add "$TEST_FILE"
    git commit -m "test: verify automatic deployment system ($(date +%H:%M))"
    
    echo "Pushing to trigger deployment..."
    git push origin main
    
    echo -e "${GREEN}✅ Test deployment triggered!${NC}"
    echo
    echo "Check your GitHub Actions at:"
    echo "https://github.com/Bruteforce-Group/piNAS/actions"
    echo
    echo "Your piNAS should update automatically within 2-5 minutes."
    
    # Clean up test file
    git rm "$TEST_FILE"
    git commit -m "cleanup: remove deployment test file"
    git push origin main
else
    echo "Skipping deployment test."
fi

echo
echo -e "${GREEN}🎉 Setup Complete!${NC}"
echo "==================="
echo
echo "Your piNAS deployment system is ready!"
echo "• Every commit to main will trigger automatic deployment"
echo "• Check deployment status: ./scripts/manage-clients.sh status"
echo "• Add new clients: ./scripts/setup-sdcard.sh --client-ip <IP>"
echo
echo "Documentation:"
echo "• SSH-SETUP.md - Detailed SSH setup guide"
echo "• DEPLOYMENT-COMPLETE.md - Complete system overview"
echo "• ./scripts/manage-clients.sh help - Client management commands"
echo