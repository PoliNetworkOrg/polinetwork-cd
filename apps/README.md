# Docker applications

Each immediate child directory is one PoliNetwork application and one Compose
project. Workloads move here from [`../k8s-apps/`](../k8s-apps/) after their
ARM64 image, health checks, resource limits, persistence and rollback behavior
have passed the VM migration gates.

Adding `apps/x/compose.yaml` is enough for doco.cd to discover and reconcile
it. Runtime secrets live under an application-owned OpenBao path. Reference
them in `apps/x/.doco-cd.yaml`, then expose them to only the required service
with an environment-backed Compose secret. The
[`openbao-canary/`](openbao-canary/) folder is the smallest complete example.

Applications normally join `pn-app`; only routed HTTP services also join
`pn-edge`. Use a unique folder name across `apps/` and `core/`, or set an
explicit project `name` in the folder's `.doco-cd.yaml`.
