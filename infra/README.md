# Bootstrap infrastructure

These services exist outside the doco.cd reconciliation loop because the loop
depends on them:

- [`openbao/`](openbao/) stores deployment secrets and auto-unseals through the
  Terraform-managed Azure Key Vault key.
- [`doco-cd/`](doco-cd/) polls this repository and natively discovers every
  immediate `core/*/compose.yaml` and `apps/*/compose.yaml` project.

On a new host, [`../bootstrap/bootstrap-vm.sh`](../bootstrap/bootstrap-vm.sh)
owns their ordering, recovery and host-local AppRole generation. These
infrastructure projects are updated deliberately rather than deploying
themselves.
