#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR=$(mktemp -d /tmp/level4-iteration5-tests.XXXXXX)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SCRIPT="$SCRIPT_DIR/Level4 Iteration5.sh"
FAKE_BIN="$TEST_DIR/bin"
PROJECT="$TEST_DIR/project"
FAKE_STATE_DIR="$TEST_DIR/fake-state"
FAKE_LOG="$TEST_DIR/commands.log"

cleanup() {
  [[ "$TEST_DIR" == /tmp/level4-iteration5-tests.* ]] && rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

mkdir -p "$FAKE_BIN" "$PROJECT/.terraform" "$FAKE_STATE_DIR"
printf '%s\n' 'terraform {}' >"$PROJECT/main.tf"
printf '%s\n' '{"backend":{"type":"local","config":{}}}' \
  >"$PROJECT/.terraform/terraform.tfstate"
touch "$FAKE_LOG" "$FAKE_STATE_DIR/terraform-resource"

cat >"$FAKE_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'aws %s\n' "$*" >>"$FAKE_LOG"

account=${FAKE_ACCOUNT:-123456789012}
region=${FAKE_REGION:-eu-north-1}
service=${1:-}
operation=${2:-}
shift $(( $# >= 2 ? 2 : $# ))

has_arg() {
  local wanted=$1 value
  shift
  for value in "$@"; do [[ "$value" == "$wanted" ]] && return 0; done
  return 1
}

arg_after() {
  local wanted=$1
  shift
  while (($# > 0)); do
    if [[ "$1" == "$wanted" && $# -ge 2 ]]; then printf '%s' "$2"; return 0; fi
    shift
  done
  return 1
}

case "$service/$operation" in
  sts/get-caller-identity)
    query=$(arg_after --query "$@" || true)
    case "$query" in
      Arn) printf 'arn:aws:iam::%s:user/Example.Owner\n' "$account" ;;
      Account) printf '%s\n' "$account" ;;
      *) printf '{"Account":"%s","Arn":"arn:aws:iam::%s:user/Example.Owner"}\n' "$account" "$account" ;;
    esac
    ;;
  configure/get)
    printf '%s\n' "$region"
    ;;
  codepipeline/get-pipeline)
    name=$(arg_after --name "$@")
    [[ -f "$FAKE_STATE_DIR/pipeline-$name" ]] || exit 255
    printf '{"pipeline":{"name":"%s"}}\n' "$name"
    ;;
  codepipeline/delete-pipeline)
    name=$(arg_after --name "$@")
    rm -f -- "$FAKE_STATE_DIR/pipeline-$name"
    ;;
  codebuild/batch-get-projects)
    name=$(arg_after --names "$@")
    if [[ -f "$FAKE_STATE_DIR/codebuild-$name" ]]; then printf '%s\n' "$name"; else printf 'None\n'; fi
    ;;
  codebuild/delete-project)
    name=$(arg_after --name "$@")
    rm -f -- "$FAKE_STATE_DIR/codebuild-$name"
    printf '{}\n'
    ;;
  s3api/head-bucket)
    bucket=$(arg_after --bucket "$@")
    [[ -f "$FAKE_STATE_DIR/bucket-$bucket" ]] || exit 255
    ;;
  s3api/list-multipart-uploads)
    printf '{"Uploads":[]}\n'
    ;;
  s3api/list-object-versions)
    printf '{"Versions":[],"DeleteMarkers":[]}\n'
    ;;
  s3api/delete-bucket)
    bucket=$(arg_after --bucket "$@")
    rm -f -- "$FAKE_STATE_DIR/bucket-$bucket"
    ;;
  *)
    printf 'Unsupported fake AWS command: %s/%s %s\n' "$service" "$operation" "$*" >&2
    exit 64
    ;;
esac
AWS

cat >"$FAKE_BIN/terraform" <<'TERRAFORM'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'terraform %s\n' "$*" >>"$FAKE_LOG"

declare -a args=()
for value in "$@"; do
  [[ "$value" == -chdir=* ]] || args+=("$value")
done
set -- "${args[@]}"
command=${1:-}
shift || true

case "$command" in
  init|validate)
    exit 0
    ;;
  state)
    case ${1:-} in
      list)
        [[ -f "$FAKE_STATE_DIR/terraform-resource" ]] && printf 'aws_instance.demo\n'
        ;;
      pull)
        if [[ -n ${FAKE_BACKEND_BUCKET:-} ]]; then
          printf '%s\n' "{\"resources\":[{\"mode\":\"managed\",\"type\":\"aws_s3_bucket\",\"name\":\"terraform_state\",\"instances\":[{\"attributes\":{\"bucket\":\"$FAKE_BACKEND_BUCKET\",\"id\":\"$FAKE_BACKEND_BUCKET\"}}]}]}"
        else
          printf '%s\n' '{"resources":[]}'
        fi
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  plan)
    out=''
    for value in "$@"; do
      case "$value" in -out=*) out=${value#-out=} ;; esac
    done
    [[ -n "$out" ]] || exit 64
    printf 'reviewed destroy plan\n' >"$out"
    ;;
  show)
    if [[ ${1:-} == -json ]]; then
      cat <<'JSON'
{"resource_changes":[{"address":"aws_instance.demo","change":{"actions":["delete"]}}]}
JSON
    else
      printf 'Plan: 0 to add, 0 to change, 1 to destroy.\n'
    fi
    ;;
  apply)
    rm -f -- "$FAKE_STATE_DIR/terraform-resource"
    ;;
  *)
    printf 'Unsupported fake Terraform command: %s %s\n' "$command" "$*" >&2
    exit 64
    ;;
esac
TERRAFORM

cat >"$FAKE_BIN/git" <<'GIT'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *'rev-parse --is-inside-work-tree'* ]]; then
  printf 'true\n'
elif [[ "$*" == *'status --short'* ]]; then
  exit 0
else
  exit 0
fi
GIT

chmod +x "$FAKE_BIN/aws" "$FAKE_BIN/terraform" "$FAKE_BIN/git"
export PATH="$FAKE_BIN:$PATH"
export FAKE_STATE_DIR FAKE_LOG

common=(
  --project-dir "$PROJECT"
  --region eu-north-1
  --owner Example.Owner
  --expected-account 123456789012
  --expected-region eu-north-1
  --include-derived-project-targets
)

touch "$FAKE_STATE_DIR/pipeline-ContinuousDelivery-example-owner"
touch "$FAKE_STATE_DIR/codebuild-verify-example-owner"
touch "$FAKE_STATE_DIR/bucket-example-owner-src"

: >"$FAKE_LOG"
bash "$SCRIPT" --check-only --project-dir "$PROJECT" --region eu-north-1 \
  --include-derived-project-targets >/dev/null
if grep -En 'terraform (plan|apply)|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'check-only invoked a destructive or planning command'
fi
pass 'check-only is read-only'

: >"$FAKE_LOG"
bash "$SCRIPT" --plan "${common[@]}" >/dev/null
[[ -s "$PROJECT/tfdestroyplan" ]] || fail 'plan file was not created'
[[ -s "$PROJECT/tfdestroyplan.iteration5.json" ]] || fail 'plan metadata was not created'
grep -Eq 'terraform .*plan -destroy' "$FAKE_LOG" || fail 'destroy plan was not requested'
if grep -En 'terraform .*apply|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'plan mode performed a destructive command'
fi
pass 'plan is saved but never applied automatically'

: >"$FAKE_LOG"
if bash "$SCRIPT" --execute "${common[@]}" --yes \
  --confirmation 'WRONG PHRASE' >/dev/null 2>&1; then
  fail 'incorrect confirmation was accepted'
fi
if grep -En 'terraform .*apply|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'incorrect confirmation reached destructive commands'
fi
pass 'incorrect confirmation blocks execution'

cp -- "$PROJECT/tfdestroyplan" "$PROJECT/tfdestroyplan.reviewed"
printf 'tamper\n' >>"$PROJECT/tfdestroyplan"
: >"$FAKE_LOG"
if bash "$SCRIPT" --execute "${common[@]}" --yes \
  --confirmation 'DESTROY 123456789012 eu-north-1 Example.Owner' \
  >/dev/null 2>&1; then
  fail 'tampered plan was accepted'
fi
if grep -En 'terraform .*apply|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'tampered plan reached destructive commands'
fi
mv -- "$PROJECT/tfdestroyplan.reviewed" "$PROJECT/tfdestroyplan"
pass 'tampered saved plan is blocked by SHA-256'

: >"$FAKE_LOG"
if bash "$SCRIPT" --execute "${common[@]}" \
  --bucket 'unreviewed-extra-bucket' \
  --yes \
  --confirmation 'DESTROY 123456789012 eu-north-1 Example.Owner' \
  >/dev/null 2>&1; then
  fail 'changed CLI targets were accepted after plan review'
fi
if grep -En 'terraform .*apply|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'changed CLI targets reached destructive commands'
fi
pass 'CLI targets are bound to the reviewed plan phase'

: >"$FAKE_LOG"
FAKE_ACCOUNT=000000000000 \
  bash "$SCRIPT" --plan "${common[@]}" --replace-plan >/dev/null 2>&1 \
  && fail 'wrong AWS account was accepted'
if grep -En 'terraform .*plan|terraform .*apply|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'account mismatch reached planning or destructive commands'
fi
pass 'wrong AWS account is blocked before planning'

cat >"$PROJECT/.terraform/terraform.tfstate" <<'JSON'
{
  "backend": {
    "type": "s3",
    "config": {
      "bucket": "self-managed-state-test"
    }
  }
}
JSON
export FAKE_BACKEND_BUCKET='self-managed-state-test'
plan_sha_before=$(sha256sum "$PROJECT/tfdestroyplan" | awk '{print $1}')
: >"$FAKE_LOG"
if bash "$SCRIPT" --plan "${common[@]}" --replace-plan >/dev/null 2>&1; then
  fail 'self-managed active S3 backend was accepted for destroy planning'
fi
plan_sha_after=$(sha256sum "$PROJECT/tfdestroyplan" | awk '{print $1}')
[[ "$plan_sha_before" == "$plan_sha_after" ]] \
  || fail 'backend blocker replaced the previously reviewed plan'
grep -Eq 'terraform .*state pull' "$FAKE_LOG" \
  || fail 'active backend state was not inspected'
if grep -En 'terraform .*plan -destroy|terraform .*apply|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'self-managed backend blocker reached planning or destructive commands'
fi

: >"$FAKE_LOG"
if bash "$SCRIPT" --execute "${common[@]}" --yes \
  --confirmation 'DESTROY 123456789012 eu-north-1 Example.Owner' \
  >/dev/null 2>&1; then
  fail 'self-managed active S3 backend was accepted for execution'
fi
if grep -En 'terraform .*apply|aws .*delete|aws .*terminate|aws .*revoke' "$FAKE_LOG"; then
  fail 'self-managed backend blocker reached destructive execution commands'
fi
unset FAKE_BACKEND_BUCKET
printf '%s\n' '{"backend":{"type":"local","config":{}}}' \
  >"$PROJECT/.terraform/terraform.tfstate"
pass 'self-managed active S3 backend blocks plan and execute'

: >"$FAKE_LOG"
bash "$SCRIPT" --execute "${common[@]}" --yes \
  --confirmation 'DESTROY 123456789012 eu-north-1 Example.Owner' \
  >/dev/null
grep -Eq 'terraform .*apply' "$FAKE_LOG" || fail 'reviewed plan was not applied'
grep -Eq 'aws codepipeline delete-pipeline' "$FAKE_LOG" || fail 'pipeline was not deleted'
grep -Eq 'aws codebuild delete-project' "$FAKE_LOG" || fail 'CodeBuild project was not deleted'
grep -Eq 'aws s3api delete-bucket' "$FAKE_LOG" || fail 'source bucket was not deleted'
[[ ! -e "$FAKE_STATE_DIR/terraform-resource" ]] || fail 'Terraform resource remains'
[[ ! -e "$FAKE_STATE_DIR/pipeline-ContinuousDelivery-example-owner" ]] || fail 'pipeline remains'
[[ ! -e "$FAKE_STATE_DIR/codebuild-verify-example-owner" ]] || fail 'CodeBuild project remains'
[[ ! -e "$FAKE_STATE_DIR/bucket-example-owner-src" ]] || fail 'source bucket remains'
pass 'reviewed plan and exact derived targets execute in safe order'

if grep -En '(^|[^0-9])[0-9]{12}([^0-9]|$)|i-[0-9a-fA-F]{17}|sg-[0-9a-fA-F]{17}|([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' "$SCRIPT"; then
  fail 'literal account, resource ID, or IPv4 CIDR remains in repaired script'
fi
pass 'literal accounts, resource IDs, and CIDRs are removed'

bash -n "$SCRIPT"
pass 'Bash syntax is valid'

printf '\nALL ITERATION 5 TESTS PASSED\n'
