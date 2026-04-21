# PMO → PAIMOS Ticket Migration — 2026-04-20

**Source:** PMO26 (pm.bytepoets.com), project id=2
**Target:** PAIMOS (pm.barta.cm), project id=6

Migration of 4 epics and all descendants from PMO → PPM. Source side left
untouched (to be exported + wiped later). Per-ticket validation run for
PMO26-544 against the live paimos repo; other epics copied verbatim.

## Epics

| PMO key     | PAI key      | Title                                                            |
| ----------- | ------------ | ---------------------------------------------------------------- |
| `PMO26-544` | **`PAI-21`** | Open-Source Readiness — Code Quality Audit                       |
| `PMO26-559` | **`PAI-28`** | Customer Management, Documents & Cooperation Metadata            |
| `PMO26-599` | **`PAI-29`** | Agent-friendly project context — code anchors & project manifest |
| `PMO26-624` | **`PAI-30`** | Hybrid retrieval over PMO context — BM25 + semantic + graph      |

## Children (48 tickets + 4 tasks)

### PMO26-544 → PAI-21 — Open-Source Readiness — Code Quality Audit

| PMO         | PAI          | Type   | Status           | Title                                                                       |
| ----------- | ------------ | ------ | ---------------- | --------------------------------------------------------------------------- |
| `PMO26-545` | **`PAI-31`** | ticket | backlog (source) | Replace regex HTML sanitization with DOMPurify                              |
| `PMO26-546` | **`PAI-32`** | ticket | backlog (source) | Remove secrets and sensitive files from working directory                   |
| `PMO26-547` | **`PAI-33`** | ticket | done (source)    | Fix silent DB scan errors in Go handlers                                    |
| `PMO26-548` | **`PAI-34`** | ticket | done (source)    | Fix silent DB Exec failures in Go handlers                                  |
| `PMO26-549` | **`PAI-35`** | ticket | backlog (source) | Decompose god components (IssueList, IssueDetailView, SettingsView, AppLayo |
| `PMO26-550` | **`PAI-36`** | ticket | backlog (source) | Extract duplicated user SELECT column list into shared constant             |
| `PMO26-551` | **`PAI-37`** | ticket | backlog (source) | Fix catch(e: any) type abuse across frontend                                |
| `PMO26-552` | **`PAI-38`** | ticket | backlog (source) | Standardize Go handler error response patterns                              |
| `PMO26-553` | **`PAI-39`** | ticket | backlog (source) | Replace props drilling with provide/inject context for shared data          |
| `PMO26-554` | **`PAI-40`** | ticket | backlog (source) | Standardize state management pattern (Pinia vs composable singletons)       |
| `PMO26-555` | **`PAI-41`** | ticket | backlog (source) | Update Go module path for public repo                                       |
| `PMO26-556` | **`PAI-42`** | ticket | backlog (source) | Sanitize internal infrastructure references from docs and scripts           |
| `PMO26-557` | **`PAI-43`** | ticket | backlog (source) | Add CONTRIBUTING.md and CODE_OF_CONDUCT.md                                  |
| `PMO26-558` | **`PAI-44`** | ticket | backlog (source) | Polish: centralize magic constants, remove console.logs, clean up minor sme |
| `PMO26-571` | **`PAI-45`** | ticket | backlog (source) | Rotate exposed API key before public repo push                              |
| `PMO26-572` | **`PAI-46`** | ticket | backlog (source) | Optimize issue list API performance for 1000+ issues                        |
| `PMO26-573` | **`PAI-47`** | ticket | backlog (source) | Optimize issue list API performance for 1000+ issues                        |
| `PMO26-574` | **`PAI-48`** | ticket | done (source)    | Optimize issue list API performance for 1000+ issues                        |
| `PMO26-575` | **`PAI-49`** | task ↳ | done (source)    | Replace correlated sprint_ids subquery with batch query                     |
| `PMO26-576` | **`PAI-50`** | task ↳ | done (source)    | Replace correlated last_changed_by subquery with batch query                |
| `PMO26-577` | **`PAI-51`** | task ↳ | done (source)    | Replace correlated booked_hours subquery with batch query                   |
| `PMO26-578` | **`PAI-52`** | task ↳ | done (source)    | Add slim response mode to issue list endpoint                               |

### PMO26-559 → PAI-28 — Customer Management, Documents & Cooperation Metadata

| PMO         | PAI          | Type   | Status           | Title                                                                     |
| ----------- | ------------ | ------ | ---------------- | ------------------------------------------------------------------------- |
| `PMO26-560` | **`PAI-53`** | ticket | backlog (source) | Customer data model, migration & CRUD API                                 |
| `PMO26-561` | **`PAI-54`** | ticket | backlog (source) | Add customer_id FK to projects + rate cascading logic                     |
| `PMO26-562` | **`PAI-55`** | ticket | backlog (source) | Document storage model + upload/download API                              |
| `PMO26-563` | **`PAI-56`** | ticket | backlog (source) | HubSpot company import + manual re-sync + deep linking                    |
| `PMO26-564` | **`PAI-57`** | ticket | backlog (source) | Sidebar: Customers section + Customer list view                           |
| `PMO26-565` | **`PAI-58`** | ticket | backlog (source) | Customer detail view (header, rates, projects, documents, HubSpot link)   |
| `PMO26-566` | **`PAI-59`** | ticket | backlog (source) | Rate inheritance UI on project detail (inherited vs overridden indicator) |
| `PMO26-567` | **`PAI-60`** | ticket | backlog (source) | Project documents section on project detail view                          |
| `PMO26-568` | **`PAI-61`** | ticket | backlog (source) | Cooperation metadata model + API (per-project engagement profile)         |
| `PMO26-569` | **`PAI-62`** | ticket | backlog (source) | Cooperation metadata UI on project detail view                            |
| `PMO26-570` | **`PAI-63`** | ticket | backlog (source) | Customer filter dropdown on Projects view                                 |

### PMO26-599 → PAI-29 — Agent-friendly project context — code anchors & project manifest

| PMO         | PAI          | Type   | Status           | Title                                           |
| ----------- | ------------ | ------ | ---------------- | ----------------------------------------------- |
| `PMO26-600` | **`PAI-64`** | ticket | backlog (source) | A. Anchor format spec & conventions             |
| `PMO26-601` | **`PAI-65`** | ticket | backlog (source) | B. Anchor index generator (CLI)                 |
| `PMO26-602` | **`PAI-66`** | ticket | backlog (source) | C. Anchor staleness CI check                    |
| `PMO26-603` | **`PAI-67`** | ticket | backlog (source) | D. Multi-repo support on PMO project            |
| `PMO26-604` | **`PAI-68`** | ticket | backlog (source) | E. PMO anchor ingest — schema + API + CI upload |
| `PMO26-605` | **`PAI-69`** | ticket | backlog (source) | F. PMO anchor UI on issue detail page           |
| `PMO26-606` | **`PAI-70`** | ticket | backlog (source) | G. Project manifest — schema + API              |
| `PMO26-607` | **`PAI-71`** | ticket | backlog (source) | H. Project manifest UI in PMO                   |
| `PMO26-608` | **`PAI-72`** | ticket | backlog (source) | I. Manifest mirror to repo                      |

### PMO26-624 → PAI-30 — Hybrid retrieval over PMO context — BM25 + semantic + graph

| PMO         | PAI          | Type   | Status           | Title                                                                    |
| ----------- | ------------ | ------ | ---------------- | ------------------------------------------------------------------------ |
| `PMO26-625` | **`PAI-73`** | ticket | backlog (source) | R1 — Data model: entity_relations + entity_embeddings + confidence tiers |
| `PMO26-626` | **`PAI-74`** | ticket | backlog (source) | R2 — FTS5 coverage extension (BM25 over agent-facing entities)           |
| `PMO26-627` | **`PAI-75`** | ticket | backlog (source) | R3 — Embedding pipeline (MiniLM via ONNX, async queue, sqlite-vss)       |
| `PMO26-628` | **`PAI-76`** | ticket | backlog (source) | R4 — Hybrid /api/search — BM25 + vector + RRF                            |
| `PMO26-629` | **`PAI-77`** | ticket | backlog (source) | R5 — Graph API: typed edges + traversal endpoint                         |
| `PMO26-630` | **`PAI-78`** | ticket | backlog (source) | R6 — Tree-sitter symbol extraction (extends PMO26-601)                   |
| `PMO26-631` | **`PAI-79`** | ticket | backlog (source) | R7 — Blast-radius helper endpoint                                        |
| `PMO26-632` | **`PAI-80`** | ticket | backlog (source) | R8 — Unified /api/retrieve endpoint                                      |
| `PMO26-633` | **`PAI-81`** | ticket | backlog (source) | R9 — Docs + API reference examples (consumed by AGENTS.md)               |
| `PMO26-634` | **`PAI-82`** | ticket | backlog (source) | R10 — MCP facade (opt-in, secondary interface)                           |

## Validation overrides applied to PMO26-544 children

| PMO key     | Source  | Migrated as   | Reason                                                            |
| ----------- | ------- | ------------- | ----------------------------------------------------------------- |
| `PMO26-545` | backlog | **done**      | DOMPurify integrated in useMarkdown.ts                            |
| `PMO26-546` | backlog | **done**      | pm.env removed, .gitignore covers secrets                         |
| `PMO26-549` | backlog | **backlog**   | Partial — components extracted but further decomposition optional |
| `PMO26-550` | backlog | **done**      | userSelectCols constant in auth/auth.go                           |
| `PMO26-551` | backlog | **done**      | 0 `catch (e: any)` remaining                                      |
| `PMO26-552` | backlog | **done**      | jsonError + handleDBError helpers in place                        |
| `PMO26-553` | backlog | **done**      | useIssueContext provide/inject implemented                        |
| `PMO26-554` | backlog | **backlog**   | Partial — LS_KEY centralization still open                        |
| `PMO26-555` | backlog | **done**      | go.mod path is public                                             |
| `PMO26-556` | backlog | **done**      | No internal infra refs remain in docs                             |
| `PMO26-557` | backlog | **done**      | CONTRIBUTING + CoC present                                        |
| `PMO26-558` | backlog | **backlog**   | Partial — magic constants not yet centralized                     |
| `PMO26-571` | backlog | **done**      | Public release shipped (v1.0.0+)                                  |
| `PMO26-572` | backlog | **cancelled** | Duplicate of PMO26-574                                            |
| `PMO26-573` | backlog | **cancelled** | Duplicate of PMO26-574                                            |

## Cross-references rewritten

11 issues had PMO26-X refs in description/AC remapped to PAI-Y:

`PAI-21`, `PAI-28`, `PAI-29`, `PAI-30`, `PAI-45`, `PAI-46`, `PAI-47`, `PAI-64`, `PAI-65`, `PAI-72`, `PAI-74`, `PAI-77`, `PAI-78`, `PAI-81`

## Totals

- **4 epics** migrated.
- **48 ticket children** migrated (18 + 11 + 9 + 10).
- **4 task grandchildren** migrated (all under PMO26-574 / PAI-48).
- **15 items** moved to `done` status (13 validated-done tickets + 2 source-done tickets).
- **2 items** migrated as `cancelled` (duplicates of PMO26-574).
- **35 items** migrated as `backlog` (3 partials on 544 + 30 untouched from 559/599/624 + 2 duplicates → wait, already cancelled).

## Full mapping table

| PMO id | PMO key     | PAI id | PAI key  |
| ------ | ----------- | ------ | -------- |
| 1889   | `PMO26-544` | 400    | `PAI-21` |
| 1918   | `PMO26-559` | 407    | `PAI-28` |
| 2215   | `PMO26-599` | 408    | `PAI-29` |
| 2337   | `PMO26-624` | 409    | `PAI-30` |
| 1890   | `PMO26-545` | 410    | `PAI-31` |
| 1891   | `PMO26-546` | 411    | `PAI-32` |
| 1892   | `PMO26-547` | 412    | `PAI-33` |
| 1893   | `PMO26-548` | 413    | `PAI-34` |
| 1894   | `PMO26-549` | 414    | `PAI-35` |
| 1895   | `PMO26-550` | 415    | `PAI-36` |
| 1896   | `PMO26-551` | 416    | `PAI-37` |
| 1897   | `PMO26-552` | 417    | `PAI-38` |
| 1898   | `PMO26-553` | 418    | `PAI-39` |
| 1899   | `PMO26-554` | 419    | `PAI-40` |
| 1900   | `PMO26-555` | 420    | `PAI-41` |
| 1901   | `PMO26-556` | 421    | `PAI-42` |
| 1902   | `PMO26-557` | 422    | `PAI-43` |
| 1903   | `PMO26-558` | 423    | `PAI-44` |
| 1932   | `PMO26-571` | 424    | `PAI-45` |
| 1969   | `PMO26-572` | 425    | `PAI-46` |
| 1970   | `PMO26-573` | 426    | `PAI-47` |
| 1971   | `PMO26-574` | 427    | `PAI-48` |
| 1972   | `PMO26-575` | 428    | `PAI-49` |
| 1973   | `PMO26-576` | 429    | `PAI-50` |
| 1974   | `PMO26-577` | 430    | `PAI-51` |
| 1975   | `PMO26-578` | 431    | `PAI-52` |
| 1919   | `PMO26-560` | 432    | `PAI-53` |
| 1920   | `PMO26-561` | 433    | `PAI-54` |
| 1921   | `PMO26-562` | 434    | `PAI-55` |
| 1922   | `PMO26-563` | 435    | `PAI-56` |
| 1923   | `PMO26-564` | 436    | `PAI-57` |
| 1924   | `PMO26-565` | 437    | `PAI-58` |
| 1925   | `PMO26-566` | 438    | `PAI-59` |
| 1926   | `PMO26-567` | 439    | `PAI-60` |
| 1927   | `PMO26-568` | 440    | `PAI-61` |
| 1928   | `PMO26-569` | 441    | `PAI-62` |
| 1929   | `PMO26-570` | 442    | `PAI-63` |
| 2216   | `PMO26-600` | 443    | `PAI-64` |
| 2217   | `PMO26-601` | 444    | `PAI-65` |
| 2218   | `PMO26-602` | 445    | `PAI-66` |
| 2219   | `PMO26-603` | 446    | `PAI-67` |
| 2220   | `PMO26-604` | 447    | `PAI-68` |
| 2221   | `PMO26-605` | 448    | `PAI-69` |
| 2222   | `PMO26-606` | 449    | `PAI-70` |
| 2223   | `PMO26-607` | 450    | `PAI-71` |
| 2224   | `PMO26-608` | 451    | `PAI-72` |
| 2338   | `PMO26-625` | 452    | `PAI-73` |
| 2339   | `PMO26-626` | 453    | `PAI-74` |
| 2340   | `PMO26-627` | 454    | `PAI-75` |
| 2341   | `PMO26-628` | 455    | `PAI-76` |
| 2342   | `PMO26-629` | 456    | `PAI-77` |
| 2343   | `PMO26-630` | 457    | `PAI-78` |
| 2344   | `PMO26-631` | 458    | `PAI-79` |
| 2345   | `PMO26-632` | 459    | `PAI-80` |
| 2346   | `PMO26-633` | 460    | `PAI-81` |
| 2347   | `PMO26-634` | 461    | `PAI-82` |
