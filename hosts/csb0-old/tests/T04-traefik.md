# T04: Traefik (csb0)

Test reverse proxy and SSL termination.

## Host Information

| Property    | Value                 |
| ----------- | --------------------- |
| **Host**    | csb0                  |
| **Service** | Traefik Reverse Proxy |
| **Ports**   | 80, 443               |
| **Routes**  | home.barta.cm, etc.   |

## Prerequisites

- [ ] SSH access to csb0
- [ ] DNS pointing to csb0

## Automated Tests

Run: `./T04-traefik.sh`

## Test Procedures

### Test 1: Container Running

**Command:** `docker ps --format "{{.Names}}" | grep traefik`

**Expected:** Container found

### Test 2: Container Stable

**Command:** `docker inspect --format "{{.RestartCount}}" <container>`

**Expected:** < 5 restarts

### Test 3: Route to Node-RED

**Command:** `curl -I https://home.barta.cm`

**Expected:** HTTP response (not 502/503)

### Test 4: SSL Certificate

**Command:** `curl -sI https://home.barta.cm`

**Expected:** Valid HTTPS response

## Test Results Summary

| Test | Description       | Status |
| ---- | ----------------- | ------ |
| T1   | Container Running | ⏳     |
| T2   | Container Stable  | ⏳     |
| T3   | Route to Node-RED | ⏳     |
| T4   | SSL Certificate   | ⏳     |

## Routed Services

| Domain             | Backend   |
| ------------------ | --------- |
| home.barta.cm      | Node-RED  |
| bitwarden.barta.cm | Bitwarden |

## Notes

- Let's Encrypt certificates auto-renewed
- Check logs: `docker logs csb0-traefik-1`
