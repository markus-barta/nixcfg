# joe-board-pusher (hsb0)

Read-only paper IB client (`clientId` 50 → `100.64.0.6:4002`) projecting
`inspr.joe.household.v1` and POSTing to `https://cs0.barta.cm/joe/inbox` every
`JOE_PUSH_INTERVAL_SEC` (default 30).

Never connects to live 4001. Never places orders. Uses shared agenix push token.
