# Bootstrap infrastructure

These services exist outside the doco.cd reconciliation loop because the loop
depends on them:

- [`openbao/`](openbao/) stores deployment secrets and auto-unseals through the
  Terraform-managed Azure Key Vault key.
- [`doco-cd/`](doco-cd/) polls this repository and natively discovers every
  immediate `core/*/compose.yaml` and `apps/*/compose.yaml` project.

On a new host, bootstrap Docker first, start OpenBao, restore or initialize it,
restore the referenced runtime secrets, provision the single doco.cd AppRole
described in its README, and then start doco.cd. These infrastructure projects
are updated deliberately with ordinary `docker compose up -d`; they cannot
safely deploy themselves.
