# Import household history seed (ops)

Do **not** wipe `data.json`. Backup first.

```bash
# on Mac (example paths)
scp ~/joel-ib/tmp-joe-history-fix/cs0-history-seed.json csb0:/tmp/joe-history-seed.json
ssh csb0 'cp -a /var/lib/joe-board/data.json /var/lib/joe-board/data.json.bak-$(date +%Y%m%d%H%M) &&   cp -a /var/lib/joe-board/history.json /var/lib/joe-board/history.json.bak-$(date +%Y%m%d%H%M) 2>/dev/null;   install -m 0644 -o mba -g 1000 /tmp/joe-history-seed.json /var/lib/joe-board/history.json'
```

Seed contents: day-0 2026-09-01 virt flat (€15k / PnL 0), sparse journal marks Sep 3–4, then hsb1 dense series from 2026-09-08T21:45+02.
