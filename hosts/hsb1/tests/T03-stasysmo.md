# StaSysMo v2 live verification

Run the adjacent `.sh` on the deployed host. It checks the existing
`stasysmo-daemon` service, `/run/stasysmo/snapshot` ownership/mode/format/freshness,
and the installed fish compositor plus built-in Starship `git_commit`.
It performs no writes. It requires Python 3 and the owner's fish configuration.

The portable isolated assertions live in `tests/T91-stasysmo.sh`; those cover
hostile snapshots, the reader, collector fixtures and actual PTY layouts.
