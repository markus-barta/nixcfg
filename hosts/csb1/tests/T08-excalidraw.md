# T08: Excalidraw - Manual Test

Tests that Excalidraw whiteboard is running and accessible.

## Prerequisites

- SSH access to csb1
- `draw.barta.cm` DNS resolving to `152.53.64.166`

## Tests

### 1. Container Running

```bash
ssh mba@cs1.barta.cm -p 2222 "docker ps | grep excalidraw"
```

Expected: Container `csb1-excalidraw-1` listed with `Up` status.

### 2. Service Accessible

```bash
curl -I https://draw.barta.cm
```

Expected: `HTTP/2 200`

### 3. Logs Clean

```bash
ssh mba@cs1.barta.cm -p 2222 "docker logs csb1-excalidraw-1 --tail 20"
```

Expected: Nginx startup messages, no errors.

## Troubleshooting

```bash
# Restart
ssh mba@cs1.barta.cm -p 2222 "cd ~/docker && docker compose restart excalidraw"

# Full logs
ssh mba@cs1.barta.cm -p 2222 "docker logs csb1-excalidraw-1"
```
