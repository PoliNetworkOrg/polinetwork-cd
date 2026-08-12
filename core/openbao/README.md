# OpenBao

This Compose project runs OpenBao with integrated Raft storage, internal TLS,
Azure Key Vault Auto Unseal and persistent audit output. Its state and TLS
files live below `/srv/polinetwork/state/openbao`. The Terraform-managed
identity client ID is non-secret and is tracked directly in `compose.yaml`.

OpenBao joins `pn-secrets` for Agent access and `pn-edge` for its
Access-protected UI/API route. It publishes no host port. Initialization,
recovery material and runtime secrets must never be committed.

Prepare TLS from the repository root, then deploy from this directory:

```sh
sudo ./prepare.sh
docker compose up -d --pull always --wait --wait-timeout 120
```

Native Raft snapshot production and clean-host recovery tooling live with the
backup service in [`../zerobyte/openbao-snapshot/`](../zerobyte/openbao-snapshot/).
