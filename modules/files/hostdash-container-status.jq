# Convert Docker's `ps --format '{{json .}}'` records into the HostDash v1
# container map. A null allowlist preserves the pre-NIX-393 fleet behavior;
# an explicit list publishes only runtime objects that have a dashboard card.
map(
  select(
    $allowed == null
    or (.Names as $name | ($allowed | index($name)) != null)
  )
  | {
      key: .Names,
      value: {
        running: (.State == "running"),
        state: .State,
        status: .Status,
        health: (
          if (.Status | test("\\(healthy\\)")) then "healthy"
          elif (.Status | test("\\(unhealthy\\)")) then "unhealthy"
          elif (.Status | test("\\(health: starting\\)")) then "starting"
          else null
          end
        )
      }
    }
)
| from_entries
