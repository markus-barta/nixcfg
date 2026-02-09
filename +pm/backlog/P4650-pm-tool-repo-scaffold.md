# pm-tool: Repository Scaffolding

**Created**: 2026-02-09
**Priority**: P4650 (Medium)
**Status**: Backlog
**Depends on**: P4500 (PRD)

---

## Problem

Need to create the `markus-barta/pm-tool` repository with project structure, Dockerfile, and basic scaffolding.

---

## Solution

### Repository Structure

```
pm-tool/
├── README.md
├── Dockerfile              # Multi-stage: Go build + Vue build → Alpine
├── docker-compose.yml      # Dev convenience
├── .github/
│   └── workflows/
│       └── build.yml       # Build & push to GHCR
├── backend/
│   ├── go.mod
│   ├── go.sum
│   ├── main.go             # Entry point, router setup
│   ├── handlers/            # HTTP handlers (CRUD)
│   ├── models/              # Data models
│   ├── db/                  # SQLite setup & migrations
│   └── auth/                # Session-based auth
├── frontend/
│   ├── package.json
│   ├── vite.config.ts
│   ├── src/
│   │   ├── App.vue
│   │   ├── views/           # Pages (Dashboard, Projects, Issues)
│   │   ├── components/      # Reusable components
│   │   └── api/             # Backend API client
│   └── public/
└── data/                    # SQLite DB (gitignored, volume-mounted)
```

### Dockerfile (multi-stage)

```dockerfile
# Stage 1: Build frontend
FROM node:22-alpine AS frontend
WORKDIR /app/frontend
COPY frontend/ .
RUN npm ci && npm run build

# Stage 2: Build backend
FROM golang:1.23-alpine AS backend
WORKDIR /app
COPY backend/ ./backend/
RUN cd backend && CGO_ENABLED=1 go build -o /pm-tool .

# Stage 3: Runtime
FROM alpine:3.21
RUN apk add --no-cache sqlite-libs
COPY --from=backend /pm-tool /usr/local/bin/
COPY --from=frontend /app/frontend/dist /app/static/
EXPOSE 8888
CMD ["pm-tool"]
```

---

## Acceptance Criteria

- [ ] GitHub repo created: `markus-barta/pm-tool`
- [ ] Dockerfile builds successfully
- [ ] `docker run` serves hello page on :8888
- [ ] Go backend compiles with SQLite support
- [ ] Vue frontend builds with Vite
- [ ] .gitignore covers data/, node_modules/, dist/

---

## Notes

- This is a **development** task, tracked here for ops awareness
- Actual development happens in the pm-tool repo
- nixcfg only tracks the deployment/infra side

---

## Related

- P4500: pm-tool PRD
- P4550: msbp Docker infrastructure
- P4600: msbp deployment pipeline
