# OpenBao Agent canary

This profile validates the per-application OpenBao Agent pattern. The Agent
authenticates with its dedicated AppRole and renders one secret into a tmpfs
volume consumed by an otherwise network-isolated container.

`bootstrap.sh` creates and verifies the least-privilege OpenBao policy and
credential files without printing their values.

Use this folder as the secret-bearing application contract:

1. Store values under an application-owned OpenBao path such as
   `secret/apps/x`.
2. Give the folder's AppRole read access only to that path.
3. Reference keys in an Agent `.ctmpl` file and render them into the shared
   tmpfs volume.
4. Mount only the rendered file into the application container.

Docker Compose has no native OpenBao secret provider, so the Agent sidecar is
the boundary that keeps the AppRole and OpenBao network access away from the
application.
