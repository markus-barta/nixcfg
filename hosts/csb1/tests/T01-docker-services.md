# T01: Docker Services

**Feature ID**: F01  
**Status**: ⏳ Pending

## Overview

Tests that Docker is running and all containers are healthy. csb1 runs all services as Docker containers.

## Prerequisites

- SSH access to csb1 (port 2222)

## Manual Test Procedure

### Step 1: Verify Docker Service Running

```bash
ssh -p 2222 mba@cs1.barta.cm
systemctl status docker
```

**Expected**: Service is `active (running)`

### Step 2: Check Docker Version

```bash
ssh -p 2222 mba@cs1.barta.cm
docker --version
```

**Expected**: Docker version displayed (e.g., `Docker version 24.x.x`)

### Step 3: List All Containers

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps -a
```

**Expected**: Shows all containers with their status

### Step 4: Count Running Containers

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps -q | wc -l
```

**Expected**: Should show ~15 containers (Grafana, InfluxDB, Docmost, Paperless, Traefik, backup, etc.)

### Step 5: Check for Unhealthy Containers

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps --filter "health=unhealthy"
```

**Expected**: No unhealthy containers listed

### Step 6: Check for Restarting Containers

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps --filter "status=restarting"
```

**Expected**: No containers stuck in restart loop

### Step 7: Check Docker Networks

```bash
ssh -p 2222 mba@cs1.barta.cm
docker network ls
```

**Expected**: Default bridge and custom networks present

### Step 8: Check Docker Volumes

```bash
ssh -p 2222 mba@cs1.barta.cm
docker volume ls
```

**Expected**: Volumes for persistent data present

## Automated Test

Run the automated test script:

```bash
./tests/T01-docker-services.sh
```

## Success Criteria

- ✅ Docker daemon running
- ✅ Expected number of containers running
- ✅ No unhealthy containers
- ✅ No containers in restart loop
- ✅ Docker networks present
- ✅ Docker volumes present

## Container Inventory

| Container            | Service       | Purpose                    |
| -------------------- | ------------- | -------------------------- |
| csb1-grafana-1       | Grafana       | Monitoring dashboards      |
| csb1-influxdb-1      | InfluxDB      | Time series database       |
| csb1-docmost-1       | Docmost       | Documentation platform     |
| csb1-docmost-db-1    | PostgreSQL    | Docmost database           |
| csb1-docmost-redis-1 | Redis         | Docmost cache              |
| csb1-paperless-1     | Paperless-ngx | Document management        |
| csb1-paperless-\*    | (multiple)    | Paperless support services |
| csb1-traefik-1       | Traefik       | Reverse proxy              |
| csb1-restic-cron-\*  | Restic        | Backup system              |

## Troubleshooting

### Docker Service Not Running

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo systemctl restart docker
journalctl -u docker -n 50
```

### Container Not Starting

```bash
docker logs <container_name> --tail 100
```

### Restart Loop

Check container logs for errors, may need to fix configuration or data.

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
