# LEGACY — precedente guida operativa AKS → K3s single-node

> Documento superato da `migration-plan.md` e conservato esclusivamente come riferimento storico.

> **Documento complementare:** [report HTML navigabile](migration-assessment-report.html) · [assessment Markdown sorgente](../migration-assessment-report.md)

## 1. Stato del documento e modalità d’uso

| Campo | Valore |
|---|---|
| Stato | **Bozza operativa derivata dall’assessment read-only** |
| Data di riferimento | 13 agosto 2026 |
| Ambiente osservato | Azure Sponsorship, `westeurope` |
| Sorgente | `migration-assessment-report.md` |
| Ambito | Preparazione, canary, migrazione progressiva e decommissioning controllato |
| Autorizzazione implicita | **Nessuna** |

Questa guida rende eseguibili i gate e le fasi dell’assessment; non è un’autorizzazione generale a modificare l’infrastruttura. Ogni operazione `apply`, provisioning/deploy, cutover o delete richiede un’approvazione nominativa e registrata per la specifica change window.

Le approvazioni minime sono:

- **Apply Azure/Terraform:** `[NOME APPROVER CLOUD]`, con piano salvato e revisionato.
- **Provisioning/Deploy Ansible, K3s, Flux, ESO o workload:** `[NOME APPROVER PLATFORM]` e owner del servizio interessato.
- **Cutover traffico/DNS/Cloudflare o writer:** `[NOME APPROVER CUTOVER]`, owner applicativo e owner dati quando applicabile.
- **Delete/decommissioning di risorse, dati o identity:** `[NOME APPROVER DECOMMISSION]`, owner della risorsa e approvatore di sicurezza/dati se pertinente.

Un’approvazione deve indicare almeno change ID, soggetto, oggetti inclusi, piano di rollback, finestra, evidenze verificate e scadenza. In assenza di approvazione, eseguire soltanto verifiche read-only.

### Convenzioni di attendibilità

- **Osservato:** verificato il 13 agosto 2026 nell’assessment.
- **Dichiarato:** presente nel codice, non necessariamente applicato o presente nello state.
- **Inferito:** conclusione tecnica derivata da più osservazioni.
- **Da verificare:** non certificabile con gli accessi disponibili.

I placeholder tra parentesi graffe, per esempio `{{KUBE_CONTEXT}}`, devono essere sostituiti in una change record privata prima dell’esecuzione. Non inserire valori sensibili in questa guida, nei log o negli artefatti pubblici.

## 2. Quattro blocker da chiudere prima del cutover

La migrazione non può passare dalla preparazione al cutover finché questi quattro blocker non hanno owner, evidenza e decisione approvata:

1. **Compatibilità ARM64:** tre immagini applicative sono sicuramente `amd64`-only: bot maintenance e le due immagini C# di `bot-rooms`. Devono essere ricostruite e testate multi-arch oppure il relativo workload deve essere esplicitamente escluso/dismesso.
2. **Backup e restore database:** non è stato osservato un backup applicativo verificato per PostgreSQL e MariaDB. Dump consistenti, cifratura, trasferimento e restore su database vuoto sono obbligatori; uno snapshot di volume non basta.
3. **Cloudflare Tunnel non versionato:** hostnames, route, Access policy e configurazione remote-managed non sono presenti nei repository ispezionati. Serve export metadata-only, owner nominato e percorso di ripristino/cutover provato.
4. **Terraform state inaccessibile:** l’identità dell’assessment ha ricevuto `403 AuthorizationPermissionMismatch`. Coverage, drift e piano di distruzione non sono certificabili finché un’identità autorizzata non esegue `state list`, `plan -refresh-only` e `plan` salvati e revisionati senza esporre valori sensibili.

### Esposizioni critiche da contenere con urgenza

I quattro blocker sopra impediscono il cutover, ma non sostituiscono le remediation di sicurezza già classificate nell’assessment. **Argo CD con accesso anonimo e ruolo predefinito admin** e i **LoadBalancer pubblici di PostgreSQL/MariaDB** sono esposizioni critiche; **SSH da `0.0.0.0/0`** è un’esposizione alta. Devono ricevere immediatamente owner, verifica di raggiungibilità e change di contenimento separata, con rollback e approvazione di sicurezza.

La raccolta read-only e la preparazione in ambienti isolati possono continuare mentre la remediation è pianificata. Non eseguire canary raggiungibili dall’esterno, deploy che ampliano la superficie, migrazioni dati o cutover finché le esposizioni critiche non sono state rimosse oppure formalmente contenute con controllo compensativo, scadenza e accettazione del rischio da Security. Immagini `latest`, risorse legacy e uso condiviso dell’IMDS restano gate delle fasi pertinenti. Non usare un blocker non chiuso come motivo per anticipare un’altra fase.

## 3. Decisione target e confini architetturali

La destinazione proposta è una VM ARM64 sostituibile, inizialmente `Standard_E2ps_v6` con 2 vCPU e 16 GiB, Debian 13 ARM64, OS disk separato e data disk Standard SSD inizialmente da 128 GiB. La capacità non è presunta: deve superare il canary di almeno sette giorni.

```text
GitHub source/GitOps/Terraform/Ansible
                │ CI, review, OIDC
                ▼
Azure: rete, NSG, PIP/NIC, VM, dischi, UAMI, RBAC, Key Vault, storage
                │
Debian ARM64 → Ansible → K3s single-server
                │                 │
                │                 ├─ Flux → stato Kubernetes da Git
                │                 ├─ ESO → SecretStore namespaced → Key Vault
                │                 ├─ Traefik ClusterIP
                │                 ├─ cloudflared → Cloudflare Edge via outbound 7844
                │                 ├─ osservabilità leggera
                │                 └─ StatefulSet e PVC local-path sul data disk
                │
                └─ backup logici/file cifrati → Blob Storage ZRS off-VM
```

Configurazione proposta, da pinning e approvazione in implementazione:

- K3s single-server con SQLite embedded, secrets encryption, CoreDNS, metrics-server e local-path-provisioner.
- Flannel/K3s networking e NetworkPolicy; niente operator Calico.
- ServiceLB e Traefik bundled disabilitati; Traefik versionato e riconciliato da Flux.
- Niente Longhorn su un solo nodo: il local-path provisioning non è un backup.
- PostgreSQL, MariaDB e InfluxDB inizialmente in StatefulSet sul data disk, solo con dump nativi e restore provati.
- Tre Key Vault finali per trust boundary: `platform-prod`, `applications-prod`, `ci-cd`; `kv-polinetwork` resta temporaneo e in quarantena durante la transizione.
- `SecretStore` ESO namespaced ed `ExternalSecret` espliciti; non usare un `ClusterSecretStore` globale per comodità.
- Cloudflared come Deployment Flux, token ottenuto da ESO, traffico applicativo solo outbound attraverso il tunnel.
- Flux riconcilia il solo desired state Kubernetes. CI propone digest immutabili tramite PR GitOps; nessun deploy diretto dalle pipeline applicative.

### Ownership obbligatoria

| Sistema | Possiede | Non possiede |
|---|---|---|
| Terraform | Azure resource, rete, VM, dischi, Key Vault, storage, identity e RBAC | pacchetti OS, filesystem, K3s, workload Kubernetes, valori dei secret |
| Terraform Cloudflare separato, se approvato | tunnel, DNS, route e policy dichiarative | Kubernetes, Azure e token nel repository |
| Ansible | utenti, SSH, hardening, pacchetti, mount, K3s, bootstrap Flux, supporto host backup | applicazioni, HelmRelease, ExternalSecret, valori Key Vault |
| Flux | controller e stato Kubernetes dichiarativo | VM, NSG, Key Vault, RBAC Azure, configurazione host |
| ESO | sincronizzazione Key Vault → Secret Kubernetes namespaced | creazione, classificazione e rotazione del valore remoto |
| CI | test, build multi-arch, push e proposta di aggiornamento GitOps | `kubectl apply`, Helm diretto o deploy fuori Git |
| Owner servizio/dati | comportamento applicativo, schema, consistenza, writer e criteri di accettazione | modifiche infrastrutturali senza approvazione |

Ogni oggetto deve avere un owner unico. In particolare, Terraform non deve creare gli stessi oggetti Kubernetes che Flux riconcilia.

## 4. Ruoli e RACI

Sostituire i placeholder con persone o gruppi reali prima della fase 0.

| Attività | Platform operator | Owner applicativo | Owner dati | Security | Approver change | FinOps/approver |
|---|---|---|---|---|---|---|
| Read-only inventory e baseline | R | C | C | C | I | I |
| Accesso Terraform state | R | I | I | C | A | I |
| Piano Azure/Terraform | R | C | C | C | A | C |
| Provisioning VM/K3s/Flux | R | C | I | C | A | I |
| Mapping secret e ESO | R | R | C | A/C | A | I |
| Build e test ARM64 | C | R | I | C | A | I |
| Migrazione dati e restore | R | C | R | C | A | I |
| Handoff Argo → Flux | R | R | C | C | A | I |
| Cutover Cloudflare/writer | R | R | R | C | A | I |
| Monitoraggio post-cutover | R | R | R | C | A | I |
| Delete/decommissioning | R | C | C | A/C | A | C |
| Accettazione finale | C | A/R | A/R | C | A | I |

Legenda: **R** responsabile operativo, **A** approvatore/accountable, **C** consultato, **I** informato. Un singolo operatore può eseguire più ruoli, ma non può auto-approvare la propria change critica.

## 5. Regole di sicurezza operativa

1. **Classificare ogni comando:** `[RO]` verifica read-only, `[REV]` modifica reversibile, `[DEST]` modifica distruttiva o non immediatamente reversibile.
2. `[RO]` non significa automaticamente “senza controllo”: state refresh, accesso a dati e query di produzione richiedono comunque ticket e least privilege.
3. Mai leggere, stampare, copiare o inserire in Git valori di Secret Kubernetes, Key Vault, Cloudflare, token K3s, chiavi di backup o credenziali.
4. Usare output metadata-only: nomi, versioni, condizioni, checksum non reversibili, timestamp, dimensioni ed esiti. Redigere URL firmati, token e payload.
5. Nessun `apply`, deploy, cutover o delete senza approvazione nominativa per la fase. `--dry-run`, `plan`, `check_mode` e diff non sono autorizzazioni a eseguire il seguito.
6. Un backup è valido solo quando il job è riuscito, il checksum è registrato e un restore rappresentativo è stato completato con esito positivo.
7. Prima di modificare dati, fare checkpoint e definire chi è il writer authoritative. Non usare dual-write improvvisato.
8. Prima di handoff GitOps, un solo controller deve possedere ciascuna risorsa. Argo e Flux non devono mai riconciliare contemporaneamente la stessa risorsa.
9. Non esporre API K3s, HTTP/HTTPS applicativo, PostgreSQL o MariaDB nell’NSG. SSH, se necessario, è limitato a CIDR amministrativi approvati e chiavi nominative.
10. Non utilizzare comandi o procedure del vecchio runbook Docker/OpenBao. Questa guida riguarda K3s, Flux, ESO e backup applicativi; i residui legacy vanno soltanto inventariati e rimossi con change separata.
11. Conservare evidenze in un’area con accesso limitato. I log del terminale devono essere redatti prima di essere allegati al ticket.
12. In caso di dubbio, fermare la fase, preservare lo stato e chiedere all’approvatore; non “provare” su produzione.

### Classificazione delle modifiche

| Classe | Esempi | Evidenza e approvazione |
|---|---|---|
| Read-only | inventory Azure/Kubernetes, manifest OCI, `terraform plan`, `flux get`, metriche | ticket, identità usata, timestamp, output redatto |
| Reversibile | PR GitOps, suspend/resume Flux, rollout, aggiunta target isolato, nuovo SecretStore, change NSG con rollback | change nominata, diff, backup/checkpoint, owner e piano di ritorno |
| Distruttiva | prune dati, rimozione Argo/CSI/Longhorn con dipendenze, delete PVC/dischi/AKS/Key Vault/RBAC, overwrite writer | approvazione separata, retention verificata, piano di recovery testato; mai inclusa in un’approvazione generica |

## 6. Placeholder e change record

Compilare prima dell’esecuzione e mantenere il record fuori da repository pubblico.

```text
CHANGE_ID={{CHANGE_ID}}
FASE={{FASE_0_9}}
FINESTRA_UTC={{START_UTC}}/{{END_UTC}}
TICKET={{TICKET_URL_OR_ID}}
EXECUTOR={{NOME_O_GRUPPO}}
APPROVER_APPLY={{NOME}}
APPROVER_DEPLOY={{NOME}}
APPROVER_CUTOVER={{NOME_O_NA}}
APPROVER_DELETE={{NOME_O_NA}}
OWNER_PLATFORM={{NOME_O_GRUPPO}}
OWNER_APP={{NOME_O_GRUPPO}}
OWNER_DATI={{NOME_O_GRUPPO}}
OWNER_CLOUDFLARE={{NOME_O_GRUPPO}}
SECURITY_CONTACT={{NOME_O_GRUPPO}}
BREAK_GLASS_REF={{RIFERIMENTO_SEGURO}}
SUBSCRIPTION_ID={{SUBSCRIPTION_ID}}
RESOURCE_GROUP_TARGET={{RESOURCE_GROUP}}
RESOURCE_GROUP_SOURCE={{RESOURCE_GROUP}}
KUBE_CONTEXT_SOURCE={{KUBE_CONTEXT}}
KUBE_CONTEXT_TARGET={{KUBE_CONTEXT}}
TERRAFORM_DIR={{PATH_OR_REPOSITORY_REF}}
ANSIBLE_DIR={{PATH_OR_REPOSITORY_REF}}
GITOPS_REPOSITORY={{URL_OR_REF}}
GITOPS_COMMIT={{COMMIT_SHA}}
TERRAFORM_PLAN={{PRIVATE_ARTIFACT_PATH}}
CLOUDFLARE_EXPORT={{PRIVATE_ARTIFACT_PATH}}
BACKUP_MANIFEST={{PRIVATE_ARTIFACT_PATH}}
RESTORE_EVIDENCE={{PRIVATE_ARTIFACT_PATH}}
ROLLBACK_DEADLINE_UTC={{TIME}}
```

Ogni record deve contenere: scope esatto, risorse escluse, pre-check, segnali attesi, evidenze, approvazioni, decisione GO/NO-GO, orario di stop, rollback eseguito o dichiarato non necessario, incidenti e firma dell’owner.

## 7. Prerequisiti e matrice accessi

| Accesso/artefatto | Minimo necessario | Owner | Verifica senza valori sensibili | Gate |
|---|---|---|---|---|
| Azure subscription | Reader per inventory; Contributor scoped solo apply approvato | Cloud | `az account show` e query risorse | Fase 0 |
| Terraform state blob | lettura/list/versioni e lock secondo procedura | Cloud/IaC | `terraform state list` con output nomi soltanto | Fase 0 |
| Terraform CI | OIDC read-only per PR; write separata con Environment protetto | CI/IaC | workflow e subject/environment revisionati | Fase 0 |
| Azure Key Vault | control plane separato da Secrets User/Officer; accesso a valori solo runtime autorizzato | Security/Secrets | ruoli, scope e audit; mai `get` da terminale | Fase 0/4 |
| GitOps repository | read pubblico nel caso previsto; altrimenti deploy key read-only | GitOps | clone/checkout a commit noto | Fase 0/3 |
| Registry | manifest e pull read-only; multi-arch digest | CI/App | inspect manifest metadata-only | Fase 0 |
| Kubernetes source | read-only per inventory; admin solo change approvate | Platform | context, RBAC e audit | Fase 0 |
| Kubernetes target | accesso amministrativo temporaneo e nominativo | Platform | kubeconfig con permessi/expiry documentati | Fase 2 |
| Cloudflare | export e modifica limitata a owner tunnel/DNS | Cloudflare owner | elenco tunnel/route/hostname metadata-only | Fase 0/7 |
| Backup storage | write/read scoped per uploader; recovery read-only/break-glass | Backup owner | test file cifrato senza stampa chiave | Fase 0/6 |
| Monitor esterno | check endpoint indipendente dal cluster | SRE/Platform | probe e alert test | Fase 5/7 |

Prima di procedere, verificare almeno due amministratori nominativi, accesso break-glass testato senza visualizzare secret, lock Terraform funzionante, change freeze noto e contatti di escalation reperibili.

## 8. Comandi template e segnali comuni

I comandi sono modelli, non un elenco di autorizzazioni. Sostituire i placeholder, verificare la versione CLI e allegare output redatto.

### 8.1 Verifiche read-only

```bash
# [RO] Azure: subscription/tenant e contesto attivo
az account show --subscription "{{SUBSCRIPTION_ID}}" \
  --query '{subscription:id,tenant:tenantId,user:user.name}' -o json

# [RO] Inventory metadata-only, senza payload di secret
az resource list --subscription "{{SUBSCRIPTION_ID}}" \
  --query '[].{name:name,type:type,group:resourceGroup,location:location}' -o table

# [RO] Kubernetes: contesto, nodi, workload e storage senza valori Secret
kubectl --context "{{KUBE_CONTEXT}}" config current-context
kubectl --context "{{KUBE_CONTEXT}}" get nodes -o wide
kubectl --context "{{KUBE_CONTEXT}}" get deploy,statefulset,pod,svc,pvc \
  --all-namespaces -o wide
kubectl --context "{{KUBE_CONTEXT}}" get externalsecret,secretstore \
  --all-namespaces -o wide

# [RO] Capacity e condizioni; non usare output che decodifica Secret
kubectl --context "{{KUBE_CONTEXT}}" top node
kubectl --context "{{KUBE_CONTEXT}}" get events --all-namespaces \
  --sort-by=.lastTimestamp

# [RO] Terraform: inventory dello state e generazione di plan binari riservati
# Verificare prima backend/workspace/subscription/variable set nel change record.
terraform -chdir="{{TERRAFORM_DIR}}" workspace show
terraform -chdir="{{TERRAFORM_DIR}}" state list
terraform -chdir="{{TERRAFORM_DIR}}" plan -refresh-only \
  -out="{{PRIVATE_REFRESH_PLAN_FILE}}"
terraform -chdir="{{TERRAFORM_DIR}}" plan \
  -out="{{PRIVATE_PLAN_FILE}}"
sha256sum "{{PRIVATE_REFRESH_PLAN_FILE}}" "{{PRIVATE_PLAN_FILE}}"

# [RO] Ansible: usare esclusivamente verify.yml, senza --diff
ansible-playbook -i "{{INVENTORY}}" "{{ANSIBLE_VERIFY_PLAYBOOK}}" \
  --check --tags "{{VERIFY_TAGS}}"

# [RO] OCI: verificare lista piattaforme e digest, senza pull/deploy
{{OCI_INSPECT_TOOL}} manifest "{{IMAGE_REF}}"

# [RO] Flux: health e revisioni
flux check
flux get sources git -A
flux get kustomizations -A
flux get helmreleases -A
```

Non usare `kubectl get secret ... -o yaml/jsonpath` né comandi equivalenti che possano restituire valori. Per verificare le chiavi, usare solo metadata e condizioni del Secret sincronizzato, oppure un test applicativo che non stampi il valore.

I file prodotti da `terraform plan -out` possono contenere valori sensibili in forma leggibile dalle API/CLI anche quando l’output terminale li maschera. Conservarli esclusivamente in storage privato cifrato con accesso ristretto, retention breve e audit; non allegarli a ticket, repository o evidence pack generici. Nell’evidence pack registrare soltanto hash SHA-256, backend/workspace, commit, variable-set reference, timestamp, identità e sintesi redatta del diff. Anche `ansible --check` non garantisce assenza assoluta di side effect per ogni modulo: usare solo il playbook `verify.yml` revisionato; non classificare un provisioning playbook come read-only e non usare `--diff` su template/config che possono incorporare secret.

### 8.2 Modifiche controllate

```bash
# [REV] Validare e riconciliare una PR GitOps già approvata
{{GITOPS_VALIDATION_COMMAND}}
flux reconcile kustomization "{{KUSTOMIZATION_NAME}}" \
  --with-source

# [REV] Contenimento: fermare una sola Kustomization, con ticket aperto
flux suspend kustomization "{{KUSTOMIZATION_NAME}}"

# [REV] Ripristino della riconciliazione dopo verifica e approvazione
flux resume kustomization "{{KUSTOMIZATION_NAME}}"
flux reconcile kustomization "{{KUSTOMIZATION_NAME}}" \
  --with-source

# [REV] Prima dell'apply: verificare contesto e integrità rispetto al change approvato
az account show --query '{subscription:id,tenant:tenantId}' -o json
terraform -chdir="{{TERRAFORM_DIR}}" workspace show
sha256sum "{{APPROVED_PLAN_FILE}}"
git -C "{{TERRAFORM_DIR}}" rev-parse HEAD

# [REV] Applicare solo se subscription, backend/workspace, commit, variable-set,
# hash del plan e scope risorse coincidono con il record approvato.
terraform -chdir="{{TERRAFORM_DIR}}" apply "{{APPROVED_PLAN_FILE}}"
```

Per un deploy Ansible usare il playbook versionato del repository e i tag approvati. Attivare `--diff` soltanto dopo aver verificato che task e template interessati non possano esporre valori sensibili; altrimenti ometterlo. Non inserire qui nomi di playbook, release o pin non ancora scelti.

Non fornire comandi di delete in questa guida: ogni distruzione deve avere un piano separato, una lista di dipendenze e un’approvazione `DELETE` dedicata.

## 9. Pre-check globale e gate GO/NO-GO

Eseguire prima di ogni fase e ripetere dopo una pausa o un incidente:

- change ID, finestra, executor, approvatori e rollback deadline compilati;
- backup e restore evidence disponibili per gli asset coinvolti;
- AKS ancora integro e rollback target non alterato;
- state Terraform accessibile e lock disponibile;
- diff Git/plan/manifest revisionato e nessun delete inatteso;
- owner applicativo/dati reperibile;
- monitor esterno e alert path funzionanti;
- spazio, inode, CPU, memoria e latenza entro soglie;
- nessun Secret value nei log o nell’artefatto;
- dipendenze e risorse escluse dalla change esplicitamente elencate.

**GO** solo se tutti i pre-check sono verdi, l’approvazione della fase è nominativa e le evidenze sono archiviate. **NO-GO** se un blocker è aperto, il backup/restore non è valido, compare un diff distruttivo inatteso, un owner non è reperibile, i segnali superano le soglie, il rollback non è praticabile o si rileva ownership concorrente.

## 10. Fasi operative 0–9

Le fasi sono progressive. Il completamento di una fase non autorizza automaticamente la successiva.

### Fase 0 — Preparazione e chiusura dei blocker

**Obiettivo.** Rendere verificabili state, backup, immagini, tunnel, owner e baseline senza cambiare la produzione, salvo remediation di sicurezza approvata separatamente.

**Prerequisiti e attività principali**

- nominare owner/approvatori e ottenere accessi read-only;
- correggere l’accesso read-only al Terraform state;
- eseguire `state list`, `plan -refresh-only` e `plan` senza stampare secret;
- esportare metadata-only di Cloudflare: tunnel, hostname, route, Access policy, owner e rollback;
- classificare workload, secret metadata, PVC, writer esterni e risorse legacy;
- produrre dump PostgreSQL/MariaDB/Influx e completare restore rehearsal su destinazione isolata;
- correggere o escludere le immagini ARM64 bloccanti;
- raccogliere baseline di almeno sette giorni;
- aprire con urgenza una change di sicurezza separata per verificare e contenere Argo anonymous admin e i database pubblici, oltre a restringere SSH globale; preparation read-only può continuare, ma nessun canary esterno, deploy che amplia la superficie, migrazione dati o cutover può procedere con esposizioni critiche non contenute;
- approvare o respingere le proposte iniziali RPO/RTO.

**Pre-check read-only**

- `{{KUBE_CONTEXT_SOURCE}}` corrisponde al cluster atteso e il nodo è osservabile;
- tutti gli asset dati hanno owner e classificazione;
- nessun backup contiene valori esposti nei log;
- il confronto codice/state/live non ha risorse senza decisione.

**Segnali attesi**

- state leggibile con identità autorizzata e piano senza delete inattesi;
- manifest OCI per ogni immagine target include ARM64, con digest immutabile;
- restore database ripetibile e query di consistenza positive;
- inventario Cloudflare completo e canary possibile senza cambiare produzione;
- baseline CPU/memoria/storage e lista delle eccezioni firmate.

**Evidenze da catturare**

- state list, hash del plan, sintesi diff, identità e timestamp;
- report restore con checksum, durata, versione/schema e risultati dei test;
- manifest platform, SBOM/scansioni e commit di build;
- export Cloudflare redatto, ownership matrix, baseline metriche;
- verbale di chiusura blocker e approvazione report.

**GO/NO-GO.** GO solo con zero blocker aperti o con una decisione formale di esclusione di un workload che non cambia il rischio del cutover. NO-GO se manca anche uno dei quattro gate principali.

**Rollback/abort.** Nessun rollback infrastrutturale: interrompere la raccolta, conservare l’evidenza e lasciare la produzione invariata. Una remediation Argo/SSH deve avere ticket e approvazione separati.

### Fase 1 — Target Azure e confine Terraform

**Approvazione richiesta.** `APPLY` nominativo di `[APPROVER_CLOUD]`; eventuale import/state move richiede approvazione aggiuntiva IaC.

**Prerequisiti e attività principali**

- repository, provider e versioni Terraform target revisionati e riproducibili;
- definire resource group/VNet/subnet/CIDR, NSG, PIP eventuale, SKU ARM64 e quota;
- dichiarare VM, OS/data disk, UAMI ESO/backup, RBAC, Key Vault, storage ZRS e hardening state;
- rimuovere dal target ownership Helm/Kubernetes e letture di secret value;
- gestire private endpoint e risorse legacy solo dopo inventory e owner check;
- produrre plan salvato, policy check, cost estimate e resource graph pre/post atteso.

**Pre-check.** `fmt`, `validate`, lint/security, backend lock, refresh-only, assenza di delete inattesi, `prevent_destroy` sul data disk e approvazione di IP/SSH.

**Segnali attesi.** Il plan crea soltanto il perimetro target approvato; non modifica AKS, database source, DNS o secret value; RBAC è scoped; NSG non espone API/DB/app e SSH è limitato.

**Evidenze.** Plan hash, policy results, resource graph, cost estimate, lista risorse create/importate, approvazione `APPLY`.

**GO/NO-GO.** GO se il plan è identico al perimetro approvato e il rollback della sola fondazione è possibile. NO-GO per qualsiasi destroy, replacement inatteso, role troppo ampio, quota/SKU non confermata o state ambiguo.

**Rollback/abort.** Prima dell’apply, scartare il plan. Dopo un apply parziale, fermare la change e usare il piano di recovery della fondazione; non eseguire `destroy` per riflesso. Proteggere il data disk e registrare risorse orfane. Qualsiasi delete richiede un piano `DELETE` separato.

### Fase 2 — Provisioning host e K3s

**Approvazione richiesta.** `DEPLOY` nominativo di `[APPROVER_PLATFORM]`; approvazione cloud precedente valida solo per Fase 1.

**Prerequisiti e attività principali**

- VM target raggiungibile solo da amministratori autorizzati;
- eseguire Ansible per base, utenti nominativi, SSH key-only, hardening, firewall, patch, mount e filesystem;
- formattare il data disk solo se nuovo e identificato in modo sicuro; non riformattare un filesystem esistente;
- installare K3s con versione e checksum selezionati nella change, SQLite sul data disk, secrets encryption, API privata, ServiceLB/Traefik bundled disabilitati;
- proteggere kubeconfig, server token e recovery material in storage sicuro, mai nei log;
- ripetere il provisioning e verificare idempotenza; eseguire reboot test in finestra.

**Pre-check.** SKU/architettura, device/LUN/UUID, snapshot/checkpoint, accesso break-glass, spazio disco, DNS/clock e regole NSG.

**Segnali attesi.** `verify` Ansible verde; seconda esecuzione senza change sostanziali; mount sul data disk; K3s API privata healthy; nodo Ready dopo reboot; secrets encryption attiva; nessun ingresso pubblico non approvato.

**Evidenze.** commit Ansible/K3s e checksum, output `--check`, `findmnt`/filesystem metadata, condizioni K3s, reboot timestamp, audit SSH/firewall redatto.

**GO/NO-GO.** GO se host e K3s sono ricreabili da zero e l’API non è Internet-facing. NO-GO per mount ambiguo, lockout SSH, API pubblica, encryption non verificabile, disco insufficiente o divergenza di idempotenza.

**Rollback/abort.** Interrompere Ansible al primo errore non compreso. Per un host non recuperabile, ricreare solo l’OS secondo change approvata preservando il data disk; usare Azure Run Command/break-glass documentato. Non cancellare il disco per “ripartire puliti”.

### Fase 3 — Bootstrap platform: Flux, ESO, networking e osservabilità

**Approvazione richiesta.** `DEPLOY` nominativo di `[APPROVER_PLATFORM]` e review del repository GitOps.

**Prerequisiti e attività principali**

- bootstrap Flux con controller minimi da Ansible e repository read-only; non introdurre PAT write se il repository è pubblico;
- creare root `GitRepository`/`Kustomization` e dipendenze esplicite, senza wildcard che possano riattivare `bot-prod` o `tutor-prod`;
- installare ESO e CRD; creare policy, ServiceAccount e SecretStore solo nei namespace consumer;
- installare Traefik versionato come ClusterIP, cloudflared solo come skeleton non esposto finché secret/route non sono pronti;
- predisporre osservabilità leggera, backup skeleton e alert esterno.

**Pre-check.** Git commit noto, manifest validati/schema/policy, immagini ARM64 dei controller verificate, K3s capacity e accesso Key Vault/RBAC predisposti.

**Segnali attesi.** Flux `Ready=True`, source revision attesa, CRD ESO established, resource budget sostenibile, nessun Secret statico nei manifest, Traefik disponibile internamente, alert sui failure di reconcile.

**Evidenze.** commit GitOps, `flux check/get`, condizioni CRD/Deployment, diff e lista namespace; nessun valore secret.

**GO/NO-GO.** GO se la foundation si re-installa in ambiente isolato e converge con lo stesso commit. NO-GO per dependency loop, prune inatteso, CRD non Ready, controller fuori budget, secret hardcoded o source non deterministico.

**Rollback/abort.** Sospendere soltanto la root/Kustomization coinvolta, correggere via PR e riconciliare. Se il bootstrap è corrotto, rimuovere/reinstallare Flux tramite Ansible solo con change approvata; non ripristinare Argo sul target.

### Fase 4 — Migrazione CSI → ESO e trust boundary

**Approvazione richiesta.** `DEPLOY` di `[APPROVER_PLATFORM]`, approvazione Security per UAMI/IMDS e owner per ogni consumer.

**Prerequisiti e attività principali**

- creare/validare i tre vault target e RBAC least privilege; mantenere `kv-polinetwork` come transizione, senza copia automatica;
- provare l’autenticazione UAMI ESO via IMDS e l’isolamento da pod non autorizzati; se fallisce, fermarsi e proporre Workload Identity self-managed;
- per ogni namespace consumer creare `SecretStore` namespaced;
- creare `ExternalSecret` con mapping `data` esplicito, nome Kubernetes temporaneo diverso dal Secret CSI;
- verificare solo metadata, chiavi attese e `Ready=True`; aggiornare un workload canary, fare rollout e smoke test;
- rimuovere CSI/SecretProviderClass solo dopo che tutti i consumer sono passati e il rollback CSI non è più necessario;
- pianificare rotazione e restart controllato: il cambio di Secret non riavvia da solo pod che usano env.

**Pre-check.** mapping owner/consumer completo, remote key names approvati, refresh/retention e deletion policy definite, audit Key Vault attivo, test IMDS e policy host documentati.

**Segnali attesi.** ESO e SecretStore `Ready=True`; ExternalSecret sincronizza senza stampare valori; workload parte con il nuovo riferimento; un pod non autorizzato non ottiene il token/secret; secret mancante lascia `NotReady` e blocca la dipendenza invece di creare default vuoti.

**Evidenze.** mapping metadata-only, condizioni ESO, RBAC scope, test isolamento, rollout e smoke test, log redatti, piano di rotazione.

**GO/NO-GO.** GO per un consumer alla volta; GO completo solo quando ogni mapping è verificato. NO-GO per remote key missing, Secret vuoto/default, accesso cross-namespace, pod non autorizzato che usa MI, valori nei log o CSI rimosso troppo presto.

**Rollback/abort.** Prima della rimozione CSI, ripristinare manifest e riferimento precedente, sospendere il consumer target e revocare l’assegnazione target se necessario. Dopo la rimozione, non ricreare Secret manuali: riattivare il percorso dichiarativo approvato o fermare il workload. Non cancellare il remote secret rimuovendo un `ExternalSecret`.

### Fase 5 — Workload non critici e canary ARM64

**Approvazione richiesta.** `DEPLOY` nominativo di `[APPROVER_PLATFORM]` e owner applicativo per ogni workload.

**Sequenza.** In questa fase migrare esclusivamente `web`/`admin` come candidati canary e poi le applicazioni stateless non critiche selezionate. La migrazione dei dati appartiene alla Fase 6; il networking/Cloudflare alla Fase 7; i workload critici alla Fase 8. Per ogni app non critica: conversione/validazione manifest, Kustomization Flux sospesa o esclusa dalla root, stop del solo Application Argo, rimozione senza prune, attivazione Flux, smoke test e checkpoint.

**Regola Argo → Flux.** Mai doppia ownership, anche temporaneamente. Argo può continuare a possedere altre applicazioni, ma non la stessa risorsa che Flux sta adottando. Conservare Argo finché il rollback per app è credibile.

**Pre-check.** digest immutabile e manifest ARM64, requests/limits e probe, Secret ESO Ready, route canary, PVC ownership corretta, policy di rete, backup e monitor esterno.

**Segnali attesi.** Flux revision aggiornata; Deployment/Service healthy; HTTP/TLS smoke positivo; error rate, log e metriche normali; nessuna risorsa ricreata o prunata inattesa; endpoint canary isolato; Argo Application della singola app non sincronizza più.

**Gate canary minimo, per almeno 7 giorni**

- CPU p95 `<70%` e picchi sostenuti `<85%`;
- working set memoria `<12 GiB`, nessun OOM o eviction;
- `load15` normalmente `<2`, senza degradazione dell’endpoint;
- latenza p95 e IOPS del data disk entro soglia definita dal test database;
- almeno 20% di spazio e inode liberi anche nella proiezione a 12 mesi;
- backup completato nella finestra senza violare SLO;
- immagini, probe, Flux ed ESO healthy; se viene usato un tunnel in questa fase, deve essere un **tunnel/hostname canary isolato**, senza modifica delle route production e senza sostituire i gate Cloudflare della Fase 7.

Se la CPU fallisce, preferire SKU ARM64 da 4 vCPU/32 GiB o separazione del carico; non nascondere il problema con tuning non documentato.

**Evidenze.** diff GitOps, checkpoint Argo/Flux, revisioni e owner, smoke test, dashboard 7 giorni, eventi/OOM, CPU/RAM/load/disk, backup/restore sintetico e prova di rollback di una app.

**GO/NO-GO.** GO solo con soglie rispettate per sette giorni e owner firmatario. NO-GO per immagine non ARM64, errore funzionale, doppia ownership, memory pressure, endpoint degradato, prune o backup non valido.

**Rollback/abort.** Sospendere la Kustomization Flux della sola app; revert Git se il problema è nel desired state; riabilitare l’Application Argo e la route precedente dopo aver verificato che Argo non abbia perso ownership. Non fare rollback globale né modificare dati in questa fase.

### Fase 6 — Storage, database e restore applicativo

**Approvazione richiesta.** `DEPLOY/DATA CHANGE` nominativo di `[APPROVER_DATI]`, `[APPROVER_PLATFORM]` e owner di ciascun database. RPO/RTO sono ancora proposte finché gli owner non firmano.

**Attività principali**

- convertire PostgreSQL, MariaDB e InfluxDB a StatefulSet, con PVC local-path sul data disk e probe/requests/limits;
- correggere l’ownership del PVC Redis prima di decidere se Redis è persistente;
- identificare consumer MariaDB e client esterni; nessuna assunzione dal solo manifest;
- eseguire backup applicativi cifrati: `pg_dump` custom + globals/roles, dump MariaDB consistente + grant/schema, backup nativo InfluxDB, export file/config;
- trasferire verso staging e Blob ZRS con identity scoped; registrare checksum, dimensioni e timestamp senza chiavi;
- ripristinare su database vuoto, verificare schema/versione, row/object counts e query applicative; ripetere almeno due rehearsal prima del cutover;
- produrre backup target e provare un nuovo restore prima di dichiarare la fase verde.

**Proposte RPO/RTO da approvare dagli owner**

| Classe | RPO proposto | RTO proposto | Approvazione richiesta |
|---|---:|---:|---|
| PostgreSQL/MariaDB critici | 6 ore | 4 ore | owner dati + owner servizio |
| Platform/GitOps | commit corrente | 4 ore | platform owner |
| InfluxDB/Uptime/config non critici | 24 ore | 8 ore | owner servizio |
| VM/OS/K3s | non applicabile come dato | 4 ore | platform owner |

**Writer fencing e rollback dati**

Prima del final dump, elencare tutti i writer: applicazioni, job, cron, bot, client esterni, webhook e operatori. Durante la migrazione:

1. dichiarare il database source authoritative;
2. mettere in manutenzione o bloccare le scritture applicative e i job che possono scrivere;
3. disabilitare consumer duplicati e schedulatori sul target;
4. eseguire final dump/checksum e restore target isolato;
5. eseguire consistenza e smoke senza abilitare writer concorrenti;
6. riaprire writer su un solo lato dopo il cutover autorizzato;
7. registrare l’istante di fencing e il primo writer attivo.

Non esiste rollback sicuro a AKS dopo scritture sul target senza riconciliare tali scritture. Se il target ha ricevuto dati, l’owner dati deve scegliere tra forward-fix, restore del target verso il source con conflitti esplicitamente risolti, oppure perdita/ricostruzione approvata. Non dichiarare “rollback” se comporta perdita silenziosa.

**Segnali attesi.** Restore applicativo riuscito, query di consistenza positive, schema compatibile, backup target leggibile, nessun writer doppio, IOPS/latency nel limite e spazio proiettato sufficiente.

**Evidenze.** manifest backup metadata-only, checksum, log cifrati redatti, restore report, query/check di consistenza, lista writer e verbale fencing, misure RPO/RTO reali.

**GO/NO-GO.** GO solo con due restore rehearsal positivi, owner dati firmatario, backup target verificato e finestra di downtime/fencing approvata. NO-GO per dump non consistente, restore fallito, writer non identificato, conflitto schema, disk latency fuori soglia o RPO/RTO non approvati.

**Rollback/abort.** Prima del fencing, scartare il target e mantenere AKS authoritative. Dopo il fencing ma prima di riaprire writer, ripristinare source secondo backup/checkpoint. Dopo nuove scritture target, fermare entrambe le scritture, preservare entrambi i dataset e aprire un incidente dati; non sovrascrivere il source automaticamente.

### Fase 7 — Networking e cutover Cloudflare

**Approvazione richiesta.** `CUTOVER` nominativo di `[APPROVER_CUTOVER]`, owner Cloudflare, owner applicativi e security.

**Prerequisiti e attività principali**

- target app/data healthy, canary 7 giorni e restore validato;
- export Cloudflare metadata-only completo e route/hostname approvati;
- configurare cloudflared target tramite Flux/ESO, almeno due repliche se il processo lo richiede, ricordando che sono sullo stesso nodo e non danno HA VM;
- verificare outbound TCP/UDP 7844 e percorso `Cloudflare Edge → cloudflared → Traefik ClusterIP → Service → Pod`;
- predisporre TTL, finestra, monitor esterno e route di ritorno al tunnel AKS;
- eliminare la pubblicazione diretta di 3306/5432 e non aprire HTTP/HTTPS nell’NSG target;
- verificare che bootstrap Terraform/Ansible/Flux non dipenda dal tunnel.

**Pre-check.** hostname/route/Access policy inventariati; TLS e auth testati; target e source distinguibili; DNS/Cloudflare rollback attuabile; writer fencing e change window coordinati.

**Segnali attesi.** tunnel target con connessioni stabili e log senza reconnect loop; tutti gli hostname rispondono al target canary; TLS/Access/redirect/cookie corretti; monitor esterno verde; nessuna porta app/DB pubblica.

**Evidenze.** export e diff route redatto, stato tunnel/repliche, test endpoint per hostname, probe esterno, NSG effective rules, timestamp DNS/route, owner sign-off.

**GO/NO-GO.** GO solo se tutti gli hostname sono verificati, il percorso di ritorno è provato e non ci sono dipendenze amministrative dal tunnel. NO-GO per route mancante/parziale, TLS/auth errati, tunnel instabile, monitor esterno rosso, exposure DB/app o export non ripristinabile.

**Rollback/abort.** Durante la finestra ripristinare le route al tunnel AKS senza modificare dati o avviare writer duplicati. Conservare log e orari. Se il target ha già ricevuto scritture, applicare la regola di fencing della Fase 6 prima di tornare al source.

### Fase 8 — Workload critici e cutover applicativo

**Approvazione richiesta.** `DEPLOY/CUTOVER` nominativo di owner applicativi, owner dati, platform e approvatore change.

**Sequenza.** Solo dopo Fasi 5–7: backend, bot, polinetcc e workload finali; i bot ARM64 precedentemente bloccati entrano solo con digest e test su ARM64. Migrare un gruppo per volta, mai riattivare namespace dormienti. Per bot/job/webhook, bloccare o drenare i consumer source per evitare doppia elaborazione.

**Pre-check.** DB e Secret ESO healthy, tunnel/route stabili, test funzionali owner, code/error baseline, rate limit e side effect esterni noti, backup immediato e rollback data plan firmato.

**Segnali attesi.** endpoint e flussi funzionali positivi; error rate e latenza entro baseline; nessun job/bot elabora due volte; un solo writer per servizio; Flux revision attesa; backup post-cutover completato; monitor esterno verde.

**Evidenze.** checklist funzionale firmata, metriche prima/dopo, log redatti, lista writer, revisioni GitOps, Secret/ESO metadata, backup checksum, timestamp cutover e decisioni.

**GO/NO-GO.** GO solo con owner applicativi e dati presenti, nessuna doppia ownership Argo/Flux, nessun writer doppio e rollback verificabile. NO-GO per side effect duplicati, error rate fuori baseline, secret/DB non pronti, image incompatibile o backup fallito.

**Rollback/abort.** Sospendere/portare a zero il workload target secondo piano approvato, impedire nuovi writer, ripristinare route e workload AKS, quindi verificare consistenza dati prima di riaprire source. Se ci sono state scritture target, applicare la procedura di riconciliazione dati; non riattivare AKS alla cieca.

### Fase 9 — Decommissioning AKS e residui

**Approvazione richiesta.** `DELETE` separato e nominativo di `[APPROVER_DECOMMISSION]`, owner risorsa, Security e owner dati. L’approvazione del cutover non autorizza alcun delete.

**Prerequisiti e attività principali**

- osservazione stabile per almeno 14 giorni;
- DR test completo su VM pulita, incluse applicazioni, database, tunnel canary, alert e nuovo backup;
- retention cutover e retention legale verificate; almeno due restore database positivi;
- final inventory di DNS, tunnel, identity, role assignment, disks, private endpoint, storage, NSG, client esterni e namespace;
- piano distruttivo separato con ordine, dipendenze, resource IDs, backup/checkpoint e criterio di stop;
- rimuovere prima gli oggetti AKS-specifici non necessari e solo poi AKS/LB/PIP/dischi/identity secondo il piano; non toccare B2C, Communication Services o risorse di ownership non confermata;
- aggiornare Terraform state e Snowflake Register; rivedere orphan SP, access policy e risorse legacy con ticket distinti.

**Pre-check.** nessun endpoint punta ad AKS, nessun client DB pubblico dipende dai vecchi LB, nessuna identity target usa AKS, backup off-host recuperabile, costi e state attesi, owner reperibili.

**Segnali attesi.** target e backup continuano a essere verdi; nessun alert di dipendenza; resource graph e state coincidono; costi AKS/LB scendono; inventory non contiene risorse non spiegate.

**Evidenze.** final inventory, piano distruttivo hashato, approvazioni `DELETE`, retention/restore evidence, query dependency, cost comparison, state post-change, Snowflake Register aggiornato e verbale.

**GO/NO-GO.** GO solo con DR clean-VM test superato, periodo di osservazione completato, rollback target non più necessario secondo owner, retention scaduta/approvata e ogni delete risolto. NO-GO per dipendenze sconosciute, restore non provato, route AKS, dati non archiviati o qualsiasi delete inatteso nel plan.

**Rollback/abort.** Prima del delete, annullare il piano e mantenere AKS. Durante una rimozione, fermarsi al primo errore o dipendenza; non eseguire comandi compensativi non approvati. Dopo la distruzione non esiste rollback immediato: il recovery è Terraform + Ansible + Flux + restore da backup, con RTO da misurare.

## 11. Disaster recovery su VM pulita

Il test DR è obbligatorio prima del decommissioning e deve essere eseguito in resource group isolato, senza copiare file dal nodo production.

1. Dichiarare finestra, owner e approvazione separata per creare e poi distruggere l’ambiente di test.
2. Verificare accesso a repository, state, Git bundle, registry, Key Vault e Blob ZRS con identità break-glass.
3. Creare una VM pulita con un piano Terraform approvato e non collegato alla produzione.
4. Eseguire Ansible da zero due volte; la seconda deve produrre zero change sostanziali.
5. Verificare mount, K3s, SQLite, secrets encryption e kubeconfig protetto.
6. Bootstrap Flux dal repository/commit previsto, senza file copiati dal nodo production.
7. Verificare ESO con Secret di test e metadata-only; non stampare valori.
8. Riconciliare platform e workload data vuoti.
9. Ripristinare PostgreSQL, MariaDB, InfluxDB e file/config dai backup selezionati.
10. Eseguire query di consistenza, smoke test, probe, alert, spazio e nuovo backup.
11. Avviare tunnel/hostname canary senza modificare production.
12. Misurare tempo reale, interventi manuali, RPO/RTO e failure incontrati.
13. Correggere la documentazione finché il percorso è ripetibile.
14. Distruggere il test solo con approvazione `DELETE` separata e conservare il verbale.

Il DR non è superato se richiede una password sul laptop di una persona, un file dal vecchio nodo, una modifica manuale non registrata o valori di Secret copiati a mano.

## 12. Incidenti ed escalation

### Contenimento iniziale

1. Fermare la fase e non fare delete, prune o rotazioni irreversibili.
2. Registrare orario UTC, change ID, comando/funzione in corso, executor e sintomi.
3. Preservare metriche, eventi, revisioni, plan, log redatti e stato writer.
4. Se pertinente, sospendere solo la Kustomization o il workload coinvolto; evitare shutdown globale non necessario.
5. Chiamare `[ON_CALL_PLATFORM]`; per dati chiamare anche `[ON_CALL_DATA]`, per security `[SECURITY_CONTACT]`, per Cloudflare `[OWNER_CLOUDFLARE]`.
6. Dichiarare GO/NO-GO e aggiornarlo nel ticket; non riaprire writer o route senza approvatore.

### Classificazione rapida

| Severità | Esempi | Prima azione | Escalation |
|---|---|---|---|
| P0 critica | perdita/corruzione dati, writer doppio, produzione irraggiungibile dopo cutover, credenziale esposta | fermare writer e change, preservare evidenze | approvatore cutover, owner dati, security, platform |
| P1 alta | ESO non Ready, tunnel instabile, OOM/eviction, Flux prune inatteso, restore fallito | sospendere componente e valutare rollback | platform + owner servizio + approvatore |
| P2 media | singola app degradata, reconcile ritardata, alert non critico | contenere per app e aprire fix | owner app/platform |
| P3 bassa | documentazione, drift non impattante, warning capacity | registrare e pianificare | owner della fase |

Se un valore sensibile è stato stampato o allegato, trattarlo come incidente: interrompere la distribuzione dell’evidenza, revocare/ruotare tramite procedura approvata, preservare audit e coinvolgere Security. Non inserire il valore nel ticket per “spiegare” l’incidente.

## 13. Evidence pack

Conservare un evidence pack per fase in area privata, con indice e checksum. Struttura suggerita:

```text
evidence/{{CHANGE_ID}}/
  00-index.yaml
  01-approvals/
  02-prechecks/
  03-plan-metadata-and-redacted-diffs/
  04-inventory-metadata/
  05-git-and-image-attestations/
  06-kubernetes-health/
  07-metrics-and-capacity/
  08-backup-restore/
  09-cloudflare-metadata/
  10-cutover-and-writer-fencing/
  11-rollback-or-abort/
  12-incident-and-escalation/
  13-signoff/
```

`00-index.yaml` deve indicare change ID, fase, commit, identità, timestamp UTC, strumenti/versioni, file inclusi, hash, redazioni, approvatori e decisione. Non archiviare kubeconfig, token, Secret manifest con `data`, URL firmati, chiavi, dump in chiaro, log contenenti credenziali **né file binari prodotti da `terraform plan -out`**. Per i plan conservare nell’evidence pack soltanto hash, contesto e sintesi redatta; il binario resta in storage privato cifrato a retention breve. I dump devono restare cifrati e con accesso limitato secondo policy dati.

Evidenze minime per fase:

- **Fase 0:** blocker register, state/plan, ARM64 manifest, restore rehearsal, Cloudflare export, baseline.
- **Fase 1:** plan Terraform, policy, resource graph, cost estimate e approvazione apply.
- **Fase 2:** Ansible check/idempotenza, mount, hardening, K3s health/reboot.
- **Fase 3:** Flux/ESO/CRD health, revisioni, dependency graph e assenza secret statici.
- **Fase 4:** mapping metadata-only, RBAC/IMDS proof, condizioni ESO e rollout canary.
- **Fase 5:** handoff per app, smoke, 7-day capacity, rollback test e segnali Argo/Flux.
- **Fase 6:** checksum/dump, restore, query consistenza, writer list/fencing, RPO/RTO.
- **Fase 7:** route/hostname export, tunnel, TLS/Access, probe esterno e NSG.
- **Fase 8:** functional acceptance, side-effect check, backup post-cutover e sign-off owner.
- **Fase 9:** DR clean-VM, final inventory, plan delete, retention e state/register post-change.

## 14. Handover checklist

Il passaggio all’esercizio ordinario è completo solo quando tutti gli elementi sono firmati:

- [ ] owner e sostituti per Platform, App, Dati, Security, Cloudflare, Backup e Change nominati;
- [ ] accessi tramite gruppi/PIM e break-glass testato, senza credenziali personali non documentate;
- [ ] repository Terraform/Ansible/GitOps, commit/pin e CI OIDC spiegati e recuperabili;
- [ ] confini Terraform/Ansible/Flux/ESO/CI documentati; nessuna doppia ownership residua;
- [ ] K3s, mount data disk, secrets encryption, API privata e processo di upgrade verificati;
- [ ] SecretStore namespaced, ExternalSecret, RBAC e rotazioni documentati senza valori;
- [ ] immagini tutte digest-pinned, ARM64 verificata, SBOM/scansioni e procedura PR digest disponibile;
- [ ] PostgreSQL/MariaDB/InfluxDB StatefulSet, backup, retention, restore e writer fencing documentati;
- [ ] RPO/RTO firmati dagli owner, oppure eccezioni registrate con data di revisione;
- [ ] Traefik/cloudflared, hostnames, route, TLS, Access e rollback Cloudflare ripristinabili;
- [ ] alert host/K3s/Flux/ESO/tunnel/Traefik/database/backup/certificati attivi e almeno un monitor esterno;
- [ ] canary 7 giorni e osservazione post-cutover di almeno 14 giorni archiviati;
- [ ] DR clean-VM superato, tempi reali e interventi manuali registrati;
- [ ] AKS e residui delete approvati separatamente, retention scaduta, state e Snowflake Register coerenti;
- [ ] final acceptance firmata da owner applicativi, owner dati, platform e change approver.

## 15. Accettazione finale

La migrazione è accettata solo quando una persona che non conosce la storia dell’ambiente può, usando esclusivamente repository, state, vault/backup autorizzati e questa guida:

1. ottenere accesso tramite gruppi documentati;
2. ricreare Azure da Terraform e l’host da Ansible;
3. bootstrap Flux senza secret personali o PAT write non necessari;
4. materializzare i Secret tramite Key Vault/ESO senza leggerne i valori;
5. ripristinare ogni dato critico da backup verificato;
6. ripubblicare gli endpoint Cloudflare;
7. dimostrare RPO/RTO, alert, backup e restore;
8. spiegare ogni eccezione residua nello Snowflake Register;
9. eseguire rollback/abort secondo i criteri della fase senza affidarsi a conoscenza orale.

Se un passaggio richiede un file dal vecchio nodo, una password sul laptop di una persona, un comando non versionato o una procedura orale, l’accettazione è **NO-GO**.

**Firme finali**

```text
OWNER_PLATFORM={{NOME / DATA / FIRMA}}
OWNER_APPLICAZIONI={{NOME / DATA / FIRMA}}
OWNER_DATI={{NOME / DATA / FIRMA}}
OWNER_SECURITY={{NOME / DATA / FIRMA}}
OWNER_CLOUDFLARE={{NOME / DATA / FIRMA}}
APPROVER_CHANGE={{NOME / DATA / FIRMA}}
APPROVER_DECOMMISSION={{NOME / DATA / FIRMA O N/A}}
```

## 16. Riferimenti

- `migration-assessment-report.md`, in particolare sezioni su blocker, target architecture, ownership, backup/DR, canary, Cloudflare e piano fasi 0–9.
- Debian 13: <https://www.debian.org/releases/trixie/>
- K3s requirements, datastore, backup/restore, packaged components e hardening: <https://docs.k3s.io/>
- Flux components e Kustomize controller: <https://fluxcd.io/flux/components/>
- External Secrets Operator Azure Key Vault: <https://external-secrets.io/main/provider/azure-key-vault/>
- Azure Key Vault RBAC e managed identity VM: <https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide> e <https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-managed-identities-work-vm>
- Cloudflare Tunnel availability e firewall: <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/> e <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/>
- GitHub Actions OIDC con Azure: <https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure>
