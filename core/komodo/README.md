# Komodo

This Compose project runs Komodo Core and Periphery with the MongoDB instance
they require. MongoDB is part of this directory because it is private to
Komodo, not a shared database service.

Persistent data, generated communication keys and the protected environment
file live below `/srv/polinetwork/state/komodo`. Core is routed through Traefik
on `pn-edge`; MongoDB and Periphery use the project-private `komodo-api`
network, while Periphery also has outbound access for Git and registries.
Terminal and container-exec features remain disabled.

Komodo is the only service started directly during bootstrap. It is
intentionally excluded from the `core` Stack so a failed Stack deployment
cannot replace its own control plane. After restoring the protected environment
file, run:

```sh
core/komodo/start.sh
```

On a clean Komodo database, Traefik is not available yet. Start Komodo with a
temporary loopback-only port and reach it through an SSH local forward:

```sh
PN_KOMODO_BOOTSTRAP_ACCESS=true core/komodo/start.sh
```

Create one Git-backed Resource Sync named
`polinetwork-vm` for public repository `PoliNetworkOrg/polinetwork-cd`, branch
`vm`, resource path `core/komodo/resources`. Applying it creates or updates the
`core` and `applications` Stacks and then keeps the Resource Sync itself in Git.
The declaration does not auto-deploy either Stack, which prevents a new `core`
project from starting beside the legacy stateful projects during migration.

After the `core` Stack is healthy, rerun `core/komodo/start.sh` without the
temporary variable. Compose recreates Core without the loopback binding;
normal access then uses the Access-protected Traefik/Cloudflare route. A
restored Komodo database already contains the Resource Sync and does not need
this first-run step.
