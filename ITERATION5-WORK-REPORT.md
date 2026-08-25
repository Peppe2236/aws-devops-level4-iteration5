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

## Kvarstående livearbete

Det verkliga Iteration 5-resultatet kan inte markeras som fullständigt förrän följande har utförts av operatören:

- säkerhetskopiera state utanför den aktiva backend-bucketen;
- migrera state till en separat skyddad backend eller kontrollerad lokal teardown-kopia;
- köra live `--check-only` igen och verifiera att blockeraren är borta;
- manuell granskning av en riktig destroy-plan;
- uttryckligt beslut om execute;
- efterkontroll av Terraform-state och valda AWS-resurser.

Detta är avsiktligt. Dokumentation eller automatiska tester får aldrig betraktas som tillstånd att radera en riktig AWS-miljö.
