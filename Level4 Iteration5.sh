#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# AWS DevOps Level 4 – Iteration 5
# Review-first teardown of Terraform and explicitly selected AWS resources.
###############################################################################

SCRIPT_NAME=$(basename -- "${BASH_SOURCE[0]}")
MODE='check'
PROJECT_DIR=$PWD
PROFILE=''
REGION_OVERRIDE=''
EXPECTED_ACCOUNT=''
EXPECTED_REGION=''
OWNER_OVERRIDE=''
OWNER_WAS_EXPLICIT=0
PLAN_FILE=''
REPLACE_PLAN=0
SKIP_TERRAFORM=0
USE_DERIVED_TARGETS=0
ASSUME_YES=0
CONFIRMATION=''
REVOKE_PORT=80

AWS_ARN=''
AWS_ACCOUNT_ID=''
AWS_REGION_RESOLVED=''
OWNER=''
OWNER_LOWER=''
ENVIRONMENT_NAME=''
PLAN_METADATA=''
TEMP_DIR=''
ACTIVE_S3_BACKEND_BUCKET=''
SELF_MANAGED_BACKEND_BUCKET=''

declare -a PIPELINES=()
declare -a CODEBUILD_PROJECTS=()
declare -a BUCKETS=()
declare -a STATE_BUCKETS=()
declare -a IAM_ROLES=()
declare -a INSTANCE_PROFILES=()
declare -a SECURITY_GROUP_IDS=()
declare -a REVOKE_CIDRS=()
declare -a ORPHAN_INSTANCE_IDS=()

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [mode] [options]

Modes (choose exactly one):
  --check-only              Validate identity, project, and targets. Default.
                            Never creates a plan or changes AWS.
  --plan                    Create a saved Terraform destroy plan for review.
                            Never applies the plan or deletes CLI targets.
  --execute                 Apply an already reviewed saved plan and then
                            delete only explicitly selected CLI targets.

Identity and project:
  --project-dir PATH        Terraform root module to tear down.
                            Default: current directory.
  --profile PROFILE         AWS CLI profile. Default: inherited configuration.
  --region REGION           AWS region used for all regional operations.
  --expected-account ID     Required for --plan and --execute.
  --expected-region REGION  Required for --plan and --execute.
  --owner NAME              Required for --plan and --execute. Used only for
                            exact project-name derivation and confirmation.

Terraform plan:
  --plan-file PATH          Saved destroy plan. Default: PROJECT/tfdestroyplan.
  --replace-plan            Permit --plan to replace that exact existing plan.
  --skip-terraform          Do not plan/apply Terraform. Useful only for a
                            separately reviewed CLI-only cleanup.

Explicit AWS CLI targets (repeat options where noted):
  --include-derived-project-targets
                            Add only these owner-derived project targets:
                              ContinuousDelivery-OWNER-SLUG pipeline
                              verify-OWNER-SLUG CodeBuild project
                              OWNER-SLUG-src source bucket
                            State, IAM, security groups, and EC2 are never
                            derived automatically.
  --pipeline-name NAME      Exact CodePipeline name. Repeatable.
  --codebuild-project NAME  Exact CodeBuild project name. Repeatable.
  --bucket NAME             Exact non-state S3 bucket. Repeatable.
  --state-bucket NAME       Exact Terraform-state S3 bucket. Repeatable and
                            always deleted last.
  --iam-role NAME           Exact IAM role to remove. Repeatable.
  --instance-profile NAME   Exact instance profile to remove. Repeatable.
  --security-group-id ID    Exact security group for rule cleanup. Repeatable.
  --revoke-cidr CIDR        Explicit IPv4 CIDR to revoke on TCP port 80.
                            Repeatable; requires --security-group-id.
  --revoke-port PORT        TCP port for --revoke-cidr. Default: 80.
  --orphan-instance-id ID   Exact non-Terraform EC2 instance to terminate.
                            Repeatable. Broad name/tag termination is forbidden.

Execution confirmation:
  Interactive --execute requires typing:
    DESTROY ACCOUNT REGION OWNER

  --yes                    Non-interactive execution. Requires --confirmation.
  --confirmation TEXT      Must exactly match the phrase above.

Other:
  -h, --help               Show this help.

Safe sequence:
  1. ${SCRIPT_NAME} --check-only --project-dir PATH
  2. ${SCRIPT_NAME} --plan --project-dir PATH --owner NAME \
       --expected-account ID --expected-region REGION
  3. Review: terraform show PROJECT/tfdestroyplan
  4. Re-run with --execute and the same identity/target options.

Safety guarantees:
  * Default mode is read-only.
  * --plan never applies or deletes anything.
  * --execute never creates a new plan; it applies the reviewed saved plan.
  * Plan SHA-256, account, region, owner, and project path are verified.
  * No account IDs, user names, buckets, security groups, CIDRs, or EC2 IDs
    are hard-coded.
  * An active S3 backend bucket cannot be destroyed by the Terraform state
    stored inside that same bucket. State must be migrated first.
  * Terraform-state buckets are explicit and deleted last.
  * The script never runs git commit/push and never rewrites Terraform files.
USAGE
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/level4-iteration5.* ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  local command=${BASH_COMMAND:-unknown}
  command=${command%%$'\n'*}
  command=${command:0:180}
  printf '[ERROR] Command failed on line %s (exit %s): %s\n' \
    "$line" "$rc" "$command" >&2
  exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

add_unique() {
  local array_name=$1
  local value=$2
  local existing
  local -n target_array=$array_name

  for existing in "${target_array[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  target_array+=("$value")
}

validate_owner() {
  [[ "$1" =~ ^[A-Za-z0-9._+=,@-]{1,64}$ ]] \
    || die "Invalid owner. Use 1-64 IAM-safe characters."
}

validate_account_id() {
  [[ "$1" =~ ^[0-9]{12}$ ]] || die "Invalid AWS account ID: $1"
}

validate_region() {
  [[ "$1" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] \
    || die "Invalid AWS region: $1"
}

validate_pipeline_name() {
  [[ "$1" =~ ^[A-Za-z0-9.@_-]{1,100}$ ]] \
    || die "Invalid CodePipeline name: $1"
}

validate_codebuild_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,149}$ ]] \
    || die "Invalid CodeBuild project name: $1"
}

validate_bucket_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
    || die "Invalid S3 bucket name: $1"
  [[ "$1" != *'..'* ]] || die "Invalid S3 bucket name: $1"
}

validate_iam_name() {
  [[ "$1" =~ ^[A-Za-z0-9+=,.@_-]{1,128}$ ]] \
    || die "Invalid IAM name: $1"
}

validate_security_group_id() {
  [[ "$1" =~ ^sg-[0-9a-fA-F]{8,32}$ ]] \
    || die "Invalid security group ID: $1"
}

validate_instance_id() {
  [[ "$1" =~ ^i-[0-9a-fA-F]{8,32}$ ]] \
    || die "Invalid EC2 instance ID: $1"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "Invalid TCP port: $1"
  (( 10#$1 >= 1 && 10#$1 <= 65535 )) || die "TCP port must be 1-65535."
}

validate_ipv4_cidr() {
  python3 - "$1" <<'PYTHON' || die "Invalid IPv4 CIDR: $1"
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if network.version == 4 else 1)
PYTHON
}

set_mode() {
  local requested=$1
  if [[ "$MODE" != 'check' && "$MODE" != "$requested" ]]; then
    die "Choose exactly one of --check-only, --plan, or --execute."
  fi
  MODE=$requested
}

while (($# > 0)); do
  case "$1" in
    --check-only)
      set_mode 'check'
      shift
      ;;
    --plan)
      set_mode 'plan'
      shift
      ;;
    --execute)
      set_mode 'execute'
      shift
      ;;
    --project-dir)
      (($# >= 2)) || die "--project-dir requires a path."
      PROJECT_DIR=$2
      shift 2
      ;;
    --profile)
      (($# >= 2)) || die "--profile requires a value."
      PROFILE=$2
      shift 2
      ;;
    --region)
      (($# >= 2)) || die "--region requires a value."
      REGION_OVERRIDE=$2
      shift 2
      ;;
    --expected-account)
      (($# >= 2)) || die "--expected-account requires a value."
      EXPECTED_ACCOUNT=$2
      shift 2
      ;;
    --expected-region)
      (($# >= 2)) || die "--expected-region requires a value."
      EXPECTED_REGION=$2
      shift 2
      ;;
    --owner)
      (($# >= 2)) || die "--owner requires a value."
      OWNER_OVERRIDE=$2
      OWNER_WAS_EXPLICIT=1
      shift 2
      ;;
    --plan-file)
      (($# >= 2)) || die "--plan-file requires a path."
      PLAN_FILE=$2
      shift 2
      ;;
    --replace-plan)
      REPLACE_PLAN=1
      shift
      ;;
    --skip-terraform)
      SKIP_TERRAFORM=1
      shift
      ;;
    --include-derived-project-targets)
      USE_DERIVED_TARGETS=1
      shift
      ;;
    --pipeline-name)
      (($# >= 2)) || die "--pipeline-name requires a value."
      validate_pipeline_name "$2"
      add_unique PIPELINES "$2"
      shift 2
      ;;
    --codebuild-project)
      (($# >= 2)) || die "--codebuild-project requires a value."
      validate_codebuild_name "$2"
      add_unique CODEBUILD_PROJECTS "$2"
      shift 2
      ;;
    --bucket)
      (($# >= 2)) || die "--bucket requires a value."
      validate_bucket_name "$2"
      add_unique BUCKETS "$2"
      shift 2
      ;;
    --state-bucket)
      (($# >= 2)) || die "--state-bucket requires a value."
      validate_bucket_name "$2"
      add_unique STATE_BUCKETS "$2"
      shift 2
      ;;
    --iam-role)
      (($# >= 2)) || die "--iam-role requires a value."
      validate_iam_name "$2"
      add_unique IAM_ROLES "$2"
      shift 2
      ;;
    --instance-profile)
      (($# >= 2)) || die "--instance-profile requires a value."
      validate_iam_name "$2"
      add_unique INSTANCE_PROFILES "$2"
      shift 2
      ;;
    --security-group-id)
      (($# >= 2)) || die "--security-group-id requires a value."
      validate_security_group_id "$2"
      add_unique SECURITY_GROUP_IDS "$2"
      shift 2
      ;;
    --revoke-cidr)
      (($# >= 2)) || die "--revoke-cidr requires a value."
      validate_ipv4_cidr "$2"
      add_unique REVOKE_CIDRS "$2"
      shift 2
      ;;
    --revoke-port)
      (($# >= 2)) || die "--revoke-port requires a value."
      validate_port "$2"
      REVOKE_PORT=$2
      shift 2
      ;;
    --orphan-instance-id)
      (($# >= 2)) || die "--orphan-instance-id requires a value."
      validate_instance_id "$2"
      add_unique ORPHAN_INSTANCE_IDS "$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --confirmation)
      (($# >= 2)) || die "--confirmation requires a value."
      CONFIRMATION=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1. Use --help for usage."
      ;;
  esac
done

require_command aws
require_command git
require_command jq
require_command python3
require_command sha256sum
require_command terraform

[[ -d "$PROJECT_DIR" ]] || die "Terraform project directory does not exist: $PROJECT_DIR"
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd -P)

mapfile -t TF_FILES < <(find "$PROJECT_DIR" -maxdepth 1 -type f -name '*.tf' -print)
((${#TF_FILES[@]} > 0)) || die "No Terraform .tf files found in $PROJECT_DIR"

if [[ -n "$PROFILE" ]]; then
  export AWS_PROFILE=$PROFILE
fi

if [[ -n "$REGION_OVERRIDE" ]]; then
  validate_region "$REGION_OVERRIDE"
  export AWS_REGION=$REGION_OVERRIDE
  export AWS_DEFAULT_REGION=$REGION_OVERRIDE
fi

AWS_ARN=$(aws sts get-caller-identity --query Arn --output text) \
  || die "AWS authentication failed. Reauthenticate the intended profile."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
  || die "Could not resolve the AWS account ID."
validate_account_id "$AWS_ACCOUNT_ID"

AWS_REGION_RESOLVED=${REGION_OVERRIDE:-${AWS_REGION:-}}
if [[ -z "$AWS_REGION_RESOLVED" ]]; then
  AWS_REGION_RESOLVED=$(aws configure get region 2>/dev/null || true)
fi
[[ -n "$AWS_REGION_RESOLVED" ]] || die "No AWS region is configured. Use --region."
validate_region "$AWS_REGION_RESOLVED"
export AWS_REGION=$AWS_REGION_RESOLVED
export AWS_DEFAULT_REGION=$AWS_REGION_RESOLVED

if [[ -n "$OWNER_OVERRIDE" ]]; then
  OWNER=$OWNER_OVERRIDE
else
  OWNER=${AWS_ARN##*/}
fi
validate_owner "$OWNER"

OWNER_LOWER=$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')
ENVIRONMENT_NAME=$(printf '%s' "$OWNER_LOWER" \
  | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
[[ -n "$ENVIRONMENT_NAME" ]] || die "Owner could not produce a safe environment name."

if [[ -n "$EXPECTED_ACCOUNT" ]]; then
  validate_account_id "$EXPECTED_ACCOUNT"
fi
if [[ -n "$EXPECTED_REGION" ]]; then
  validate_region "$EXPECTED_REGION"
fi

if [[ "$MODE" != 'check' ]]; then
  [[ -n "$EXPECTED_ACCOUNT" ]] \
    || die "--expected-account is required for --plan and --execute."
  [[ -n "$EXPECTED_REGION" ]] \
    || die "--expected-region is required for --plan and --execute."
  (( OWNER_WAS_EXPLICIT == 1 )) \
    || die "--owner is required for --plan and --execute."
fi

if [[ -n "$EXPECTED_ACCOUNT" && "$AWS_ACCOUNT_ID" != "$EXPECTED_ACCOUNT" ]]; then
  die "AWS account mismatch: authenticated=$AWS_ACCOUNT_ID expected=$EXPECTED_ACCOUNT"
fi
if [[ -n "$EXPECTED_REGION" && "$AWS_REGION_RESOLVED" != "$EXPECTED_REGION" ]]; then
  die "AWS region mismatch: active=$AWS_REGION_RESOLVED expected=$EXPECTED_REGION"
fi

if (( USE_DERIVED_TARGETS == 1 )); then
  add_unique PIPELINES "ContinuousDelivery-${ENVIRONMENT_NAME}"
  add_unique CODEBUILD_PROJECTS "verify-${ENVIRONMENT_NAME}"
  add_unique BUCKETS "${ENVIRONMENT_NAME}-src"
fi

if ((${#REVOKE_CIDRS[@]} > 0 && ${#SECURITY_GROUP_IDS[@]} == 0)); then
  die "--revoke-cidr requires at least one exact --security-group-id."
fi
if ((${#SECURITY_GROUP_IDS[@]} > 0 && ${#REVOKE_CIDRS[@]} == 0)); then
  die "--security-group-id requires at least one explicit --revoke-cidr."
fi
if (( ASSUME_YES == 1 )) && [[ "$MODE" != 'execute' ]]; then
  die "--yes is valid only with --execute."
fi
if [[ -n "$CONFIRMATION" && "$MODE" != 'execute' ]]; then
  die "--confirmation is valid only with --execute."
fi

if [[ -z "$PLAN_FILE" ]]; then
  PLAN_FILE="$PROJECT_DIR/tfdestroyplan"
elif [[ "$PLAN_FILE" != /* ]]; then
  PLAN_FILE="$PROJECT_DIR/$PLAN_FILE"
fi
PLAN_METADATA="${PLAN_FILE}.iteration5.json"

TEMP_DIR=$(mktemp -d /tmp/level4-iteration5.XXXXXX)

log "AWS identity      : $AWS_ARN"
log "AWS account       : $AWS_ACCOUNT_ID"
log "AWS profile       : ${AWS_PROFILE:-default}"
log "AWS region        : $AWS_REGION_RESOLVED"
log "Terraform project : $PROJECT_DIR"
log "Owner             : $OWNER"
log "Environment slug  : $ENVIRONMENT_NAME"
log "Mode              : $MODE"
log "Terraform plan    : $PLAN_FILE"

if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_STATUS=$(git -C "$PROJECT_DIR" --no-pager status --short)
  if [[ -n "$GIT_STATUS" ]]; then
    warn "Terraform project has uncommitted Git changes:"
    printf '%s\n' "$GIT_STATUS" >&2
  else
    log "Git status        : clean"
  fi
else
  warn "Terraform project is not inside a Git worktree."
fi

managed_state_addresses() {
  terraform -chdir="$PROJECT_DIR" state list 2>/dev/null \
    | awk '!/(^|\.)data\./ { print }'
}

print_array() {
  local label=$1
  shift
  local -a values=("$@")
  local value

  if ((${#values[@]} == 0)); then
    printf '  %-22s %s\n' "$label:" '(none)'
    return
  fi
  for value in "${values[@]}"; do
    printf '  %-22s %s\n' "$label:" "$value"
  done
}

print_inventory() {
  local state_output
  state_output=$(managed_state_addresses || true)

  printf '\n===== REVIEW TARGETS =====\n'
  if [[ -n "$state_output" && $SKIP_TERRAFORM -eq 0 ]]; then
    printf '  Terraform resources:\n%s\n' "$state_output" | sed 's/^/    /'
  elif (( SKIP_TERRAFORM == 1 )); then
    printf '  Terraform resources:  (skipped by request)\n'
  else
    printf '  Terraform resources:  (none found)\n'
  fi

  print_array 'CodePipeline' "${PIPELINES[@]}"
  print_array 'CodeBuild' "${CODEBUILD_PROJECTS[@]}"
  print_array 'S3 bucket' "${BUCKETS[@]}"
  print_array 'STATE BUCKET (last)' "${STATE_BUCKETS[@]}"
  print_array 'IAM role' "${IAM_ROLES[@]}"
  print_array 'Instance profile' "${INSTANCE_PROFILES[@]}"
  print_array 'Security group' "${SECURITY_GROUP_IDS[@]}"
  print_array 'CIDR revoke' "${REVOKE_CIDRS[@]}"
  print_array 'Orphan EC2' "${ORPHAN_INSTANCE_IDS[@]}"
}

has_cli_targets() {
  (( ${#PIPELINES[@]} + ${#CODEBUILD_PROJECTS[@]} + ${#BUCKETS[@]} \
     + ${#STATE_BUCKETS[@]} + ${#IAM_ROLES[@]} + ${#INSTANCE_PROFILES[@]} \
     + ${#SECURITY_GROUP_IDS[@]} + ${#ORPHAN_INSTANCE_IDS[@]} > 0 ))
}

cli_target_fingerprint() {
  local value group_id cidr
  {
    for value in "${PIPELINES[@]}"; do printf 'pipeline\t%s\n' "$value"; done
    for value in "${CODEBUILD_PROJECTS[@]}"; do printf 'codebuild\t%s\n' "$value"; done
    for value in "${BUCKETS[@]}"; do printf 'bucket\t%s\n' "$value"; done
    for value in "${STATE_BUCKETS[@]}"; do printf 'state-bucket\t%s\n' "$value"; done
    for value in "${IAM_ROLES[@]}"; do printf 'iam-role\t%s\n' "$value"; done
    for value in "${INSTANCE_PROFILES[@]}"; do printf 'instance-profile\t%s\n' "$value"; done
    for group_id in "${SECURITY_GROUP_IDS[@]}"; do
      for cidr in "${REVOKE_CIDRS[@]}"; do
        printf 'sg-rule\t%s\ttcp\t%s\t%s\n' "$group_id" "$REVOKE_PORT" "$cidr"
      done
    done
    for value in "${ORPHAN_INSTANCE_IDS[@]}"; do printf 'orphan-ec2\t%s\n' "$value"; done
  } | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

target_exists_text() {
  local kind=$1
  local value=$2

  case "$kind" in
    pipeline)
      aws codepipeline get-pipeline --name "$value" --output json >/dev/null 2>&1
      ;;
    codebuild)
      [[ "$(aws codebuild batch-get-projects --names "$value" \
        --query 'projects[0].name' --output text 2>/dev/null || true)" == "$value" ]]
      ;;
    bucket)
      aws s3api head-bucket --bucket "$value" >/dev/null 2>&1
      ;;
    role)
      aws iam get-role --role-name "$value" --output json >/dev/null 2>&1
      ;;
    profile)
      aws iam get-instance-profile --instance-profile-name "$value" \
        --output json >/dev/null 2>&1
      ;;
    sg)
      aws ec2 describe-security-groups --group-ids "$value" \
        --output json >/dev/null 2>&1
      ;;
    instance)
      aws ec2 describe-instances --instance-ids "$value" \
        --output json >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

inspect_cli_targets() {
  local value
  printf '\n===== READ-ONLY AWS TARGET CHECK =====\n'

  for value in "${PIPELINES[@]}"; do
    target_exists_text pipeline "$value" \
      && log "CodePipeline exists: $value" \
      || warn "CodePipeline not found or inaccessible: $value"
  done
  for value in "${CODEBUILD_PROJECTS[@]}"; do
    target_exists_text codebuild "$value" \
      && log "CodeBuild exists: $value" \
      || warn "CodeBuild not found or inaccessible: $value"
  done
  for value in "${BUCKETS[@]}" "${STATE_BUCKETS[@]}"; do
    target_exists_text bucket "$value" \
      && log "S3 bucket exists: $value" \
      || warn "S3 bucket not found or inaccessible: $value"
  done
  for value in "${IAM_ROLES[@]}"; do
    target_exists_text role "$value" \
      && log "IAM role exists: $value" \
      || warn "IAM role not found or inaccessible: $value"
  done
  for value in "${INSTANCE_PROFILES[@]}"; do
    target_exists_text profile "$value" \
      && log "Instance profile exists: $value" \
      || warn "Instance profile not found or inaccessible: $value"
  done
  for value in "${SECURITY_GROUP_IDS[@]}"; do
    target_exists_text sg "$value" \
      && log "Security group exists: $value" \
      || warn "Security group not found or inaccessible: $value"
  done
  for value in "${ORPHAN_INSTANCE_IDS[@]}"; do
    target_exists_text instance "$value" \
      && log "EC2 instance exists: $value" \
      || warn "EC2 instance not found or inaccessible: $value"
  done
}

inspect_active_s3_backend() {
  local backend_metadata="$PROJECT_DIR/.terraform/terraform.tfstate"
  local backend_type backend_bucket managed_count=0 explicit_target=0 value
  local state_snapshot="$TEMP_DIR/active-backend-state.json"

  ACTIVE_S3_BACKEND_BUCKET=''
  SELF_MANAGED_BACKEND_BUCKET=''

  if [[ ! -f "$backend_metadata" ]]; then
    if [[ "$MODE" == 'execute' ]]; then
      die "Cannot verify the active backend because initialized backend metadata is missing: $backend_metadata"
    fi
    warn "Active-backend safety could not be inspected before Terraform initialization."
    return 0
  fi

  backend_type=$(jq -r '.backend.type // empty' "$backend_metadata") \
    || die "Could not read initialized Terraform backend metadata."
  if [[ "$backend_type" != 's3' ]]; then
    log "Active backend safety: backend type '${backend_type:-local}' is not S3."
    return 0
  fi

  backend_bucket=$(jq -r '.backend.config.bucket // empty' "$backend_metadata") \
    || die "Could not read the active S3 backend bucket."
  [[ -n "$backend_bucket" ]] \
    || die "Initialized S3 backend metadata does not contain a bucket name."
  ACTIVE_S3_BACKEND_BUCKET=$backend_bucket

  : >"$state_snapshot"
  chmod 600 "$state_snapshot"
  if ! terraform -chdir="$PROJECT_DIR" state pull >"$state_snapshot"; then
    if [[ "$MODE" == 'check' ]]; then
      warn "Could not inspect whether the active S3 backend bucket is managed by this Terraform state."
      return 0
    fi
    die "Could not inspect the active Terraform state before a destructive phase."
  fi

  managed_count=$(jq --arg bucket "$backend_bucket" '[
    .resources[]?
    | select(.mode == "managed" and .type == "aws_s3_bucket")
    | .instances[]?.attributes
    | select(.bucket == $bucket or .id == $bucket)
  ] | length' "$state_snapshot")

  for value in "${STATE_BUCKETS[@]}"; do
    if [[ "$value" == "$backend_bucket" ]]; then
      explicit_target=1
      break
    fi
  done

  log "Active S3 backend bucket: $backend_bucket"
  if (( managed_count == 0 && explicit_target == 0 )); then
    log "Active backend safety: bucket is not a destroy target."
    return 0
  fi

  if (( managed_count > 0 )); then
    SELF_MANAGED_BACKEND_BUCKET=$backend_bucket
    warn "BLOCKER: Terraform manages its own active S3 backend bucket: $backend_bucket"
  fi
  if (( explicit_target == 1 )); then
    warn "BLOCKER: The active S3 backend bucket is also an explicit state-bucket target: $backend_bucket"
  fi

  if [[ "$MODE" != 'check' ]]; then
    die "Migrate and back up Terraform state to a different backend before planning or executing deletion of the active backend bucket."
  fi
  warn "Check-only found a backend blocker. No plan was created and nothing was deleted."
}

create_destroy_plan() {
  local plan_json="$TEMP_DIR/plan.json"
  local delete_count unexpected_count plan_sha target_sha

  if (( SKIP_TERRAFORM == 1 )); then
    log "Terraform planning skipped by request."
    return 0
  fi

  terraform -chdir="$PROJECT_DIR" init -input=false
  inspect_active_s3_backend

  if [[ -e "$PLAN_FILE" || -e "$PLAN_METADATA" ]]; then
    (( REPLACE_PLAN == 1 )) \
      || die "Plan or metadata already exists. Review it or use --replace-plan for this exact path."
    rm -f -- "$PLAN_FILE" "$PLAN_METADATA"
  fi

  terraform -chdir="$PROJECT_DIR" validate
  terraform -chdir="$PROJECT_DIR" plan -destroy -input=false -no-color \
    -lock-timeout=60s -out="$PLAN_FILE"
  terraform -chdir="$PROJECT_DIR" show -json "$PLAN_FILE" >"$plan_json"

  delete_count=$(jq '[
    .resource_changes[]?
    | select(.change.actions | index("delete"))
  ] | length' "$plan_json")
  unexpected_count=$(jq '[
    .resource_changes[]?
    | .change.actions as $a
    | select(($a == ["delete"] or $a == ["no-op"] or $a == ["read"]) | not)
  ] | length' "$plan_json")

  (( unexpected_count == 0 )) \
    || die "Destroy plan contains $unexpected_count unexpected non-destroy action(s)."
  (( delete_count > 0 )) \
    || die "Destroy plan contains no delete actions. Nothing was saved for execution."

  plan_sha=$(sha256sum "$PLAN_FILE" | awk '{print $1}')
  target_sha=$(cli_target_fingerprint)
  jq -n \
    --arg account "$AWS_ACCOUNT_ID" \
    --arg region "$AWS_REGION_RESOLVED" \
    --arg owner "$OWNER" \
    --arg project "$PROJECT_DIR" \
    --arg plan "$PLAN_FILE" \
    --arg sha256 "$plan_sha" \
    --arg cli_target_sha256 "$target_sha" \
    --argjson deletes "$delete_count" \
    '{schema:1, account:$account, region:$region, owner:$owner,
      project_dir:$project, plan_file:$plan, plan_sha256:$sha256,
      cli_target_sha256:$cli_target_sha256, delete_actions:$deletes}' >"$PLAN_METADATA"
  chmod 600 "$PLAN_FILE" "$PLAN_METADATA"

  printf '\n===== TERRAFORM DELETE ADDRESSES =====\n'
  jq -r '
    .resource_changes[]?
    | select(.change.actions | index("delete"))
    | .address
  ' "$plan_json"

  log "Saved reviewed-plan candidate: $PLAN_FILE"
  log "Delete actions              : $delete_count"
  log "Plan SHA-256                : $plan_sha"
  log "CLI target SHA-256          : $target_sha"
  log "Infrastructure was not changed. Review with:"
  printf '  terraform -chdir=%q show %q\n' "$PROJECT_DIR" "$PLAN_FILE"
}

validate_saved_plan() {
  local current_sha current_target_sha metadata_value plan_json="$TEMP_DIR/execution-plan.json"
  local unexpected_count delete_count

  [[ -f "$PLAN_FILE" ]] || die "Reviewed plan file not found: $PLAN_FILE"
  [[ -f "$PLAN_METADATA" ]] || die "Plan metadata not found: $PLAN_METADATA"

  metadata_value=$(jq -r '.account' "$PLAN_METADATA")
  [[ "$metadata_value" == "$AWS_ACCOUNT_ID" ]] \
    || die "Plan account mismatch: metadata=$metadata_value active=$AWS_ACCOUNT_ID"
  metadata_value=$(jq -r '.region' "$PLAN_METADATA")
  [[ "$metadata_value" == "$AWS_REGION_RESOLVED" ]] \
    || die "Plan region mismatch: metadata=$metadata_value active=$AWS_REGION_RESOLVED"
  metadata_value=$(jq -r '.owner' "$PLAN_METADATA")
  [[ "$metadata_value" == "$OWNER" ]] \
    || die "Plan owner mismatch: metadata=$metadata_value active=$OWNER"
  metadata_value=$(jq -r '.project_dir' "$PLAN_METADATA")
  [[ "$metadata_value" == "$PROJECT_DIR" ]] \
    || die "Plan project mismatch: metadata=$metadata_value active=$PROJECT_DIR"
  metadata_value=$(jq -r '.plan_file' "$PLAN_METADATA")
  [[ "$metadata_value" == "$PLAN_FILE" ]] \
    || die "Plan path mismatch: metadata=$metadata_value selected=$PLAN_FILE"

  current_sha=$(sha256sum "$PLAN_FILE" | awk '{print $1}')
  metadata_value=$(jq -r '.plan_sha256' "$PLAN_METADATA")
  [[ "$current_sha" == "$metadata_value" ]] \
    || die "Saved plan SHA-256 does not match its review metadata."
  current_target_sha=$(cli_target_fingerprint)
  metadata_value=$(jq -r '.cli_target_sha256' "$PLAN_METADATA")
  [[ "$current_target_sha" == "$metadata_value" ]] \
    || die "CLI targets differ from the reviewed plan phase. Use the exact same target options."

  terraform -chdir="$PROJECT_DIR" show -json "$PLAN_FILE" >"$plan_json"
  delete_count=$(jq '[
    .resource_changes[]?
    | select(.change.actions | index("delete"))
  ] | length' "$plan_json")
  unexpected_count=$(jq '[
    .resource_changes[]?
    | .change.actions as $a
    | select(($a == ["delete"] or $a == ["no-op"] or $a == ["read"]) | not)
  ] | length' "$plan_json")
  (( unexpected_count == 0 )) || die "Saved plan now reports unexpected actions."
  [[ "$delete_count" == "$(jq -r '.delete_actions' "$PLAN_METADATA")" ]] \
    || die "Saved plan delete count does not match review metadata."

  log "Reviewed Terraform plan verified: $delete_count delete action(s)."
  log "Verified plan SHA-256: $current_sha"
  log "Verified CLI target SHA-256: $current_target_sha"
}

confirm_execution() {
  local required="DESTROY $AWS_ACCOUNT_ID $AWS_REGION_RESOLVED $OWNER"
  local answer

  printf '\n===== FINAL DESTRUCTIVE CONFIRMATION =====\n'
  warn "This action is intentionally destructive and may be irreversible."
  warn "Required confirmation: $required"

  if (( ASSUME_YES == 1 )); then
    [[ -n "$CONFIRMATION" ]] \
      || die "--yes requires --confirmation with the exact required phrase."
    [[ "$CONFIRMATION" == "$required" ]] \
      || die "Non-interactive confirmation phrase does not match."
    return 0
  fi

  [[ -t 0 ]] || die "Interactive confirmation required. Use --yes with exact --confirmation only after review."
  read -r -p 'Type the exact confirmation phrase: ' answer
  [[ "$answer" == "$required" ]] || die "Confirmation did not match. Nothing was deleted."
}

delete_pipeline() {
  local name=$1
  if ! target_exists_text pipeline "$name"; then
    warn "CodePipeline already absent or inaccessible; skipping: $name"
    return 0
  fi
  aws codepipeline delete-pipeline --name "$name"
  ! target_exists_text pipeline "$name" || die "CodePipeline still exists after delete: $name"
  log "Deleted CodePipeline: $name"
}

delete_codebuild_project() {
  local name=$1
  if ! target_exists_text codebuild "$name"; then
    warn "CodeBuild project already absent or inaccessible; skipping: $name"
    return 0
  fi
  aws codebuild delete-project --name "$name" >/dev/null
  ! target_exists_text codebuild "$name" || die "CodeBuild project still exists after delete: $name"
  log "Deleted CodeBuild project: $name"
}

empty_and_delete_bucket() {
  local bucket=$1
  local listing payload count key upload_id
  local payload_file="$TEMP_DIR/delete-${bucket}.json"

  if ! target_exists_text bucket "$bucket"; then
    warn "S3 bucket already absent or inaccessible; skipping: $bucket"
    return 0
  fi

  while true; do
    listing=$(aws s3api list-multipart-uploads --bucket "$bucket" --output json)
    count=$(jq '[.Uploads[]?] | length' <<<"$listing")
    (( count > 0 )) || break
    while IFS=$'\t' read -r key upload_id; do
      [[ -n "$key" && -n "$upload_id" ]] || continue
      aws s3api abort-multipart-upload --bucket "$bucket" \
        --key "$key" --upload-id "$upload_id"
    done < <(jq -r '.Uploads[]? | [.Key,.UploadId] | @tsv' <<<"$listing")
  done

  while true; do
    listing=$(aws s3api list-object-versions --bucket "$bucket" \
      --max-items 1000 --output json)
    payload=$(jq -c '{
      Objects: ([.Versions[]?, .DeleteMarkers[]?]
        | map({Key:.Key,VersionId:.VersionId})),
      Quiet: true
    }' <<<"$listing")
    count=$(jq '.Objects | length' <<<"$payload")
    (( count > 0 )) || break
    printf '%s\n' "$payload" >"$payload_file"
    aws s3api delete-objects --bucket "$bucket" \
      --delete "file://$payload_file" >/dev/null
    log "Deleted $count object version(s)/marker(s) from $bucket"
  done

  aws s3api delete-bucket --bucket "$bucket"
  ! target_exists_text bucket "$bucket" || die "S3 bucket still exists after delete: $bucket"
  log "Deleted S3 bucket: $bucket"
}

delete_instance_profile() {
  local profile=$1
  local role
  local -a roles=()

  if ! target_exists_text profile "$profile"; then
    warn "Instance profile already absent or inaccessible; skipping: $profile"
    return 0
  fi

  mapfile -t roles < <(aws iam get-instance-profile \
    --instance-profile-name "$profile" \
    --query 'InstanceProfile.Roles[].RoleName' --output text \
    | tr '\t' '\n' | sed '/^$/d; /^None$/d')
  for role in "${roles[@]}"; do
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "$profile" --role-name "$role"
  done
  aws iam delete-instance-profile --instance-profile-name "$profile"
  ! target_exists_text profile "$profile" || die "Instance profile still exists: $profile"
  log "Deleted instance profile: $profile"
}

delete_iam_role() {
  local role=$1
  local policy
  local -a inline_policies=()
  local -a attached_policies=()

  if ! target_exists_text role "$role"; then
    warn "IAM role already absent or inaccessible; skipping: $role"
    return 0
  fi

  mapfile -t inline_policies < <(aws iam list-role-policies --role-name "$role" \
    --query 'PolicyNames[]' --output text | tr '\t' '\n' | sed '/^$/d; /^None$/d')
  for policy in "${inline_policies[@]}"; do
    aws iam delete-role-policy --role-name "$role" --policy-name "$policy"
  done

  mapfile -t attached_policies < <(aws iam list-attached-role-policies --role-name "$role" \
    --query 'AttachedPolicies[].PolicyArn' --output text \
    | tr '\t' '\n' | sed '/^$/d; /^None$/d')
  for policy in "${attached_policies[@]}"; do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$policy"
  done

  aws iam delete-role --role-name "$role"
  ! target_exists_text role "$role" || die "IAM role still exists after delete: $role"
  log "Deleted IAM role: $role"
}

revoke_security_group_rules() {
  local group_id cidr rules count
  for group_id in "${SECURITY_GROUP_IDS[@]}"; do
    target_exists_text sg "$group_id" \
      || die "Explicit security group is absent or inaccessible: $group_id"
    for cidr in "${REVOKE_CIDRS[@]}"; do
      rules=$(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$group_id" --output json)
      count=$(jq --arg cidr "$cidr" --argjson port "$REVOKE_PORT" '[
        .SecurityGroupRules[]?
        | select(.IsEgress == false)
        | select(.IpProtocol == "tcp")
        | select(.FromPort == $port and .ToPort == $port)
        | select(.CidrIpv4 == $cidr)
      ] | length' <<<"$rules")
      if (( count == 0 )); then
        log "Security-group rule already absent: $group_id tcp/$REVOKE_PORT $cidr"
        continue
      fi

      aws ec2 revoke-security-group-ingress \
        --group-id "$group_id" --protocol tcp \
        --port "$REVOKE_PORT" --cidr "$cidr" >/dev/null

      rules=$(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$group_id" --output json)
      count=$(jq --arg cidr "$cidr" --argjson port "$REVOKE_PORT" '[
        .SecurityGroupRules[]?
        | select(.IsEgress == false)
        | select(.IpProtocol == "tcp")
        | select(.FromPort == $port and .ToPort == $port)
        | select(.CidrIpv4 == $cidr)
      ] | length' <<<"$rules")
      (( count == 0 )) || die "Security-group rule still exists after revoke: $group_id $cidr"
      log "Revoked tcp/$REVOKE_PORT $cidr from $group_id"
    done
  done
}

terminate_orphan_instance() {
  local instance_id=$1
  local state

  if ! target_exists_text instance "$instance_id"; then
    warn "EC2 instance already absent or inaccessible; skipping: $instance_id"
    return 0
  fi
  state=$(aws ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)
  if [[ "$state" == 'terminated' ]]; then
    log "EC2 instance already terminated: $instance_id"
    return 0
  fi
  aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$instance_id"
  log "Terminated explicit orphan EC2 instance: $instance_id"
}

apply_terraform_plan() {
  local remaining
  (( SKIP_TERRAFORM == 0 )) || return 0

  terraform -chdir="$PROJECT_DIR" apply -input=false "$PLAN_FILE"
  remaining=$(managed_state_addresses || true)
  if [[ -n "$remaining" ]]; then
    warn "Managed Terraform state still contains addresses after apply:"
    printf '%s\n' "$remaining" >&2
    die "Terraform teardown is incomplete. CLI cleanup was not started."
  fi
  log "Terraform-managed resources are absent from state."
}

run_cli_cleanup() {
  local value

  for value in "${PIPELINES[@]}"; do delete_pipeline "$value"; done
  for value in "${CODEBUILD_PROJECTS[@]}"; do delete_codebuild_project "$value"; done
  for value in "${BUCKETS[@]}"; do empty_and_delete_bucket "$value"; done
  revoke_security_group_rules
  for value in "${ORPHAN_INSTANCE_IDS[@]}"; do terminate_orphan_instance "$value"; done
  for value in "${INSTANCE_PROFILES[@]}"; do delete_instance_profile "$value"; done
  for value in "${IAM_ROLES[@]}"; do delete_iam_role "$value"; done

  if ((${#STATE_BUCKETS[@]} > 0)); then
    warn "Deleting explicit Terraform-state bucket(s) last. State history will be lost."
    for value in "${STATE_BUCKETS[@]}"; do empty_and_delete_bucket "$value"; done
  fi
}

if [[ "$MODE" != 'plan' ]]; then
  inspect_active_s3_backend
fi

print_inventory
inspect_cli_targets

case "$MODE" in
  check)
    log "Check-only completed. No plan was created and nothing was deleted."
    ;;
  plan)
    create_destroy_plan
    if has_cli_targets; then
      log "CLI targets were inventoried only; --plan never deletes them."
    fi
    log "Plan phase completed. Infrastructure was not changed."
    ;;
  execute)
    if (( SKIP_TERRAFORM == 0 )); then
      validate_saved_plan
    elif ! has_cli_targets; then
      die "--execute --skip-terraform requires at least one explicit CLI target."
    fi
    confirm_execution
    apply_terraform_plan
    run_cli_cleanup
    log "Iteration 5 teardown completed for the reviewed targets."
    ;;
  *)
    die "Internal mode error: $MODE"
    ;;
esac
