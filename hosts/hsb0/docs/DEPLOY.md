# hsb0 deploy notes

## Paper desk runner

This PR does not deploy and cannot create the GitHub credential. A human with
hsb0 access must perform exactly these steps:

1. In GitHub, create a fine-grained token limited to the private
   `markus-barta/oc-workspace-shared` repository with Metadata read and Issues
   read/write. Create the two labels once:

   ```bash
   gh label create hsb0-paper-intent --repo markus-barta/oc-workspace-shared --color 1d76db
   gh label create hsb0-paper-halt --repo markus-barta/oc-workspace-shared --color b60205
   ```

2. On hsb0, from `/home/mba/Code/nixcfg`, create the agenix ciphertext and put
   only the raw token in the editor (no `KEY=`, quotes, or other fields):

   ```bash
   cd /home/mba/Code/nixcfg
   agenix -e secrets/hsb0-ib-desk-runner-github-token.age
   ```

3. Switch NixOS. Use `path:.` for the first switch because the newly created
   ciphertext is intentionally absent from this code-only PR and therefore is
   not yet part of Git's flake source:

   ```bash
   sudo nixos-rebuild switch --flake path:.#hsb0
   ```

4. Verify the units without reading credentials or raw intent state:

   ```bash
   systemctl status ib-desk-runner.timer joel-ib-paper-flatten-own.timer
   sudo systemctl start ib-desk-runner.service
   journalctl -u ib-desk-runner.service -n 20 --no-pager
   systemctl list-timers joel-ib-paper-flatten-own.timer
   ```

5. Submit a recon intent using the contract in `IB-DESK-RUNNER.md` and retain
   its issue URL/result as the live proof. Preserve the encrypted `.age` file
   through the repository's normal reviewed secret-ciphertext workflow; never
   commit or print the raw token.

Do not recreate or reconfigure `ib-gateway`, do not publish `4001`, and do not
change the joe-board-pusher image pin during this deployment.
