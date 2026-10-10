# Ansible production bootstrap

These playbooks turn the Terraform-managed `k3s01` Debian 13 ARM64 VM into the
single-node production K3s target. Terraform remains responsible for Azure;
Ansible owns the host, disks, K3s, the Flux bootstrap, and the host-level
control-plane backup. Flux owns resources inside Kubernetes after bootstrap.

## Safety properties

- The Premium and Standard data disks are resolved by Azure LUN, checked for
  their minimum expected sizes, formatted only when blank, and mounted by UUID.
- The K3s binary and Flux Operator manifest have exact versions and SHA-256
  checksums.
- Pod and Service CIDRs do not overlap the Azure `10.43.0.0/16` VNet.
- ServiceLB and bundled local-storage are disabled; bundled Traefik is retained
  and Flux configures its Service as `ClusterIP`.
- Pod-CIDR traffic is denied access to Azure IMDS, and admission rejects host
  namespaces outside trusted `kube-system`. Host backups select only the
  dedicated backup managed identity and upload to the private `backups` Blob
  container.
- SSH root/password authentication is disabled, and the host firewall accepts
  SSH only from private ranges (the VNet and the cluster CIDRs; WARP sessions
  arrive from the cloudflared Pods). The NSG denies all inbound traffic, so a
  public IP on the NIC is outbound-only. Azure Run Command or Serial Console is
  the break-glass path.

## Run

Install dependencies from a trusted operator machine that can reach the private
VM, then use the guarded runner. It performs check mode, two apply runs, rejects
a non-idempotent second run, executes the runtime verification, and saves the
non-secret logs under the ignored `ansible/artifacts/` directory:

```sh
cd ansible
ansible-galaxy collection install -r requirements.yml
./scripts/provision-and-verify.sh
```

The second provision run must report no substantive changes. To run from inside
the VM through Azure Run Command, first place a reviewed checkout on the VM and
run `./scripts/provision-and-verify.sh inventories/local/hosts.yml`. Do not copy
a private SSH key or secret value into the repository or Azure Run Command
parameters.

The backup timer writes a consistent SQLite backup plus the K3s server token and
configuration, uploads the archive over HTTPS using `id-k3s-backup`, and retains
seven days of local staging copies. `verify.yml` forces a fresh upload and checks
that its SQLite database and custody files can be restored locally. A clean-VM
off-host restore remains mandatory before application cutover.

Daily SSH uses Cloudflare Access for Infrastructure: WARP routes 10.43.1.4/32
through the `k3s01` tunnel, the "k3s01 SSH" Access application admits the
Direttivo Entra group as `pnadmin`, and sshd trusts the account's short-lived
certificate authority (`cloudflare_ssh_ca_public_key`). Azure Run Command and
Serial Console remain the break-glass path.
