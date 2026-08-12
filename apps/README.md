# Docker applications

This directory contains PoliNetwork-owned applications deployed on `vm01` as
the Compose project named `applications`. Applications are moved here from
[`../k8s-apps/`](../k8s-apps/) only after their ARM64 image, secret delivery,
health checks, resource limits, backup/restore and rollback behavior pass the
migration gates.

Every immediate child folder containing `compose.yaml` is deployed
automatically. Adding `apps/x/compose.yaml` is enough; do not edit the root
Compose file or Komodo resources. Add `.komodo-ignore` to a folder only when it
must remain outside the aggregate project.

Production application containers use `pn-app`; only routed HTTP services also
join `pn-edge`. Applications consume secret files rendered into tmpfs by a
dedicated OpenBao Agent in the same folder. The application never receives an
OpenBao token or direct OpenBao network access. The
[`openbao-canary/`](openbao-canary/) folder is the reference pattern: add the
value below `secret/apps/x`, grant an app-specific AppRole only that path, and
reference its keys from the folder's Agent template.

After adding `secret/apps/x` in OpenBao, provision the folder identity without
placing the administrator password in an argument:

```sh
printf '%s\n' "$PN_OPENBAO_ADMIN_PASSWORD" |
  core/openbao/provision-app-role.sh x
unset PN_OPENBAO_ADMIN_PASSWORD
```

The resulting credentials are available only at
`/srv/polinetwork/state/openbao/approle/x`. Mount that directory into the
folder's Agent, following `openbao-canary/compose.yaml`.

Render and validate the same catalog Komodo deploys:

```sh
../bootstrap/render-compose-catalog.sh .
docker compose -f .komodo.compose.yaml config --quiet
docker compose -f .komodo.compose.yaml --profile secrets-canary config --quiet
```

The generated `.komodo.compose.yaml` is intentionally ignored by Git. Komodo
uses a fresh disposable clone, generates `compose.yaml` there, and deploys
project `applications`.
