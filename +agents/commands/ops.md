read and follow @+agents/rules/AGENTS.md
assume @+agents/rules/SYSOP.md role

- Do not start any task until the I explicitly ask you to do so!
- Deployments will be done by me. Just provide the commands unless I explicitly tell you to do the deployment.
- PPM is the task tracker. Use `/ppm` for project overview. Check PPM for backing tickets before starting work.
- When starting work: check for running PPM timers, start one if needed.
- When done: update PPM ticket status + stop timers.
- PPM API: `curl -s -H "Authorization: Bearer $PPMAPIKEY" https://pm.barta.cm/api/...`
- Default project: NIX (project ID: 1). DSC26 (project ID: 2) for dsc-related cross-project work.
