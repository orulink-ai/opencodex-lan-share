# opencodex LAN Share - Troubleshooting

## Quick Diagnostic

Run the built-in diagnostic tool on either server or client:

```powershell
# Server side
.\tools\diagnostics.ps1

# Client side
.\tools\diagnostics.ps1 -ServerIp 192.168.1.110
```

Or run specific test suites:

```powershell
.\tests\test-connectivity.ps1
.\tests\test-models.ps1
.\tests\test-stream.ps1
.\tests\test-client-windows.ps1
```

## Common Issues

### 1. "Cannot connect to proxy" (TC-CONN-01 fails)

**Symptoms:** Health endpoint unreachable, port not listening.

**Causes & fixes:**
- Proxy not running → `ocx start`
- Proxy crashed → `ocx logs --tail 30` to check logs
- Wrong port → `ocx config get port` to verify (should be 10100)

### 2. "Colleague cannot reach proxy" (TC-CONN-05 fails)

**Symptoms:** Local proxy works but remote machine cannot connect.

**Causes & fixes:**
- Firewall blocking port 10100 → Run `setup-lan.ps1` as admin
- Wrong LAN IP → Verify with `ipconfig`, update client config
- Different subnet → Both machines must be on same LAN (e.g., 192.168.1.x)
- Windows network profile is "Public" → Change to "Private" in Windows Settings

### 3. "401 Unauthorized"

**Symptoms:** HTTP 401 when colleague tries to use proxy.

**Causes & fixes:**
- Missing or wrong access key → Generate new key: `manage-users.ps1 -Create`
- Proxy auth not configured → Check `ocx access key list`

### 4. "Model list not updating after client setup" ⭐ NEW

**Symptoms:** Colleague ran setup-client script, restarted Codex Desktop, but model selector still shows default models only.

**Root cause:** The client machine does NOT have opencodex installed. Codex Desktop alone cannot read `model_provider = "opencodex"` or `[model_providers.opencodex]` config sections. These are opencodex-specific configuration keys.

**Fix:**
1. Run the setup script again (it now auto-detects and installs opencodex):
   ```powershell
   .\setup-client.ps1 -ServerIp 192.168.1.110 -AccessKey ocx_data_xxxx
   ```
2. Or manually install opencodex:
   ```powershell
   npm install -g @bitkyc08/opencodex
   ```
3. Verify installation:
   ```powershell
   ocx --version
   ```
4. Fully quit and reopen Codex Desktop

**Verification:** Run the client diagnostic:
```powershell
.\tools\diagnostics.ps1 -ServerIp 192.168.1.110
```
Check that "--- opencodex ---" section shows a version number, not "NOT FOUND".

### 5. "Node.js not found" when running setup script

**Symptoms:** `node --version` fails, opencodex cannot be installed.

**Causes & fixes:**
- Windows: The script attempts `winget install OpenJS.NodeJS.LTS`. If winget is unavailable, install manually from https://nodejs.org/
- macOS: The script attempts `brew install node`. If Homebrew is unavailable, install manually from https://nodejs.org/
- Linux: The script attempts `sudo apt-get install nodejs npm`. For other distros, use the appropriate package manager.

### 6. "npm install -g @bitkyc08/opencodex failed"

**Symptoms:** opencodex installation fails during setup.

**Causes & fixes:**
- Permission denied → On Linux, try `sudo npm install -g @bitkyc08/opencodex`
- npm registry unreachable → Check internet connection, try `npm config set registry https://registry.npmmirror.com` (China mirror)
- Node.js version too old → Update to Node.js 18+ LTS

### 7. "Model not found"

**Symptoms:** Requested model returns 404.

**Causes & fixes:**
- Model catalog out of date → `ocx sync` on server
- Model not registered → `ocx models add <provider> <model>`
- Provider not configured → `ocx provider list` to verify

### 8. "Slow responses"

**Symptoms:** High latency on all requests.

**Causes & fixes:**
- Network congestion → Check LAN bandwidth usage
- Provider throttling → Check API rate limits on provider dashboards
- Large context windows → Reduce `max_tokens` in requests
- Proxy memory pressure → Increase `appOwnedMemoryBudgetMb` in `config.json`

### 9. "Proxy stops after reboot"

**Symptoms:** After server restart, proxy not running.

**Causes & fixes:**
- Service not installed → Run `setup-lan.ps1` (installs service)
- Service disabled → `ocx service status`, then `ocx service start`

## Diagnostic Commands Reference

```powershell
# Proxy status
ocx status
ocx health
ocx logs --tail 50

# opencodex (client side)
ocx --version
ocx models list
npm list -g opencodex

# Node.js
node --version
npm --version

# Network
netstat -an | findstr 10100
Test-NetConnection 192.168.1.110 -Port 10100

# Firewall
Get-NetFirewallRule -DisplayName "*OpenCodex*" | Format-List

# Models
ocx models list
ocx provider list

# Access keys
ocx access key list

# Config
Get-Content ~/.codex/config.toml

# HTTP tests
curl http://127.0.0.1:10100/health
curl http://127.0.0.1:10100/v1/models
```

## Getting Help

1. Run the diagnostic tool first: `.\tools\diagnostics.ps1`
2. Run the client test suite: `.\tests\test-client-windows.ps1`
3. Check the logs: `ocx logs --tail 100`
4. File an issue in the project repository with the diagnostic output attached
