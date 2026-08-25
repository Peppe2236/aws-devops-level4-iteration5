# AWS DevOps Level 4 – Iteration 5

Iteration 5 is a review-first teardown workflow for Terraform-managed infrastructure and a narrowly selected set of AWS resources.

This repository replaces an unsafe terminal transcript with a tested Bash program. The default mode is read-only, Terraform planning is separated from execution, and every destructive run is bound to an exact AWS account, region, owner, project directory, saved-plan hash, and typed confirmation phrase.

## Current status

| Area | Status |
| --- | --- |
| Original script audit | Completed |
| Bash repair and safety redesign | Completed |
| Isolated simulation tests | Passed |
| Live AWS preflight | Passed; self-managed backend blocker worked |
| State backup and controlled migration | Completed and verified |
| Live destroy-plan review | Passed; exactly three delete actions |
| Controlled execution | Completed with exact confirmation |
| Final absence verification | Passed |

No AWS resources were deleted during repair or isolated testing. A later,
explicitly approved live run removed exactly the three reviewed
Terraform-managed resources after state backup, backend isolation and saved-plan
verification. No CLI targets were selected.

## Repository contents

| Path | Purpose |
| --- | --- |
| `Level4 Iteration5.sh` | Repaired teardown program |
| `HANDBOK.md` | Complete Swedish operating handbook |
| `ROADMAP.md` | Completed Iteration 5 phases |
| `ITERATION5-WORK-REPORT.md` | Audit, repair, and verification report |
| `DMC/03-evidence/` | Defect-management evidence |
| `tests/test-iteration5.sh` | Fake AWS/Terraform safety test suite |

## Key safeguards

- `--check-only` is the default and never creates a plan or changes AWS.
- `--plan` creates a saved destroy plan but never applies it.
- `--execute` applies only an existing reviewed plan.
- The plan is protected by SHA-256 metadata.
- Account, region, owner, project path, plan path, and delete count must match.
- CLI targets are fingerprinted and must match the reviewed plan phase.
- Interactive execution requires typing `DESTROY ACCOUNT REGION OWNER` exactly.
- Non-interactive execution requires both `--yes` and the exact confirmation phrase.
- State buckets, IAM roles, security groups, CIDRs, and orphan EC2 instances are never derived automatically.
- Orphan EC2 termination accepts only explicit instance IDs; broad tag/name searches are forbidden.
- Planning and execution stop when an active S3 backend bucket is managed by the Terraform state stored inside that same bucket.
- Terraform-state buckets are explicit and always deleted last.
- The script never commits, pushes, rewrites Terraform files, or runs `terraform destroy` automatically.

## Safe workflow

Read the full [HANDBOK.md](HANDBOK.md) before using the script.

### 1. Read-only preflight

```bash
bash "Level4 Iteration5.sh" \
  --check-only \
  --project-dir "/absolute/path/to/terraform/root" \
  --region "eu-north-1"
```

### 2. Create a destroy plan

```bash
bash "Level4 Iteration5.sh" \
  --plan \
  --project-dir "/absolute/path/to/terraform/root" \
  --region "eu-north-1" \
  --owner "YOUR_OWNER" \
  --expected-account "123456789012" \
  --expected-region "eu-north-1" \
  --include-derived-project-targets
```

This does not apply or delete anything.

Planning is blocked when the active S3 backend bucket is also a Terraform destroy target. Back up the state and migrate it to a different protected backend before continuing. Never use `--state-bucket` to bypass this guard.

### 3. Review the exact saved plan

```bash
terraform \
  -chdir="/absolute/path/to/terraform/root" \
  show \
  "/absolute/path/to/terraform/root/tfdestroyplan"
```

### 4. Execute only after review

Re-run the script with `--execute` and the same identity and target options. The script verifies the saved plan and displays the exact confirmation phrase. Do not execute when any resource is unexpected.

## Sanitized live result

The completed reference run followed the documented stop-and-migrate path:

- preflight detected and blocked a self-managed active S3 backend;
- remote state and its complete version history were backed up externally;
- state was copied to a controlled local backend without changing lineage;
- the saved plan contained exactly three reviewed Terraform deletions;
- the CLI target list was empty;
- execution required the exact interactive confirmation phrase;
- Terraform reported `0 added, 0 changed, 3 destroyed`;
- final state contained zero managed resources;
- the approved bucket was absent from the AWS account;
- both external state backups passed SHA-256 verification.

Account IDs, resource names, state lineage and local paths are intentionally
excluded from this public repository.

## Tests

```bash
bash -n "Level4 Iteration5.sh"
bash "tests/test-iteration5.sh"
```

The test suite replaces AWS, Terraform, and Git with local fakes. It never contacts AWS and proves that the destructive commands remain behind the required safeguards.
It uses standard `grep`; `ripgrep` (`rg`) is not required.

## Original defects removed

- invalid Bash caused by pasted JSON output;
- automatic `terraform apply` immediately after planning;
- hard-coded account IDs, user names, instance IDs, bucket names, VPC/subnet/security-group IDs, addresses, and CIDRs;
- deletion of shared or unrelated buckets;
- broad EC2 name-based termination;
- unquoted variables and unsafe temporary files;
- ignored AWS errors and missing post-delete verification;
- no account, region, plan-integrity, or confirmation controls;
- no protection against Terraform destroying the S3 bucket containing its own active state.

See [DMC/03-evidence/DMC-I5-001-005-summary.txt](DMC/03-evidence/DMC-I5-001-005-summary.txt) for the recorded verification result.
