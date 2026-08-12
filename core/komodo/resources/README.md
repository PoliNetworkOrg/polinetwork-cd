# Komodo resources

`stacks.toml` is the Git source for the self-managed `polinetwork-vm` Resource
Sync and the `core` and `applications` Stacks. Seed that Resource Sync once in a
clean Komodo database. It also creates `deploy-polinetwork-vm`, whose Git
webhook first syncs these declarations and then deploys `core` followed by
`applications`.

Both stacks run `bootstrap/render-compose-catalog.sh` before deployment, so
their Komodo definitions never list service files. After the initial Resource
Sync is accepted, configure one branch-`vm` webhook for the procedure. A push
then pulls Git, discovers every immediate `*/compose.yaml`, and runs Compose.
