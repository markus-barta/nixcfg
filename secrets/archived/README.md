# Archived Secrets

These `.age` files are legacy secrets from the original pbek/nixcfg repository.
They are kept for reference but are **NOT actively used**.

## Archived Files

| File                 | Original Purpose              | Why Archived                            |
| -------------------- | ----------------------------- | --------------------------------------- |
| `id_ecdsa_sk.age`    | Yubikey SSH key               | No Yubikey in use                       |
| `nixpkgs-review.age` | nixpkgs contribution workflow | Not used                                |
| `github-token.age`   | GitHub API token              | Using `~/.secrets/github-token` instead |
| `neosay.age`         | Matrix notification config    | Config not needed                       |
| `atuin.age`          | Shell history sync config     | atuin disabled                          |
| `secret1.age`        | Test file                     | Never used                              |

## If You Need These

If you ever need to use one of these secrets:

1. Move the `.age` file back to `secrets/`
2. Uncomment the entry in `secrets.nix`
3. Add your host key to the `publicKeys` list
4. Run `just rekey` to re-encrypt with your keys

## Archive Date

2025-12-06 - As part of pbek → markus nixcfg transition
