# Uptime Kuma Secure Secret Integration (hsb0)

**Created**: 2025-12-22  
**Completed**: 2026-01-06  
**Priority**: P5310 (Medium)  
**Status**: ✅ DONE  
**Host**: hsb0

---

## Problem

Uptime Kuma stores notification URLs (including tokens) in its SQLite database. To avoid storing sensitive tokens in plaintext in the database, we needed a way to use environment variables in Apprise notification URLs.

---

## Solution Implemented

Created an `apprise` wrapper script that:

1. Intercepts all `apprise` CLI calls from Uptime Kuma
2. Expands environment variables using `envsubst`
3. Loads secrets from agenix-managed `/run/agenix/uptime-kuma-env`

**Configuration** (in `hosts/hsb0/configuration.nix`):

```nix
systemd.services.uptime-kuma = {
  path = [
    (pkgs.writeShellScriptBin "apprise" ''
      # Apprise Wrapper for Environment Variable Expansion
      args=()
      for arg in "$@"; do
        expanded_arg=$(echo "$arg" | ${pkgs.gettext}/bin/envsubst)
        args+=("$expanded_arg")
      done
      exec ${pkgs.apprise}/bin/apprise "''${args[@]}"
    '')
  ];
  serviceConfig.EnvironmentFile = [ config.age.secrets.uptime-kuma-env.path ];
};
```

---

## Usage

### In agenix secret (`secrets/uptime-kuma-env.age`):

```bash
TELEGRAM_TOKEN="123456789:ABC-YourActualToken"
EMAIL_PASS="your-app-password"
```

### In Uptime Kuma UI (Notification Setup):

- **Telegram**: `tgram://$TELEGRAM_TOKEN/your_chat_id`
- **Email**: `mailto://user@gmail.com:$EMAIL_PASS@smtp.gmail.com`

The wrapper automatically expands `$TELEGRAM_TOKEN` to the actual value from the secret file.

---

## Verification (2026-01-06)

- ✅ Uptime Kuma service running (Up 1 week 5 days)
- ✅ Apprise CLI installed and in PATH
- ✅ Wrapper script active in service path
- ✅ Secret file deployed at `/run/agenix/uptime-kuma-env`
- ✅ Secret contains `TELEGRAM_TOKEN`

---

## Notes

**Alternative approach**: Uptime Kuma also supports storing notification configs directly in its database via the UI. For a home setup, this is acceptable since the database is on a trusted host. The wrapper approach is more secure but adds complexity.

**Best practices for monitors**:

- Heartbeat Interval: 60 seconds
- Retries: 3 (notifies after ~3 minutes of consistent failure)
- Retry Interval: 60 seconds

This prevents "hiccup" alerts (false positives) in a home network environment.

---

## Related

- `P5200-hsb0-uptime-kuma.md` - Initial Uptime Kuma setup
- `P5300-uptime-kuma-apprise-integration.md` - Apprise CLI integration
- `P4100-uptime-kuma-complete-monitors.md` - Monitor configuration
