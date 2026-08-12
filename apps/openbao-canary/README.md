# OpenBao Agent canary

This profile validates the per-application OpenBao Agent pattern. The Agent
authenticates with its dedicated AppRole and renders one secret into a tmpfs
volume consumed by an otherwise network-isolated container.

`bootstrap.sh` creates and verifies the least-privilege OpenBao policy and
credential files without printing their values.
