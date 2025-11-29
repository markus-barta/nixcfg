# T04: Traefik

**Feature ID**: F04  
**Status**: ⏳ Pending

## Overview

Tests that Traefik reverse proxy is running and routing traffic correctly. Traefik handles SSL termination and routes requests to backend services.

## Prerequisites

- SSH access to csb1 (port 2222)
- Network access to \*.barta.cm domains

## Manual Test Procedure

### Step 1: Check Container Running

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps | grep traefik
```

**Expected**: `csb1-traefik-1` container running

### Step 2: Check Container Logs

```bash
ssh -p 2222 mba@cs1.barta.cm
docker logs csb1-traefik-1 --tail 50
```

**Expected**: No critical errors

### Step 3: Test Dashboard (if enabled)

```bash
ssh -p 2222 mba@cs1.barta.cm
curl -s http://localhost:8080/api/overview
```

**Expected**: Returns JSON with router/service info

### Step 4: Test HTTPS Routing - Grafana

```bash
curl -s -o /dev/null -w "%{http_code}" https://grafana.barta.cm/
```

**Expected**: Returns `200` or `302`

### Step 5: Test HTTPS Routing - Docmost

```bash
curl -s -o /dev/null -w "%{http_code}" https://docmost.barta.cm/
```

**Expected**: Returns `200` or `302`

### Step 6: Test SSL Certificates

```bash
echo | openssl s_client -connect grafana.barta.cm:443 2>/dev/null | openssl x509 -noout -dates
```

**Expected**: Shows valid certificate dates

### Step 7: Test HTTP to HTTPS Redirect

```bash
curl -s -o /dev/null -w "%{http_code}" -L http://grafana.barta.cm/
```

**Expected**: Redirects to HTTPS (returns `200` after redirect)

## Automated Test

Run the automated test script:

```bash
./tests/T04-traefik.sh
```

## Success Criteria

- ✅ Container running
- ✅ Routes to backend services
- ✅ SSL certificates valid (Let's Encrypt)
- ✅ HTTP to HTTPS redirect working

## Domains Routed

| Domain             | Backend Service | Purpose               |
| ------------------ | --------------- | --------------------- |
| grafana.barta.cm   | Grafana         | Monitoring dashboards |
| docmost.barta.cm   | Docmost         | Documentation         |
| paperless.barta.cm | Paperless-ngx   | Document management   |
| influxdb.barta.cm  | InfluxDB        | Time series database  |

## Troubleshooting

### Container Not Running

```bash
cd /home/mba/docker
docker-compose up -d traefik
docker logs csb1-traefik-1 --tail 100
```

### SSL Certificate Issues

```bash
# Check ACME logs
docker logs csb1-traefik-1 | grep -i acme

# Check certificate storage
docker exec csb1-traefik-1 ls -la /letsencrypt/
```

### Routing Not Working

```bash
# Check router configuration
docker exec csb1-traefik-1 traefik show routers

# Check labels on target container
docker inspect csb1-grafana-1 --format='{{json .Config.Labels}}' | jq
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
