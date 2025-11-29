# T02: Grafana

**Feature ID**: F02  
**Status**: ⏳ Pending

## Overview

Tests that Grafana monitoring dashboards are running and accessible. Grafana provides visualization for metrics collected from csb0 via MQTT/InfluxDB.

## Prerequisites

- SSH access to csb1 (port 2222)
- Network access to grafana.barta.cm

## Manual Test Procedure

### Step 1: Check Container Running

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps | grep grafana
```

**Expected**: `csb1-grafana-1` container running

### Step 2: Check Container Logs

```bash
ssh -p 2222 mba@cs1.barta.cm
docker logs csb1-grafana-1 --tail 50
```

**Expected**: No critical errors, server started successfully

### Step 3: Test Internal Port

```bash
ssh -p 2222 mba@cs1.barta.cm
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health
```

**Expected**: Returns `200`

### Step 4: Test External URL via Traefik

```bash
curl -s -o /dev/null -w "%{http_code}" https://grafana.barta.cm/api/health
```

**Expected**: Returns `200`

### Step 5: Test SSL Certificate

```bash
curl -v https://grafana.barta.cm 2>&1 | grep -i "SSL certificate verify ok"
```

**Expected**: SSL certificate is valid

### Step 6: Login via Browser

1. Navigate to https://grafana.barta.cm
2. Login with admin credentials (see 1Password)
3. Verify dashboards load

**Expected**: Login successful, dashboards display data

### Step 7: Check Data Sources

1. Go to Settings → Data Sources
2. Verify InfluxDB connection

**Expected**: InfluxDB data source connected

## Automated Test

Run the automated test script:

```bash
./tests/T02-grafana.sh
```

## Success Criteria

- ✅ Container running
- ✅ Internal port accessible
- ✅ External URL accessible
- ✅ SSL certificate valid
- ✅ Login works
- ✅ Dashboards show data

## Users

Grafana has multiple users configured:

- admin (administrator)
- caroline
- otto
- gerhard
- markus
- mailina

See 1Password for credentials.

## Troubleshooting

### Container Not Running

```bash
cd /home/mba/docker
docker-compose up -d grafana
docker logs csb1-grafana-1 --tail 100
```

### No Data in Dashboards

- Check InfluxDB connection
- Verify MQTT data flowing from csb0
- Check time range selector

### SSL Certificate Issues

Check Traefik logs for Let's Encrypt errors:

```bash
docker logs csb1-traefik-1 | grep -i acme
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
