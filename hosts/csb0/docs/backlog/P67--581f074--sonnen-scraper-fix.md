# sonnen-scraper-fix

**Host**: csb0
**Priority**: P67
**Status**: Backlog
**Created**: 2025-12-06

---

## Problem

Sonnen battery website changed structure. Cypress scraper no longer works. No solar monitoring data reaching InfluxDB/Grafana.

## Solution

Check if Sonnen now provides API. If yes, replace scraper with API calls. If no, update Cypress selectors for new website structure.

## Implementation

- [ ] Check current Sonnen website structure
- [ ] Investigate if Sonnen provides official API (check docs, look for endpoints)
- [ ] **If API available:**
  - [ ] Replace Cypress with simple API calls
  - [ ] Update Node-RED to call API instead
  - [ ] Remove Cypress container (no longer needed)
- [ ] **If no API:**
  - [ ] Update Cypress selectors for new website
  - [ ] Test scraping locally
  - [ ] Deploy updated scraper
- [ ] Verify MQTT publishing works (`home/basement/sonnenbattery/webscrape`)
- [ ] Check data appears in csb1 InfluxDB
- [ ] Verify Grafana shows solar data again

## Acceptance Criteria

- [ ] Solar data flowing to MQTT
- [ ] Data visible in csb1 InfluxDB
- [ ] Grafana dashboard shows solar metrics
- [ ] Container csb0-cypress-1 either working or removed (if API used)

## Notes

- Current state: csb0-cypress-1 running but not functional
- Schedule: Every 5 minutes (attempting)
- MQTT topic silent: `home/basement/sonnenbattery/webscrape`
- Files to check:
  - `/home/mba/docker/cypress-scraper/` (scraper scripts)
  - `/home/mba/docker/nodered/data/flows.json` (Sonnen Scraper tab)
- Priority: 🟢 LOW (optional feature, doesn't affect core functionality)
- Effort: Medium (2-3 hours depending on API availability)
- Origin: Migrated from `hosts/csb0/secrets/BACKLOG.md` (2025-12-06)
