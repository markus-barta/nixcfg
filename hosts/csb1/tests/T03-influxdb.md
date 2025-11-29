# T03: InfluxDB

**Feature ID**: F03  
**Status**: ⏳ Pending

## Overview

Tests that InfluxDB time series database is running and accepting data. InfluxDB receives data from csb0 via MQTT and stores metrics for Grafana visualization.

## Prerequisites

- SSH access to csb1 (port 2222)

## Manual Test Procedure

### Step 1: Check Container Running

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps | grep influxdb
```

**Expected**: `csb1-influxdb-1` container running

### Step 2: Check Container Logs

```bash
ssh -p 2222 mba@cs1.barta.cm
docker logs csb1-influxdb-1 --tail 50
```

**Expected**: No critical errors, server started successfully

### Step 3: Test Health Endpoint

```bash
ssh -p 2222 mba@cs1.barta.cm
curl http://localhost:8086/health
```

**Expected**: Returns JSON with `"status":"pass"`

### Step 4: Test Ping Endpoint

```bash
ssh -p 2222 mba@cs1.barta.cm
curl http://localhost:8086/ping
```

**Expected**: Returns 204 No Content

### Step 5: List Buckets (via CLI)

```bash
ssh -p 2222 mba@cs1.barta.cm
docker exec csb1-influxdb-1 influx bucket list
```

**Expected**: Shows configured buckets (e.g., `jhw22_data`)

### Step 6: Query Recent Data

```bash
ssh -p 2222 mba@cs1.barta.cm
docker exec csb1-influxdb-1 influx query \
  'from(bucket:"jhw22_data") |> range(start:-5m) |> limit(n:10)'
```

**Expected**: Returns recent data points (if MQTT data flowing from csb0)

## Automated Test

Run the automated test script:

```bash
./tests/T03-influxdb.sh
```

## Success Criteria

- ✅ Container running
- ✅ Health endpoint returns pass
- ✅ Ping endpoint responds
- ✅ Buckets configured
- ✅ Recent data present (when csb0 MQTT active)

## Data Flow

```
csb0 (MQTT) → InfluxDB (csb1) → Grafana (csb1)
```

If no recent data:

1. Check csb0 MQTT broker is running
2. Check InfluxDB Telegraf/collector configuration
3. Check network connectivity between csb0 and csb1

## Troubleshooting

### Container Not Running

```bash
cd /home/mba/docker
docker-compose up -d influxdb
docker logs csb1-influxdb-1 --tail 100
```

### No Recent Data

- Check csb0 MQTT broker status
- Verify InfluxDB subscription to MQTT topics
- Check time sync between servers

### Storage Issues

```bash
docker exec csb1-influxdb-1 df -h /var/lib/influxdb2
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
