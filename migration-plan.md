# PoliNetwork — piano operativo AKS → K3s

| Campo | Valore |
|---|---|
| Stato | Pronto per l’implementazione incrementale |
| Ultimo aggiornamento | 23 agosto 2026 |
| Produzione durante i lavori | AKS, fino al cutover finale |
| Target | K3s single-node trattato da subito come production |
| Durata prevista | 1–2 giorni |
| Sorgente modificabile | `migration-plan.md` |
| HTML generato | `migration-plan.html` |

> Questo Markdown è la sorgente del documento. Modificalo e usa `make publish` per rigenerare l’HTML e aggiornare Postplan. Non modificare direttamente l’HTML.

## 1. Decisioni prese, stato e blocchi

### Obiettivo e principio operativo

La piattaforma deve poter essere ricostruita da una VM vuota usando Terraform, Ansible e Git. Il report è rivolto all’attuale owner/approvatore o alla persona che gli succederà: non richiede ulteriori livelli di approvazione interni.

Le operazioni normali avvengono così:

```text
Terraform → risorse Azure
Ansible   → Debian, mount, hardening e K3s
Flux      → tutto ciò che vive in Kubernetes
ESO       → secret da Azure Key Vault
```

`kubectl` e SSH restano strumenti eccezionali per diagnosi, manutenzione o migrazioni one-shot. Non fanno parte della gestione quotidiana.

AKS continua a fornire production durante la costruzione. K3s viene però configurato subito con regole, backup e sicurezza da production; cambia soltanto il traffico che riceve. Il passaggio avviene in 1–2 giorni, senza una settimana di osservazione.

### Perimetro reale dei workload

`polinetwork-cd#main` contiene molti servizi. `bot-maintenance` è soltanto il primo canary, non l’unico servizio da migrare.

| Workload attuale | Decisione | Storage/dipendenze principali |
|---|---|---|
| `admin` | Migrare | backend |
| `backend` | Migrare | PostgreSQL, Key Vault, Azure `file-blobs` |
| `bot-maintenance` | Migrare per primo come canary | secret Telegram; può restare spento per alcune ore |
| `bot-ts` / Telegram | Migrare | Redis, InfluxDB, secret |
| `influxdb` | Migrare | 5 GiB dati + 500 MiB config dichiarati |
| `monitoring` | Migrare 1:1 | Grafana, Prometheus e node-exporter; Loki/Tempo/Mimir non iniziali |
| `polinetcc` | Migrare | PostgreSQL e secret |
| `postgres` | Migrare con dump/restore a writer fermi | 32 GiB dichiarati, circa 87 MiB usati |
| `uptime-kuma` | Migrare | 200 MiB dichiarati, circa 19 MiB usati |
| `web` | Migrare | backend |
| `cloudflared` | Migrare come applicazione Flux | token da ESO; route verso Traefik |
| `mariadb` | Conservare come legacy | dump finale verificato; nessun requisito di continuità |
| `bot-rooms`, vecchio bot C#, `bot-prod`, `tutor-prod` | Non migrare | esclusione intenzionale |
| cartelle `tests/*` disabilitate | Non migrare | test storici |

Il vecchio Deployment C# in `bot-mat` non viene migrato; viene migrato solo `bot-mat-maintenance`, rinominabile in modo più chiaro come `bot-maintenance` durante la ristrutturazione.

### Repository: scelta semplice

La soluzione consigliata è:

- `polinetwork-cd`: unica source of truth per Flux, manifest applicativi, Ansible e documentazione operativa;
- `terraform`: repository separato per risorse Azure e state remoto;
- repository applicativi: codice, test e build delle immagini.

Tenere Ansible in `polinetwork-cd` è pratico: con un solo clone si ricostruiscono host e cluster. Terraform resta separato perché ha state, permessi e lifecycle diversi; mescolarlo al repository riconciliato da Flux aumenterebbe il rischio senza semplificare il ripristino.

Struttura target:

```text
polinetwork-cd/
  ansible/
    inventories/k3s/
    roles/{base,security,storage,k3s,flux,backup}/
    playbooks/{provision,verify}.yml
  clusters/k3s/
    flux-system/
    infrastructure.yaml
    apps.yaml
  infrastructure/
    storage/
    traefik/              # HelmChartConfig del Traefik bundled e routing condiviso
    external-secrets/
    cloudflared/
    observability/
    backup/
  apps/
    admin/
    backend/
    bot-maintenance/
    bot-ts/
    influxdb/
    polinetcc/
    postgres/
    uptime-kuma/
    web/
  docs/
```

Le cartelle continuano a corrispondere ai namespace. I `config.json` custom vengono eliminati dopo la conversione:

- un namespace disabilitato semplicemente non è referenziato da `clusters/k3s/apps.yaml`;
- l’automazione immagini è descritta con risorse Flux standard vicino al workload;
- non serve più un generatore custom basato su `disabled` e `update_strategy`.

### Storage: tre dischi totali, due per i dati

Inventario misurato su AKS:

| Dato | Richiesto oggi | Usato osservato | Target |
|---|---:|---:|---|
| PostgreSQL | 32 GiB | 87 MiB | fast |
| MariaDB legacy | 100 GiB | 577 MiB | solo dump; restore temporaneo se serve |
| Redis | 500 MiB | quasi vuoto | fast |
| InfluxDB | 5.5 GiB | 15 MiB | standard |
| Prometheus | 12 GiB | 349 MiB | standard |
| Grafana | 1 GiB | 51 MiB | standard |
| Uptime Kuma | 200 MiB | 19 MiB | fast |
| `file-blobs` | Azure Blob | esterno al cluster | resta su Azure Blob |

Configurazione scelta:

| Disco | SKU/capacità iniziale | Mount | Contenuto |
|---|---|---|---|
| OS | Standard SSD 64 GiB | `/` | Debian e strumenti host; nessun dato applicativo |
| fast | Premium SSD v2 64 GiB, baseline 3.000 IOPS / 125 MB/s | `/srv/fast` | PostgreSQL, Redis e futuri dati realmente critici |
| standard | Standard SSD E10 128 GiB | `/srv/standard` | K3s/containerd, InfluxDB, Prometheus, Grafana, volumi non critici e staging backup |

Si usa `/srv/standard`, non `/srv/hdd`, perché il disco è uno Standard SSD e ospita anche K3s. Un HDD risparmierebbe circa 3,71 USD/mese ma rallenterebbe containerd, volumi ordinari e restore; il risparmio non giustifica il collo di bottiglia. Azure indica Premium SSD v2 per workload sensibili a latenza e Standard SSD per applicazioni leggere. [Azure Managed Disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types)

Flux installa un solo local-path-provisioner con due StorageClass:

- `fast`, directory `/srv/fast/volumes`, per PostgreSQL, Redis e dati realmente critici;
- `standard`, directory `/srv/standard/volumes`, per gli altri PVC e i Job di backup/restore.

Il provisioner supporta StorageClass diverse associate a `nodePath` differenti. Le dimensioni dei PVC local-path non sono quote reali: retention e alert disco sono quindi obbligatori. [Rancher Local Path Provisioner](https://github.com/rancher/local-path-provisioner)

Budget iniziale sui dischi:

| Area | Disco | Budget iniziale |
|---|---|---:|
| PostgreSQL | fast | 16 GiB iniziali |
| Redis e cache critiche | fast | 4 GiB |
| crescita database e margine | fast | circa 40 GiB |
| K3s, containerd e immagini | standard | 40 GiB |
| InfluxDB | standard | 8 GiB |
| Prometheus, Grafana e Uptime Kuma | standard | 16 GiB |
| staging backup, restore workspace e margine | standard | circa 56 GiB |

I valori sono budget interni, non quote rigide. Oggi i dati persistenti attivi, esclusa MariaDB legacy, usano meno di 1 GiB; PostgreSQL usa circa 87 MiB, InfluxDB circa 15 MiB e Prometheus circa 349 MiB. Alert al 70% e 85% e revisione dopo le prime 24 ore. I backup autorevoli vanno su Azure Blob ZRS; `/srv/standard` da solo non è un backup.

Le immagini container stanno sullo Standard SSD. K3s usa `data-dir: /srv/standard/k3s`, quindi containerd salva layer, snapshot e immagini in `/srv/standard/k3s/agent/containerd`. Sul nodo AKS sono presenti circa 8,6 GB di immagini uniche, ma molte appartengono ad AKS, Longhorn, Argo e CSI e non verranno migrate. Il budget di 40 GiB copre ampiamente immagini target, layer estratti e qualche versione precedente. Kubelet esegue garbage collection automatica delle immagini inutilizzate con soglie high/low configurate da Ansible; non serve pulizia SSH periodica.

Il target iniziale installa soltanto Grafana, Prometheus e node-exporter. Loki, Tempo e Mimir non sono requisiti del cutover e non vengono installati nei primi due giorni. Potranno essere valutati in seguito, uno alla volta, dopo aver misurato CPU, memoria e crescita di `/srv/standard`; non riserviamo oggi disco o controller per componenti che non servono.

### Costo dello storage e budget Azure

Prezzi retail Consumption in USD per `westeurope`, verificati il 14 agosto 2026 tramite [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices). Sono stime prima di sponsorship, transazioni, egress e tasse.

Baseline storage attuale, escludendo interamente la VM di prova recente (`vm01`, `disk-core`, `disk-services` e `disk-vm01-os`):

| Risorsa production | Tier fatturato | USD/mese |
|---|---|---:|
| OS disk node AKS | Premium P10 128 GiB | 21,68 |
| PostgreSQL | Premium P4 32 GiB | 5,81 |
| MariaDB | Standard HDD S10 128 GiB | 5,89 |
| Totale |  | **33,38** |

Target:

| Risorsa | Tier | USD/mese |
|---|---|---:|
| OS VM | Standard SSD 64 GiB | da ricalcolare sul listino corrente |
| `/srv/fast` | Premium SSD v2 64 GiB, performance baseline | 6,07 |
| `/srv/standard` | Standard SSD E10 128 GiB | 9,60 + transazioni |
| NAT Gateway + IP pubblico outbound | Standard | da includere: tariffa oraria, dati processati e bandwidth |
| Totale |  | **da ricalcolare prima del prossimo apply** |

Il target mantiene 192 GiB di data disk e, isolando i soli dischi, resta più economico della baseline production. Un Premium da 32 GiB costerebbe circa 3,04 USD/mese, ma coinciderebbe già con la dimensione nominale dell’attuale volume PostgreSQL e lascerebbe poco margine a Redis e alla crescita del database. Il 64 GiB costa soltanto circa 3,04 USD/mese in più ed è la scelta consigliata.

Non si acquistano 4.000 IOPS. Il Premium SSD v2 include 3.000 IOPS e 125 MB/s; in West Europe aggiungere 1.000 IOPS costa circa 5,84 USD/mese, quasi quanto i 6,07 USD/mese della capacità da 64 GiB. Le metriche Azure degli ultimi 30 giorni mostrano sul node pool AKS un picco complessivo dei data disk di circa 3,06 IOPS, p99 circa 0,78 IOPS. La misura a un minuto può nascondere burst molto brevi, ma il margine rispetto a 3.000 è comunque enorme. Si aumenta a 4.000 soltanto se `Data Disk IOPS Consumed Percentage` resta oltre il 70% o se la latenza applicativa dimostra un collo di bottiglia. Premium SSD v2 permette di modificare IOPS e throughput senza sostituire il disco, fino a quattro volte in 24 ore. [Azure Premium SSD v2 performance](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types#premium-ssd-v2)

La stima del 14 agosto, precedente all’implementazione Terraform, era **103–110 USD/mese**. Non è più utilizzabile come approvazione di spesa: il codice applicato usa un OS disk da 64 GiB e un NAT Gateway con IP pubblico outbound, non inclusi in quel totale. Azure fattura il NAT Gateway dall’istante di creazione, più dati processati e bandwidth. [Azure NAT Gateway pricing](https://azure.microsoft.com/en-us/pricing/details/azure-nat-gateway/)

Prima del prossimo apply si deve quindi rigenerare il confronto current/target dal Cost Management reale e dal listino `westeurope`, includendo NAT, IP, Key Vault, Blob e transazioni. Se i 2.000 USD sono annuali, il tetto medio resta 166,67 USD/mese. Saldo e scadenza reali della sponsorship restano da leggere nel portale; nessun cutover è autorizzato da una stima precedente.

### ServiceLB, MetalLB e Traefik

ServiceLB crea Pod `svclb-*` con `hostPort` per ogni Service `LoadBalancer`; su un nodo singolo occupa direttamente le porte del nodo. MetalLB assegna VIP da un pool e li annuncia tramite ARP/L2 o BGP; è utile soprattutto quando una rete esterna deve raggiungere Service `LoadBalancer` su bare metal. [K3s ServiceLB](https://docs.k3s.io/networking/networking-services) · [MetalLB](https://metallb.io/configuration/)

Nel target il traffico entra così:

```text
Internet → Cloudflare → cloudflared nel cluster → Traefik ClusterIP → Service → Pod
```

Cloudflare non ha bisogno di un IP `LoadBalancer`: `cloudflared` raggiunge Traefik tramite DNS Kubernetes. Quindi:

- ServiceLB disabilitato;
- MetalLB non installato;
- Traefik bundled di K3s mantenuto e configurato come `ClusterIP` tramite `HelmChartConfig` gestito da Flux;
- nessun Azure Load Balancer e nessun IP pubblico.

Se in futuro un consumer nella VNet dovesse richiedere un vero VIP, si rivaluterà un Azure Internal Load Balancer o MetalLB. Oggi entrambi sarebbero componenti inutili.

Non si installa una seconda release Traefik con Flux. K3s distribuisce Traefik come componente packaged tramite il proprio Helm controller; Flux conserva in Git e riconcilia soltanto il `HelmChartConfig`, gli `Ingress`/`IngressRoute` e i middleware. Il Service risultante è `traefik` nel namespace `kube-system`. [K3s networking services](https://docs.k3s.io/networking/networking-services) · [K3s HelmChartConfig](https://docs.k3s.io/add-ons/helm#customizing-packaged-components-with-helmchartconfig)

### Versioni e aggiornamenti K3s/Traefik

Versioni iniziali fissate al 14 agosto 2026:

| Componente | Versione |
|---|---|
| K3s | `v1.36.3+k3s1` |
| Kubernetes | `v1.36.3` |
| Traefik bundled | `v3.7.8` |

`v1.36.3+k3s1` è la release indicata dal canale K3s `stable` alla data del piano, ma Ansible deve usare questa versione esatta e il relativo checksum: non deve seguire automaticamente `stable` o `latest`. Prima dell'implementazione, se il piano non viene eseguito subito, si ricontrollano release note, supporto e componenti embedded e si aggiorna il pin con una modifica revisionata. [K3s v1.36 release notes](https://docs.k3s.io/release-notes/v1.36.X)

Il lifecycle supportato del Traefik bundled segue K3s. Un `HelmChartConfig` può tecnicamente cambiare `image.tag`, ma farlo aggiornerebbe l'immagine senza aggiornare insieme chart, valori e CRD: nel target non si usa questo override. Le correzioni Traefik arrivano quindi tramite una nuova release K3s. Se in futuro servisse aggiornare Traefik con urgenza senza aggiornare K3s, la modifica va trattata come decisione architetturale: disabilitare il componente bundled e passare a una `HelmRelease` Flux, non forzare soltanto il tag dell'immagine.

L'upgrade K3s resta manuale e controllato, eseguito da Ansible in finestra di manutenzione; non si installa inizialmente `system-upgrade-controller`. Si applicano normalmente le patch mensili e si passa alle minor una alla volta, senza saltare versioni. Per ogni upgrade:

1. leggere le release note K3s e Kubernetes, inclusi i cambi del chart Traefik;
2. fissare in Git nuova versione e checksum, senza usare un channel mobile;
3. salvare in modo coordinato `${data-dir}/server/db`, `${data-dir}/server/token` e configurazione K3s, verificando che la copia sia disponibile off-VM;
4. applicare il role Ansible, che sostituisce il binario e riavvia `k3s` mantenendo la configurazione in `/etc/rancher/k3s/config.yaml`;
5. verificare versione, nodo `Ready`, Flux, ESO, Traefik, tunnel e smoke test applicativi;
6. in caso di regressione, ripristinare binario precedente, datastore e token della stessa copia.

Durante il riavvio l'API Kubernetes è brevemente indisponibile; i container già avviati normalmente continuano a funzionare. Se la release cambia Traefik, il suo rollout può comunque interrompere per breve tempo il traffico sul single-node: l'upgrade richiede quindi una finestra e non promette zero downtime. Un rollback tra minor richiede il datastore precedente; senza quel backup non si procede. [K3s manual upgrades](https://docs.k3s.io/upgrades/manual) · [K3s backup and restore](https://docs.k3s.io/datastore/backup-restore) · [K3s rollback](https://docs.k3s.io/upgrades/roll-back)

### ESO namespaced

Si usa un `SecretStore` in ogni namespace che consuma secret. La ragione è semplice: un `ExternalSecret` può riferirsi soltanto allo store dello stesso namespace. Un errore in `backend` non può quindi puntare per sbaglio allo store `platform` di `cloudflared`.

Il costo è una piccola ripetizione YAML, ridotta con un Kustomize component comune. Un `ClusterSecretStore` sarebbe più corto ma globale e richiederebbe conditions/label ben mantenute. In un cluster piccolo, con secret di applicazioni e platform distinti, il confine namespaced è più leggibile per il prossimo owner.

I due vault target, senza suffissi di ambiente, sono:

| Vault | Contenuto | Consumer |
|---|---|---|
| `kv-pn-infra` | Cloudflare, backup e secret dei controller | namespace infrastrutturali autorizzati |
| `kv-pn-apps` | secret runtime delle applicazioni e database | SecretStore dei namespace applicativi |

Un vault separato `kv-pn-dev` verrà creato soltanto se nascerà una vera trust boundary dev. Non si usano nomi `-prod`: qui dev e prod non sono piattaforme separate.

I nomi dei Key Vault sono globalmente unici; `kv-pn-infra` e `kv-pn-apps` risultavano disponibili il 14 agosto 2026, ma la disponibilità non costituisce una prenotazione e va ricontrollata prima del piano Terraform. Non si crea un vault CI finché non esiste un secret CI reale: GHCR usa il `GITHUB_TOKEN` temporaneo e Azure usa GitHub OIDC. I secret CI/CD legacy restano nel vault corrente finché il consumer non è verificato, poi vengono ruotati o revocati invece di essere copiati alla cieca.

L’identità ESO può leggere entrambi i vault target. L’identità CI non entra nel cluster. Il target usa Azure RBAC e non access policy legacy. ESO raccomanda Workload Identity; su K3s self-managed richiede però un issuer OIDC raggiungibile e aggiunge bootstrap. Per la prima migrazione si usa una UAMI della VM con accesso read-only ai vault e blocco dell’IMDS per i Pod non autorizzati; se quel test di isolamento fallisce, il cutover dei secret si ferma e si implementa Workload Identity. [ESO Azure Key Vault provider](https://external-secrets.io/latest/provider/azure-key-vault/)

### Cloudflare Tunnel e SSH

`cloudflared` resta un Deployment gestito da Flux. Le route hostname correnti vengono ricreate verso Traefik, non codificate a mano nell’host. Il token arriva da `kv-pn-infra` tramite ESO.

Cloudflare Access for Infrastructure non rende SSH pubblico. Il flusso è outbound-only: `cloudflared` apre il tunnel verso Cloudflare, mentre NSG e firewall non accettano TCP/22 da Internet. [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)

Accesso amministrativo:

```text
laptop con WARP + login Entra/MFA
  → policy Cloudflare Access
  → tunnel outbound
  → IP privato VM:22
```

Configurazione scelta:

1. il tunnel annuncia una route `/32` per l’IP privato della VM;
2. in Zero Trust si crea un Infrastructure Target, per esempio `k3s.polinetwork.internal`, associato a quell’IP;
3. l’Infrastructure Application consente protocollo SSH, porta 22 e solo l’utente Unix amministrativo creato da Ansible;
4. la policy ammette il gruppo Entra degli owner con MFA e device enrollment;
5. il laptop usa Cloudflare One Client/WARP in modalità Traffic and DNS;
6. Ansible configura `sshd` per la CA Cloudflare e disabilita password/root login;
7. il test utente è `warp-cli target list` seguito da `ssh <utente>@k3s.polinetwork.internal`.

Cloudflare usa certificati SSH brevi al posto di chiavi personali permanenti. La procedura completa e i campi Terraform sono nella documentazione ufficiale. [Cloudflare Access for Infrastructure SSH](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-infrastructure-access/)

Poiché il tunnel vive in K3s, se K3s è completamente fermo anche questo percorso può non funzionare. Il break-glass resta Azure Run Command o Serial Console. Installare un secondo `cloudflared` via systemd soltanto per SSH sarebbe più resiliente, ma duplicare tunnel e credenziali non è giustificato finché il break-glass Azure è verificato.

Una discussione successiva ha esplorato come alternativa Headscale + Headplane come servizi systemd, con Better Auth aggiornato come IdP OIDC e Authentik soltanto se la gestione utenti di Better Auth non fosse sufficiente. Questa alternativa risponde alla preferenza per una UI e per amministratori che non hanno necessariamente un account Entra, ma non è mai stata approvata come sostituzione del flusso Cloudflare né riportata nell’implementazione. Il baseline eseguibile di questo piano resta quindi Cloudflare Access SSH. Prima di finalizzare il role Ansible, l’owner deve confermare esplicitamente una delle due strade; se sceglie Headscale, vanno aggiornati insieme questo piano, bootstrap, backup, monitoring e modello IAM.

### Aggiornamento automatico di `:latest`

Il repository Git conserva il tag desiderato `latest`, ma non viene modificato a ogni build. Per questa modalità si usa la Gitless image automation del Flux Operator, non `ImageUpdateAutomation`:

1. un `ResourceSetInputProvider` di tipo `OCIArtifactTag` osserva in GHCR il solo tag `latest` ed esporta tag e digest;
2. un `ResourceSet` usa quei valori per generare la `Kustomization` applicativa;
3. `Kustomization.spec.images` sostituisce in cluster `latest` con `latest@sha256:<digest>`;
4. la modifica del Pod template crea un nuovo ReplicaSet e Kubernetes esegue il rollout, senza commit automatici.

Il Deployment versionato in Git continua a esprimere soltanto:

```yaml
image: ghcr.io/polinetworkorg/backend:latest
```

La `Kustomization` generata dal Flux Operator materializza invece il digest nel cluster. Senza questa trasformazione la stringa del Pod template non cambierebbe quando GHCR sostituisce `latest`, quindi Kubernetes non creerebbe un nuovo ReplicaSet; `imagePullPolicy: Always` da sola agisce soltanto quando un Pod viene creato e non provoca il rollout. [Flux Operator: Gitless image automation](https://fluxoperator.dev/docs/resourcesets/image-automation/) · [Kubernetes image pull policy](https://kubernetes.io/docs/concepts/containers/images/)

Il percorso ordinario è event-driven: un webhook GitHub di organizzazione, limitato all’evento `package`, chiama un Flux `Receiver` di tipo `github`. Il Receiver verifica la firma HMAC e forza subito la riconciliazione dei `ResourceSetInputProvider` delle immagini PoliNetwork; se il digest di `latest` è cambiato, il `ResourceSet` aggiorna la `Kustomization` generata e avvia il rollout. GitHub emette l’evento `package` con azione `published` quando un package viene pubblicato. [Flux webhook receivers](https://fluxcd.io/flux/guides/webhook-receivers/) · [GitHub webhook `package`](https://docs.github.com/en/webhooks/webhook-events-and-payloads#package)

Il Receiver è pubblicato tramite Traefik e Cloudflare su un hostname dedicato. Non va protetto da Cloudflare Access, perché GitHub non può completarne il login: l’autenticazione applicativa è la firma HMAC di GitHub; Cloudflare fornisce TLS, proxy e rate limiting. Il secret del webhook è generato casualmente, conservato in Key Vault, materializzato da ESO nel Secret referenziato dal Receiver e mai inserito in Git. Si usa un solo Receiver con l’elenco esplicito dei provider PoliNetwork: un evento può quindi causare scansioni superflue degli altri repository, ma soltanto al momento di una pubblicazione e non ogni minuto.

Il fallback `fluxcd.controlplane.io/reconcileEvery` dei provider è impostato a `6h`. Il webhook elimina quindi il polling frequente, non la riconciliazione periodica di sicurezza. GitHub non ritenta automaticamente le consegne fallite: un operatore può ridistribuirle dalla cronologia GitHub, mentre il fallback recupera comunque il nuovo digest entro sei ore. Il cutover richiede una prova reale di pubblicazione, consegna, digest runtime e rollout. [GitHub: failed webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries)

Questa scelta rinuncia intenzionalmente ad avere ogni digest nella cronologia Git. Il digest applicato resta osservabile nello stato del `ResourceSetInputProvider`, nella `Kustomization` generata, nel Deployment e nei ReplicaSet. Per rollback: sospendere il provider, recuperare il digest precedente dal ReplicaSet e inserirlo come override esplicito revisionato in Git; dopo la correzione rimuovere l’override e riattivare il provider. Non affidarsi al solo `kubectl rollout undo`, perché la riconciliazione ripristinerebbe il digest corrente.

Questa automazione vale per immagini PoliNetwork. Database, controller e immagini terze usano una versione esplicita e vengono aggiornati con una PR, senza digest obbligatorio.

### Terraform: state separati e foundation già applicata

La ristrutturazione Terraform non è più un’attività futura. La PR Terraform `#79`, incorporata in `stable` come commit `0937051`, ha separato:

- `environments/legacy`, backend key `state.tfstate`, che conserva AKS e le risorse Kubernetes/Helm legacy;
- `environments/k3s`, backend key `k3s.tfstate`, che possiede soltanto la foundation K3s;
- `module.shared`, mantenuto nello state legacy, per storage backup, container, retention e budget condivisi.

Il cleanup autorizzato del precedente tentativo è stato applicato: `vm01`, il suo PIP/NIC/NSG/VNet, `disk-core`, `disk-services`, le vecchie identity e la chiave OpenBao non risultano più presenti. Sono stati mantenuti AKS, `rg-polinetwork`, `polinetworksa`, `polinetworkbackups`, i container backup, retention e budget. Non si usa comunque mai un `terraform destroy` generale e una risorsa condivisa non deve appartenere a entrambi gli state.

Verifica read-only del 23 agosto 2026:

- `k3s01` è accesa, usa `Standard_E2ps_v6`, IP privato `10.43.1.4` e nessun IP pubblico sulla NIC;
- sono collegati `disk-k3s-fast` Premium SSD v2 64 GiB, `disk-k3s-standard` Standard SSD 128 GiB e OS disk Standard SSD 64 GiB;
- VNet, subnet, NSG deny-inbound, NAT Gateway outbound-only, UAMI/RBAC e Blob access sono nello state K3s;
- il piano `environments/legacy` termina con `No changes`;
- il piano corrente `environments/k3s` mostra `0 add, 3 change, 0 destroy`: i tre Key Vault applicati hanno ancora firewall `Allow`, mentre il codice richiede `Deny` e la subnet K3s;
- la VNet temporanea `disk-insp-2-vnet` esiste ancora fuori dallo state K3s e va identificata prima di una sua eventuale rimozione.

Esiste inoltre una divergenza tra il codice applicato e l’ultima decisione: Terraform ha creato `kv-polinetwork-platform`, `kv-polinetwork-apps` e `kv-polinetwork-ci`; il target approvato successivamente usa soltanto `kv-pn-infra` e `kv-pn-apps`. Prima del prossimo apply bisogna correggere il codice, inventariare per metadata gli eventuali contenuti dei tre vault applicati e revisionare attentamente create/delete e RBAC. Il vault CI non va copiato automaticamente.

### PostgreSQL, MariaDB e `file-blobs`

Per il cutover PostgreSQL basta un dump/restore in una finestra a bassa attività, purché prima si fermino tutti i writer. Questo produce un RPO del cutover prossimo a zero: non vengono accettate scritture tra dump e switch. Dopo il cutover servono comunque backup periodici, perché il dump della migrazione non protegge dai guasti futuri.

MariaDB non ha un RPO/RTO operativo. Scrivere “RPO 0” significherebbe zero perdita dati ed è più restrittivo del necessario. La definizione corretta è: servizio legacy senza SLA; si conserva un dump finale con checksum, si prova una volta il restore e non si avvia MariaDB su K3s se non emerge un consumer reale.

`file-blobs` è lo storage on-demand del backend e resta `polinetworksa/file-blobs`. Il backend usa già Azure Blob SDK e restituisce URL Blob. Per la migrazione 1:1:

- non si copia `file-blobs` sui dischi della VM;
- il backend scrive/elimina tramite Managed Identity con ruolo limitato al container;
- la lettura pubblica resta invariata durante il cutover, perché oggi il container ha accesso pubblico `blob`;
- la privatizzazione richiede una modifica applicativa separata per URL SAS brevi o proxy del backend e non viene mescolata al cutover.

### Argo CD

Non si modifica Argo CD. Continua a riconciliare AKS esattamente come oggi mentre Flux possiede K3s. Non esiste conflitto perché i cluster sono diversi.

Al cutover si fermano i workload AKS, si spostano le route e si lascia Flux gestire K3s. Argo, Image Updater e AKS vengono rimossi solo alla fine. Investire tempo in nuove policy Argo prima della sua eliminazione non porta beneficio alla migrazione.

### Modifiche di sicurezza incluse nella migrazione

| Problema corrente | Correzione target |
|---|---|
| SSH pubblico `0.0.0.0/0` sulla VM esistente | nessun PIP e nessuna regola inbound; Access SSH via tunnel + break-glass Azure |
| Service database `LoadBalancer` | PostgreSQL/Redis/InfluxDB solo `ClusterIP` |
| secret letti da Terraform e scritti come Secret Kubernetes | rimuovere data source dei valori e provider Kubernetes dal root target; ESO crea i Secret |
| Key Vault unico e access policy ampie | due vault per trust boundary, Azure RBAC e identità dedicate |
| credenziali Azure statiche nel backend | Managed Identity con scope sul container Blob e sulle sole API necessarie |
| Dashboard con cluster-admin | non migrare Kubernetes Dashboard |
| immagini terze non versionate (`redis`, `influxdb`, Prometheus, Grafana) | tag di versione espliciti |
| immagini PoliNetwork senza rollout deterministico di `latest` | Flux Operator risolve e applica `latest@sha256` direttamente in cluster |
| Longhorn single-node con overhead elevato | local-path-provisioner e backup off-VM |
| assenza di request/limit | valori iniziali per ogni workload, poi correzione con metriche |
| digest runtime non registrato nella cronologia Git | stato del provider, eventi e ReplicaSet osservabili; rollback con override digest esplicito e revisionato in Git |
| backup locale confuso con DR | dump cifrati su Blob ZRS e restore testato |

Le NetworkPolicy vengono aggiunte per namespace dopo lo smoke test del servizio, iniziando da database e controller. Non si applica un default-deny globale prima di conoscere i flussi: sarebbe sicurezza apparente con alto rischio di outage.

### Blocker reali

Non ci sono blocker per iniziare a scrivere Ansible e la struttura Flux. Prima del cutover devono però essere chiusi questi punti:

| Blocco prima del cutover | Evidenza richiesta |
|---|---|
| Route Cloudflare | tabella hostname → servizio/porta → policy Access, poi route Traefik equivalente |
| Secret | ogni nome corrente associato a consumer, vault target ed ExternalSecret; nessun valore in Git |
| PostgreSQL | dump/restore di prova riuscito e lista completa dei writer da fermare |
| Capacità VM | test di almeno 1–2 ore con tutti i workload iniziali; CPU non stabilmente oltre l’80% e niente OOM |
| Scelta SSH | conferma esplicita Cloudflare Access oppure revisione completa verso Headscale/Headplane |
| Accesso amministrativo | Access SSH da rete domestica e Azure Run Command/Serial Console entrambi verificati prima di rimuovere il PIP |
| Terraform/Key Vault | codice riconciliato sui due vault finali; firewall `Deny`; piano K3s e legacy revisionati e poi entrambi `No changes` |

`bot-maintenance` non è un blocker: è già multi-arch (`amd64`/`arm64`), pubblica soltanto `latest` e può essere fermato per alcune ore durante il canary.

### Identità Azure da verificare

Questi object ID sono stati rilevati nell’assessment. L’attuale owner può eseguire l’audit e decidere direttamente; la rimozione avviene soltanto dopo il cutover o dopo aver escluso consumer reali.

| Object ID | Identità osservata | Azione prevista |
|---|---|---|
| `99053e08-87b6-4585-b77d-e9d2072551eb` | non risolta; Contributor subscription/KV | cercare owner e log, poi rimuovere se orphan |
| `76786ae8-54bf-4468-b301-f7d1dec5c086` | non risolta; Contributor subscription | cercare owner e log, poi rimuovere se orphan |
| `16990676-5daf-4d97-b0d0-a820d31ba947` | non risolta; Contributor + Owner state container | verificare con priorità prima di toccare lo state |
| `14db305f-1e26-46cd-8acb-dbe49ef67282` | service principal legacy | credenziale scaduta; rimuovere se senza consumer |
| `7254cc61-1f41-439b-822d-1fe5a7025a43` | `CAnalyzer` | credenziale scaduta; rimuovere se senza consumer |
| `81dd9fd1-ea71-420a-9f8a-8cbb74f479a6` | GitHub Terraform read-only | mantenere, solo plan/state read |
| `f220ce5b-e174-413d-b6f8-04e214b85d76` | GitHub Terraform read-write | mantenere con OIDC e scope ridotto |
| `245ea657-bfb5-4ca2-9640-5487c648b902` | identity AKS | eliminare con AKS |
| `43fab6a8-439d-4f98-b387-682df65783f8` | identity CSI AKS | eliminare dopo CSI → ESO e AKS |
| `5c40836d-796f-4d54-a194-1f0b8374185a` | `id-vm01-openbao` | eliminare con il vecchio tentativo se OpenBao non è target |
| `0959e426-bdaf-4168-9e92-2b43f4d55917` | `id-vm01-backup` | riusare solo se coerente col nuovo backup; altrimenti sostituire |

## 2. Istruzioni precise per eseguire la migrazione

### Regole di esecuzione

Lavora su branch e pull request. Un merge su `polinetwork-cd#main` è l’operazione ordinaria che Flux riconcilia; non eseguire deploy manuali. I comandi `kubectl` sotto indicati sono soltanto controlli eccezionali durante la migrazione. Non stampare mai Secret Kubernetes o valori Key Vault.

La sequenza è pensata per due giornate. Se un criterio di uscita fallisce, si corregge Git/Ansible e si riesegue; AKS resta production fino al cutover.

### 0 — Fotografia e audit read-only

Carica l’accesso Azure e conserva output senza secret in una directory ignorata da Git:

```bash
cd /home/lorenzo/dev/PoliNetwork/terraform
source ./access_key.sh

export MIGRATION_EVIDENCE="/home/lorenzo/dev/PoliNetwork/aks-vm-migration/evidence/$(date +%F)"
mkdir -p "$MIGRATION_EVIDENCE"
chmod 700 "$MIGRATION_EVIDENCE"

az account show --query '{subscription:name,id:id,tenant:tenantId,user:user.name}' -o yaml
terraform state list > "$MIGRATION_EVIDENCE/terraform-state.txt"
terraform plan -lock=false -no-color > "$MIGRATION_EVIDENCE/terraform-current-plan.txt"
kubectl get deploy,statefulset,daemonset,cronjob,service,ingress,pvc -A -o wide \
  > "$MIGRATION_EVIDENCE/kubernetes-inventory.txt"
```

Il piano corrente deve terminare con `No changes`. Non usare `terraform apply` in questa fase.

Per verificare tutte le identità note senza modificare Azure:

```bash
cd /home/lorenzo/dev/PoliNetwork/terraform
source ./access_key.sh

for object_id in \
  99053e08-87b6-4585-b77d-e9d2072551eb \
  76786ae8-54bf-4468-b301-f7d1dec5c086 \
  16990676-5daf-4d97-b0d0-a820d31ba947 \
  14db305f-1e26-46cd-8acb-dbe49ef67282 \
  7254cc61-1f41-439b-822d-1fe5a7025a43 \
  81dd9fd1-ea71-420a-9f8a-8cbb74f479a6 \
  f220ce5b-e174-413d-b6f8-04e214b85d76 \
  245ea657-bfb5-4ca2-9640-5487c648b902 \
  43fab6a8-439d-4f98-b387-682df65783f8 \
  5c40836d-796f-4d54-a194-1f0b8374185a \
  0959e426-bdaf-4168-9e92-2b43f4d55917
do
  echo "### $object_id"
  az ad sp show --id "$object_id" \
    --query '{objectId:id,appId:appId,name:displayName,type:servicePrincipalType,enabled:accountEnabled}' \
    -o yaml 2>/dev/null || echo "service principal non risolto"
  az role assignment list --all --include-inherited \
    --assignee-object-id "$object_id" \
    --query '[].{role:roleDefinitionName,scope:scope,assignmentId:id}' -o table
done | tee "$MIGRATION_EVIDENCE/identity-audit.txt"
```

Per le due app GitHub Actions verifica che usino federation e non password:

```bash
for app_id in \
  773afc65-715d-4050-a821-769c46fdb76f \
  76b5658e-375b-454e-b28a-b2d0fb19ab43
do
  az ad app credential list --id "$app_id" \
    --query '[].{name:displayName,end:endDateTime,keyId:keyId}' -o table
  az ad app federated-credential list --id "$app_id" \
    --query '[].{name:name,issuer:issuer,subject:subject,audiences:audiences}' -o table
done
```

Output atteso: read-only limitata a PR/branch Terraform; read-write limitata all’Environment GitHub `production`. Per i principal non risolti controlla anche Entra ID → Enterprise applications → Deleted applications e Audit/Sign-in logs. Non revocare ancora nulla.

Infine, dal pannello Cloudflare esporta soltanto metadata in una tabella:

```text
hostname | tunnel | origin service:porta | policy Access | nuovo Ingress Traefik
```

Non esportare token.

### 1 — Ristrutturare `polinetwork-cd`

Crea un branch da `origin/main`, non dal vecchio branch `vm`:

```bash
cd /home/lorenzo/dev/PoliNetwork/polinetwork-cd
git fetch origin
git switch -c k3s-flux origin/main
```

Esegui in commit piccoli e reversibili:

1. crea `ansible/`, `clusters/k3s/`, `infrastructure/` e `apps/`;
2. sposta ogni namespace attivo sotto `apps/<namespace>` conservando i manifest funzionanti;
3. porta solo `bot-mat-maintenance` in `apps/bot-maintenance`; non portare il vecchio bot C#;
4. non referenziare `bot-prod`, `bot-rooms`, `tutor-prod` e `tests`;
5. converti gradualmente `SecretProviderClass` in `ExternalSecret`;
6. elimina i `config.json` solo dopo che Flux rappresenta sia inclusione sia image automation;
7. aggiungi CI con `kustomize build`, `flux-local test` o almeno schema validation prima del merge.

Il criterio di uscita è che `clusters/k3s` ricostruisca l’intero target e nessun manifest attivo dipenda dal generatore Argo custom.

### 2 — Riconciliare Terraform già applicato

Parti da `origin/stable`, non dal vecchio branch di implementazione. La state split, il cleanup e la foundation sono già stati applicati; non ripeterli e non importare risorse manualmente.

1. crea una PR che sostituisca la mappa dei tre vault con `infra = "kv-pn-infra"` e `apps = "kv-pn-apps"`;
2. aggiorna i riferimenti RBAC da `platform` a `infra` e rimuovi la risorsa CI;
3. prima di pianificare, inventaria soltanto nomi/versioni e consumer dei tre vault esistenti, senza leggere o stampare valori;
4. non copiare i secret CI legacy: migra soltanto un secret con consumer dimostrato; preferisci `GITHUB_TOKEN` e OIDC;
5. includi nello stesso piano il firewall `default_action = "Deny"` e la subnet K3s per entrambi i vault target;
6. lascia invariati VM, dischi, VNet, NAT, AKS e storage condiviso.

Esegui i controlli sui due root:

```bash
cd /home/lorenzo/dev/PoliNetwork/terraform
source ./access_key.sh

terraform -chdir=environments/k3s init
terraform -chdir=environments/k3s fmt -check
terraform -chdir=environments/k3s validate
terraform -chdir=environments/k3s plan -out=k3s.tfplan
terraform -chdir=environments/k3s show -no-color k3s.tfplan > k3s.plan.txt

terraform -chdir=environments/legacy init
terraform -chdir=environments/legacy fmt -check
terraform -chdir=environments/legacy validate
terraform -chdir=environments/legacy plan -out=legacy.tfplan
terraform -chdir=environments/legacy show -no-color legacy.tfplan > legacy.plan.txt
```

Il piano K3s può creare i due nomi finali e rimuovere i tre nomi precedenti, ma non deve sostituire VM/dischi né modificare AKS. Il piano legacy deve restare `No changes`. Poiché i Key Vault hanno purge protection, controlla esplicitamente il comportamento delle eliminazioni e conserva ogni secret ancora necessario prima dell’apply. Applica soltanto il piano revisionato tramite il workflow protetto; poi riesegui entrambi i piani fino a `No changes`.

### 3 — Provisionare Debian e K3s con Ansible

Ansible deve:

- creare l’utente amministrativo e configurare sudo;
- disabilitare root login e password SSH;
- configurare nftables e unattended security updates senza reboot automatico;
- formattare ext4 e montare per UUID `/srv/fast` e `/srv/standard`;
- installare K3s `v1.36.3+k3s1`, verificandone il checksum, con secrets encryption, configurazione persistente in `/etc/rancher/k3s/config.yaml` e data-dir `/srv/standard/k3s`;
- configurare garbage collection automatica delle immagini, per esempio high 70% e low 55%;
- mantenere Traefik bundled e disabilitare ServiceLB e local-storage bundled;
- installare Flux controller e il root source pubblico;
- installare agent/script di backup host-level se necessari;
- eseguire test automatici di mount, servizio K3s, porte e idempotenza.

Esecuzione:

```bash
cd /home/lorenzo/dev/PoliNetwork/polinetwork-cd/ansible
ansible-playbook -i inventories/k3s playbooks/provision.yml --check --diff
ansible-playbook -i inventories/k3s playbooks/provision.yml
ansible-playbook -i inventories/k3s playbooks/provision.yml
ansible-playbook -i inventories/k3s playbooks/verify.yml
```

La seconda esecuzione non deve produrre modifiche sostanziali. Se serve correggere qualcosa via SSH, la stessa correzione va immediatamente riportata nel role Ansible e ritestata.

### 4 — Bootstrap Flux e storage

Flux riconcilia nell’ordine:

```text
namespaces e StorageClass
→ HelmChartConfig e readiness del Traefik bundled
→ External Secrets Operator
→ SecretStore ed ExternalSecret
→ cloudflared
→ backup e osservabilità
→ applicazioni
```

Installa local-path-provisioner pin a una versione e configura `storageClassConfigs` per `/srv/fast/volumes` e `/srv/standard/volumes`. `standard` è la default; soltanto PostgreSQL, Redis e altri dati dichiarati critici usano `fast`. InfluxDB, Prometheus, Grafana e Uptime Kuma usano `standard`.

Configura Kustomization Flux separate con `dependsOn`, health check e prune. Il prune è abilitato per manifest ricreabili; PVC e namespace dati hanno protezioni esplicite e non vengono rimossi accidentalmente da un rename.

Il root GitRepository è pubblico e fa bootstrap in sola lettura, senza PAT. Installa il Flux Operator open source a versione e digest fissati, quindi dichiara la `FluxInstance`; non installare `image-reflector-controller` o `image-automation-controller`, perché gli aggiornamenti immagine usano `ResourceSet` e `ResourceSetInputProvider`. Flux non richiede alcun permesso `contents:write` sul repository `polinetwork-cd`.

Verifica eccezionale:

```bash
flux check
flux get kustomizations -A
flux get helmreleases -A
```

Da quel momento le riconciliazioni normali partono da merge/push Git, non da `flux reconcile` manuale.

### 5 — Migrare Key Vault e secret verso ESO

Costruisci una tabella privata senza valori:

```text
nome secret | consumer | namespace | vault corrente | vault target | owner | ruota sì/no
```

Sposta per metadata/ownership:

- infrastruttura e Cloudflare → `kv-pn-infra`;
- runtime app/database → `kv-pn-apps`;
- pipeline → nessun vault nuovo finché non emerge un secret CI reale; usare `GITHUB_TOKEN` e OIDC dove già disponibili;
- sconosciuti → restano temporaneamente nel vault corrente e non vengono copiati alla cieca.

Per ogni namespace Flux crea un `SecretStore` e gli `ExternalSecret`; le applicazioni passano da CSI mount a `secretKeyRef` o `envFrom`. Verifica solo `Ready` e nomi, mai i valori.

Prima di usare secret reali esegui il test IMDS automatizzato dal playbook/CI:

1. ESO deve ottenere i secret di test;
2. un Pod applicativo senza autorizzazione deve ricevere un rifiuto da IMDS;
3. i log non devono contenere token.

Se il Pod ottiene un token Azure, non procedere: si implementa Azure Workload Identity per ESO prima del cutover.

### 6 — Configurare Traefik, cloudflared e Access SSH

K3s installa il proprio Traefik bundled; Flux applica un `HelmChartConfig` `traefik` nel namespace `kube-system` che imposta il Service a `ClusterIP`, senza cambiare separatamente il tag dell'immagine. Flux gestisce inoltre gli `Ingress`/`IngressRoute` e i middleware. Per ogni hostname si crea una route con host, Service e porta corrispondenti. Il tunnel punta a:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      spec:
        type: ClusterIP
```

```text
http://traefik.kube-system.svc.cluster.local:80
```

Non creare una `HelmRelease` Traefik né Service `LoadBalancer`. Prima di configurare le route Cloudflare, verificare che esistano una sola installazione Traefik e un solo Service `traefik`, di tipo `ClusterIP`.

Per SSH in Cloudflare Zero Trust:

1. Networking → Tunnels → route: aggiungi l’IP privato VM `/32` al tunnel K3s;
2. Settings → WARP Client: abilita Traffic and DNS e Gateway proxy TCP;
3. Access controls → Targets: crea `k3s.polinetwork.internal` con IP privato e virtual network del tunnel;
4. Access controls → Applications: crea Infrastructure Application, target precedente, SSH/TCP 22;
5. policy allow: gruppo Entra owner, MFA, username Unix creato da Ansible;
6. Ansible installa la CA SSH Cloudflare e valida `sshd -t` prima del reload;
7. sul laptop installa/enrolla WARP, poi esegui:

```bash
warp-cli target list
ssh <utente>@k3s.polinetwork.internal
```

Prova anche Azure Run Command o Serial Console. Solo dopo entrambi i test elimina PIP e regola SSH pubblica tramite Terraform.

### 7 — Configurare `latest` automatico

Per ogni immagine PoliNetwork aggiungi un `ResourceSetInputProvider` e un `ResourceSet`. Il provider risolve il digest del solo tag `latest`:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: backend-image
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "6h"
spec:
  type: OCIArtifactTag
  url: oci://ghcr.io/polinetworkorg/backend
  filter:
    includeTag: '^latest$'
    limit: 1
```

Il `ResourceSet` genera la `Kustomization` dell’applicazione e applica il digest come image patch. Il root Flux continua a gestire il `GitRepository` e le definizioni dei `ResourceSet`, ma non deve anche dichiarare una seconda `Kustomization` per la stessa applicazione:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: backend
  namespace: flux-system
spec:
  inputStrategy:
    name: Permute
  inputsFrom:
    - kind: ResourceSetInputProvider
      name: backend-image
  resources:
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: backend
        namespace: flux-system
      spec:
        interval: 30m
        path: ./apps/backend
        prune: true
        sourceRef:
          kind: GitRepository
          name: flux-system
        images:
          - name: ghcr.io/polinetworkorg/backend
            newTag: << inputs.backend_image.tag | quote >>
            digest: << inputs.backend_image.digest | quote >>
```

Nel Deployment in Git resta `image: ghcr.io/polinetworkorg/backend:latest`, senza marker Flux e senza digest. Verifica con il build locale del Flux Operator che il template produca `latest@sha256:<digest>` prima del merge. I dettagli comuni di `dependsOn`, health check, timeout e ServiceAccount vanno inclusi nella `Kustomization` generata come nelle altre applicazioni.

Configura il webhook prima del canary, non come ottimizzazione successiva. Esempio ridotto del Receiver (la lista completa contiene tutti e soli i `ResourceSetInputProvider` PoliNetwork):

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: polinetwork-packages
  namespace: flux-system
spec:
  type: github
  events:
    - ping
    - package
  secretRef:
    name: github-package-webhook
  resources:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: ResourceSetInputProvider
      name: backend-image
```

1. crea un hostname dedicato che inoltra soltanto il path `/hook/...` del Service `webhook-receiver` di `notification-controller`; non pubblicare altri endpoint del controller;
2. applica rate limiting Cloudflare, ma non Cloudflare Access;
3. genera il secret in Key Vault e sincronizzalo con ESO nel Secret `github-package-webhook` con chiave `token`;
4. recupera `.status.webhookPath` del Receiver senza registrarlo nei log del repository;
5. crea un webhook GitHub a livello organizzazione verso l’URL dedicato, content type JSON, TLS verification attiva, stesso secret e solo eventi `package`;
6. verifica l’evento `ping`, poi pubblica un nuovo `latest` di test e controlla consegna GitHub `2xx`, riconciliazione immediata, nuovo digest nello stato del provider e rollout, confermando che Git non riceva commit;
7. verifica anche il fallback in una prova controllata con un intervallo temporaneamente ridotto, poi ripristina `6h` tramite Git.

Se non è disponibile il permesso amministrativo per creare il webhook di organizzazione, usa temporaneamente webhook di repository con la stessa configurazione soltanto nei repository che pubblicano le immagini; non tornare al polling ogni minuto.

### 8 — Canary `bot-maintenance`

Committa namespace, Deployment, request/limit, probe, SecretStore ed ExternalSecret. Mantieni il worker spento finché i secret non sono `Ready`.

Durante una finestra breve:

1. ferma il Deployment AKS `bot-mat-maintenance` per evitare doppie azioni;
2. abilita quello K3s tramite commit Git;
3. verifica startup, log applicativi e side effect per 1–2 ore;
4. pubblica una nuova immagine `latest` di test e verifica il digest runtime, il rollout Flux e l’assenza di commit automatici;
5. se fallisce, sospendi il provider, applica l’override del digest precedente oppure disabilita il workload K3s tramite commit Git e riattiva il Deployment AKS.

Non serve un’osservazione di sette giorni: questo canary può restare fermo alcune ore e serve a validare ARM64, ESO, Flux e image automation nello stesso giorno.

### 9 — Migrare i workload e i dati

Ordine consigliato, mantenendo AKS attivo per ciò che non è ancora passato:

1. `admin`, `web` e `polinetcc` con hostname temporanei;
2. `backend`, inizialmente con PostgreSQL AKS raggiungibile solo tramite percorso privato temporaneo;
3. `bot-ts`, Redis e InfluxDB, fermando i worker concorrenti;
4. PostgreSQL con cutover dati;
5. Uptime Kuma;
6. Grafana, Prometheus e node-exporter con retention e alert disco;
7. route Cloudflare definitive.

Per ogni workload: verifica ARM64, secret ESO, dipendenze, probe, request/limit, route e rollback. Un merge abilita il target; non usare `kubectl apply`.

Per PostgreSQL:

1. esegui prima un dump/restore di prova sul target e misura la durata;
2. nella finestra finale ferma Deployment e CronJob che scrivono;
3. verifica che non restino sessioni applicative di scrittura;
4. crea dump consistente, checksum e copia off-VM;
5. ripristina sul target e confronta schema, conteggi e query principali;
6. abilita i consumer K3s e sposta le route;
7. non consentire mai scritture contemporanee su source e target.

Per MariaDB:

1. identifica eventuali consumer con ricerca nei repository e connessioni correnti;
2. se non esistono, crea un dump finale con routine/eventi/trigger e checksum;
3. prova il restore una volta in un database temporaneo;
4. salva il dump cifrato su Blob ZRS;
5. non installare MariaDB permanentemente su K3s.

`file-blobs` non viene migrato: dopo aver assegnato la Managed Identity al backend, prova upload, download pubblico e delete di un file test.

### 10 — Osservabilità, backup e test DR

Installa Grafana, Prometheus e node-exporter con versioni esplicite e retention Prometheus compatibile con il PVC da 12 GiB. Imposta alert su:

- CPU host oltre 80% per 15 minuti;
- memoria disponibile sotto 2 GiB;
- `/srv/fast` e `/srv/standard` al 70% e 85%;
- IOPS consumati del disco fast oltre 70% per 15 minuti;
- inode, backup fallito, Flux non Ready, ExternalSecret non Ready, tunnel down e certificati in scadenza.

Durante il test di 1–2 ore con tutti i workload, se CPU o memoria superano stabilmente i limiti, riduci retention/frequenza di scrape e sospendi dashboard non necessarie. Loki, Tempo e Mimir restano fuori dal perimetro iniziale.

Backup automatici:

- PostgreSQL: dump periodico consistente, cifrato, su Blob ZRS;
- InfluxDB/Grafana/Uptime Kuma: backup applicativo o archivio coerente dei rispettivi path;
- K3s SQLite + server token: snapshot coordinato per facilitare il recovery, non come unica source of truth;
- Terraform state: blob versioning/soft delete;
- Key Vault: soft delete e purge protection;
- repository: GitHub più mirror/export periodico se desiderato.

Test DR obbligatorio prima di spegnere AKS:

1. ricrea una VM vuota con Terraform;
2. esegui Ansible due volte;
3. lascia che Flux ricostruisca platform e app;
4. verifica ESO senza leggere valori;
5. ripristina PostgreSQL e gli altri dati;
6. verifica Cloudflare, endpoint, image automation, monitoring e backup.

Ogni passaggio manuale non previsto diventa una correzione ad Ansible, Flux o al documento, non una nota affidata alla memoria.

### 11 — Cutover e rimozione AKS entro il secondo giorno

Quando tutti i workload sono validati:

1. esegui i dump finali e ferma tutti i writer AKS;
2. sposta le route Cloudflare al tunnel/Traefik K3s;
3. esegui smoke test di login Access, API, web, bot, upload Blob e dashboard;
4. osserva per alcune ore CPU, errori, tunnel e spazio disco;
5. in caso di errore, ripristina le route AKS e riattiva soltanto i writer source;
6. se tutto è stabile, rimuovi le Application Argo senza modificare prima le policy Argo;
7. genera un piano Terraform di decommissioning che elimini solo AKS, LB/PIP/dischi e identity non più usati;
8. conserva dump e snapshot finali per 14 giorni anche se AKS viene eliminato subito;
9. applica il piano e controlla costi, endpoint e backup.

Non aspettare sette giorni per il decommissioning. La finestra di rollback lunga è fornita dai dump/snapshot conservati, non dal mantenimento dell’intero AKS acceso.

### Rigenerare e pubblicare questo documento

```bash
cd /home/lorenzo/dev/PoliNetwork/aks-vm-migration
make html
make publish
```

Su Arch Linux, se manca il renderer Markdown:

```bash
sudo pacman -S python-markdown
```
