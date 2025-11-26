# piNAS Bug Fixes and Improvements

This document tracks identified bugs, security issues, and improvements discovered during code review.

## Critical Issues (Must Fix)

### 1. pinas-install.sh

#### ❌ Line 289-291: Duplicate venv creation
**Status:** TO FIX
```bash
# Current (wrong):
if ! python3 -m venv /opt/pinas-dashboard/.venv 2>/dev/null; then
    python3 -m venv /opt/pinas-dashboard/.venv
fi

# Should be:
python3 -m venv /opt/pinas-dashboard/.venv || {
    echo "ERROR: Failed to create virtual environment" >&2
    return 1
}
```

#### ❌ Line 420: Background process without cleanup
**Status:** TO FIX
```bash
# Add trap at start of init_display stage:
trap 'pkill -f pinas-install-display.py 2>/dev/null || true' EXIT
```

#### ⚠️ Line 192-196: cmdline.txt parameter truncation
**Status:** TO FIX
```bash
# Current might lose existing modules
# Need to append instead of replace
```

### 2. pinas-update.sh

#### ❌ Line 179: sudo in non-interactive context (cron)
**Status:** TO FIX
```bash
# Current:
sudo cp -r "$INSTALL_DIR" "$dest"

# Fix: Run script as root or use NOPASSWD sudo
# Document in systemd service: User=root
```

#### ⚠️ Lines 88-95: Config file permissions not validated
**Status:** TO FIX
```bash
# Add before sourcing:
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found" >&2
    exit 1
fi

config_perms=$(stat -f%Lp "$CONFIG_FILE" 2>/dev/null || stat -c%a "$CONFIG_FILE" 2>/dev/null)
if [ "$config_perms" != "600" ]; then
    echo "WARNING: $CONFIG_FILE should be mode 600 (currently $config_perms)" >&2
fi
```

#### ⚠️ Line 152: Credentials visible in process list
**Status:** TO FIX
```bash
# Use curl config file instead:
curl -fSL "$download_url" \
    -K <(cat <<EOF
-H "X-Client-Id: $CLIENT_ID"
-H "X-Client-Token: $CLIENT_TOKEN"
EOF
    ) \
    -o "$archive"
```

### 3. manage-clients.sh

#### ❌ Line 283: SSH without host key verification
**Status:** TO FIX
```bash
# Add to SSH commands:
ssh -o StrictHostKeyChecking=accept-new "pi@$identifier" ...
```

#### ⚠️ Line 256: Public key not safely injected
**Status:** TO FIX
```bash
# Current (unsafe):
ssh "pi@$identifier" "echo '$public_key' >> ~/.ssh/authorized_keys"

# Fix:
ssh "pi@$identifier" "cat >> ~/.ssh/authorized_keys" < "$DEPLOY_KEY_PUB"
```

#### ⚠️ Line 276: Inconsistent client_id generation
**Status:** TO FIX
```bash
# Ensure bash version matches Python slugify():
client_id=$(echo "${client_name:-$identifier}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g')
```

## High Priority Issues

### 4. publish-artifact.sh

#### ⚠️ Line 66: Daily version collision risk
**Status:** TO FIX
```bash
# Current wraps at 100 builds
# Fix: Use timestamp + build count or daily sequence based on actual commits today
```

#### ⚠️ Line 115: sort -z not portable to older macOS
**Status:** TO FIX
```bash
# Check if sort -z available:
if sort --version >/dev/null 2>&1 && sort --help 2>&1 | grep -q -- '-z'; then
    find . -type f -print0 | sort -z | xargs -0 sha256sum
else
    find . -type f | sort | xargs sha256sum
fi
```

### 5. setup-sdcard.sh

#### ⚠️ Line 98: Platform-specific default path
**Status:** TO FIX
```bash
if [ -z "$VOL_NAME" ]; then
    case "$(uname)" in
        Darwin) VOL_NAME="/Volumes/bootfs" ;;
        Linux) VOL_NAME="/mnt/boot" ;;
        *) echo "ERROR: Unsupported platform"; exit 1 ;;
    esac
fi
```

## Medium Priority Issues

### Error Handling Improvements

1. **pinas-install.sh line 236**: `dpkg -i ... || true` suppresses failures
2. **pinas-update.sh line 165**: tar extraction not validated
3. **manage-clients.sh line 61**: ssh-keygen might fail silently
4. **publish-artifact.sh line 134**: wrangler availability not checked

### Documentation Gaps

1. **pinas-install.sh**: No comments on progress JSON structure
2. **pinas-update.sh**: Worker state payload format not documented
3. **manage-clients.sh**: Client ID generation logic needs comments
4. **setup-sdcard.sh**: config.txt modifications poorly documented

## Low Priority (Code Quality)

1. **pinas-install.sh line 1015**: CPU percent with interval=None might return 0
2. **pinas-upgrade-usb.sh line 339**: Dummy action is clever but undocumented
3. **manage-clients.sh line 424**: Remove functionality not implemented
4. **All scripts**: Bare `except:` clauses should be more specific

## Fixes Applied

- ✅ Hardcoded WiFi credentials removed from boot/user-data
- ✅ WiFi credentials now use template (boot/user-data.example)
- ✅ .gitignore updated to exclude sensitive files

## Testing Checklist

After applying fixes, verify:

- [ ] pinas-install.sh runs without errors on fresh Pi
- [ ] pinas-update.sh works via cron (test with systemd timer)
- [ ] manage-clients.sh can add/setup/test clients
- [ ] publish-artifact.sh creates valid tarballs
- [ ] setup-sdcard.sh works on both macOS and Linux
- [ ] All services start correctly after installation
- [ ] Update flow works end-to-end
- [ ] TFT display shows progress correctly
- [ ] USB gadget mode works
- [ ] Samba shares are accessible

## Implementation Priority

**Phase 1 (Critical - Do Now):**
1. Fix pinas-install.sh background process cleanup
2. Fix pinas-update.sh sudo/cron compatibility
3. Fix manage-clients.sh SSH security issues
4. Add proper error handling to all scripts

**Phase 2 (High - Do Soon):**
1. Fix version collision in publish-artifact.sh
2. Make setup-sdcard.sh cross-platform
3. Improve config file validation
4. Add comprehensive logging

**Phase 3 (Medium - Do Later):**
1. Refactor complex Python-in-bash code
2. Add more documentation
3. Implement remove functionality in manage-clients.sh
4. Improve error messages across all scripts

## Notes

- All scripts use `set -euo pipefail` which is excellent
- Code quality is generally high
- Most issues are edge cases or security hardening opportunities
- No major architectural problems found
