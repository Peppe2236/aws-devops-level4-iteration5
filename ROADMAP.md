# AWS DevOps Level 4 – Iteration 5 Roadmap

## Status legend

- ✅ Completed
- 🔄 In progress
- ⏳ Pending explicit authorization

## Phase 1 – Original-script audit ✅

- [x] preserve the uploaded original
- [x] identify the Bash syntax failure
- [x] separate terminal output from executable intent
- [x] identify automatic Terraform apply behavior
- [x] identify stale identities, IDs, buckets, addresses, and CIDRs
- [x] identify unsafe broad EC2 termination
- [x] identify unsafe state-bucket deletion order

## Phase 2 – Safety redesign ✅

- [x] enable strict Bash execution
- [x] make read-only preflight the default
- [x] separate check, plan, and execute modes
- [x] require exact AWS account, region, and owner for plan/execute
- [x] bind the reviewed plan to SHA-256 metadata
- [x] require exact interactive or non-interactive confirmation
- [x] remove all user-specific hard-coded resources
- [x] require exact orphan EC2 instance IDs
- [x] require explicit state-bucket selection
- [x] delete state buckets last
- [x] block a Terraform-managed active S3 backend before plan or execute
- [x] add post-operation verification

## Phase 3 – Isolated verification ✅

- [x] pass `bash -n`
- [x] prove check-only invokes no planning or destructive commands
- [x] prove plan mode never applies or deletes
- [x] prove an incorrect confirmation blocks execution
- [x] prove a modified plan fails SHA-256 validation
- [x] prove changed CLI targets fail reviewed-target validation
- [x] prove an account mismatch blocks before Terraform planning
- [x] prove a self-managed active S3 backend blocks before destroy planning
- [x] simulate the reviewed Terraform and exact-target teardown sequence
- [x] verify stale identities and addresses are absent

## Phase 4 – Documentation and DMC ✅

- [x] create the GitHub README
- [x] create the Swedish operating handbook
- [x] create the Iteration 5 roadmap
- [x] create the work report
- [x] record DMC-I5-001 through DMC-I5-005

## Phase 5 – Live preflight ✅

- [x] prepare the standalone Iteration 5 workspace
- [x] verify `pwd` and Git status
- [x] verify the intended AWS identity, account, and region
- [x] run `--check-only` against the real Terraform root
- [x] review every discovered Terraform and CLI target
- [x] identify that the active S3 backend is managed by its own state
- [x] add and simulate the automatic backend blocker
- [x] back up state outside the active backend bucket
- [x] preserve every state-object version and delete marker
- [x] verify the external backup with SHA-256
- [x] copy state to a controlled local teardown backend
- [x] rerun live `--check-only` and confirm the blocker is cleared

## Phase 6 – Live destroy-plan review ✅

- [x] prepare `force_destroy` through a reviewed non-delete update
- [x] create a real saved destroy plan
- [x] review every Terraform delete address
- [x] confirm exactly three delete actions and no unexpected action
- [x] bind the saved plan and empty CLI target list to SHA-256 metadata
- [x] preserve required backup/state evidence
- [x] record explicit approval before applying

## Phase 7 – Controlled teardown ✅

- [x] verify the saved plan and metadata immediately before execute
- [x] enter the exact destructive confirmation phrase
- [x] apply only the reviewed Terraform plan
- [x] destroy exactly three approved Terraform resources
- [x] verify Terraform-managed resources are absent from local state
- [x] confirm that no CLI targets were selected
- [x] verify the approved state bucket is absent from the AWS account
- [x] reverify both external state backups after teardown
- [x] record final read-only AWS absence checks

## Phase 8 – Standalone GitHub release ✅

- [x] prepare a standalone repository structure
- [x] exclude original transcripts, state, plans, credentials, and local values
- [x] create `Peppe2236/aws-devops-level4-iteration5`
- [x] commit the repaired script, tests, documentation, and DMC evidence
- [x] push and verify the public repository
