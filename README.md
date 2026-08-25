# polinetwork-cd

PoliNetwork deployment source of truth. The current AKS manifests remain in
place during migration; the production K3s host bootstrap is documented in
[ansible/README.md](ansible/README.md), and the new Flux root starts at
[`clusters/k3s`](clusters/k3s).
