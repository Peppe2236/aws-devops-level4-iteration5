# Arbetsrapport – Level 4 Iteration 5

## Uppdrag

Den bifogade filen `Level4 iteration5.sh` skulle granskas, korrigeras och paketeras på samma professionella sätt som Level 4 Iteration 4.

Iteration 5 skiljer sig från tidigare iterationer genom att dess mål är destruktivt: Terraform-resurser och kompletterande AWS-resurser ska kunna avvecklas. Reparationsarbetet har därför prioriterat skydd mot fel konto, fel region, fel plan och fel resursmål.

## Ursprungligt skick

Originalet var 602 rader och 27 251 byte. SHA-256 för originalfilen var:

```text
fd5883c2ab2712ca2f1e025c77fc6ab4983c2369cbdf90ab75b3a212baaf1d2f
```

`bash -n` stoppade vid rad 591 eftersom ett inklistrat JSON-objekt låg aktivt i Bashfilen.

Enbart syntaxreparation hade inte varit tillräcklig. Scriptet innehöll även automatisk Terraform-apply, hårdkodade resurser från en annan miljö, versions- och state-bucket-radering, dolda IAM-fel och bred EC2-terminering.

## Genomförd reparation

Scriptet byggdes om till tre separata lägen:

- read-only `--check-only`;
- icke-applicerande `--plan`;
- explicit `--execute` av en redan sparad och granskad plan.

Följande säkerhetsfunktioner infördes:

- strikt Bashläge och central felhantering;
- portabel Terraformkatalog via `--project-dir`;
- AWS-profil och region som explicita inputs;
- obligatoriskt förväntat konto, region och owner för plan/execute;
- SHA-256 och metadata för sparad plan;
- SHA-256-bindning av den granskade CLI-targetlistan;
- kontroll av planens action-typer och delete-antal;
- exakt destruktiv bekräftelse;
- explicit targetmodell för IAM, S3, security groups och orphan EC2;
- inga hårdkodade användarnamn, konton, buckets, IDs, adresser eller CIDR;
- versionerad S3-städning i batcher;
- state-buckets alltid sist;
- automatisk blockerare när aktiv S3-backend hanteras av det state som ligger i bucketen;
- verifiering efter Terraform apply och efter CLI-radering.

## Testning

Inga verkliga AWS-, Terraform apply- eller delete-kommandon kördes under reparationen.

Testsviten ersatte `aws`, `terraform` och `git` med lokala fake-kommandon och verifierade:

1. check-only är read-only;
2. planläget sparar planen utan apply;
3. fel bekräftelse blockerar execution;
4. manipulerad plan stoppas av SHA-256;
5. ändrade CLI-targets stoppas efter planfasen;
6. fel AWS-konto stoppas före planering;
7. granskad plan och exakta projekttargets körs i avsedd ordning;
8. aktiv Terraform-hanterad S3-backend blockerar före destroy-planering;
9. gamla identiteter, IDs och CIDR är borttagna;
10. Bash-syntaxen är giltig.

Samtliga simulerade tester passerade.

## Resultat från live preflight

Den första riktiga `--check-only`-körningen verifierade rätt AWS-identitet, konto, region, Git-status och Terraform-root. De härledda CodePipeline-, CodeBuild- och source-bucket-målen saknades. Terraform-state innehöll endast en versionerad och krypterad S3-bucket för remote state samt dess versionerings- och krypteringsresurser.

Preflighten visade att samma S3-bucket både var aktiv backend och Terraform-hanterad resurs. Ingen destroy-plan skapades. Detta registrerades som DMC-I5-005 och ledde till den automatiska backend-blockeraren ovan.

## Genomförd live teardown

Efter den blockerade preflighten genomfördes följande kontrollerade arbetskedja:

1. aktuell remote state hämtades till en skyddad katalog utanför projektet;
2. samtliga fem S3-objektversioner och fyra delete markers inventerades;
3. fem separata versionskopior laddades ned och verifierades med SHA-256;
4. backendkonfigurationen kopierades till en isolerad teardown-katalog;
5. state flyttades till en kontrollerad lokal backend med bevarad lineage;
6. originalets remote state verifierades oförändrad före planering;
7. `force_destroy` ändrades till `true` genom en separat plan med en update,
   noll create och noll delete;
8. en sparad destroy-plan skapades med exakt tre delete-åtgärder;
9. varje delete-adress, planens SHA-256 och den tomma CLI-targetlistan granskades;
10. execute verifierade samma plan och krävde den exakta destruktiva frasen;
11. Terraform rapporterade `0 added, 0 changed, 3 destroyed`;
12. read-only slutkontroll verifierade serial 7, noll managed resources,
    borttagen bucket och båda externa statebackuperna.

Den granskade destroy-planens SHA-256 var:

```text
61ef3d1ecfc4c2b444dec1f08a671db07690b7ddf5fdb540d9478a78d8663048
```

Inga explicita CLI-targets valdes eller raderades. Kontonummer, bucketnamn,
lokala sökvägar och state-lineage har avsiktligt utelämnats ur den publika
rapporten. De privata backupfilerna ligger utanför Git-repositoryt.

## Slutresultat

Iteration 5 är fullständigt genomförd. Säkerhetsblockeraren fungerade, state
säkerhetskopierades och isolerades före planering, endast den granskade planen
applicerades och den efterföljande verifieringen visade att de tre godkända
Terraform-resurserna och state-bucketen var borta. Återställningsunderlaget
verifierades både före och efter teardown.

Dokumentation och tester utgör fortfarande aldrig ett generellt tillstånd att
radera en annan AWS-miljö. Varje framtida körning kräver ny preflight, ny plan,
ny granskning och ny explicit bekräftelse.
