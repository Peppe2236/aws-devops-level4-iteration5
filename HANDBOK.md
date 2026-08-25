# Handbok – AWS DevOps Level 4 Iteration 5

## 1. Vad Iteration 5 går ut på

Iteration 5 är projektets kontrollerade avvecklingsfas. Syftet är att granska och därefter, endast efter uttryckligt beslut, ta bort de AWS-resurser som skapats under tidigare iterationer.

Det är inte ett vanligt deploymentscript. En felaktig körning kan förstöra EC2-instansers data, Terraform-state, versionshistorik i S3, IAM-konfiguration och CI/CD-resurser. Därför är scriptet byggt kring principen **granska först, verkställ separat**.

Arbetskedjan är:

1. verifiera katalog, Git-status, AWS-identitet, konto och region;
2. inventera Terraform-state och exakt angivna AWS-mål;
3. skapa en sparad Terraform destroy-plan;
4. granska planen manuellt;
5. verifiera planens SHA-256 och metadata;
6. kräva en exakt destruktiv bekräftelse;
7. applicera den granskade Terraform-planen;
8. verifiera att Terraform-resurserna är borta;
9. radera endast uttryckligen valda CLI-resurser;
10. ta Terraform-state-buckets sist.

## 2. Varför originalet inte fick köras

Originalfilen blandade kommandon, Terraform-utskrifter och JSON från tidigare körningar. Den hade dessutom ett syntaxfel och skulle ändå ha varit farlig efter en enkel syntaxreparation.

De viktigaste problemen var:

- `terraform plan -destroy` följdes direkt av `terraform apply`;
- resurser från en annan användare och ett annat konto var hårdkodade;
- specifika S3-buckets tömdes utan ägarskapskontroll;
- en EC2-instans söktes med ett brett taggnamn och terminerades;
- state-buckets kunde tas bort innan en fullständig slutkontroll;
- fel från IAM-kommandon gömdes med `2>/dev/null`;
- exakta konto-, region- och planintegritetskontroller saknades.

Den reparerade versionen bevarar uppgiftens teardown-mål men tar bort dessa risker.

## 3. Scriptets tre lägen

### `--check-only`

Detta är standardläget. Det:

- läser AWS-identiteten;
- kontrollerar konto och region när förväntade värden anges;
- kontrollerar Terraformkatalogen;
- visar Git-status;
- listar Terraform-state;
- inventerar angivna CLI-mål.

Det skapar ingen plan och raderar ingenting.

### `--plan`

Planläget:

- kräver explicit owner, förväntat konto och förväntad region;
- kör `terraform init` och `terraform validate`;
- skapar en sparad `terraform plan -destroy`;
- stoppar oväntade icke-destroy-åtgärder;
- beräknar planens SHA-256;
- sparar konto, region, owner, projektkatalog, planfil och delete-antal i separat metadata;
- skriver ut adresserna som Terraform planerar att ta bort.

Planläget kör aldrig `terraform apply` och raderar inga CLI-resurser.

### `--execute`

Execute-läget skapar aldrig en ny plan. Det kräver att den tidigare sparade planen och dess metadata finns kvar och fortfarande matchar.

Före apply verifieras:

- aktivt AWS-konto;
- aktiv AWS-region;
- owner;
- absolut projektkatalog;
- absolut planfil;
- SHA-256;
- antal delete-åtgärder;
- SHA-256-fingeravtrycket för alla CLI-targets;
- att planen inte innehåller oväntade åtgärder.

Därefter måste operatören skriva exakt:

```text
DESTROY ACCOUNT REGION OWNER
```

## 4. Förberedelser

Kontrollera först verktygen och AWS-sessionen:

```bash
aws --version
terraform version
jq --version
python3 --version
git --version
aws sts get-caller-identity
aws configure get region
```

Verifiera även rätt projektkatalog:

```bash
cd "/absolute/path/to/terraform/root"
pwd
git --no-pager status --short --branch
terraform state list
```

Stoppa om konto, region, katalog eller resurser inte är exakt de avsedda.

## 5. Read-only preflight

```bash
bash "/path/to/Level4 Iteration5.sh" \
  --check-only \
  --project-dir "/absolute/path/to/terraform/root" \
  --region "eu-north-1"
```

Du kan även lägga till exakta mål för read-only inventering. Scriptet kan härleda tre projektspecifika mål när `--include-derived-project-targets` anges:

- CodePipeline `ContinuousDelivery-OWNER-SLUG`;
- CodeBuild `verify-OWNER-SLUG`;
- source-bucket `OWNER-SLUG-src`.

Inga state-buckets, IAM-resurser, security groups eller EC2-instanser härleds automatiskt.

## 6. Skapa och granska destroy-planen

```bash
bash "/path/to/Level4 Iteration5.sh" \
  --plan \
  --project-dir "/absolute/path/to/terraform/root" \
  --region "eu-north-1" \
  --owner "YOUR_OWNER" \
  --expected-account "123456789012" \
  --expected-region "eu-north-1" \
  --include-derived-project-targets
```

Granska sedan planen separat:

```bash
terraform \
  -chdir="/absolute/path/to/terraform/root" \
  show \
  "/absolute/path/to/terraform/root/tfdestroyplan"
```

Kontrollera varje resursadress. Kör inte vidare om planen innehåller något som ska bevaras.

## 7. Exakta CLI-mål

Följande flaggor är repeatable och lägger endast till det exakta angivna målet:

| Flagga | Mål |
| --- | --- |
| `--pipeline-name` | CodePipeline |
| `--codebuild-project` | CodeBuild-projekt |
| `--bucket` | vanlig source/artifact-bucket |
| `--state-bucket` | Terraform-state-bucket, alltid sist |
| `--iam-role` | IAM-roll |
| `--instance-profile` | instansprofil |
| `--security-group-id` | security group för regelstädning |
| `--revoke-cidr` | IPv4-CIDR som ska tas bort |
| `--orphan-instance-id` | exakt EC2-instans-ID |

`--orphan-instance-id` accepterar inte taggnamn eller sökmönster. Det minskar risken att fel instans termineras.

## 8. Execute

Använd samma identitets- och målflaggor som vid planeringen, men byt `--plan` mot `--execute`.

Scriptet visar den exakta bekräftelsefrasen. Läs målöversikten igen innan du skriver den.

För automatiserad körning krävs både `--yes` och `--confirmation`. Detta bör endast användas i en separat godkänd pipeline där planen redan har granskats.

## 9. Raderingsordning

Efter en lyckad Terraform-apply används följande ordning:

1. CodePipeline;
2. CodeBuild;
3. vanliga source/artifact-buckets;
4. uttryckliga security-group-regler;
5. uttryckliga orphan-EC2-instanser;
6. instansprofiler;
7. IAM-roller;
8. uttryckliga Terraform-state-buckets sist.

S3-rutinen avbryter multipart uploads och tar bort både objektversioner och delete markers i batcher innan bucket-raderingen.

## 10. Återställning och incidenthantering

Det finns ingen generell undo för en lyckad teardown.

- En borttagen EC2-rootvolym kan vara permanent förlorad.
- En tömd versionerad S3-bucket har inte kvar versionshistoriken.
- En borttagen state-bucket tar bort Terraformhistoriken.
- IAM-roller och policies måste återskapas från kod eller dokumentation.

Innan execute bör du därför säkerställa att nödvändiga data, state och konfigurationer finns i en separat godkänd backup. Planfil och metadata är lokala kontrollartefakter, inte en återställningsbackup.

## 11. Test och release

```bash
bash -n "Level4 Iteration5.sh"
bash "tests/test-iteration5.sh"
git --no-pager diff --check
git --no-pager status --short
```

De automatiska testerna använder fake AWS och fake Terraform. De bevisar kontrollflödet men ersätter inte en live preflight eller manuell granskning av en riktig destroy-plan.
Testsuiten använder vanlig `grep`; `ripgrep` (`rg`) behöver inte vara installerat.
