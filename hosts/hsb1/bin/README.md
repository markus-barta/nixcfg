# hsb1 Scripts

Scripts that run on hsb1 for monitoring and automation.

## netcup-monitor.sh

**Daily** health check for Netcup cloud servers (csb0, csb1).

### Features

- Checks both servers via Netcup REST API **daily at 19:00**
- Tracks consecutive failures in `/var/lib/netcup-monitor/state.json`
- Alerts via **Telegram + Email + LaMetric** if offline for **2+ consecutive days**
- **Continues alerting daily** while servers remain offline

### Configuration

Stored in `~/secrets/netcup-monitor.env` (gitignored):

```bash
NETCUP_REFRESH_TOKEN="..."
CSB0_ID="607878"
CSB1_ID="646294"
TELEGRAM_BOT="..."
TELEGRAM_CHAT="..."
EMAIL="markus@barta.com"
APPRISE_URL="http://localhost:8001/notify/"
```

LaMetric uses `~/secrets/smarthome.env` (LAMETRIC_SKY_VR_AUTHORIZATION).

### Usage

```bash
# Normal check
~/bin/netcup-monitor.sh

# Send test notification (Telegram only)
~/bin/netcup-monitor.sh --test

# Send test to LaMetric
~/bin/netcup-monitor.sh --test-lametric

# Check state
cat /var/lib/netcup-monitor/state.json

# View logs
tail -50 /var/lib/netcup-monitor/monitor.log

# Check timer status
systemctl status netcup-monitor.timer
systemctl list-timers netcup-monitor.timer
```

### Deployment

After editing `configuration.nix`, deploy to hsb1:

```bash
# On hsb1
cd ~/Code/nixcfg
git pull
just switch
```

### Manual Run

```bash
# Trigger immediately
sudo systemctl start netcup-monitor.service

# Check result
journalctl -u netcup-monitor.service
```

### ⚠️ Backlog Note

This script is **manually set up** - not fully declarative yet.
See `hosts/hsb1/BACKLOG.md` for planned improvements.
