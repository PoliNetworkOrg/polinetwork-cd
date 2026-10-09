# polinetwork-cd

PoliNetwork deployment source of truth for the K3s cluster. Flux on `k3s01`
tracks this `k3s-flux` branch from [`clusters/k3s`](clusters/k3s); each
application lives in `apps/<namespace>`. The production K3s host bootstrap is
documented in [ansible/README.md](ansible/README.md). AKS keeps deploying the
root-level application folders from `main` until cutover.
