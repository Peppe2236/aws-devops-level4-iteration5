# Security Policy

## Destructive-operation policy

`Level4 Iteration5.sh` is intentionally capable of deleting infrastructure. A destructive run must always be based on a separately reviewed saved Terraform plan and exact AWS targets.

Never publish or commit:

- AWS credentials or session tokens;
- Terraform state or saved plans;
- `terraform.tfvars` or generated backend configuration;
- private keys;
- plan metadata containing local absolute paths;
- the uploaded original transcript with historical third-party identifiers.

## Required review

Before `--execute`:

1. verify the active AWS account and region;
2. verify the Terraform project directory;
3. review every delete address in `terraform show`;
4. verify every explicit CLI target;
5. confirm required backup and retention decisions;
6. enter the exact confirmation phrase only when the teardown is intended.

## Reporting

Do not include credentials, state content, private IP details, or secret values in a public issue. Revoke exposed credentials immediately through the relevant AWS identity process.
