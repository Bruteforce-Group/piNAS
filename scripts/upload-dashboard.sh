#!/bin/bash
# Upload dashboard screenshot to Cloudflare R2 via Worker API
# This runs on the piNAS device

WORKER_URL="https://pinas.bozza.au"
CLIENT_ID="pinas-01"
CLIENT_TOKEN="${CLIENT_TOKEN:-}"
SCREENSHOT_PATH="/tmp/pinas-dashboard-live.png"

# Check if screenshot exists
if [ ! -f "$SCREENSHOT_PATH" ]; then
    echo "Error: Screenshot not found at $SCREENSHOT_PATH"
    exit 1
fi

# Upload to Worker
curl -s -X POST "${WORKER_URL}/dashboard" \
    -H "X-Client-Id: ${CLIENT_ID}" \
    -H "X-Client-Token: ${CLIENT_TOKEN}" \
    -H "Content-Type: image/png" \
    --data-binary "@${SCREENSHOT_PATH}"

echo ""
