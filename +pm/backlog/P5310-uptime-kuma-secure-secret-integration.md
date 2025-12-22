# P5310-uptime-kuma-secure-secret-integration

## Context

Uptime Kuma uses the `apprise` CLI for notifications on `hsb0`. To keep tokens out of the web UI, a secure wrapper with environment variable expansion has been implemented. This task tracks the final setup and configuration.

## Status: PENDING (User Decision Needed)

The infrastructure is ready, but the user has deferred the final token entry and UI configuration.

## Goals

- [x] Create a secure way to use environment variables in Apprise URLs
- [x] Use `agenix` to store secrets (`uptime-kuma-env.age`)
- [x] Implement a wrapper for `apprise` that expands environment variables using `envsubst`
- [ ] User to populate `secrets/uptime-kuma-env.age` with real tokens
- [ ] User to configure Uptime Kuma notifications using `$VAR_NAME` syntax

## Best Practices (Hobby/Home Setup)

To prevent "hiccup" alerts (false positives), use the following monitor settings in Uptime Kuma:

- **Heartbeat Interval**: 60 seconds
- **Retries**: 3 (notifies after ~3 minutes of consistent failure)
- **Retry Interval**: 60 seconds

## Variable Convention Examples

Store these in `secrets/uptime-kuma-env.age`:

```bash
KUMA_TELEGRAM_TOKEN=123456789:ABC-YourActualToken
KUMA_EMAIL_PASS=your-app-password
```

Use in Uptime Kuma UI:

- Telegram: `tgram://$KUMA_TELEGRAM_TOKEN/your_chat_id`
- Email: `mailto://user@gmail.com:$KUMA_EMAIL_PASS@smtp.gmail.com`

## Implementation Details

- **Wrapper**: Injected via `systemd.services.uptime-kuma.path` in `hsb0/configuration.nix`.
- **Secrets**: Loaded via `EnvironmentFile` from `/run/agenix/uptime-kuma-env`.

## References

- `hosts/hsb0/configuration.nix`
- `secrets/secrets.nix`
- Chat history: 2025-12-22 (Uptime Kuma notification setup)
