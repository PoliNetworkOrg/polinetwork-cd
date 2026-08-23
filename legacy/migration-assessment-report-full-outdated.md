# LEGACY — assessment esteso precedente

> Documento non operativo e non aggiornato con le decisioni finali. La sorgente corrente è `../migration-plan.md`; l’HTML corrente è `../migration-plan.html`.

# PoliNetwork — Assessment per la migrazione AKS → K3s single-node

**Data dell'osservazione:** 13 agosto 2026

**Ambiente:** subscription Azure Sponsorship, regione `westeurope`

**Branch di lavoro:** `k3s-ansible`

**Stato del documento:** assessment read-only; nessuna modifica infrastrutturale applicata

> Questo documento è il deliverable dell'assessment. Non è un runbook esecutivo e non autorizza alcun `apply`, deploy, cutover o decommissioning. Il futuro `migration-runbook.html` dovrà essere prodotto solo dopo revisione e approvazione di questo report.

## Convenzioni e attendibilità

- **Osservato**: verificato il 13 agosto 2026 tramite Azure CLI, `kubectl`, Git, API dei registry o file locali.
- **Dichiarato**: presente nel codice, ma non necessariamente nello state o nell'ambiente live.
- **Inferito**: conclusione tecnica derivata da più osservazioni; è indicata come tale.
- **Da verificare**: non determinabile in modo affidabile con gli accessi read-only disponibili.
- Nessun valore di Secret Kubernetes o di Azure Key Vault è stato letto o stampato. Nel report compaiono esclusivamente nomi, metadata e relazioni.

Repository e riferimenti principali analizzati:

- Terraform: `../terraform`, branch `stable`, commit `bb36745…`;
- desired state AKS: `../polinetwork-cd`, riferimento remoto `origin/main`, commit `6ff993a523f6c82de90786b898450dd7735df3be`;
- repository applicativi locali: `admin`, `backend`, `polinet.cc`, `telegram`, `web` e gli altri repository presenti nella directory parent;
- ambiente live: subscription Azure attiva e contesto Kubernetes `aks-polinetwork`.

La directory `legacy/` di questo repository contiene il materiale della precedente migrazione Docker Compose. È stata deliberatamente esclusa come fonte architetturale; le risorse Azure eventualmente create da quel lavoro sono comunque inventariate perché esistono nell'ambiente reale.

---

## Scope update — 14 agosto 2026

Questo assessment viene aggiornato con il perimetro operativo approvato:

- **da migrare ora:** solo `bot-maintenance`;
- **da mantenere come legacy:** MariaDB, con dati da preservare e restore verificato, ma senza introdurre nuovo lavoro applicativo non necessario;
- **fuori scope esplicito:** bot C# (`bot-rooms`), `bot-prod` e `tutor-prod`. Non devono essere ricostruiti, riattivati o trattati come blocker ARM64;
- **produzione durante la transizione:** AKS resta il cluster production; VM-K3s è dev/staging e access mode finché la migrazione incrementale non viene approvata;
- **Cloudflare:** gli hostname Zero Trust esistenti restano la configurazione di riferimento. Il lavoro target consiste nel mappare le route esistenti verso Ingress/Traefik e spostare `cloudflared` in Flux/cluster, non nel reinventare gli hostname;
- **secrets:** il report mantiene solo metadata e nomi; nessun valore deve entrare in Git, nel report o nei comandi.

Esecuzione già completata per il primo workload:

- repository clonata: `PoliNetworkOrg/bot-maintenance`;
- commit `dba6d33`: build multi-arch `linux/amd64,linux/arm64`;
- commit `90bd247`: pubblicazione del tag `latest` multi-arch;
- commit `f0e6595`: rimozione del tag `main-${{ github.run_number }}`;
- GitHub Action precedente: [Docker Image CI run 31801957423](https://github.com/PoliNetworkOrg/bot-maintenance/actions/runs/31801957423), conclusa `success` in 31 secondi;
- la nuova run finale del commit `f0e6595` pubblica esclusivamente `latest` con immagini `linux/amd64` e `linux/arm64`;
- nessun deploy o modifica al cluster AKS eseguito: AKS continua a usare il riferimento precedente fino alla wave dev/staging.

La run ha prodotto un warning non bloccante: le action Docker/checkout usate dal workflow sono ancora target Node.js 20 e GitHub le forza a Node.js 24. Il repository mostra inoltre 5 alert Dependabot preesistenti (3 high, 2 moderate). Vanno gestiti in una PR separata di dependency/security maintenance, senza mescolarli al cambio ARM64 già validato.

Questo aggiornamento prevale sulle ipotesi più ampie presenti nelle sezioni ARM64 e nel primo executive summary.

---

## 1. Executive summary

La migrazione incrementale è tecnicamente realizzabile sulla VM ARM64 `Standard_E2ps_v6` da 2 vCPU e 16 GiB. Il primo workload da portare è esclusivamente `bot-maintenance`; i bot C# sono fuori scope e non bloccano il progetto. Il workflow ARM64 di `bot-maintenance` è ora passato. La VM-K3s staging può essere preparata mentre AKS resta production. I gate residui prima di un qualunque cutover production/data sono: backup e restore verificati per i dati che resteranno necessari, mapping delle route Cloudflare esistenti verso Traefik, separazione delle ownership Terraform/Ansible/Flux e checklist security approvata. L'accesso allo state è stato recuperato con `source ./access_key.sh`: `terraform plan -lock=false -no-color` ha restituito `No changes`, mentre `plan -refresh-only` ha evidenziato solo attributi sensibili ricalcolati dello storage backup.

Lo stato corrente è più fragile di quanto suggerisca il semplice conteggio dei workload. AKS esegue Kubernetes `1.29.13`, mentre in West Europe Azure offre oggi le minor `1.31`–`1.36`; il solo nodo allocabile ha circa 5,65 GiB e la memoria è al 100% secondo `kubectl top`. Prometheus mostra, sui sette giorni disponibili, CPU media 25,5%, picco 39,3%, memoria media 77,3% e picco 86,2%. L'uso applicativo osservato è modesto; gran parte dell'overhead deriva da AKS, Argo CD, Longhorn e Kubernetes Dashboard. Il passaggio a K3s e la rimozione di questi componenti rende plausibile il target da 16 GiB. Le 2 vCPU restano il limite reale: l'idoneità va confermata con un canary ARM64 e soglie di accettazione esplicite.

La raccomandazione è:

1. Debian 13 stable ARM64 su una VM sostituibile, con OS disk separato e data disk Standard SSD inizialmente da 128 GiB;
2. Terraform proprietario esclusivo delle risorse Azure; Ansible proprietario del sistema operativo e di K3s; Flux proprietario esclusivo dello stato Kubernetes;
3. K3s single-server con SQLite, secrets encryption, `local-path-provisioner`, CoreDNS e metrics-server; ServiceLB e Traefik bundled disabilitati; Traefik installato e versionato tramite Flux;
4. niente Longhorn su un solo nodo: volumi locali sul data disk, StatefulSet per i database e backup applicativi cifrati verso storage ZRS esterno;
5. Flux bootstrap da repository Git pubblico senza PAT di bootstrap; source/kustomize/helm controller e image automation per i tag delle app PoliNetwork;
6. tre Key Vault finali, per trust boundary (`platform-prod`, `applications-prod`, `ci-cd`), mantenendo temporaneamente `kv-polinetwork` come vault di transizione;
7. `SecretStore` namespaced e `ExternalSecret` espliciti, non un `ClusterSecretStore` globale;
8. `cloudflared` come Deployment riconciliato da Flux, con token fornito da ESO e traffico interamente outbound;
9. migrazione Argo → Flux per singola applicazione, senza doppia ownership;
10. test di disaster recovery su VM pulita prima del decommissioning di AKS.

Il costo retail target noto è circa **USD 85–100/mese**, esclusi traffico, transazioni, retention effettiva dei backup e possibili sconti della sponsorship: `E2ps_v6` costa USD 0,11/h (circa 80,30/mese), E4 + E10 circa USD 12/mese, un IP Standard circa USD 3,65/mese. Tre Key Vault Standard non introducono un canone fisso significativo: sono fatturate soprattutto le operazioni. La stima va validata con Cost Management, perché la API di consumption della sponsorship restituisce quantità/costo non utilizzabili.

**Decisione complessiva:** procedere in modo incrementale con AKS production invariato e VM-K3s in dev/staging. Il primo canary è `bot-maintenance`; nessun cutover production finché backup/restore, networking, secret e security checklist non sono verificati.

---

## 2. Metodo, perimetro e limiti

### 2.1 Controlli eseguiti

- Azure: subscription/tenant, resource group, risorse, VM/AKS/node pool, networking, dischi, storage, Key Vault metadata/access policy, managed identity, service principal, federated credential e role assignment.
- Kubernetes: risorse namespaced e cluster-wide, immagini, resource requests/limits, PVC/PV/StorageClass, Secret metadata, SecretProviderClass, Argo CD, networking, metriche istantanee e dati Prometheus.
- Git/Terraform: branch e working tree di ogni repository, moduli/provider/backend/workflow, manifests Argo/Kustomize, Dockerfile e workflow di build.
- Registry: manifest OCI delle immagini live, senza pull o deploy.
- Costi: Azure Retail Prices API, prezzo Consumption in USD per `westeurope`, rilevato il 13 agosto 2026.

### 2.2 Operazioni non eseguite

Non sono stati eseguiti `terraform apply`, comandi Kubernetes mutativi, modifiche Azure/Cloudflare/DNS/Key Vault/RBAC, accessi SSH, rotazioni o deploy. Sono stati eseguiti `terraform state list`, `terraform plan -refresh-only -lock=false` e `terraform plan -lock=false` in sola lettura dopo `source ./access_key.sh`; il piano normale ha restituito `No changes`. `terraform show` non è stato usato per evitare di stampare o manipolare valori sensibili. L'unico commit/push effettuato è quello esplicitamente richiesto nella repository `bot-maintenance`; questo repository di assessment non è stato committato né pushato.

### 2.3 Limiti dell'evidenza

- Nessun accesso Cloudflare API: gli hostname Zero Trust sono noti come configurazione esistente, ma il mapping completo hostname → Service/Ingress deve essere esportato o verificato prima del passaggio a Traefik.
- Nessuna lettura dei secret value: non è possibile validarne formato o funzionamento, correttamente.
- Cost Management nella subscription Sponsorship non restituisce costi affidabili; i costi sono prezzi retail, non fattura effettiva.
- Prometheus raccoglie sostanzialmente sé stesso e node-exporter, non una serie completa dei pod. Il capacity planning applicativo è quindi prudenziale.
- Lo state Terraform è ora leggibile con `access_key.sh`; la coverage è verificata, ma il codice possiede ancora risorse Kubernetes/Helm e data source di secret che dovranno essere rimosse dal target.
- I sorgenti dei bot C# non sono presenti localmente: sono fuori scope e non verranno corretti o migrati in questa iniziativa.

### 2.4 Procedura read-only Terraform/Azure

La sessione autorizzata parte dalla repository Terraform, perché `access_key.sh` prepara l'ambiente Azure. I comandi sotto non applicano modifiche:

```bash
cd /home/lorenzo/dev/PoliNetwork/terraform
source ./access_key.sh

az account show --query '{subscription:id,tenant:tenantId,user:user.name}' -o json
az group list --query '[].name' -o table

terraform state list
terraform plan -refresh-only -lock=false -no-color
terraform plan -lock=false -no-color
```

`-lock=false` evita di creare un lock remoto durante l'ispezione. Non eseguire `terraform apply`, `terraform destroy`, `terraform import`, `terraform state rm/mv`, né comandi Azure `update/delete` o comandi Kubernetes mutativi. Non usare `terraform show -json` o output di provider se non è stato prima verificato che non contengano valori sensibili.

Risultato osservato il 14 agosto 2026:

- `terraform state list`: riuscito;
- `terraform plan -refresh-only -lock=false`: riuscito, con soli attributi sensibili ricalcolati per lo storage backup;
- `terraform plan -lock=false`: `No changes. Your infrastructure matches the configuration.`

Questo rimuove il blocker di accesso allo state, ma non autorizza ancora un apply: il target deve prima spostare fuori da Terraform Kubernetes/Helm e data source dei secret.

### 2.5 Verifica ripetibile di `bot-maintenance`

La repository è pubblica e il codice non contiene secret. Il workflow usa il `GITHUB_TOKEN` ephemeral per pubblicare su GHCR; nessun token applicativo deve essere aggiunto al repository.

Per replicare localmente la build multi-arch su Arch Linux:

```bash
sudo pacman -S docker-buildx qemu-user-static qemu-user-static-binfmt
sudo systemctl restart docker
docker run --privileged --rm tonistiigi/binfmt --install arm64

cd /home/lorenzo/dev/PoliNetwork/bot-maintenance
docker buildx create --name polinetwork-builder --use
docker buildx inspect --bootstrap
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/polinetworkorg/bot-maintenance:local \
  --output type=oci,dest=/tmp/bot-maintenance-multiarch.tar .
```

Per verificare la pipeline e il tag `latest` già pubblicato:

```bash
gh run view 31803305519 --repo PoliNetworkOrg/bot-maintenance
docker manifest inspect ghcr.io/polinetworkorg/bot-maintenance:latest \
  | jq '[.manifests[].platform | {os, architecture}]'
```

Il run `31801957423` ha validato la build multi-arch precedente. La run finale `31803305519` è `success` e il manifest `latest` contiene `linux/amd64` e `linux/arm64` (oltre agli artefatti di attestazione OCI marcati `unknown/unknown`). Il tag non va ancora inserito nel GitOps production: Flux dovrà seguirlo soltanto nell'overlay VM-K3s staging.

---

## 3. Stato attuale

```text
Internet
  │
  ├─ Cloudflare DNS / remote-managed Tunnel
  │      │ token in Kubernetes Secret
  │      ▼
  │   cloudflared (2 pod, AKS)
  │      └─ route remote non presente in Git
  │
  ├─ Public Load Balancer: MariaDB :3306
  └─ Public Load Balancer: PostgreSQL :5432
         │
         ▼
AKS aks-polinetwork — Kubernetes 1.29.13
  ├─ userpool: 1 × Standard_B2ms, amd64, ~5.65 GiB allocabili
  ├─ Argo CD + ApplicationSet + Image Updater
  ├─ Azure Key Vault CSI Provider → kv-polinetwork
  ├─ Longhorn → blob longhorn-backups
  ├─ Azure Disks → MariaDB / PostgreSQL
  ├─ Prometheus + Grafana + node-exporter
  └─ applicazioni PoliNetwork

GitHub Actions → GHCR/Docker Hub
Terraform → Azure + Kubernetes + Helm (responsabilità oggi miste)
```

### 3.1 Osservazioni prioritarie

| Severità | Osservazione | Conseguenza |
|---|---|---|
| Critica | Argo CD ha accesso anonimo abilitato e `policy.default: role:admin` | Un accesso non autenticato al server, se raggiungibile, avrebbe privilegi amministrativi. Verificare esposizione e correggere con change separato urgente. |
| Critica | MariaDB e PostgreSQL sono esposti da LoadBalancer pubblici | Superficie di attacco non necessaria; il target non deve esporre le porte database. |
| Critica | Nessun backup database-aware/restore test osservato per i due DB su Azure Disk | Un backup di volume non garantisce consistenza né ripristinabilità applicativa. |
| Alta | AKS 1.29.13 è fuori dalle versioni oggi offerte in `westeurope` | Piattaforma obsoleta; ridurre la durata della migrazione, senza saltare i gate. |
| Alta | Nodo al 100% memoria allocabile nella fotografia `kubectl top` | Rischio eviction/OOM e nessun margine per operazioni pesanti. |
| Risolto per la build | `bot-maintenance` era `amd64`-only | Il workflow pubblica esclusivamente `latest` multi-arch; resta da eseguire il canary soltanto su VM-K3s staging. |
| Informativa | Bot C# `bot-rooms`, `bot-prod` e `tutor-prod` non sono ARM64-ready | Fuori scope esplicito; non devono essere riattivati da Flux. |
| Alta | Terraform possiede anche Helm/Kubernetes e data source di secret | Il target deve separare ownership prima di qualunque apply di migrazione. |
| Alta | NSG della VM `vm01` consente SSH da `0.0.0.0/0` | Non accettabile come configurazione target. |
| Alta | Container `file-blobs` è pubblico e storage accetta shared key | Va verificata la necessità; separare/hardenizzare lo storage IaC. |
| Media | Argo Image Updater usa write-back `argocd`, non Git | Il digest live può divergere dal repository; desired state non completamente riproducibile. |
| Media | Longhorn è configurato con 3 repliche su un solo nodo | Nessuna HA reale, overhead rilevante e configurazione incoerente. |
| Media | Il PVC `redis-pvc` è montato nel pod applicativo `bot-ts`, non nel pod Redis | Possibile errore di persistenza; il Redis live appare stateless. |

---

## 4. Inventario Azure

### 4.1 Subscription e resource group

| Campo | Valore osservato |
|---|---|
| Subscription | `Microsoft Azure Sponsorship` (`dcd88855-70df-49a0-9f15-a91941bba034`) |
| Tenant | `7f8cafc8-4314-4070-9744-fe02f91bcb21` |
| Cloud | AzureCloud |
| Regione principale | `westeurope` |
| Resource group principali | `rg-polinetwork`, `MC_rg-polinetwork_aks-polinetwork_westeurope` |
| Altri RG pertinenti | `temp`, `users-polinetwork`, `NetworkWatcherRG`, `azureapp-auto-alerts…` |

### 4.2 Risorse core

| Nome / gruppo | Tipo e regione | Dipendenze | Dichiarata in Terraform | Target | Impatto costo |
|---|---|---|---|---|---|
| `aks-polinetwork` / `rg-polinetwork` | AKS 1.29.13, West Europe | VNet AKS, LB, node pool, CSI, identità | Sì | Eliminare solo in fase 9 | Control plane Free; compute/network/dischi restano a consumo |
| `userpool` | VMSS 1 × `Standard_B2ms`, amd64 | AKS | Sì | Eliminare con AKS | ~USD 70,08/mese retail compute |
| `supportpool` | `Standard_B2s`, count 0 | AKS | Sì | Eliminare | Nessun compute con count 0 |
| `vm01` | VM `Standard_E2ps_v6`, ARM64, Debian 13 | NIC, PIP, tre dischi, MI | Sì, ma appartiene alla precedente migrazione | Non adottare implicitamente; importare/ricreare secondo target approvato | ~USD 80,30/mese compute |
| OS disk `vm01` | Standard SSD E4 32 GiB | VM | Sì | Mantenere o ricreare | ~USD 2,40/mese + transazioni |
| `disk-core` | Premium SSD P4 32 GiB | `vm01` | Sì | Eliminabile dopo inventario dei dati legacy | ~USD 5,81/mese |
| `disk-services` | Standard SSD E6 64 GiB | `vm01` | Sì | Riutilizzo non automatico; preferito nuovo data disk dichiarato | Prezzo da verificare nel piano |
| `md-polinetwork` | Standard HDD S10 100 GiB | PV MariaDB | Sì | Migrare dati, poi eliminare | ~USD 5,89/mese + transazioni |
| `md-polinetwork-postgres` | Premium SSD P4 32 GiB | PV PostgreSQL | Sì | Migrare dati, poi eliminare | ~USD 5,81/mese |
| AKS managed OS disk/VMSS | disco nodo | `userpool` | Indiretto | Eliminare con node pool | Da Cost Management |
| `kv-polinetwork` | Key Vault Standard | app, CSI, CI, legacy, VM MI | Sì | Mantenere come vault di transizione; migrare e poi valutare decommission | USD 0,03/10k operazioni standard |
| `polinetworksa` | Storage Account LRS | Terraform state, file pubblici, backup Longhorn | Sì | Mantenere, separare/hardenizzare funzioni | capacità + operazioni |
| `polinetworkbackups` | Storage Account Standard ZRS | backup legacy/target | Sì | Mantenere come destinazione backup | capacità ZRS + operazioni |
| `id-vm01-backup` | User-assigned MI | storage backups | Sì | Mantenere solo se riusata dalla VM target | Nessun canone diretto |
| `id-vm01-openbao` | User-assigned MI | Key Vault key operations | Sì | Legacy: eliminare dopo verifica dipendenze | Nessun canone diretto |
| AKS CSI managed identity | User-assigned MI gestita AKS | lettura `kv-polinetwork` | AKS-managed | Eliminare con AKS dopo ESO | Nessun canone diretto |
| Public IP AKS outbound | Standard PIP | AKS LB | Indiretto | Eliminare con AKS | ~USD 3,65/mese |
| Public IP MariaDB | Standard PIP | LB :3306 | Indiretto/manifest | Eliminare dopo cutover | ~USD 3,65/mese |
| Public IP PostgreSQL | Standard PIP | LB :5432 | Indiretto/manifest | Eliminare dopo cutover | ~USD 3,65/mese |
| Public IP `vm01` | Standard PIP `20.123.148.140` | NIC VM | Sì | Mantenere solo se necessario per SSH; nessun ingresso applicativo | ~USD 3,65/mese |
| AKS Standard Load Balancer | Load Balancer | AKS e DB Service | AKS-managed | Eliminare con AKS | regole + dati, da verificare |
| VNet AKS `10.224.0.0/12` | VNet/subnet | AKS, private endpoint | Sì in parte | Eliminare solo dopo sgancio di tutte le dipendenze | Minimo diretto; PE ha costo |
| `vnet-main` / `snet-services` | `10.42.0.0/16`, `10.42.1.0/24` | VM target | Sì | Mantenere | Nessun canone VNet diretto |
| NSG VM | consente SSH globale, poi deny | NIC/subnet VM | Sì | Modificare nel futuro piano approvato | Nessun canone diretto |
| Private endpoint `polinetworksa` + NIC + Private DNS | rete privata storage | VNet AKS/storage | **Non trovato nel codice** | Decidere se ricreare sulla VNet target o rimuovere | PE/DNS a consumo |
| Container `longhorn-backups` | Blob | Longhorn | Sì/indiretto | Conservare fino a scadenza e restore validation | capacità/operazioni |
| Container `terraform-state` | Blob | backend Terraform | Sì | Mantenere e hardenizzare | trascurabile, ma critico |
| Container `file-blobs` | Blob, public blob access | applicazioni da verificare | Sì | Verificare consumer; non lasciare pubblico per default | capacità/egress |

### 4.3 Risorse correlate ma non parte del cutover Kubernetes

| Risorsa | Decisione proposta |
|---|---|
| Tenant/directory B2C `polinetworkapsusers` | Mantenere; verificare dipendenza del backend, fuori dal decommission AKS. |
| Azure Communication Services `pn-comms`, `pn-email-comms` e dominio | Mantenere finché i consumer sono confermati. |
| Action group / alert Azure | Mappare agli alert target, poi rimuovere solo gli elementi AKS-specifici. |
| Network Watcher | Servizio regionale Azure; non trattarlo come residuo applicativo. |
| Container Registry | Nessun ACR osservato; le immagini arrivano da GHCR/Docker Hub. |
| Log Analytics | Nessun workspace osservato; non è un costo corrente da migrare. |
| Azure Backup Vault | Nessuno osservato. |
| Snapshot Azure | Nessuno osservato. |

### 4.4 Risorse Azure non riconciliate chiaramente dal Terraform corrente

- private endpoint, NIC e zona DNS privata legati a `polinetworksa`;
- `disk-insp-2-vnet`/NSG in `rg-polinetwork`;
- `disk-inspector-vnet`/NSG nel resource group `temp`, entrambi con regola SSH pubblica;
- risorse B2C, Communication Services, email, alert e NetworkWatcher, probabilmente con ownership separata;
- tutte le risorse generate nel managed resource group AKS, possedute indirettamente dal servizio;
- role assignment a principal non più risolvibili.

Questa lista è **provvisoria** finché non sarà possibile leggere lo state. Non eliminare alcuna risorsa sulla sola base del confronto statico.

---

## 5. Inventario Kubernetes attuale

### 5.1 Cluster

| Campo | Valore osservato |
|---|---|
| Cluster/context | `aks-polinetwork` |
| Kubernetes | `1.29.13` |
| Client `kubectl` | `1.34.2`; skew oltre il range supportato di ±1 minor |
| Network plugin/policy | kubenet + Calico |
| Load balancer | Standard |
| API server | pubblico |
| OIDC / workload identity | disabilitati |
| Nodo attivo | `Standard_B2ms`, 2 vCPU, ~8 GiB fisici, 1900m/5.65 GiB allocabili |
| Namespace | 33, molti vuoti o legacy |
| HPA/VPA | nessuno |
| NetworkPolicy applicative | nessuna; solo policy di sistema `konnectivity` |
| Ingress/Gateway | nessun Ingress o Gateway live; nessun controller ingress attivo |
| Cert-manager | namespace vuoto, nessun Certificate/Issuer osservato |

### 5.2 Workload applicativi e dati

`-` significa request non dichiarata, non consumo nullo.

| Namespace/workload | Immagine live | Deploy | Storage | Secret/Config principali | Request CPU/RAM | ARM64 | Decisione target |
|---|---|---|---|---|---|---|---|
| `admin/admin` | `ghcr.io/polinetworkorg/admin:latest@sha256:b36e…` | Argo/Kustomize | nessuno | config app | `-/-` | sì, manifest multi-arch verificato | Migrare con tag `latest` e Flux digest automation |
| `backend/backend` | `ghcr.io/polinetworkorg/backend:latest@sha256:e1f4…` | Argo/Kustomize | nessuno | `azure-kv` | `-/-` | sì | Migrare dopo ESO |
| `bot-mat/bot-mat-maintenance` | `ghcr.io/polinetworkorg/bot-maintenance:latest@sha256:934d…` | Argo/Kustomize | nessuno | `azure-kv` | `-/-` | **sì, build verificata** | Primo workload: usare `latest` e Flux digest automation solo in dev/staging |
| `bot-rooms/bot-rooms` + init | `botcsharp_dev@sha256:da4f…`, `botcsharp-config@sha256:d22b…` | Argo/Kustomize | nessuno | config generata da init | `10m/100Mi` app | **no, entrambe amd64-only** | Fuori scope; non migrare o riattivare |
| `bot-ts/bot-ts` | `ghcr.io/polinetworkorg/telegram:latest@sha256:43be…` | Argo/Kustomize | `redis-pvc` 500 Mi montato sull'app | `azure-kv` | `100m/200Mi` | sì | Correggere ownership PVC |
| `bot-ts/bot-ts-redis` | `redis` non versionata | Argo/Kustomize | **nessun PVC montato** | nessuno | `50m/400Mi` | sì, immagine ufficiale | Usare una versione esplicita e decidere persistenza |
| `cloudflare/cloudflared…` | `cloudflare/cloudflared:latest` | Terraform/Helm | nessuno | token in Secret | `-/-` | sì | Migrare in platform Flux |
| `influxdb/influxdb` | `influxdb` non versionata | Argo | data 5 GiB + config 500 Mi Longhorn | `azure-kv` | `-/-` | sì | StatefulSet, pin e backup nativo |
| `mariadb/mariadb` | `mariadb:10.9.4` | Terraform/Kubernetes | Azure Disk 100 GiB | `mariadb-secret`, initdb, TLS | `50m/500Mi` | sì | Verificare uso; StatefulSet + dump/restore |
| `monitoring/grafana` | `grafana/grafana:latest` | Argo | 1 GiB Longhorn | config | `250m/400Mi` | sì | Tenere solo se dashboard versionate |
| `monitoring/prometheus` | `prom/prometheus` non versionata | Argo | 12 GiB Longhorn | config | `-/-` | sì | Stack leggero, retention breve |
| `monitoring/node-exporter` | `prom/node-exporter:v1.8.2` | Argo | host mounts | config | `-/-` | sì | Mantenere con versione esplicita |
| `polinetcc/polinetcc` | `ghcr.io/polinetworkorg/polinet.cc:latest@sha256:4310…` | Argo/Kustomize | nessuno | `azure-kv` | `-/-` | sì | Migrare dopo ESO |
| `postgres/postgres` | `postgres:17.4` | Argo | Azure Disk 32 GiB | `azure-kv` | `-/-` | sì | StatefulSet + backup/restore |
| `uptime-kuma/uptime-kuma` | digest `4c364e…` | Argo | 200 Mi Longhorn | config | `-/-` | sì | Migrare dopo export/restore |
| `web/web` | `ghcr.io/polinetworkorg/web:latest@sha256:fa6c…` | Argo/Kustomize | nessuno | config | `-/-` | sì | Migrare per primo/canary |

`bot-prod` e `tutor-prod` risultano presenti nei repository/namespace ma non hanno workload live. Sono fuori scope e non devono essere riattivati incidentalmente da Flux.

### 5.3 Componenti platform

| Componente | Stato | Target |
|---|---|---|
| Argo CD 2.14.3 | 8 workload inclusi Redis, Dex, Image Updater | Sostituire con Flux, poi eliminare |
| Secrets Store CSI Driver + Azure Provider | DaemonSet AKS, 7 SecretProviderClass | Sostituire con ESO |
| Longhorn 1.8.1 | numerosi controller/sidecar, ~1,2 GiB RAM | Eliminare; storage locale + backup esterno |
| Kubernetes Dashboard | 5 workload e service account cluster-admin | Eliminare; amministrazione via `kubectl` con RBAC |
| Calico/Tigera | gestito da AKS | Non migrare come operator; usare networking K3s e NetworkPolicy |
| CoreDNS | 2 repliche AKS | K3s bundled, 1 replica sufficiente |
| metrics-server | 2 repliche AKS | K3s bundled |
| Prometheus/Grafana/node-exporter | osservabilità parziale | Ridimensionare, non sostituire con stack più pesante |

### 5.4 Namespace da rivedere/eliminare

Sono vuoti o apparentemente legacy: `app-dev`, `bot-prod`, `cert-manager`, `ingress`, `ingress-nginx`, `nginx-ingress`, `tutor-prod`, vari namespace `test`/`spc-test`. La rimozione deve avvenire solo dopo confronto con Git e conferma owner; Flux non deve ricrearli per errore.

### 5.5 RBAC Kubernetes rilevante

- binding `admin-global` assegna `cluster-admin` direttamente a un'email e a un GUID utente;
- Kubernetes Dashboard possiede un service account amministrativo cluster-wide;
- Argo `AppProject` ammette qualsiasi repository/destinazione/risorsa;
- Argo ha anonymous access e default role admin;
- non sono state osservate boundary per namespace applicativi.

Il target deve sostituire binding individuali con gruppi Entra/documentati e ruoli stretti, eliminare Dashboard e non esporre Flux UI perché Flux non ne richiede una.

---

## 6. Inventario storage e database

### 6.1 Volumi live

| Owner | PVC/PV/SC | Provisioning | Capacità / uso osservato | Classe dato | Backup osservato | RPO/RTO proposto |
|---|---|---|---|---|---|---|
| MariaDB | `mariadb-storage-claim` | Azure Disk `md-polinetwork`, Standard HDD | 100 GiB / ~577 MiB | 3 — persistente critico | nessun dump o snapshot Azure osservato | RPO 6h, RTO 4h |
| PostgreSQL | `postgres-pvc` | Azure Disk `md-polinetwork-postgres`, Premium P4 | 32 GiB / ~88 MiB | 3 — persistente critico | nessun `pg_dump` o snapshot osservato | RPO 6h, RTO 4h |
| InfluxDB | data + config | Longhorn | 5 GiB/~15 MiB; 500 MiB/~28 KiB | 3 se metriche storiche necessarie, altrimenti 2 | backup Longhorn solo se volume taggato | RPO 24h, RTO 8h |
| Prometheus | `prometheus-pvc` | Longhorn | 12 GiB / ~354 MiB | 1/2, ricreabile con perdita storico accettata | Longhorn | RPO non critico, RTO 8h |
| Grafana | `grafana-pvc` | Longhorn | 1 GiB / ~51 MiB | 2 se dashboard non in Git | Longhorn | esportare dashboard; RTO 8h |
| Uptime Kuma | `uptime-pvc` | Longhorn | 200 MiB / ~19 MiB | 3 per config/cronologia | Longhorn | RPO 24h, RTO 8h |
| bot-ts | `redis-pvc` | Longhorn | 500 MiB / ~24 KiB | classificazione incerta | Longhorn | chiarire consumer prima del cutover |

Longhorn esegue backup giornalieri con retention 3 verso `azblob://longhorn-backups@core.windows.net`, ma copre solo i volumi taggati e non i due Azure Disk. Nessuna evidenza read-only dimostra un restore riuscito. La replica Longhorn 3 su un nodo non protegge dalla perdita del nodo e aumenta memoria/IO.

### 6.2 Database dentro o fuori K3s

Relazioni consumer osservabili senza leggere dati: `backend` e `polinetcc` referenziano credenziali PostgreSQL; `bot-ts` referenzia InfluxDB; per MariaDB non è stato dimostrato un consumer live univoco dai manifest correnti e il servizio è pubblicamente raggiungibile, quindi owner e client esterni sono un gate umano. Nessuna query sui contenuti dei database è stata eseguita.

**Raccomandazione:** mantenere inizialmente PostgreSQL, MariaDB e InfluxDB dentro K3s sul data disk locale, perché i dataset sono piccoli e servizi Azure gestiti aggiungerebbero costo e complessità rispetto al budget. La scelta è condizionata a:

- conversione a StatefulSet;
- backup logico applicativo cifrato fuori VM;
- restore provato su database vuoto;
- requests/limits e sonde;
- verifica che MariaDB sia ancora realmente necessaria;
- finestra di indisponibilità esplicita: un nodo singolo non offre HA.

Passare a un servizio gestito diventa giustificato solo se l'RTO/RPO richiesto è incompatibile con il single-node o se il carico IOPS/CPU supera il canary. Il costo deve essere calcolato prima, non assunto.

---

## 7. Inventario dei secret

### 7.1 Consumo runtime attivo: CSI → ESO

| Workload | SecretProviderClass | Vault | Secret remoti (nomi) | Modalità attuale | Secret K8s target | ExternalSecret target |
|---|---|---|---|---|---|---|
| backend | `backend-spc` | `kv-polinetwork` | `backend-azure-client-id`, `backend-azure-client-secret`, `backend-azure-tenant-id`, `backend-encryption-key`, `backend-auth-github-secret`, `backend-auth-github-id`, `backend-auth-secret`, `postgres-root-password`, `postgres-root-user` | CSI + Secret `azure-kv` | `backend-runtime` | `backend-runtime` nel namespace `backend` |
| bot-mat | `bot-mat-spc` | `kv-polinetwork` | `prod-bot-mat-token` | CSI + `azure-kv` | `bot-mat-runtime` | `bot-mat-runtime` |
| bot-rooms | `bot-rooms-spc` | `kv-polinetwork` | `dev-aule-bot-token`, `dev-db-user`, `dev-db-password` | CSI/config init | `bot-rooms-runtime` | `bot-rooms-runtime` |
| bot-ts | `bot-ts-spc` | `kv-polinetwork` | `bot-ts-token`, `influxdb-token`, `openai-api-key` | CSI + `azure-kv` | `bot-ts-runtime` | `bot-ts-runtime` |
| influxdb | `influxdb-spc` | `kv-polinetwork` | `influxdb-admin-password` | CSI + `azure-kv` | `influxdb-runtime` | `influxdb-runtime` |
| polinetcc | `polinetcc-spc` | `kv-polinetwork` | `postgres-polinetcc-password`, `postgres-polinetcc-user` | CSI + `azure-kv` | `polinetcc-db` | `polinetcc-db` |
| postgres | `postgres-spc` | `kv-polinetwork` | `postgres-root-user`, `postgres-root-password` | CSI + `azure-kv` | `postgres-admin` | `postgres-admin` |
| test | `spc-test` | `kv-polinetwork` | `ExampleSecret`/test | CSI | nessuno | eliminare dopo conferma |

### 7.2 Classificazione dei 69 metadata Key Vault

La tabella include ogni nome osservato; “legacy/review” significa che nessun consumer live è stato dimostrato, non che il secret sia eliminabile senza verifica.

| Trust boundary / nomi | Consumer noto o probabile | Target | Azione |
|---|---|---|---|
| `cloudflare-tunnel-token`, `cloudflared-vm-tunnel-token` | Cloudflare K8s/legacy VM | `platform-prod` | identificare il tunnel attivo, mantenere un solo token, ruotare dopo cutover |
| `cluster-monitoring-app-password`, `cluster-monitoring-telegram-token`, `grafana-admin-password` | monitoring | `platform-prod` | migrare solo quelli ancora usati; preferire SSO/receiver scoped |
| `zerobyte-app-secret`, `zerobyte-azure-storage-account-key`, `zerobyte-restic-password`, `zerobyte-restic-recovery-key` | backup legacy | `platform-prod` o eliminare | non adottare Zerobyte/OpenBao implicitamente; verificare dati legacy; rimuovere shared key nel target |
| `ca-crt`, `ca-key` | TLS legacy/DB | `platform-prod` se ancora necessari | determinare issuer e data scadenza; non copiare una CA privata senza ownership documentata |
| `compose-vm-ssh-private-key`, `compose-vm-ssh-public-key` | precedente VM | vault di transizione | non riusare come bootstrap target; sostituire con chiavi nominative |
| `admin-db-password`, `backend-auth-github-id`, `backend-auth-github-secret`, `backend-auth-secret`, `backend-azure-client-id`, `backend-azure-client-secret`, `backend-azure-tenant-id`, `backend-encryption-key` | admin/backend | `applications-prod` | ESO namespaced; sostituire credenziali Azure statiche con MI/OIDC dove possibile |
| `postgres-root-password`, `postgres-root-user`, `postgres-polinetcc-password`, `postgres-polinetcc-user`, `prod-db-password`, `prod-mat-db-user`, `prod-bot-mat-db-password` | PostgreSQL/app | `applications-prod` | separare admin da role applicativi; ruotare dopo restore/cutover |
| `pgadmin-email`, `pgadmin-password` | amministrazione PostgreSQL legacy | vault di transizione | nessun pgAdmin live osservato; eliminare o migrare solo dopo owner check |
| `influxdb-admin-password`, `influxdb-token` | InfluxDB/bot-ts | `applications-prod` | creare token least-privilege per consumer |
| `bot-ts-token`, `openai-api-key`, `prod-bot-mat-token`, `prod-mod-bot-token`, `prod-tutorapp-bot-token` | bot/app runtime | `applications-prod` | ESO nel solo namespace consumer |
| `dev-aule-bot-token`, `dev-db-host`, `dev-db-user`, `dev-db-password`, `dev-app-admin-db-password`, `dev-app-admin-db-user`, `dev-app-secret-token`, `dev-mat-config-password`, `dev-mod-bot-token`, `dev-newbot-db-password`, `dev-newbot-db-user`, `dev-tutorapp-db-password`, `dev-tutorapp-db-user` | ambienti dev/legacy | vault di transizione, poi eventuale `applications-dev` | non mischiare dev e prod nel nuovo vault; confermare se l'ambiente esiste |
| `prod-mod-db-user`, `prod-mod-git-email`, `prod-mod-git-password` | bot mod legacy | `applications-prod` o `ci-cd` in base al consumer | la password Git runtime va eliminata a favore di GitHub App/deploy key scoped |
| `prod-tutorapp-auth-password`, `prod-tutorapp-auth-user`, `prod-tutorapp-azure-client-id`, `prod-tutorapp-azure-secret`, `prod-tutorapp-db-password`, `prod-tutorapp-db-user` | tutor-prod inattivo | vault di transizione | non migrare finché workload/owner non sono confermati |
| `dockerhub-pat`, `dockerhub-username` | CI image push/pull | `ci-cd` | preferire OIDC/short-lived se supportato; accesso solo CI |
| `gh-runner-token`, `doco-cd-github-webhook-secret`, `bot-prod-git-ssh-key` | CI/CD/legacy deploy | `ci-cd` | classificare e ruotare; non esporre a ESO salvo runtime indispensabile |
| `argocd-client-id`, `argocd-client-secret` | Argo SSO | vault di transizione | eliminare dopo rimozione Argo e revocare client |
| `mc-amp-license`, `mc-amp-password` | servizio non osservato | vault di transizione | identificare owner/consumer prima di qualsiasi migrazione |
| `elasticsearch-password` | servizio non osservato | vault di transizione | verificare inutilizzo; nessun Elasticsearch live osservato |

**Nota:** alcuni nomi nella riga dev/prod sono stati accorciati solo nella classificazione logica? No: la lista usa i nomi metadata osservati; nessun valore è riportato. Prima dell'implementazione va generato automaticamente un CSV metadata-only con `id`, `updated`, `enabled`, consumer e owner, conservato in area privata se gli identificatori sono ritenuti sensibili.

### 7.3 Identità e permessi sui secret

| Identità | Risorsa | Permesso attuale | Necessario | Azione proposta |
|---|---|---|---|---|
| AKS CSI managed identity | `kv-polinetwork` | `get` via access policy | nessuno dopo migrazione | rimuovere con AKS |
| VM system/UAMI | Key Vault/storage | permessi eterogenei | solo token ESO e backup scoped | creare identità dedicate, non riusare OpenBao legacy |
| `id-vm01-backup` | container backups | Storage Blob Data Contributor scoped | write/read backup | riusare o ricreare con scope container |
| `id-vm01-openbao` | key operations | crypto key permissions | nessuno nel target proposto | eliminare dopo verifica legacy |
| GitHub Actions Terraform read-only | subscription/state | OIDC, reader/plan | read/plan | mantenere, ridurre scope se possibile |
| GitHub Actions Terraform read-write | subscription/state | OIDC, write | apply approvato | mantenere con environment protetto e least privilege |
| SP legacy `azure-cli-2022…` | subscription | Contributor; credential scaduta | nessuno | rimuovere assignment e applicazione dopo audit |
| SP `CAnalyzer…` | subscription | Reader; credential scaduta | probabilmente nessuno | verificare owner, poi rimuovere |
| principal non risolvibili | subscription/Key Vault | Contributor/access policy | nessuno dimostrato | inventario e rimozione separata |
| amministratori umani | subscription/Key Vault | Owner/access policy ampia | operazioni tramite gruppi/PIM | gruppi Entra, separazione control/data plane |

### 7.4 Identità Azure da verificare una per una

Questi sono gli object ID rilevati il 14 agosto 2026. Gli ID non risolvibili hanno `principalName` vuoto e sono i primi candidati a revoca, dopo conferma dell'owner.

| Object ID | Nome/identità osservata | Accesso osservato | Valutazione |
|---|---|---|---|
| `99053e08-87b6-4585-b77d-e9d2072551eb` | principal non risolto | Contributor subscription; Contributor su `kv-polinetwork`; KV Get/List | **Critico:** identificare e revocare se non indispensabile |
| `76786ae8-54bf-4468-b301-f7d1dec5c086` | principal non risolto | Contributor subscription | **Critico:** identificare e revocare |
| `16990676-5daf-4d97-b0d0-a820d31ba947` | principal non risolto | Contributor subscription; Owner sul container `terraform-state` | **Critico:** verificare backend e sostituire con identità Terraform scoped |
| `14db305f-1e26-46cd-8acb-dbe49ef67282` | service principal legacy, principal name app ID `a81e664c-…` | Contributor subscription | verificare credenziale/consumer; rimuovere se legacy |
| `7254cc61-1f41-439b-822d-1fe5a7025a43` | `CAnalyzer`, app ID `2455f2d3-…` | Reader subscription | verificare consumer; probabilmente revocabile |
| `81dd9fd1-ea71-420a-9f8a-8cbb74f479a6` | `gh-action-terraform-readonly`, app `773afc65-…` | Reader subscription; KV Get/List | utile per PR plan; mantenere e limitare allo state/read |
| `f220ce5b-e174-413d-b6f8-04e214b85d76` | `gh-action-terraform-readwrite`, app `76b5658e-…` | Contributor subscription; KV key management e secret Get/List | utile solo apply approvato; proteggere Environment/PIM e ridurre scope |
| `245ea657-bfb5-4ca2-9640-5487c648b902` | identity AKS/managed service, principal `51c7237d-…` | Contributor RG/managed RG/disk | mantenere solo finché AKS esiste; rimuovere con AKS |
| `43fab6a8-439d-4f98-b387-682df65783f8` | AKS Secrets Store CSI identity | KV key Get, secret Get | rimuovere dopo CSI → ESO |
| `5c40836d-796f-4d54-a194-1f0b8374185a` | `id-vm01-openbao` | KV key Get/Wrap/Unwrap | legacy; rimuovere se OpenBao non è target |
| `0959e426-bdaf-4168-9e92-2b43f4d55917` | `id-vm01-backup` | KV secret Get; storage backup scoped | mantenere solo per backup target |
| `6b6a6388-c024-450b-80b4-9dcfa474c9f0` | `adminorg@polinetwork.org` | Owner subscription/AKS; full KV access policy | break-glass/owner, non uso quotidiano |
| `e5c02779-40c6-4034-ac8a-bfa5861eff25` | `Azure Subscriptions Owners` | Owner subscription | gruppo privilegiato; PIM e audit |

#### Procedura read-only esplicita

Eseguire dalla repository Terraform, perché `access_key.sh` imposta la sessione Azure necessaria:

```bash
cd /home/lorenzo/dev/PoliNetwork/terraform
source ./access_key.sh

az account show \
  --query '{subscription:name,subscriptionId:id,tenantId:tenantId,user:user.name}' \
  -o table
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
```

Per ciascun **object ID** della tabella, verificare prima se il service principal esiste e poi elencare esattamente le assegnazioni. Sostituire soltanto il valore di `OBJECT_ID`:

```bash
OBJECT_ID="99053e08-87b6-4585-b77d-e9d2072551eb"

az ad sp show --id "$OBJECT_ID" \
  --query '{objectId:id,appId:appId,name:displayName,type:servicePrincipalType,enabled:accountEnabled}' \
  -o yaml

az role assignment list --all --include-inherited \
  --assignee-object-id "$OBJECT_ID" \
  --query '[].{role:roleDefinitionName,scope:scope,assignmentId:id}' \
  -o table
```

Ripetere per i tre object ID non risolti. Se `az ad sp show` restituisce `does not exist` ma la seconda query mostra ancora ruoli, classificare l'assegnazione come **candidate orphan**: non cancellarla ancora. Controllare in Azure Portal **Microsoft Entra ID → Enterprise applications → Deleted applications** e **Monitoring → Audit logs**, cercando object ID/app ID e l'ultimo owner/consumer. L'assenza dall'elenco live, da Deleted applications e dai log disponibili è un forte indizio di orphan, non una prova che si possa rimuovere senza change review.

Per le applicazioni ancora risolte, prendere l'`appId` dall'output precedente e verificare esclusivamente metadata delle credenziali e subject OIDC; questi comandi non mostrano secret:

```bash
APP_ID="a81e664c-6b68-42e6-b025-6e0677ec5979"

az ad app credential list --id "$APP_ID" \
  --query '[].{name:displayName,start:startDateTime,end:endDateTime,keyId:keyId}' \
  -o table

az ad app federated-credential list --id "$APP_ID" \
  --query '[].{name:name,issuer:issuer,subject:subject,audiences:audiences}' \
  -o yaml

rg -n --hidden --glob '!**/.git/**' \
  'a81e664c-6b68-42e6-b025-6e0677ec5979|azure-cli-2022-12-05-21-16-25' \
  /home/lorenzo/dev/PoliNetwork
```

Risultato già osservato: `azure-cli-2022…` ha una credenziale scaduta il 5 dicembre 2023 e nessuna federation; `CAnalyzer` ha una credenziale scaduta il 15 gennaio 2024 e nessuna federation. Prima della revoca vanno ancora verificati owner, sign-in log Entra e assenza di consumer esterni ai repository locali.

Per le due identità GitHub Actions, verificare che non esistano password e che i subject OIDC coincidano con repository/branch/environment attesi:

```bash
for APP_ID in \
  773afc65-715d-4050-a821-769c46fdb76f \
  76b5658e-375b-454e-b28a-b2d0fb19ab43
do
  az ad app credential list --id "$APP_ID" \
    --query '[].{name:displayName,end:endDateTime,keyId:keyId}' -o table
  az ad app federated-credential list --id "$APP_ID" \
    --query '[].{name:name,issuer:issuer,subject:subject,audiences:audiences}' -o table
done
```

I subject osservati sono:

- read-only: `repo:PoliNetworkOrg/terraform:pull_request` e `repo:PoliNetworkOrg/terraform:ref:refs/heads/stable`;
- read-write: `repo:PoliNetworkOrg/terraform:environment:production`.

La decisione va registrata in una tabella `object-id / owner / consumer / ultimo utilizzo / keep-remove / motivazione / nuovo scope`. Criteri:

1. mantenere GitHub OIDC, restringendo scope e proteggendo l'environment production;
2. mantenere identità AKS/CSI solo fino al decommissioning AKS;
3. mantenere `id-vm01-backup` soltanto se riusata dal backup target;
4. eliminare OpenBao solo dopo aver confermato che non fa parte del target;
5. proporre la revoca dei principal irrisolti e delle app scadute solo con owner assente, nessun consumer, nessun sign-in recente e rollback documentato.

Non eseguire `az role assignment delete`, cancellazioni Entra o modifiche Key Vault durante questa verifica: produrre prima la matrice e approvare un change separato.

---

## 8. Stato Terraform

### 8.1 Struttura e backend

- backend Azure Blob: account `polinetworksa`, container `terraform-state`, blob `state.tfstate`;
- autenticazione backend prevista con Azure AD/OIDC;
- workspace osservato: `default`;
- Terraform locale `1.15.8`; constraint del repository `~> 1.0`, troppo ampio per riproducibilità;
- provider: `azurerm 4.23`, `kubernetes 2.21.1`, `helm 2.17`, oltre a `random`, `local`, `http`;
- moduli: AKS, app/Kubernetes, Argo, Cloudflare, foundation VM, Key Vault, Dashboard, Longhorn, MariaDB, PostgreSQL, storage;
- nessun `local-exec`, `remote-exec` o provisioner Terraform osservato;
- il modulo foundation usa cloud-init e script di formattazione dischi: è configurazione host e deve passare ad Ansible.

File rilevanti: `../terraform/backend.tf`, `../terraform/providers.tf`, `../terraform/data.tf`, `../terraform/modules/foundation/main.tf`, `../terraform/modules/foundation/templates/cloud-init.yaml`, `../terraform/modules/argocd/apps.tf`.

### 8.2 Coverage e drift

Il codice dichiara gran parte di AKS, VM legacy, rete principale, dischi, storage, Key Vault e componenti Kubernetes. Con `source ./access_key.sh` la coverage è stata verificata il 14 agosto 2026: `terraform state list` è riuscito e il piano normale ha restituito `No changes`. Restano comunque questi problemi:

1. private endpoint e alcune reti “disk inspector” non risultano nel codice corrente;
2. il codice possiede ancora AKS, Argo, Cloudflare Helm, Dashboard, Longhorn, MariaDB/PostgreSQL e oggetti Kubernetes;
3. `data.tf` legge valori Key Vault e moduli Kubernetes creano Secret: lo state contiene o può contenere materiale storico sensibile;
4. il piano senza diff certifica solo il codice corrente, non il target K3s desiderato;
5. risorse live e ownership operativa possono ancora divergere, per esempio aggiornamenti immagine Argo non scritti in Git.

**Gate fase 0 rimosso:** l'accesso read-only allo state è disponibile. Il prossimo gate è progettare state split/import/move senza `apply` distruttivi e rimuovere dal target i provider Kubernetes/Helm e i data source di secret.

### 8.3 Responsabilità oggi mischiate

| Oggetto | Owner attuale | Problema | Owner target |
|---|---|---|---|
| Azure resource | Terraform | corretto in principio | Terraform |
| utenti/pacchetti/filesystem/K3s | cloud-init/script Terraform | convergenza fragile, difficile da rieseguire | Ansible |
| namespace/RBAC/Secret/PV/workload | Terraform + Argo | doppia ownership e secret nello state | Flux |
| Helm Argo/Longhorn/Dashboard/Cloudflare | Terraform | cloud plan dipende dal cluster | Flux, se mantenuto |
| aggiornamento immagini | Argo Image Updater runtime | desired state non scritto in Git | CI via PR/commit; Flux riconcilia |
| valori Key Vault | Terraform data source | possibile persistenza nello state | ESO a runtime |

### 8.4 CI Terraform

Sono presenti workflow OIDC moderni per plan/apply e drift, ma anche workflow legacy con `AZURE_CREDENTIALS`/client secret e possibile auto-apply su `stable`. Il target deve consolidare:

- PR: identità read-only, `fmt`, `validate`, lint/security, plan;
- produzione: identità write separata, GitHub Environment protetto, approvazione umana e artefatto plan verificato;
- OIDC esclusivo, senza secret Azure di lunga durata;
- action pin a commit SHA;
- nessun `kubectl` o Helm dal workflow Terraform.

GitHub documenta che OIDC consente token Azure di breve durata senza memorizzare credenziali cloud a lunga vita: [Configuring OpenID Connect in Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure).

---

## 9. Stato Argo CD

### 9.1 Installazione e modello

| Elemento | Osservato |
|---|---|
| Namespace | `argocd` |
| Chart / app | chart 7.8.7, Argo CD 2.14.3 |
| Generazione applicazioni | un ApplicationSet Git generator su `**/config.json` |
| Repository | `polinetwork-cd`, pubblico |
| Revision | `HEAD` |
| Rendering | Kustomize semplice; nessun plugin custom osservato |
| Sync | automatico, prune e self-heal |
| Image update | Argo CD Image Updater 0.15.2, write-back nel parametro Application (`argocd`), non Git |
| Project | destinazioni, repository e risorse cluster `*` |
| Hook/wave | nessun hook o sync wave rilevato |
| Secret repository | Secret metadata presenti; il repository pubblico non richiede credenziale per il read |

Le 12 Application live sono `admin`, `backend`, `bot-mat`, `bot-rooms`, `bot-ts`, `influxdb`, `mariadb`, `monitoring`, `polinetcc`, `postgres`, `uptime-kuma`, `web`. Erano tutte `Synced/Healthy` nella fotografia, ma questo non elimina i problemi di sicurezza e riproducibilità.

### 9.2 Problemi da risolvere

- anonymous access con ruolo predefinito admin;
- project senza boundary;
- digest live aggiornati fuori Git;
- Argo installato da Terraform, mentre le sue Application controllano risorse che Terraform crea anche direttamente;
- MariaDB ha ownership particolarmente mista;
- nessun ordine dichiarativo robusto per CRD/controller/consumer;
- `HEAD` e i riferimenti `latest` privi del digest riflesso riducono il determinismo del restore; il target mantiene `latest` ma registra il digest in Git tramite Flux.

Cloudflare Access con Azure AD riduce l'esposizione esterna, ma non sostituisce automaticamente l'RBAC di Argo: Argo vede ogni richiesta ammessa da Cloudflare come lo stesso utente anonymous, salvo integrazione OIDC/header esplicita. Con `policy.default: role:admin`, quindi, **ogni identità ammessa dalla policy Cloudflare dell'app Argo ottiene admin Argo**.

Policy transitoria, dato che i login applicativi non sono desiderati:

1. Cloudflare Access permette l'app Argo solo a un gruppo IT dedicato e richiede MFA;
2. `policy.default` passa da `role:admin` a `role:readonly`;
3. le modifiche ordinarie avvengono tramite Git, non tramite UI;
4. un accesso admin locale/SSO resta solo break-glass e viene auditato;
5. appena Flux possiede tutte le risorse, Argo, Dex, Image Updater, client Azure AD e Secret associati vengono rimossi.

Per Flux non serve introdurre una nuova UI o un nuovo login OIDC: l'autorizzazione operativa è GitHub branch protection/review più RBAC Kubernetes per il break-glass. Per le altre app interne, Cloudflare Access è sufficiente quando serve solo un controllo “può/non può entrare”; un OIDC applicativo è utile solo se l'app deve conoscere identità, ruoli o audit individuali.

---

## 10. Target architecture

```text
                         ┌──────────────────────────────┐
GitHub repositories ────►│ GitHub Actions               │
  app source              │ test + multi-arch build      │
  GitOps                   │ latest + Flux digest update │
  Terraform/Ansible       └──────────────┬───────────────┘
                                        │ OIDC
                                        ▼
┌──────────────────────────────── Azure subscription ────────────────────────────────┐
│ Terraform                                                                        │
│   RG + VNet/subnet + NSG + PIP + NIC + VM + OS/data disk + UAMI + RBAC + KV     │
│                                                                                    │
│  Debian 13 ARM64 — Standard_E2ps_v6                                                │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │ Ansible: base, security, storage, K3s, Flux bootstrap, backup host support   │  │
│  │                                                                              │  │
│  │ K3s single-node                                                              │  │
│  │   Flux ──► ESO ──► namespaced SecretStore ──► Azure Key Vault              │  │
│  │     ├── Traefik ClusterIP                                                    │  │
│  │     ├── cloudflared ───────── outbound 7844 ─────────► Cloudflare Edge      │  │
│  │     ├── platform/observability                                               │  │
│  │     ├── stateless applications                                               │  │
│  │     └── StatefulSet DB/PVC ──► /srv/k3s-data on dedicated data disk         │  │
│  └──────────────────────────────────────┬───────────────────────────────────────┘  │
│                                         │ encrypted logical/file backups           │
│                                         ▼                                          │
│                              Blob Storage ZRS, off-VM                               │
└────────────────────────────────────────────────────────────────────────────────────┘
```

### 10.1 Confini di ownership

| Sistema | Possiede | Non possiede |
|---|---|---|
| Terraform | risorse Azure, identity/RBAC, rete, VM, dischi, Key Vault, storage | pacchetti OS, filesystem, K3s, risorse Kubernetes, secret value |
| Terraform Cloudflare separato, se approvato | tunnel, route e DNS Cloudflare dichiarativi, con state/identity dedicati | Kubernetes, Azure e token in Git |
| Ansible | utenti, SSH, pacchetti, hardening, mount, K3s, config host, bootstrap iniziale Flux | applicazioni, HelmRelease, ExternalSecret, contenuto Key Vault |
| Flux | controller e stato Kubernetes dichiarativo | VM/NSG/Key Vault/RBAC Azure, configurazione OS |
| ESO | sincronizzazione da Key Vault a Secret Kubernetes | creazione/rotazione del valore remoto |
| CI | test/build/push e proposta di aggiornamento GitOps | deploy diretto con `kubectl apply` |

---

## 11. Diagramma e sequenza di bootstrap

```text
0. Accessi umani + repository Git + state Terraform recuperabile
   │
1. Terraform apply approvato
   ├─ rete/NSG/PIP/NIC
   ├─ VM Debian ARM64 + OS/data disk
   ├─ UAMI ESO e backup
   ├─ Key Vault + Azure RBAC
   └─ storage backup/state
   │
2. Ansible dalla workstation/runner autorizzato
   ├─ account/SSH/hardening/updates
   ├─ filesystem e mount
   ├─ K3s pinned + encryption
   └─ Flux controller minimi + root source/Kustomization
   │
3. Flux foundation
   ├─ namespace + policies + CRD
   ├─ External Secrets Operator
   └─ namespaced SecretStore
   │
4. ESO ottiene token via identità Azure e materializza Secret K8s
   │
5. Flux platform
   ├─ Traefik
   ├─ cloudflared
   ├─ osservabilità
   └─ job/agent backup
   │
6. Flux data + restore esplicito
   ├─ PostgreSQL / MariaDB / InfluxDB
   └─ verifica consistenza
   │
7. Flux applications
   ├─ non critiche
   └─ critiche dopo gate
   │
8. Smoke test → cutover Cloudflare → osservazione → decommission AKS separato
```

### Bootstrap secret residui

- **Git:** nessuno nel caso normale, perché il repository GitOps è pubblico e Flux necessita solo read. Se diventa privato, usare deploy key read-only custodita in Key Vault e iniettata durante bootstrap con un passaggio controllato.
- **Azure:** nessuna client secret sulla VM; Terraform usa OIDC, la VM usa Managed Identity.
- **K3s server token:** è generato sulla VM e va copiato immediatamente, cifrato, nello storage backup o in Key Vault. È necessario per un restore del datastore K3s; non per una ricostruzione puramente GitOps con restore applicativo.
- **Cloudflare:** il tunnel token resta un secret esterno in `platform-prod`, materializzato da ESO.
- **Chiave backup:** deve restare fuori dalla VM, in Key Vault con accesso break-glass documentato.

La Managed Identity diretta da un pod su VM richiede un proof tecnico e una boundary IMDS: tutti i workload del nodo condividono l'host e non si deve assumere isolamento automatico. Se il proof fallisce, il fallback è Azure Workload Identity su cluster self-managed, che richiede issuer OIDC/JWKS pubblici e rotazione della signing key; è più complesso e va approvato esplicitamente.

---

## 12. Terraform target

### 12.1 Struttura raccomandata

```text
terraform/
  environments/
    production/
      backend.tf
      main.tf
      variables.tf
      outputs.tf
  modules/
    network/
    compute/
    identity/
    key-vault/
    backup-storage/
```

Non è obbligatorio rifattorizzare subito tutto. La prima implementazione può conservare moduli leggibili esistenti, ma deve rimuovere dal root target provider Helm/Kubernetes e letture dei secret value.

### 12.2 Risorse target

- resource group esistente o dedicato, scelta da confermare senza spostamenti distruttivi;
- VNet `10.42.0.0/16`, subnet services e NSG;
- NIC e, solo se necessario, un PIP Standard statico;
- VM `Standard_E2ps_v6`, Trusted Launch, secure boot e vTPM;
- Debian 13 ARM64 con versione image pin/upgrade controllata;
- OS disk Standard SSD 32–64 GiB;
- data disk Standard SSD E10 128 GiB iniziale, con `prevent_destroy` e lifecycle documentato;
- UAMI dedicate a ESO e backup, assegnate alla VM;
- tre Key Vault finali con Azure RBAC, soft-delete e purge protection;
- storage ZRS backup con container privato; backend Terraform separato/hardenizzato;
- role assignment al minimo scope.

### 12.3 Hardening dello state

- accesso Entra/RBAC, non shared key;
- blob versioning, soft delete e container delete retention;
- lock Terraform e pipeline serializzata;
- backup/mirror periodico del blob, cifrato;
- rimozione futura dei resource/data source che hanno portato secret nello state;
- dopo analisi dello state storico, rotazione dei secret potenzialmente persistiti;
- nessun output sensibile nei log CI.

---

## 13. Ansible target

```text
ansible/
  ansible.cfg
  requirements.yml
  inventories/
    production/
      hosts.yml
      group_vars/
        all.yml
  roles/
    base/
    security/
    storage/
    k3s/
    flux_bootstrap/
    backup_host/
  playbooks/
    provision.yml
    verify.yml
```

### 13.1 Responsabilità per role

| Role | Responsabilità | Criterio idempotenza |
|---|---|---|
| `base` | locale/timezone, pacchetti minimi, utenti nominativi, sudo, chrony, journald | seconda esecuzione senza change |
| `security` | SSH key-only, no root/password, nftables, unattended security updates, audit essenziale | regole/template dichiarativi |
| `storage` | riconoscimento disco per LUN/UUID, GPT/filesystem, mount `/srv/k3s-data`, permessi | non riformatta un filesystem esistente |
| `k3s` | binary/version/checksum, config YAML, systemd, kubeconfig amministrativa protetta | cambio solo su config/versione |
| `flux_bootstrap` | controller pin e root `GitRepository`/`Kustomization` | server-side apply controllato, nessun manifest applicativo |
| `backup_host` | directory/staging, timer/agent solo se host-level, verifica accesso storage | job ripetibili e metriche di esito |

### 13.2 Vincoli

- niente secret in inventory Git; lookup da ambiente/Key Vault al momento dell'esecuzione senza log;
- niente manifest applicativi nei role;
- niente script monolitico; script piccolo solo per operazione non esprimibile bene con moduli;
- `check_mode` dove supportato e tag per ruolo;
- `verify.yml` deve fallire se mount, K3s, Flux, spazio disco o backup target non sono validi.

---

## 14. K3s target

Debian 13 “trixie” è la stable corrente, supporta ARM64, ha supporto Debian iniziale fino al 9 agosto 2028 e LTS fino al 30 giugno 2030: [Debian 13 release information](https://www.debian.org/releases/trixie/) e [Debian releases](https://www.debian.org/releases/). K3s supporta `aarch64` e indica per un server almeno 2 core/2 GiB, preferendo SSD: [K3s requirements](https://docs.k3s.io/installation/requirements).

### 14.1 Configurazione proposta

| Aspetto | Scelta |
|---|---|
| Topologia | un server, nessun agent separato |
| Datastore | SQLite embedded |
| Data directory | `/srv/k3s-data/server` sul data disk |
| CNI | Flannel bundled, backend predefinito; nessun operator Calico |
| NetworkPolicy | controller K3s attivo + policy GitOps |
| CoreDNS | mantenere bundled |
| metrics-server | mantenere bundled |
| local-path-provisioner | mantenere, percorso sul data disk |
| ServiceLB | disabilitare, non serve con tunnel outbound |
| Traefik bundled | disabilitare; installare versione pin via Flux |
| Cloud controller embedded | mantenere salvo prova contraria; non si usa Azure LB |
| Secrets encryption | abilitare e documentare rotazione |
| Kubeconfig | mode restrittivo, accesso solo admin |
| API 6443 | non Internet; private/SSH tunnel |
| Versione | pin esplicito scelto in fase di implementazione dal canale stable, mai `latest` |

K3s documenta SQLite come datastore predefinito per server singolo e richiede il backup sia del datastore sia del server token: [Datastore](https://docs.k3s.io/datastore) e [Backup and restore](https://docs.k3s.io/datastore/backup-restore). I componenti packaged possono essere disabilitati con i flag server: [Managing packaged components](https://docs.k3s.io/installation/packaged-components) e [server CLI](https://docs.k3s.io/cli/server).

### 14.2 Perché non Longhorn

Su un solo nodo Longhorn non fornisce tolleranza alla perdita del nodo o del disco. Introduce numerosi controller, CSI sidecar, iSCSI/NFS e circa 1,2 GiB osservati. Il data disk separato più backup applicativo off-host è più semplice e ripristinabile. `local-path` non è un backup: il suo unico ruolo è il provisioning locale.

---

## 15. Flux CD target

### 15.1 Componenti minimi

- `source-controller` e `kustomize-controller`: indispensabili;
- `helm-controller`: solo per ESO, Traefik e altri chart selezionati;
- `notification-controller`: omesso inizialmente; aggiungerlo solo se gli alert Flux non possono essere ottenuti da metriche;
- `image-reflector-controller` e `image-automation-controller`: inclusi per le immagini PoliNetwork. La CI pubblica il solo tag mobile `latest`; `ImagePolicy` filtra `^latest$`, riflette il digest con `Always` e `ImageUpdateAutomation` aggiorna il riferimento Git mantenendo il tag `latest`.

Flux documenta i controller e quelli opzionali: [Flux components](https://fluxcd.io/flux/components/) e [optional components](https://fluxcd.io/flux/installation/configuration/optional-components/).

Per rispettare il requisito `latest` senza introdurre tag `main-n`, il riferimento GitOps delle app PoliNetwork sarà di questa forma:

```yaml
# infrastructure/images/bot-maintenance-policy.yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: bot-maintenance
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: bot-maintenance
  filterTags:
    pattern: '^latest$'
  policy:
    alphabetical:
      order: asc
  digestReflectionPolicy: Always
  interval: 10m
---
# nell'immagine del Deployment gestita da Flux:
image: ghcr.io/polinetworkorg/bot-maintenance:latest@sha256:<digest> # {"$imagepolicy": "flux-system:bot-maintenance"}
```

Il tag visibile nel manifest resta `latest`; il digest viene aggiornato da Flux quando il registry assegna un nuovo digest allo stesso tag. Questo è il meccanismo Flux documentato per seguire un tag mobile: [Image Policies — digest reflection](https://fluxcd.io/flux/components/image/imagepolicies/) e [following `latest` tags](https://fluxcd.io/flux/guides/image-update/). Se in una fase successiva si decidesse di usare il solo testo `:latest` senza digest, sarebbe necessario `imagePullPolicy: Always` e un meccanismo esplicito di restart: non sarebbe più sufficiente la sola riconciliazione GitOps.

### 15.2 Struttura GitOps proposta

Adattamento incrementale del repository `polinetwork-cd`, non riscrittura completa:

```text
clusters/
  production/
    flux-system/
    infrastructure.yaml
    data.yaml
    apps.yaml
infrastructure/
  controllers/
    external-secrets/
  networking/
    traefik/
    cloudflared/
  observability/
  policies/
data/
  postgres/
  mariadb/
  influxdb/
apps/
  admin/
  backend/
  bot-mat/
  bot-rooms/
  bot-ts/
  polinetcc/
  uptime-kuma/
  web/
```

I manifest esistenti in `k8s-apps/<app>/src` possono essere spostati/meccanicamente adattati; i `config.json` Argo spariscono. Non abilitare directory test o app dormienti tramite wildcard.

### 15.3 Dipendenze e health

| Kustomization | Dipende da | Prune | Health |
|---|---|---|---|
| `controllers` | root | sì, con policy di change | Deployment ESO/CRD established |
| `secret-stores` | `controllers` | sì | SecretStore Ready |
| `networking` | `secret-stores` | sì | Traefik e cloudflared Available |
| `observability` | `controllers` | sì | Prometheus/Grafana Available |
| `data` | `secret-stores` | prudente; PVC protetti | StatefulSet Ready + job restore concluso |
| `apps-noncritical` | `networking`, `secret-stores` | sì | Deployment + HTTP smoke |
| `apps-critical` | `data`, `networking` | sì | endpoint e dipendenze applicative |

Usare `dependsOn`, `wait`, `healthChecks`, timeout e intervalli espliciti. La Kustomization supporta reconciliation, health assessment, dependency e pruning: [Flux Kustomize controller](https://fluxcd.io/flux/components/kustomize/).

### 15.4 Bootstrap

Ansible installa manifest Flux pinning la release e applica soltanto il source Git pubblico e la Kustomization root. Non usare `flux bootstrap github`, perché richiederebbe un token con permessi write non necessario per il recovery. L'installazione può essere resa ripetibile con l'equivalente di `flux install` a versione fissata: [Flux install](https://fluxcd.io/flux/cmd/flux_install/).

---

## 16. Secret architecture target

```text
Azure Key Vault                         K3s namespace
┌────────────────────┐                 ┌──────────────────────────┐
│ applications-prod  │◄── Azure RBAC ─│ SecretStore namespaced   │
│ platform-prod      │    VM/UAMI      │ ExternalSecret explicit  │
│ ci-cd              │                 │ Secret K8s owner=ESO      │
└────────────────────┘                 └──────────┬───────────────┘
                                                  │
                                             secretKeyRef/envFrom
                                                  │
                                              workload
```

### 16.1 Autenticazione Azure

**Scelta raccomandata con gate:** UAMI dedicata `id-k3s-eso` assegnata alla VM, provider ESO `authType: ManagedIdentity` con identity ID esplicita, permesso `Key Vault Secrets User` solo sui vault runtime. Prima dell'adozione:

1. provare l'ottenimento del token via IMDS dal solo pod ESO;
2. verificare che un pod applicativo non autorizzato non possa usare la stessa identità;
3. applicare e testare policy/filtri host verso `169.254.169.254`;
4. documentare il rischio residuo del nodo condiviso.

ESO raccomanda Workload Identity e documenta i metodi Azure disponibili: [ESO Azure Key Vault provider](https://external-secrets.io/main/provider/azure-key-vault/). Azure spiega che le VM ottengono token managed identity dall'IMDS locale: [Managed identities on Azure VMs](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-managed-identities-work-vm).

**Fallback:** Azure Workload Identity self-managed, solo se l'isolamento MI diretto non è accettabile. Richiede issuer OIDC e JWKS pubblicati, webhook e rotazione signing key: [self-managed cluster](https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters.html) e [OIDC issuer](https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters/oidc-issuer.html). Non usare una client secret statica se una delle due strade precedenti è praticabile.

### 16.2 ExternalSecret

- mapping `data` esplicito, mai import wildcard `dataFrom` sull'intero vault;
- `target.creationPolicy: Owner` e `deletionPolicy` scelta per impedire cancellazioni silenziose;
- refresh 1h per app, 5–15m per tunnel/secret a rotazione rapida;
- alert se `Ready=False`, remote key missing o refresh scaduto;
- `secretKeyRef`/`envFrom` sostituiscono i mount CSI;
- un cambio del Secret non riavvia automaticamente i pod che leggono env: la rotazione deve includere rollout controllato o supporto applicativo al reload. Non aggiungere un reloader controller finché non è necessario.

La specifica ESO definisce refresh, target e policy di creazione/deletion: [External Secrets API](https://external-secrets.io/main/api/spec/).

---

## 17. Proposta Key Vault

### 17.1 Alternative

| Criterio | Un vault unico | Pochi vault per trust boundary | Un vault per servizio |
|---|---|---|---|
| Semplicità | massima all'inizio | buona | bassa |
| Least privilege | difficile; RBAC è a scope vault/secret ma gestione diventa fragile | chiara per dominio | massima teorica |
| Blast radius | alto | contenuto | minimo |
| Auditing | rumoroso | leggibile | frammentato |
| Secret condivisi | semplice | gestibile entro dominio | duplicazione/ambiguità |
| ESO | un solo store ma boundary debole | store per namespace/vault | molti store e identity |
| Turnover IT | facile ma rischioso | miglior equilibrio | troppo complesso |
| Costo | sole operazioni | praticamente analogo a basso volume | analogo, ma overhead umano alto |

### 17.2 Raccomandazione

Tre vault finali:

| Vault logico | Contenuto | Reader runtime | Writer/manager |
|---|---|---|---|
| `platform-prod` | Cloudflare, backup/recovery, alert e secret platform | UAMI ESO/backup scoped | gruppo Platform Secret Operators |
| `applications-prod` | credenziali DB, auth, token e chiavi applicative prod | UAMI ESO | gruppo Application Secret Operators |
| `ci-cd` | PAT/deploy credential inevitabili, webhook CI | GitHub identity o umani autorizzati; **non ESO per default** | gruppo CI Secret Operators |

`kv-polinetwork` resta temporaneamente il quarto vault di transizione. Secret dev, legacy o senza owner vi restano in quarantena fino a classificazione; non vengono copiati automaticamente nei vault prod.

Usare Azure RBAC, purge protection e soft delete. Separare `Key Vault Contributor` (control plane, non legge valori), `Key Vault Secrets User` (lettura runtime), `Key Vault Secrets Officer` (rotazione) e gestione degli assignment via PIM/Data Access Admin. Microsoft raccomanda un vault per applicazione/ambiente come principio generale; qui il raggruppamento per trust boundary è un compromesso motivato dalla piccola scala e dai secret condivisi: [Azure Key Vault RBAC guide](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide) e [secure access guidance](https://learn.microsoft.com/en-us/azure/key-vault/general/secure-key-vault).

---

## 18. Migrazione CSI → External Secrets Operator

### 18.1 Scelta Store

Usare `SecretStore` namespaced per ogni namespace consumer. Un `ClusterSecretStore` ridurrebbe YAML ma renderebbe un vault referenziabile da tutti i namespace salvo condizioni aggiuntive. Nella scala attuale, la ripetizione esplicita è preferibile e più comprensibile. Per namespace senza secret non creare store.

### 18.2 Procedura per workload senza downtime, quando possibile

1. creare UAMI/RBAC e installare ESO senza toccare CSI;
2. creare il `SecretStore` namespaced e attendere `Ready=True`;
3. creare un `ExternalSecret` con **nome Secret Kubernetes temporaneo diverso**;
4. verificare solo metadata, chiavi attese e condizione Ready, mai valori;
5. aggiornare il Deployment per referenziare il nuovo Secret, mantenendo temporaneamente volume CSI se richiesto;
6. eseguire rollout e smoke test;
7. rimuovere volume/mount CSI dal workload;
8. dopo tutti i consumer, rimuovere SecretProviderClass, Secret CSI generati, driver e relativa identity.

Per database o applicazioni che non supportano doppia configurazione è necessaria una breve finestra di rollout. Rollback: ripristinare il manifest precedente e il riferimento CSI, finché driver e SPC non sono stati rimossi.

### 18.3 Comportamento di errore

- un remote secret mancante deve lasciare `ExternalSecret` NotReady e bloccare la Kustomization/app dipendente;
- non creare Secret vuoti o default nel manifest;
- non eliminare il Secret remoto quando viene rimosso l'ExternalSecret;
- alert dopo due refresh falliti e prima del cutover;
- rotazione con sovrapposizione credenziale dove il provider lo permette.

---

## 19. Migrazione Argo CD → Flux CD

### 19.1 Mapping

| Argo attuale | Flux target | Conversione |
|---|---|---|
| repository Git dell'ApplicationSet | un `GitRepository` root | meccanica |
| ApplicationSet generator `**/config.json` | Kustomization esplicite per gruppi/app | richiede struttura nuova; niente wildcard |
| Application `admin` | Kustomization `apps-admin` | manifest quasi meccanici |
| `backend` | `apps-backend`, dipende da secrets/data | aggiornare Secret refs |
| `bot-mat` | `apps-bot-mat` | bloccato da immagine ARM64 |
| `bot-rooms` | `apps-bot-rooms` | bloccato da due immagini ARM64 |
| `bot-ts` | `apps-bot-ts` | correggere PVC Redis e Secret refs |
| `influxdb` | `data-influxdb` | convertire a StatefulSet + backup |
| `mariadb` | `data-mariadb` | rimuovere ownership Terraform; StatefulSet/restore |
| `monitoring` | `platform-observability` | pin e ridimensionare |
| `polinetcc` | `apps-polinetcc` | aggiornare Secret refs |
| `postgres` | `data-postgres` | StatefulSet/restore e Secret refs |
| `uptime-kuma` | `apps-uptime-kuma` | restore file/config |
| `web` | `apps-web` | candidato canary |
| Argo Helm install da Terraform | Flux controllers installati da Ansible | modifica ownership |
| Argo Image Updater | Flux ImageRepository/ImagePolicy/ImageUpdateAutomation aggiorna il digest del tag `latest` in Git | modifica pipeline e ownership |
| sync wave/hook | `dependsOn`, healthCheck, Job versionati | nessuna wave live da tradurre |

### 19.2 Handoff senza doppia ownership

Per ogni applicazione:

1. convertire e validare manifest con `kustomize build`, schema e policy in CI;
2. creare la Kustomization Flux **sospesa** o non inclusa dalla root;
3. disabilitare auto-sync della sola Application Argo;
4. rimuovere l'Application senza pruning delle risorse live, verificando prima la semantica della versione Argo;
5. attivare Flux e verificare che adotti le risorse senza diff distruttivi;
6. smoke test, log, metriche, ESO e persistenza;
7. rollback: sospendere Flux, ripristinare l'Application Argo e riabilitare sync;
8. registrare owner e checkpoint.

Non usare contemporaneamente Argo e Flux sulla stessa risorsa, nemmeno “per pochi minuti”. Migrare prima `web`/`admin`, poi app stateless non critiche, quindi dati e workload critici. Al termine: rimuovere ApplicationSet, Image Updater, Argo e relativi secret/client; rimuovere dal Terraform gli oggetti Kubernetes tramite state operation approvata che non distrugga risorse adottate.

### 19.3 Rollback operativo Flux

- rollback applicativo: revert del commit GitOps e riconciliazione;
- incident containment: `flux suspend kustomization <name>` documentato nel futuro runbook;
- proteggere PVC/namespace dati con Kustomization dedicate e policy anti-delete;
- PR obbligatoria per cambi con prune su data layer;
- backup immediato prima di refactor di StatefulSet/PVC.

---

## 20. Core platform vs workload

| Classe | Componenti | Installazione / reconciliation | Secret | Failure behavior |
|---|---|---|---|---|
| Bootstrap/foundation | Debian, mount, K3s, Flux controllers/root | Terraform + Ansible | K3s token; nessun PAT Git nel caso pubblico | senza K3s/Flux il cluster non converge; Ansible lo ripristina |
| Platform controllers | ESO e CRD | Flux HelmRelease/Kustomization | identità Azure, non Secret statico | le app dipendenti restano bloccate se ESO non Ready |
| Networking | Traefik, cloudflared | Flux | tunnel token via ESO | endpoint indisponibili, nessuna esposizione diretta fallback |
| Observability | Prometheus, Grafana, node-exporter, eventuale kube-state-metrics | Flux | receiver/SSO via ESO se necessari | piattaforma funziona ma perdita di visibilità; alert esterno auspicabile |
| Backup | dump CronJob + uploader host/agent | Flux per dump, Ansible per host uploader | chiave cifratura/MI | alert immediato; nessun cutover se ultimo backup/restore non valido |
| Data services | PostgreSQL, MariaDB, InfluxDB | Flux | credenziali via ESO | app dipendenti non partono; restore è passaggio esplicito |
| Applications | admin, backend, bot, polinetcc, web, uptime | Flux | Secret namespaced | health check blocca rollout gruppo, non foundation |

L'ordine è codificato tramite Kustomization esplicite, non tramite nomi alfabetici o attese arbitrarie.

---

## 21. Cloudflare Tunnel, ingress e networking

### 21.1 Stato corrente

- Deployment `cloudflared-cloudflare-tunnel-remote`, 2 repliche, immagine `cloudflare/cloudflared:latest`;
- token nel Secret Kubernetes omonimo;
- tunnel remote-managed;
- nessun Ingress live e nessun controller ingress attivo;
- gli hostname Zero Trust e le route esistono come configurazione Cloudflare corrente, ma il mapping completo hostname → Service Kubernetes non è nei repository analizzati;
- non è stato verificato se l'accesso amministrativo dipenda dal tunnel.

### 21.2 Alternative

| Criterio | systemd/Ansible host | Deployment K3s/Flux |
|---|---|---|
| Bootstrap | parte prima di K3s | richiede K3s + Flux + ESO |
| Secret | deve arrivare sull'host | rimane Secret K8s da ESO |
| Routing ai Service | richiede porte host/config extra | DNS/service discovery Kubernetes naturale |
| Aggiornamento/rollback | Ansible/systemd | GitOps, probes e rollout |
| Osservabilità | journal/metriche host | pod status/log/metriche cluster |
| Dipendenza circolare | minore, ma crea secondo piano di config | assente se Git/Azure/Ansible non dipendono dal tunnel |
| Recovery | Ansible deve gestire token/config | Flux+ESO ricreano tutto |

### 21.3 Raccomandazione

Eseguire `cloudflared` in K3s e riconciliarlo con Flux. Terraform/Ansible/Flux bootstrap usano Azure API, Git pubblico e un canale amministrativo indipendente, quindi non dipendono dal tunnel. Gli hostname Zero Trust esistenti restano invariati: per ogni hostname si crea una route Traefik verso il Service corrispondente e si verifica prima con un hostname canary o con una route non production. Questa collocazione mantiene il token vicino al workload e riduce lo stato host.

Usare 2 repliche solo per tollerare crash/rollout del processo; entrambe sullo stesso nodo non offrono HA contro perdita VM. Cloudflare indica che ogni replica mantiene quattro connessioni outbound e che repliche aggiuntive aumentano disponibilità del connettore: [Tunnel availability](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/).

### 21.4 Traffico target

```text
Internet
  ↓
Cloudflare Edge / DNS / Access opzionale
  ↓ connessioni aperte outbound dalla VM (TCP/UDP 7844)
cloudflared Deployment
  ↓ HTTP interno
Traefik ClusterIP
  ↓ Ingress
Service ClusterIP
  ↓
Pod
```

Cloudflare documenta le regole e le destinazioni outbound del tunnel: [Tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/). Nessuna porta HTTP/HTTPS applicativa deve essere aperta nell'NSG; 3306/5432 non devono essere pubbliche. L'API K3s 6443 resta privata. Il PIP della VM deve essere rimosso dopo aver validato il canale amministrativo alternativo.

### 21.5 Stato Cloudflare da rendere dichiarativo

Prima del cutover esportare metadata-only di tunnel, hostnames, route, Access policy e owner. Preferenza: Terraform Cloudflare gestisce tunnel/DNS/routing usando token scoped fornito alla pipeline senza persisterne il valore nel repository; se ciò non è praticabile, registrare la configurazione remota come eccezione esterna con export e restore test. Il token del tunnel è sensibile e consente l'esecuzione del connettore: [remote tunnel permissions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/).

### 21.6 Amministrazione senza IP statico

Il problema non è il tuo IP dinamico in sé: è che SSH pubblico richiede una allowlist stabile. Il target deve eliminare questa dipendenza.

Cloudflare Access SSH **non rende pubblicamente raggiungibile la VM**: [Cloudflare Tunnel usa connessioni outbound-only](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) dall'origin verso Cloudflare, quindi il PIP e la regola inbound 22 possono essere rimossi. L'utente raggiunge l'edge Cloudflare e deve superare Access prima dell'inoltro: è pubblico l'endpoint Access, non l'origin SSH. Con [Access for Infrastructure](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-infrastructure-access/) e WARP-to-Tunnel si può usare come target l'IP privato e ottenere certificati SSH short-lived senza pubblicare un origin IP.

| Soluzione | Come funziona | Vantaggi | Svantaggi / uso consigliato |
|---|---|---|---|
| Cloudflare Access SSH | `cloudflared` pubblica SSH tramite Access; dal laptop si usa `cloudflared access ssh` con identità Zero Trust | nessun IP statico, policy per utente/MFA, già coerente con Cloudflare | dipende dal tunnel; usare Azure Run Command come break-glass |
| Azure Run Command | `az vm run-command invoke` esegue comandi autenticati dalla control plane Azure | nessun ingresso VM, funziona anche durante problemi SSH/tunnel | non è un terminale interattivo ideale; adatto al recovery |
| Azure Bastion | accesso SSH dal portale verso IP privato | nessun IP di casa da autorizzare | costo e risorsa Azure aggiuntiva; valutare solo se il team lo usa davvero |
| Azure VPN Point-to-Site | il laptop entra nella VNet con identità Entra/certificato | IP dinamico irrilevante, API/SSH private | costo e gestione gateway; più infrastruttura |
| Tailscale/Headscale | rete overlay autenticata tra laptop e VM | semplice, nessun IP statico, ACL per identità | componente/agent aggiuntivo; il recovery iniziale deve restare Azure-based |

**Raccomandazione:** Cloudflare Access for Infrastructure per l'uso quotidiano, con policy Azure AD/Entra limitata al gruppo IT e certificati SSH short-lived; Azure Run Command/Serial Console come break-glass. Non usare una allowlist di IP domestici, non usare un pool e non lasciare SSH pubblico aperto. Durante dev/staging si può mantenere temporaneamente un PIP solo per il bootstrap, con una scadenza esplicita; il criterio di uscita è la rimozione del PIP.

---

## 22. Storage e backup target

### 22.1 Strategia storage

- OS disk separato, senza dati applicativi intenzionali;
- un data disk Standard SSD E10 128 GiB montato per UUID in `/srv/k3s-data`;
- local-path PVC con directory identificabili per namespace/claim;
- filesystem ext4 o XFS scelto e documentato prima del provisioning; ext4 è la scelta più semplice se non emerge un requisito XFS;
- nessuna replica locale considerata backup;
- `prevent_destroy` sul disco e procedura esplicita per replacement/resize;
- metriche su bytes, inode, latency/IOPS e crescita; warning 70%, critical 85%.

128 GiB è un punto di partenza, non un dato arbitrario definitivo: i dati osservati sono inferiori a pochi GiB, ma dump, retention e crescita richiedono margine. Un benchmark canary deve confermare IOPS/latency del database. Se insufficiente, passare a Premium SSD prima del cutover senza cambiare architettura.

### 22.2 Piano backup

| Asset | Meccanismo | Destinazione | Retention iniziale | Verifica |
|---|---|---|---|---|
| Terraform state | versioning + soft delete + copia cifrata/mirror | storage separato dal failure domain operativo | 30–90 giorni versioni | restore state in backend isolato |
| Git | hosting GitHub + `git bundle --all` schedulato con OIDC | Blob ZRS | giornaliero 30, mensile 12 | clone dal bundle |
| Key Vault | IaC per struttura/RBAC + inventario versioni; export dei valori solo tramite processo sicuro di recovery/rotazione | Azure soft delete/purge protection; eventuale escrow cifrato approvato | secondo policy | ricreare vault e recuperare un secret test senza stamparlo |
| K3s | SQLite + server token cifrato | Blob ZRS | daily 7, weekly 4 | restore su K3s isolato; non è unico recovery path |
| PostgreSQL | `pg_dump` custom + globals/roles | staging locale breve → archivio cifrato Blob ZRS | 6h×28, daily 14, weekly 8, monthly 6 | `pg_restore` + query di consistenza |
| MariaDB | `mariadb-dump` consistente + grant/schema | come sopra | 6h×28, daily 14, weekly 8, monthly 6 | restore e check tabelle |
| InfluxDB | backup nativo compatibile con versione | Blob ZRS | daily 14, weekly 8 | restore e query serie campione |
| Uptime/Grafana/file PVC | export dichiarativo dove possibile; altrimenti snapshot file-level quiesced | Blob ZRS | daily 14, weekly 8 | restore applicativo |
| Certificati | ricreazione da issuer; backup solo di CA privata realmente necessaria | `platform-prod`/escrow cifrato | versionato | emissione certificato test |
| Cloudflare | Terraform/export metadata; token in vault | Git + Key Vault | per versione/config | tunnel canary funzionante |

La configurazione dichiarativa non è backup dei dati. Il target non usa una full-VM image come meccanismo primario. Snapshot del disco sono utili come checkpoint pre-cutover, ma non sostituiscono dump consistente e restore test.

### 22.3 Implementazione leggera

I CronJob Kubernetes producono dump in una directory di staging sul data disk; un uploader host-level, configurato da Ansible e autenticato con `id-vm01-backup`, cifra e trasferisce verso `polinetworkbackups`. In questo modo i job database non ricevono accesso al Blob. Per file backup usare uno strumento semplice e verificabile (per esempio restic con backend compatibile e Managed Identity) solo dopo un proof read/write/restore. Non introdurre un orchestratore backup self-hosted indispensabile a ripristinare sé stesso.

Ogni esecuzione produce metadata non sensibili: timestamp, asset, dimensione, checksum cifrato, esito, durata e ultima verifica restore. Un backup senza alert e senza restore periodico è considerato non valido.

---

## 23. Disaster recovery

### 23.1 RPO/RTO spiegati

- **RPO (Recovery Point Objective):** quanta informazione si accetta di perdere. Un RPO di 6 ore significa che, nel caso peggiore, si accettano fino a 6 ore di dati non presenti nell'ultimo backup.
- **RTO (Recovery Time Objective):** quanto tempo può restare indisponibile il servizio. Un RTO di 4 ore significa che il servizio deve tornare operativo entro quattro ore dall'incidente.

Sono obiettivi operativi, non proprietà automatiche di Azure o Kubernetes. Si scelgono in base all'importanza del servizio e determinano frequenza dei backup, test e costi.

Questi obiettivi descrivono il **disaster recovery continuativo dopo la migrazione**, non obbligano a usare replica o sincronizzazione durante il singolo cutover. Per MariaDB legacy è sufficiente un dump e restore in una finestra di bassa attività, purché durante il dump finale tutti i writer siano realmente fermati. In quel caso l'RPO del cutover è prossimo a zero: si perdono solo eventuali scritture erroneamente accettate dopo lo stop. L'RTO del cutover è il tempo misurato tra lo stop dei writer e il ritorno operativo del servizio sul target.

Procedura minima del cutover MariaDB:

1. provare prima dump e restore su un database isolato e misurarne durata/spazio;
2. dichiarare la maintenance window e mantenere AKS come sorgente autorevole;
3. sospendere CronJob, bot, backend e qualunque altro writer; non basta scegliere un orario tranquillo;
4. verificare che non restino sessioni applicative che scrivono;
5. produrre il dump finale consistente e registrarne checksum/timestamp;
6. ripristinarlo su MariaDB target isolato;
7. verificare versione/schema, conteggi di tabelle e query funzionali;
8. attivare soltanto i consumer target e cambiare il routing previsto;
9. mantenere temporaneamente il database sorgente fermo o read-only per il rollback;
10. se la validazione fallisce, spegnere i consumer target e riattivare la sorgente senza tentare merge manuali.

Un dump di cutover riuscito non sostituisce i backup successivi: dopo l'attivazione del target servono ancora dump periodici cifrati, copia esterna alla VM, alert e restore test. PostgreSQL non fa parte della wave approvata e non deve essere migrato insieme a MariaDB.

### 23.2 Obiettivi iniziali proposti

| Classe | RPO | RTO | Nota |
|---|---:|---:|---|
| MariaDB legacy dopo il cutover | 6 ore | 4 ore | default prudente per backup continuativo; il cutover con writer fermi mira a RPO ~0 |
| PostgreSQL | non definito in questa wave | non definito in questa wave | non migrare finché workload/retention fuori scope non sono decisi |
| Platform/GitOps | commit corrente | 4 ore | ricostruzione dichiarativa |
| Influx/Uptime/config non critici | 24 ore | 8 ore | confermare valore storico |
| VM/OS/K3s | non applicabile come dato | 4 ore | VM sostituibile |

### 23.3 Test DR obbligatorio

1. dichiarare una finestra e scegliere un resource group isolato;
2. verificare che repository, state e backup siano accessibili da identità break-glass;
3. creare una VM pulita con un piano Terraform esplicitamente approvato;
4. eseguire Ansible da zero due volte, richiedendo zero change sostanziali alla seconda;
5. verificare K3s, mount e secrets encryption;
6. bootstrap Flux dal repository, senza copiare file dal nodo production;
7. verificare che ESO ottenga i Secret test da Key Vault senza valori statici;
8. riconciliare platform e data workload vuoti;
9. ripristinare PostgreSQL, MariaDB, Influx e file data dai backup selezionati;
10. eseguire query di consistenza e smoke test applicativi;
11. avviare un tunnel/hostname canary senza toccare production;
12. verificare metriche, alert, spazio disco e un nuovo backup;
13. misurare RPO/RTO reali e registrare ogni intervento manuale;
14. distruggere l'ambiente di test solo con approvazione separata e conservare il verbale.

### 23.4 Recovery se GitHub non è disponibile

Recuperare i `git bundle` da Blob ZRS, creare clone locali e puntare temporaneamente Flux a un mirror accessibile. Nessun registry o Git self-hosted deve essere prerequisito unico per il proprio recovery. Le immagini devono restare in registry esterno; per workload critici valutare replica dei digest in un secondo registry solo se il costo/rischio lo giustifica.

---

## 24. Compatibilità ARM64

La VM `Standard_E2ps_v6` usa Azure Cobalt 100 ARM64 ed espone 2 vCPU/16 GiB: [Azure Epsv6 sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/epsv6-series).

### 24.1 Immagini applicative live

| Immagine | Esito manifest | Azione |
|---|---|---|
| `ghcr.io/polinetworkorg/admin` digest live | amd64 + arm64 | mantenere pipeline multi-arch e pubblicare il solo tag `latest`; Flux aggiorna il digest |
| `ghcr.io/polinetworkorg/backend` digest live | amd64 + arm64 | smoke test dipendenze native Bun |
| `ghcr.io/polinetworkorg/polinet.cc` digest live | amd64 + arm64 | smoke test Next.js/native addons |
| `ghcr.io/polinetworkorg/telegram` digest live | amd64 + arm64 | smoke test ARM reale |
| `ghcr.io/polinetworkorg/web` digest live | amd64 + arm64 | candidato canary |
| `ghcr.io/polinetworkorg/bot-maintenance:latest@sha256:934d…` | **solo amd64 nel deployment AKS corrente; nuova build multi-arch verificata** | run `31803305519`; usare `latest` solo nella wave staging tramite Flux digest automation |
| `ghcr.io/polinetworkorg/botcsharp-config@sha256:d22b…` | **solo amd64** | fuori scope, non modificare |
| `ghcr.io/polinetworkorg/botcsharp_dev@sha256:da4f…` | **solo amd64** | fuori scope, non modificare |

### 24.2 Immagini terze

Manifest ARM64 verificato per le immagini live di Cloudflared, InfluxDB, MariaDB 10.9.4, Grafana, Prometheus, Uptime Kuma, PostgreSQL 17.4, Redis e le immagini ufficiali principali. I componenti AKS/Calico/CSI, Argo, Dashboard e Longhorn non sono target e non vanno portati solo perché oggi esistono.

### 24.3 Immagini platform inventariate ma non trasferite

| Gruppo immagini live | Decisione ARM/migrazione |
|---|---|
| `quay.io/argoproj/argocd`, `ghcr.io/dexidp/dex`, Redis ECR, `argocd-image-updater` | Argo viene eliminato; nessuna immagine entra nel target. Flux deve avere manifest ARM64 verificato al pin scelto. |
| immagini AKS `mcr.microsoft.com/oss/v2/kubernetes/**`, Azure Disk/File CSI, Secrets Store CSI/Azure provider, cloud-node-manager, kube-proxy | gestite e legate ad AKS; non sono dipendenze K3s target. |
| Calico/Tigera `mcr.microsoft.com/oss/calico/**` | non trasferite; target usa Flannel e controller NetworkPolicy K3s. |
| `longhornio/**`, Alpine/pause sidecar | non trasferite perché Longhorn viene rimosso. |
| `kubernetesui/**` e `kong:3.9` | non trasferite; Dashboard viene eliminata. |
| `busybox` init Prometheus | immagine ufficiale multi-arch; usare una versione esplicita nel target se ancora necessaria. |

Questa classificazione evita di confondere “presente oggi” con “deve essere compatibile domani”. Per ogni nuova versione di Flux, ESO, Traefik, cloudflared e monitoring il manifest ARM64 resta comunque un check CI obbligatorio.

Il supporto manifest non prova la compatibilità funzionale. Le pipeline delle app presenti usano già buildx o job amd64/arm64 in branch di migrazione, ma tali branch non sono tutti merged. Il gate richiede:

- build da commit target per entrambe le architetture;
- SBOM/scansione per ciascuna immagine prodotta;
- test di startup, health, TLS, DB client e librerie native su VM ARM64;
- manifest list verificato in CI;
- per le app PoliNetwork usare `latest` nel GitOps target; Flux aggiorna automaticamente il digest osservato del tag;
- verifica nativa del workflow `bot-maintenance`; i repository C# non fanno parte di questo gate perché fuori scope.

---

## 25. Capacity planning

### 25.1 Misure correnti

| Metrica | Valore |
|---|---:|
| nodo allocabile | 1900m CPU / 5.65 GiB RAM |
| `kubectl top node` | 529m CPU (27%) / 5830 Mi (100%) |
| somma snapshot pod | ~190m CPU / 4715 Mi RAM |
| overhead non attribuito a pod | ~339m CPU / ~1.1 GiB RAM |
| Prometheus 7d CPU node | media 25,54%, picco 39,25% |
| Prometheus 7d memoria | media 77,31%, picco 86,18% |
| load15 picco | 3,03 su 2 vCPU |
| root free minimo | ~67,6 GiB |
| inode free minimo | 95,26% |
| requests dichiarate cluster | 1623m CPU / 3398 Mi RAM |
| limits dichiarati cluster | 10,74 CPU / 16,46 GiB, quindi non utili come capacity cap |

Memoria snapshot per componenti: Longhorn ~1198 Mi, Argo ~659 Mi, kube-system ~521 Mi, monitoring ~381 Mi, Calico ~262 Mi, MariaDB ~259 Mi, Dashboard ~179 Mi. Il target rimuove Longhorn, Argo, Dashboard e agent AKS, liberando circa 2 GiB o più rispetto allo stato attuale.

### 25.2 Valutazione target

- **RAM 16 GiB:** adeguata con margine, se si mantengono controller leggeri e si impostano requests/limits.
- **CPU 2 vCPU:** plausibile ma non dimostrata durante build, backup, restore o picchi bot. Load15 >2 dimostra che esistono finestre di coda CPU/IO.
- **Storage:** capacità ampia rispetto ai dati attuali; IOPS vanno misurati, soprattutto durante dump/restore.
- **Rete:** il traffico applicativo non è quantificabile dai dati raccolti; misurare egress e tunnel prima del cutover.

### 25.3 Gate canary

Eseguire per almeno 7 giorni un subset rappresentativo sulla VM ARM64, includendo backup e restore sintetico. Accettare solo se:

- CPU p95 <70% e picchi sostenuti <85%;
- memoria working set <12 GiB e nessun OOM/eviction;
- load15 normalmente <2 e nessuna degradazione endpoint;
- data disk latency p95 e IOPS entro soglia definita dal DB test;
- almeno 20% spazio e inode liberi dopo proiezione 12 mesi;
- backup completa nella finestra senza degradare SLO;
- tutte le immagini e probe sono healthy.

Se il gate CPU fallisce, la prima remediation è passare a uno SKU ARM64 da 4 vCPU/32 GiB o separare il carico, non aggiungere tuning opaco.

---

## 26. CI/CD target

### 26.1 Stato osservato

- app presenti: workflow multi-arch già introdotti in branch `migration/arm64-images` o buildx per alcuni repository;
- immagini pubblicate su GHCR/Docker Hub, nessun ACR;
- tre immagini C# non dispongono di sorgente/pipeline locale verificabile;
- Terraform ha workflow OIDC corretti e workflow legacy con secret statici;
- Argo Image Updater modifica lo stato Application, non Git.

### 26.2 Flusso target

```text
pull request applicativa
  → lint/test/build amd64+arm64
  → merge
  → push immagine per commit + manifest list
  → push tag latest
  → Flux ImageRepository/ImagePolicy osserva latest e il suo digest
  → Flux ImageUpdateAutomation committa il digest mantenendo latest nel GitOps
  → Flux riconcilia
```

Non usare `kubectl apply` dalle pipeline applicative. Per le app PoliNetwork usare `latest` nei manifest. L'`ImagePolicy` deve filtrare esclusivamente `^latest$`, impostare `digestReflectionPolicy: Always` e un intervallo di polling; l'`ImageUpdateAutomation` aggiorna il digest associato lasciando invariato il tag `latest`. In questo modo non viene introdotto alcun tag `main-n` e un nuovo push di `latest` produce comunque una modifica Git e un rollout tracciabile. Azure OIDC sostituisce `AZURE_CREDENTIALS` statiche. Registry credential di pull va evitata per immagini pubbliche; per private, usare un token read-only per namespace e piano di rotazione.

Controlli CI minimi: Dockerfile lint, build entrambe le architetture, test su ARM (runner nativo o emulazione + canary nativo), verifica manifest `latest`, vulnerability scan, SBOM, firma/provenance se sostenibile, validazione Kustomize/Helm, presenza del marker Flux per il digest, schema Kubernetes e diff.

---

## 27. Osservabilità e lifecycle

### 27.1 Stack minimo

Mantenere Prometheus con retention locale 7 giorni, Grafana solo se dashboard/provisioning sono in Git, node-exporter e un kube-state-metrics leggero se necessario per stato workload. Non introdurre Loki/ELK o Log Analytics senza un caso d'uso e una stima costo. Journald con retention bounded e log container consultabili sono sufficienti inizialmente.

Alert obbligatori:

- host down, CPU/load, RAM/swap, disk bytes/inode/latency;
- K3s API e node NotReady;
- Flux reconciliation failed/stalled e revision non avanzata;
- ESO NotReady/refresh error;
- Cloudflared replica unavailable/reconnect loop;
- Traefik 5xx e endpoint esterni;
- database readiness e fallimento dump;
- età ultimo backup e ultimo restore test;
- certificati <30/<14/<7 giorni;
- GitOps drift/suspended Kustomization dimenticata.

L'alert path non deve dipendere solo dal cluster che sta segnalando la propria morte: mantenere almeno un check esterno (Uptime Kuma fuori failure domain oppure servizio gratuito/Cloudflare monitor se disponibile e approvato).

### 27.2 Policy aggiornamenti

| Componente | Policy |
|---|---|
| Debian | unattended-upgrades solo security; reboot automatico disabilitato; finestra manutenzione settimanale con pre/post-check |
| K3s | versione pin in Ansible; patch mensile revisionata; minor sequenziali dopo backup e canary; niente channel `latest` |
| Flux/ESO/Traefik | versioni chart/controller pin, PR automatica e test; major manuale |
| Cloudflared | versione esplicita, aggiornamento mensile/test tunnel |
| App PoliNetwork | tag `latest`; Flux digest automation aggiorna Git |
| PostgreSQL/MariaDB/Influx | patch compatibili testate; major con dump/restore rehearsal e rollback |

K3s raccomanda il canale `stable` per produzione, ma il target deve comunque risolvere e pinning una versione concreta: [K3s manual upgrades](https://docs.k3s.io/upgrades/manual). Non installare il system-upgrade-controller inizialmente: aggiungerebbe un controller che muta l'unico nodo e non riduce il bisogno di una finestra verificata.

---

## 28. Sicurezza e hardening

### 28.1 Host e rete

- Debian minimal, account personali, SSH key-only, root login/password disabilitati;
- stato attuale verificato: `AllowPublicSsh` priorità 100 permette TCP/22 da `0.0.0.0/0`; `DenyAllInbound` priorità 4096 non la annulla perché Azure applica la prima regola corrispondente. La VM ha PIP `20.123.148.140`;
- target: NSG e nftables deny-by-default senza eccezione SSH pubblica; 6443 non pubblico;
- nessuna porta app/DB esposta; tunnel solo outbound;
- security update automatici, reboot pianificato;
- journald bounded, audit di login/sudo e orologio sincronizzato;
- IMDS access controllato e testato per ridurre abuso delle UAMI;
- backup cifrati e chiave recovery separata;
- nessuna chiave SSH condivisa `compose-vm-*` nel target.

### 28.2 Kubernetes

- K3s secrets encryption;
- RBAC per gruppi, niente binding email diretto o Dashboard admin;
- Pod Security Admission `baseline`, poi `restricted` per namespace compatibili;
- default-deny NetworkPolicy per app/data con allow DNS, ingress e dipendenze esplicite;
- ServiceAccount dedicato solo quando serve, automount token disabilitato per default;
- securityContext non-root/read-only dove supportato;
- versioni esplicite per terze parti, tag `latest` con digest osservato da Flux per app PoliNetwork, seccomp default e capability drop;
- audit log K3s con retention dimensionata;
- protezione da prune accidentale su PVC/data namespace.

### 28.3 Azure

- Key Vault su Azure RBAC, purge protection, accesso pubblico disabilitato o firewall/private endpoint se compatibile con semplicità di recovery;
- separazione control plane/data plane e PIM per ruoli elevati;
- rimozione di Contributor subscription-wide a SP scaduti/orfani;
- GitHub OIDC con subject/environment ristretto;
- storage state/backup privato, shared key disabilitata dopo verifica consumer;
- budget/alert costi mantenuti e aggiornati.

### 28.4 Modifiche di sicurezza da includere nella migrazione

| Problema attuale | Modifica target | Verifica di accettazione |
|---|---|---|
| Argo anonymous access + `policy.default: role:admin` | transizione: CF Access solo gruppo IT+MFA e anonymous `role:readonly`; change via Git; finale: rimuovere Argo/ApplicationSet/Image Updater | nessun anonymous admin; Argo eliminato a fine handoff; nessuna doppia ownership |
| Dashboard e binding `cluster-admin` | eliminare Dashboard e service account admin; accesso con kubeconfig/RBAC nominativo | `kubectl auth can-i` negativo per utenti non autorizzati |
| `admin-global` diretto a email/GUID | gruppi Entra documentati, ruolo minimo, PIM per elevazione | matrice RBAC verificata e audit log |
| MariaDB/PostgreSQL LoadBalancer pubblici | Service `ClusterIP`/nessun PIP; accesso solo da workload o canale amministrativo autorizzato | scansione porte pubbliche e `az network public-ip list` senza PIP DB |
| PIP/SSH VM pubblico con source any | rimuovere PIP; Cloudflare Access SSH per uso quotidiano; Azure Run Command/Serial Console break-glass | accesso admin funzionante da casa con IP dinamico e nessuna porta inbound |
| NSG permissivo | deny inbound; solo egress DNS/HTTPS/NTP/Cloudflare Tunnel e subnet necessarie | NSG/nftables testati da rete esterna |
| CSI e identity AKS con access policy legacy | ESO con UAMI dedicata e Azure RBAC `Key Vault Secrets User` scoped | ESO Ready, workload non autorizzato non legge IMDS/Key Vault |
| Secret in Terraform data source/Kubernetes Secret | secret runtime solo ESO; rimuovere provider Kubernetes/Helm dal target cloud; audit/rotazione dello state storico | nessun valore in Git/log; `terraform plan` senza data source secret |
| Key Vault access policy ampia/orphan | Azure RBAC, gruppi, PIM, rimozione principal scaduti/orfani | role assignment matrix e access test least-privilege |
| Storage shared key/public blob | consumer inventory, private container, Managed Identity; disabilitare shared key quando compatibile | accesso anonimo negato e backup ancora funzionante |
| immagini e tag `latest` | versioni esplicite per terze parti; `latest` + Flux digest automation per app PoliNetwork | CI verifica manifest, scan/SBOM e marker Flux nei workload |
| NetworkPolicy assenti | default-deny per app/data, allow DNS/Traefik/DB espliciti | test connectivity autorizzata e negata |
| K3s single-node | secrets encryption, API privata, token/backup cifrati, audit bounded | restore K3s e verifica API da canale autorizzato |

Queste modifiche sono parte della migrazione, ma restano separati i change urgenti su Argo anonymous access e database pubblici: se vengono lasciati temporaneamente su AKS, devono avere owner, scadenza e approvazione esplicita.

La guida K3s di hardening è il baseline tecnico, da applicare proporzionalmente senza importare meccanismi multi-node non pertinenti: [K3s hardening guide](https://docs.k3s.io/security/hardening-guide).

---

## 29. Costi e risorse da eliminare

### 29.1 Metodo

I prezzi sono retail USD Consumption per `westeurope` ottenuti il 13 agosto 2026 dalla [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices), 730 ore/mese, senza reservation/savings plan/sponsorship. Non equivalgono alla fattura. La subscription ha circa USD 2.000 di crediti dichiarati, ma scadenza e saldo non sono stati verificati.

### 29.2 Current vs target stimato

| Voce | Current AKS osservato | Target | Delta indicativo |
|---|---:|---:|---:|
| Compute | B2ms ~USD 70,08/mese | E2ps v6 ~USD 80,30 | +10,22 |
| OS disk | AKS P10 128 GiB ~USD 21,68 | E4 32 GiB ~USD 2,40 | -19,28 |
| DB/data disk | S10 + P4 ~USD 11,70 | E10 128 GiB ~USD 9,60 | -2,10 |
| Public IP | almeno 3 AKS ~USD 10,95 | 1 VM ~USD 3,65 | -7,30 |
| Load Balancer | Standard LB + regole/dati, non determinato | nessun Azure LB | risparmio da verificare |
| Key Vault | 1 vault, USD 0,03/10k operazioni | 3 vault, stessa tariffa operazioni | trascurabile al volume attuale |
| Backup blob | Longhorn LRS + backup ZRS legacy | ZRS dimensionato/retention | dipende dai GB e transazioni |
| Monitoring | nessun Log Analytics | nessun Log Analytics | invariato |
| Totale parziale noto | **~USD 114,41 + LB/storage/egress** | **~USD 95,95 + backup/ops/egress** | almeno ~USD -18,46 più eliminazione LB |

La colonna current sopra isola il costo AKS confrontabile. Nell'ambiente reale è già accesa anche la VM `vm01` della precedente migrazione: E2ps v6 + E4 + P4 + E6 + PIP valgono circa **USD 96,96/mese** retail. Il parziale attualmente presente è quindi almeno **USD 211,37/mese**, prima di Load Balancer, storage, operazioni ed egress. Questa sovrapposizione deve essere abbreviata, ma non eliminando rollback o dati prima dei gate.

Con target ~USD 100/mese, USD 2.000 coprirebbero circa 20 mesi a prezzo retail; questa non è una previsione perché durata/saldo dei crediti e traffico sono ignoti.

### 29.3 Risorse eliminabili dopo accettazione e retention

1. AKS `aks-polinetwork`, node pool e managed resource group;
2. Standard Load Balancer e PIP AKS/DB;
3. managed OS disk del VMSS;
4. Azure Disk MariaDB/PostgreSQL, solo dopo due restore verificati e scadenza retention cutover;
5. identità CSI AKS e role assignment;
6. Longhorn backup container dopo retention legale/operativa;
7. Argo/CSI/Dashboard/Longhorn nel cluster, prima della distruzione cluster solo se richiesto dal percorso di migrazione;
8. Key Vault access policy e client Argo;
9. VM/dischi/UAMI OpenBao/Compose legacy non adottati;
10. VNet/NSG “disk inspector” e resource group `temp`, dopo owner check;
11. private endpoint legato alla VNet AKS, solo dopo ricreazione/decisione target;
12. SP scaduti/orfani e assignment, tramite change di sicurezza separato.

Ogni delete è fuori scope di questo assessment e deve avere un piano separato con target risolto, dipendenze, backup, rollback e approvazione.

---

## 30. Risk register

| Rischio | Probabilità | Impatto | Mitigazione preventiva | Recovery |
|---|---|---|---|---|
| Perdita VM / single point of failure | Media | Alto | VM sostituibile, IaC, backup off-host, monitor esterno | Terraform + Ansible + Flux + restore entro RTO |
| Perdita data disk | Bassa/Media | Critico | disk separato, alert IO, backup 6h, checkpoint pre-change | nuovo disk + restore DB/file |
| Corruzione filesystem | Bassa | Alto | shutdown/reboot controllati, fsck policy, metriche, backup consistente | sostituire/ricreare filesystem e restore |
| Indisponibilità West Europe | Bassa | Critico | backup ZRS non equivale a cross-region; conservare bundle/config portabili | ricreare in regione alternativa dopo verifica SKU/replica backup; RTO più alto |
| Perdita credenziali amministrative | Bassa/Media | Critico | gruppi Entra, almeno due admin, PIM e account break-glass testato | procedura break-glass e recovery subscription/GitHub |
| Terraform state perso/corrotto | Media oggi | Alto | RBAC, versioning/soft-delete, copia cifrata, lock | restore versione blob; import controllato come ultima opzione |
| Secret non accessibili al bootstrap | Media | Critico | UAMI/RBAC create da Terraform, proof ESO/IMDS, vault esterno | correggere assignment; fallback break-glass senza loggare valori |
| Abuso Managed Identity via IMDS da pod | Media | Critico | identità minime, test isolamento IMDS, policy host/network | revoca assignment/token, sospensione workload, fallback Workload Identity |
| Immagine `bot-maintenance` non ARM64 | **Risolto per la build; Media per il deploy** | Alto | GitHub Action `31803305519`; tag `latest` verificato amd64+arm64; promuovere solo in staging | mantenere il riferimento AKS precedente finché il canary staging non passa |
| Database non ripristinabile | **Alta oggi** | Critico | dump nativi, checksum, restore rehearsal | fermare migrazione; ripristinare AKS/disco sorgente |
| Cloudflare Tunnel non disponibile | Media | Alto | 2 repliche processo, token in KV, config esportata, canary | rollback route/tunnel AKS o bootstrap tunnel target |
| Repository Git non disponibile | Bassa/Media | Alto | bundle giornaliero off-GitHub, commit/digest pin | clone da bundle e mirror temporaneo |
| Flux prune elimina risorse | Media | Critico sui dati | Kustomization separate, review, policy, PVC protetti, backup | suspend Flux, revert Git, restore oggetto/dato |
| Doppia ownership Argo/Flux | Media durante migrazione | Alto | handoff per Application, mai dual sync | suspend Flux e riabilitare Argo o viceversa |
| Aggiornamento K3s problematico | Media | Alto | pin, backup, canary, minor sequenziali, maintenance window | reinstall versione precedente supportata/restore VM |
| Saturazione CPU | Media | Alto | requests/limits, canary 7d, alert, backup schedulati | throttle/suspend non critici; resize 4 vCPU |
| Saturazione spazio disco | Media | Critico | 70/85% alert, retention, capacity forecast | liberazione controllata; expand disk/filesystem; restore |
| Esaurimento inode | Bassa | Alto | metriche inode, log retention, cleanup immagini | cleanup controllato, expand/reformat se necessario |
| Certificati scaduti | Media | Alto | issuer dichiarativo, alert 30/14/7d | rinnovo/reissue; break-glass CA se documentata |
| Dipendenza circolare bootstrap | Media | Alto | Git pubblico, SSH indipendente da tunnel, MI senza secret, ordine Flux | Ansible installa root minima; recovery access Azure diretto |
| Errore umano su Key Vault/RBAC | Media | Critico | PIM, group roles, purge protection, change review | soft-delete recovery, ripristino role assignment da Terraform |
| Mapping Cloudflare hostname → Traefik incompleto | Media | Alto | esportare route Zero Trust e provarle con hostname canary | mantenere route verso AKS, correggere mapping target |
| Regione alternativa senza SKU ARM | Bassa | Alto | verificare due regioni e quota durante DR design | SKU compatibile alternativo o temporaneo amd64 con immagini multi-arch |

La disponibilità regionale non è risolta da ZRS: ZRS protegge da failure di zona nella stessa regione. Se il board richiede recovery da outage regionale, serve una seconda copia geograficamente ridondante o cross-region e un RTO/costo separato.

---

## 31. Decision log

### ADR-01 — Numero e confini dei Key Vault

**Decisione:** segmentazione dei secret.

**Contesto:** un vault contiene 69 secret di runtime, CI, platform, dev e legacy con identità molto diverse.

**Alternative considerate:** vault unico; tre vault per trust boundary; vault per servizio.

**Scelta:** tre vault finali (`platform-prod`, `applications-prod`, `ci-cd`), più `kv-polinetwork` solo transitorio.

**Motivazione:** riduce blast radius e rende RBAC/audit comprensibili senza proliferazione.

**Trade-off:** alcuni secret condivisi richiedono classificazione e migrazione esplicita.

**Rischi:** duplicazione durante transizione e consumer dimenticati.

**Reversibilità:** alta; i secret possono essere spostati tra vault con rotazione e periodo di sovrapposizione.

### ADR-02 — SecretStore vs ClusterSecretStore

**Decisione:** scope degli store ESO.

**Contesto:** namespace applicativi hanno trust boundary diverse.

**Alternative considerate:** un ClusterSecretStore per vault; SecretStore namespaced; combinazione.

**Scelta:** SecretStore namespaced, uno per namespace che consuma secret.

**Motivazione:** boundary visibile e minor rischio di riferimento accidentale cross-namespace.

**Trade-off:** YAML ripetuto.

**Rischi:** drift tra store se non generati/revisionati coerentemente.

**Reversibilità:** alta; conversione a ClusterSecretStore non cambia i secret remoti.

### ADR-03 — Collocazione Cloudflare Tunnel

**Decisione:** processo tunnel nel cluster.

**Contesto:** il tunnel pubblica Service Kubernetes e il bootstrap Azure/Git/SSH non ne dipende.

**Alternative considerate:** systemd/Ansible host; Deployment Flux.

**Scelta:** Deployment K3s gestito da Flux, token via ESO.

**Motivazione:** service discovery, rollout, osservabilità e secret ownership più semplici.

**Trade-off:** il tunnel arriva solo dopo K3s/Flux/ESO.

**Rischi:** un errore platform rende gli endpoint indisponibili; due repliche non proteggono la VM.

**Reversibilità:** alta; un'unità systemd può essere introdotta se emerge una dipendenza bootstrap reale.

### ADR-04 — Strategia storage

**Decisione:** storage locale su data disk separato, senza Longhorn.

**Contesto:** un solo nodo, dati attuali piccoli, Longhorn ~1,2 GiB e replica 3 priva di HA reale.

**Alternative considerate:** Longhorn; local-path su OS; local-path su data disk; servizi DB gestiti.

**Scelta:** E10 128 GiB iniziale, local-path su `/srv/k3s-data`, StatefulSet.

**Motivazione:** minima complessità e chiara separazione OS/dati.

**Trade-off:** nessuna replica/HA; restore richiesto dopo perdita disco.

**Rischi:** IOPS Standard SSD insufficienti.

**Reversibilità:** media/alta; disk espandibile o sostituibile con Premium tramite backup/restore.

### ADR-05 — Backup

**Decisione:** backup applicativi e file-level cifrati off-host.

**Contesto:** GitOps ricrea configurazione ma non dati; DB Azure Disk non hanno backup osservato.

**Alternative considerate:** full VM backup; snapshot disk; Longhorn; dump nativi + storage ZRS.

**Scelta:** dump PostgreSQL/MariaDB/Influx, backup file/K3s, Blob ZRS e restore rehearsal.

**Motivazione:** portabilità, consistenza e indipendenza dalla VM.

**Trade-off:** restore più procedurale della VM image.

**Rischi:** job apparentemente verdi ma dump inutilizzabili.

**Reversibilità:** alta; snapshot possono restare checkpoint complementari.

### ADR-06 — Ingress

**Decisione:** Cloudflare Tunnel → Traefik ClusterIP.

**Contesto:** nessun Ingress live, tunnel remote-managed, niente necessità di Azure LB.

**Alternative considerate:** Traefik K3s bundled; Traefik Flux; ingress-nginx; porte host dirette.

**Scelta:** disabilitare bundled Traefik e installare Traefik pin via Flux.

**Motivazione:** ownership/versione dichiarativa e percorso unico senza ingresso Azure pubblico.

**Trade-off:** un Helm controller/component in più rispetto al bundled.

**Rischi:** route remote non inventariate e possibile errore cutover.

**Reversibilità:** alta; controller ingress sostituibile mantenendo Ingress standard.

### ADR-07 — Bootstrap Flux

**Decisione:** bootstrap read-only da repository pubblico tramite Ansible.

**Contesto:** `flux bootstrap github` introdurrebbe PAT/write credential non necessario al restore.

**Alternative considerate:** CLI bootstrap GitHub; manifest manuale; installazione Ansible pin.

**Scelta:** Ansible installa controller minimi e root GitRepository/Kustomization.

**Motivazione:** zero secret Git bootstrap e processo idempotente.

**Trade-off:** Ansible deve pin/revisionare i manifest Flux.

**Rischi:** repository reso privato senza aggiornare il recovery.

**Reversibilità:** alta; aggiungibile deploy key read-only.

### ADR-08 — Struttura repository GitOps

**Decisione:** cluster/infrastructure/data/apps con Kustomization esplicite.

**Contesto:** ApplicationSet wildcard e config.json nascondono ordine e possono abilitare test.

**Alternative considerate:** mantenere layout Argo; monorepo completamente nuovo; adattamento incrementale.

**Scelta:** adattare `polinetwork-cd`, separando production root, platform, data e app.

**Motivazione:** diff leggibili, dipendenze esplicite, storia conservata.

**Trade-off:** fase di spostamento file e aggiornamento path.

**Rischi:** doppio percorso durante transizione.

**Reversibilità:** alta tramite Git revert.

### ADR-09 — Aggiornamenti Debian/K3s

**Decisione:** security patch automatiche, reboot/K3s controllati.

**Contesto:** nodo unico; un aggiornamento automatico equivale a downtime totale.

**Alternative considerate:** upgrade manuale ad hoc; full automatic; finestra revisionata.

**Scelta:** unattended security senza auto-reboot; finestra settimanale; K3s pin e patch mensile canary.

**Motivazione:** equilibrio tra sicurezza e prevedibilità.

**Trade-off:** richiede disciplina/alert per reboot pending.

**Rischi:** rinvio cronico della manutenzione.

**Reversibilità:** alta; frequenza e automazione regolabili.

### ADR-10 — Strategia Argo CD → Flux CD

**Decisione:** handoff per Application senza co-ownership.

**Contesto:** Argo oggi riconcilia 12 app con prune/self-heal; Flux deve sostituirlo.

**Alternative considerate:** big bang; dual control; migrazione progressiva con owner esclusivo.

**Scelta:** non critiche → data → critiche, disattivando Argo per ciascuna prima di attivare Flux.

**Motivazione:** rollback granulare e nessun controller fight.

**Trade-off:** periodo transitorio con due controller per risorse diverse.

**Rischi:** rimozione Application con prune involontario.

**Reversibilità:** alta finché Argo resta installato e AKS è disponibile.

### ADR-11 — Datastore K3s

**Decisione:** SQLite embedded.

**Contesto:** singolo server, nessun requisito HA e budget CPU limitato.

**Alternative considerate:** SQLite; embedded etcd; PostgreSQL esterno.

**Scelta:** SQLite con backup DB/token.

**Motivazione:** minimo overhead e percorso K3s supportato per single server.

**Trade-off:** nessuna HA/control-plane replica.

**Rischi:** corruzione/perdita richiede restore o rebuild GitOps.

**Reversibilità:** media; K3s supporta migrazioni datastore ma richiede change pianificato.

---

## 32. Snowflake / Manual State Register

| Stato manuale/snowflake | Evidenza | Eliminazione o documentazione |
|---|---|---|
| State Terraform letto tramite `access_key.sh` | plan read-only riuscito, `No changes` | mantenere la procedura; separare provider/risorse Kubernetes e secret prima del target |
| Config/hostname Cloudflare remote | tunnel remote-managed, non in Git | export + Terraform Cloudflare o register/versioned procedure |
| Riferimento immagine Argo non in Git | Image Updater write-back `argocd` | Flux Image Automation scrive in Git il digest del tag `latest` per le app PoliNetwork |
| Private endpoint storage non nel codice | risorsa/NIC/DNS Azure osservate | importare nel modulo target o rimuovere dopo dipendenze |
| Reti/NSG `disk-inspector` | due set, incluso RG `temp` | owner check, poi cleanup separato |
| SSH VM aperto al mondo | NSG source `0.0.0.0/0` | Cloudflare Access SSH per il gruppo IT; Azure Run Command/Serial Console come break-glass |
| DB pubblici | PIP/LB 3306 e 5432 | tunnel/private-only; eliminare Service LB |
| Key Vault access policy e principal hardcoded/orfani | codice e Azure RBAC | gruppi/UAMI nominati, Azure RBAC, rimuovere orphan |
| Secret senza owner/consumer | numerosi metadata legacy | inventory owner + quarantine + rotation/delete approvato |
| Key Vault miscela dev/prod/CI | 69 nomi in un vault | migrazione per trust boundary |
| Dashboard cluster-admin | binding live | eliminare Dashboard e binding |
| Argo anonymous admin | ConfigMap live | remediation urgente e rimozione finale Argo |
| CA/TLS DB non ricostruibile chiaramente | `ca-*` e Secret TLS, cert-manager vuoto | documentare issuer/reissue, versionare manifest |
| PVC Redis montato sull'app | manifest/live mount | chiarire persistenza e correggere StatefulSet Redis/app |
| MariaDB/PostgreSQL come Deployment | manifest live | StatefulSet dichiarativo |
| Namespace/test/job Service Connector falliti | namespace vuoti e 4 `sc-job` stale | inventario owner e cleanup approvato |
| Resource requests mancanti | maggioranza workload | requests/limits da canary e VPA offline analysis |
| Immagini `latest`/tag nudo | platform e app | versione esplicita per terze parti; `latest` + Flux digest automation per app PoliNetwork |
| Branch ARM non merged | repo app su migration branch | PR/review/merge prima del cutover |
| Bot C# fuori scope | immagini amd64-only senza repo locale | non migrare, non riattivare, non includere nelle Kustomization target |
| Workflow Terraform duplicati/static secret | `.github/workflows` | consolidare OIDC-only |
| State potenzialmente contiene secret | data source KV/K8s Secret | rimuovere ownership, audit sicuro, ruotare |
| Container `file-blobs` pubblico | storage metadata | identificare consumer, rendere privato se possibile |
| Shared Key storage abilitata | entrambi account | migrare consumer a Entra/MI, poi disabilitare |
| VM/dischi/OpenBao legacy | tag e risorse live | non adottare implicitamente; retention/cleanup approvati |
| Dashboard/config Grafana manuale possibile | PVC con 51 MiB | export provisioning/dashboard in Git |

Obiettivo di accettazione: nessuna riga “non documentata”; le eccezioni residue devono avere owner, motivo, restore path e data di revisione.

---

## 33. Questioni aperte che richiedono input umano

1. Confermare che per MariaDB legacy siano accettabili: cutover offline con writer fermi e RPO ~0; dopo il cutover backup ogni 6 ore e restore entro 4 ore. PostgreSQL resta fuori dalla wave.
2. Confermare owner e retention dei dati MariaDB legacy; `bot-prod`, `tutor-prod` e bot C# sono già fuori scope.
3. Identificare owner Cloudflare e autorizzare export/verifica del mapping tunnel, hostname, Access policy, DNS e Service/Ingress.
4. Definire il gruppo Entra IT autorizzato a Cloudflare Access SSH, MFA e owner del break-glass Azure; non è richiesta una allowlist CIDR domestica.
5. Confermare che il repository GitOps possa restare pubblico; se deve diventare privato, approvare deploy key read-only e recovery escrow.
6. Confermare se il container pubblico `file-blobs` è intenzionale e quali client dipendono dall'accesso anonimo.
7. Approvare il rischio Managed Identity condivisa via IMDS se il proof di isolamento passa; altrimenti accettare la complessità di Azure Workload Identity self-managed.
8. Indicare finestra di manutenzione e downtime accettabile per database/cutover.
9. Verificare saldo e scadenza effettivi dei crediti Sponsorship, per tradurre la stima retail in runway reale.
10. Confermare retention legale/associativa di backup, log e dati utente.

Tutto il resto è verificabile tecnicamente e non deve diventare una domanda aperta al nuovo IT owner.

---

## 34. Piano di migrazione proposto

### Fase 0 — Preparazione

| Campo | Contenuto |
|---|---|
| Prerequisiti | owner nominati, accessi read-only, nessun change freeze conflittuale |
| Azioni | recuperare state access; refresh-only plan; export Cloudflare; owner secret; backup logici; restore rehearsal; correggere immagini ARM; baseline 7 giorni |
| Verifiche | state/actual/code reconciled; tutti i DB restore; manifest ARM64; tunnel inventory; security issue Argo valutata |
| Rischio | scoprire drift/secret legacy che allunga il progetto |
| Rollback | nessun cambiamento production salvo backup/security change separati |
| Completamento | zero gate bloccanti aperti e approval del report |

### Fase 1 — Target Azure

| Campo | Contenuto |
|---|---|
| Prerequisiti | state access, design/IP/CIDR/vault approvati, piano Terraform revisionato |
| Azioni | refactor confine cloud; VM/rete/dischi/UAMI/RBAC/KV/storage; import controllati se necessari |
| Verifiche | `fmt`, `validate`, policy, plan senza delete inattesi; cost estimate; Azure resource graph |
| Rischio | adozione/distruzione involontaria risorse legacy/live |
| Rollback | non applicare plan non conforme; destroy target solo con piano separato |
| Completamento | risorse target create, production AKS invariato |

### Fase 2 — Provisioning

| Campo | Contenuto |
|---|---|
| Prerequisiti | VM target raggiungibile da admin autorizzato |
| Azioni | Ansible base/security/storage/K3s; seconda esecuzione idempotenza |
| Verifiche | SSH, firewall, mount, K3s API privata, secrets encryption, reboot test |
| Rischio | disco formattato/montato male o lockout SSH |
| Rollback | ricreare VM OS; preservare data disk; accesso Azure Run Command break-glass |
| Completamento | `verify.yml` verde dopo reboot |

### Fase 3 — Platform bootstrap

| Campo | Contenuto |
|---|---|
| Prerequisiti | K3s healthy, Git raggiungibile |
| Azioni | Flux minimi, root source, ESO, policy, Traefik, osservabilità/backup skeleton |
| Verifiche | reconciliation/health, no secret statici, resource budget |
| Rischio | dependency loop o CRD non Ready |
| Rollback | suspend root e correggere Git; rebootstrap Flux |
| Completamento | foundation riproducibile dopo reinstall Flux |

### Fase 4 — Secret migration

| Campo | Contenuto |
|---|---|
| Prerequisiti | vault/RBAC/UAMI e proof IMDS approvati |
| Azioni | creare store namespaced ed ExternalSecret; migrare un consumer canary; rotazioni pianificate |
| Verifiche | ESO Ready, chiavi metadata presenti, workload healthy, pod non autorizzato non usa MI |
| Rischio | secret mancante/errato o esposizione MI |
| Rollback | ripristinare CSI su AKS; revocare assignment target |
| Completamento | mapping completo verificato senza leggere valori |

### Fase 5 — Workload non critici

| Campo | Contenuto |
|---|---|
| Prerequisiti | workflow ARM64 `bot-maintenance` riuscito, ESO, Traefik, route canary Zero Trust |
| Azioni | migrare esclusivamente `bot-mat-maintenance` in VM-K3s dev/staging; handoff Argo/Flux solo per questa risorsa |
| Verifiche | bot process startup, Secret ESO, logs, metrics, route canary e rollback AKS |
| Rischio | route/config non equivalente |
| Rollback | sospendere Flux target e riabilitare Argo/route AKS |
| Completamento | `bot-maintenance` stabile per 7 giorni; nessun altro workload viene attivato |

### Fase 6 — Storage e database

| Campo | Contenuto |
|---|---|
| Prerequisiti | almeno due restore rehearsal, StatefulSet validati, finestra approvata |
| Azioni | final dump e restore isolato di MariaDB legacy; nessun cutover production del database nella wave bot-maintenance |
| Verifiche | row/object counts, schema, restore ripetibile, backup target e RPO/RTO approvati |
| Rischio | perdita dati o incompatibilità versione |
| Rollback | mantenere DB AKS authoritative e scartare target; nessuna dual-write non progettata |
| Completamento | owner dati firma il restore di MariaDB legacy; AKS resta authoritative |

### Fase 7 — Networking / Cloudflare

| Campo | Contenuto |
|---|---|
| Prerequisiti | app/data target healthy, route export, TTL e rollback definiti |
| Azioni | cloudflared Flux in VM-K3s staging, route canary verso Traefik/bot-maintenance, senza cambiare hostname production |
| Verifiche | endpoint canary, TLS, Access, log tunnel, nessuna porta VM app pubblica; route AKS production invariata |
| Rischio | outage DNS/tunnel o route parziale |
| Rollback | ripristino route al tunnel AKS |
| Completamento | cloudflared/Traefik staging funzionanti e mapping route documentato; nessun cutover production |

### Fase 8 — Workload critici

| Campo | Contenuto |
|---|---|
| Prerequisiti | approvazione di una futura wave; DB/tunnel stabili; change window |
| Azioni | **deferred**: backend, bot, polinetcc e workload production non fanno parte della wave corrente |
| Verifiche | da definire nella successiva approvazione; AKS resta production |
| Rischio | side effect esterni, doppia elaborazione bot/job |
| Rollback | scalare a zero target e riattivare AKS con dati coerenti secondo runbook |
| Completamento | non applicabile alla wave corrente; nessun workload production deve essere spostato |

### Fase 9 — Decommissioning AKS

| Campo | Contenuto |
|---|---|
| Prerequisiti | periodo osservazione ≥14 giorni, DR test completo, backup retention, approval separata |
| Azioni | final inventory/export; plan distruttivo; rimuovere AKS e risorse dipendenti per ordine |
| Verifiche | nessun DNS/identity/disk/PE consumer, costi scesi, target e backup verdi |
| Rischio | dipendenza nascosta e perdita rollback |
| Rollback | prima del delete: riattivazione; dopo delete: recovery da backup/IaC, non rollback immediato |
| Completamento | Azure inventory pulito, state coerente, Snowflake Register aggiornato |

---

## 35. Criteri finali di accettazione

La migrazione è completata solo quando una persona che non conosce la storia dell'infrastruttura può:

1. ottenere accesso tramite gruppi documentati;
2. ricreare Azure da Terraform e la VM da Ansible;
3. bootstrap Flux senza secret personali;
4. materializzare i secret da Key Vault tramite identità Azure;
5. ripristinare ogni dato critico da backup verificato;
6. ripubblicare tutti gli endpoint Cloudflare;
7. dimostrare RPO/RTO, alert e backup;
8. spiegare ogni eccezione residua nello Snowflake Register.

Se uno di questi passaggi richiede un file dal vecchio nodo, una password custodita sul laptop di una persona o una procedura orale, il criterio non è soddisfatto.

---

## 36. Fonti tecniche esterne

- [Debian 13 “trixie”](https://www.debian.org/releases/trixie/) e [ciclo delle release Debian](https://www.debian.org/releases/)
- [K3s requirements e ARM64](https://docs.k3s.io/installation/requirements)
- [K3s packaged components](https://docs.k3s.io/installation/packaged-components)
- [K3s datastore](https://docs.k3s.io/datastore) e [backup/restore](https://docs.k3s.io/datastore/backup-restore)
- [K3s manual upgrades](https://docs.k3s.io/upgrades/manual) e [hardening guide](https://docs.k3s.io/security/hardening-guide)
- [Flux components](https://fluxcd.io/flux/components/), [Kustomize controller](https://fluxcd.io/flux/components/kustomize/) e [optional components](https://fluxcd.io/flux/installation/configuration/optional-components/)
- [External Secrets Operator — Azure Key Vault](https://external-secrets.io/main/provider/azure-key-vault/) e [API spec](https://external-secrets.io/main/api/spec/)
- [Azure Key Vault RBAC](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide) e [security guidance](https://learn.microsoft.com/en-us/azure/key-vault/general/secure-key-vault)
- [Azure VM Managed Identity](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-managed-identities-work-vm)
- [Azure Workload Identity per cluster self-managed](https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters.html)
- [Cloudflare Tunnel availability](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/) e [firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
- [Azure Epsv6 ARM64](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/epsv6-series)
- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [GitHub Actions OIDC con Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)

---

## 37. Evidenze locali principali

| Area | Evidenza |
|---|---|
| Terraform | `../terraform/backend.tf`, `providers.tf`, `data.tf`, `main.tf`, `modules/**`, `.github/workflows/**` |
| Argo | `../terraform/modules/argocd/**`, `../terraform/argocd-applications.yaml`, live Application/ApplicationSet/AppProject/ConfigMap |
| GitOps app | `../polinetwork-cd/k8s-apps/**` al riferimento `origin/main` sopra indicato |
| App/CI | Dockerfile, package metadata e `.github/workflows/**` nei repository applicativi locali |
| Azure | output metadata-only Azure CLI del 13 agosto 2026 |
| Kubernetes | output metadata-only `kubectl get`, `kubectl top` e API Prometheus read-only del 13 agosto 2026 |
| ARM64 | OCI manifest inspect dei digest/tag live; nessuna immagine eseguita o modificata |

Il futuro runbook deve trasformare i gate e le fasi di questo report in comandi revisionabili, pre-check, checkpoint, rollback e segnali di successo. Non deve copiare ciecamente comandi dal materiale `legacy/`.
