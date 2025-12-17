# 2025-12-06 - csb0 Sonnen Battery Scraper Fix

## Description

Website changed, Cypress scraper no longer works. No solar monitoring data.

## Current State

- Container: csb0-cypress-1 (running but not functional)
- Schedule: Every 5 minutes (attempting)
- Status: Website structure changed, selectors broken
- MQTT topic silent: `home/basement/sonnenbattery/webscrape`
- Impact on csb1: Missing solar data in InfluxDB/Grafana

## Acceptance Criteria

- [ ] Check current Sonnen website structure
- [ ] Investigate if Sonnen now provides API
  - Check Sonnen documentation
  - Look for official API endpoints
  - API would be more reliable than scraping
- [ ] If API available:
  - [ ] Replace Cypress with simple API calls
  - [ ] Update Node-RED to call API instead
  - [ ] Remove Cypress container (no longer needed)
- [ ] If no API:
  - [ ] Update Cypress selectors for new website
  - [ ] Test scraping locally
  - [ ] Deploy updated scraper
- [ ] Verify MQTT publishing works
- [ ] Check data appears in csb1 InfluxDB
- [ ] Verify Grafana shows solar data again

## Files to Check

- `/home/mba/docker/cypress-scraper/` (scraper scripts)
- `/home/mba/docker/nodered/data/flows.json` (Sonnen Scraper tab)

## Priority

🟢 LOW - Optional feature, doesn't affect core functionality

## Effort

Medium (2-3 hours depending on API availability)

## Origin

Migrated from `hosts/csb0/secrets/BACKLOG.md` (2025-12-06)
