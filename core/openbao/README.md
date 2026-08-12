# OpenBao

This Compose project runs OpenBao with integrated Raft storage, internal TLS,
Azure Key Vault Auto Unseal and persistent audit output. Its state and TLS
files live below `/srv/polinetwork/state/openbao`; only the non-secret managed
identity client ID belongs in the protected Compose environment file.

OpenBao joins `pn-secrets` for Agent access and `pn-edge` for its
Access-protected UI/API route. It publishes no host port. Initialization,
recovery material and runtime secrets must never be committed.

Prepare TLS and the identity selector from the repository root, then deploy
from this directory:

```sh
sudo PN_OPENBAO_CLIENT_ID=REPLACE_WITH_TERRAFORM_OUTPUT \
  ./prepare.sh
docker compose up -d --pull always --wait --wait-timeout 120
```

Native Raft snapshot production and clean-host recovery tooling live with the
backup service in [`../zerobyte/openbao-snapshot/`](../zerobyte/openbao-snapshot/).
