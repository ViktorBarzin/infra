#!/usr/bin/env bash
# Deploys the AWS half of London's Alexa voice control: the Lambda that
# forwards Alexa Smart Home directives to ha-london, its execution role, its
# log group, and (once the skill exists) the permission for the skill to call
# it. Safe to re-run; every step checks what already exists.
#
# Plan: docs/plans/2026-10-31-london-alexa.md. Credentials: the alexa-ha-london
# IAM user in Vault secret/viktor (aws_alexa_access_key_id/_secret_access_key).
# The Lambda code is HA's reference gist, fetched fresh on every run; the gist
# revision lands in the function description.
set -euo pipefail

REGION=eu-west-1
FUNCTION=ha-london-alexa
ROLE=ha-london-alexa-lambda
BASE_URL=https://ha-london.viktorbarzin.me
GIST_ID=744b5ef548cc13d88d0569eea65f5e5b
RUNTIME=python3.13
AWS_CLI_IMAGE=amazon/aws-cli:2.31.0
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_ID="${SKILL_ID:-$(cat "$HERE/skill/skill-id" 2>/dev/null || true)}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$(vault kv get -field=aws_alexa_access_key_id secret/viktor)}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$(vault kv get -field=aws_alexa_secret_access_key secret/viktor)}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

aws() {
  docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION="$REGION" \
    -v "$WORK:/work" -w /work "$AWS_CLI_IMAGE" --output json "$@"
}

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::$ACCOUNT:role/$ROLE"
echo "account $ACCOUNT, region $REGION"

# Execution role: lambda.amazonaws.com may assume it; it carries only the
# managed basic-execution policy (write its own logs).
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  cat >"$WORK/trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document file:///work/trust.json >/dev/null
  echo "created role $ROLE"
  NEW_ROLE=1
fi
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Log group first, so retention is set before the first invocation creates it.
if ! aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/$FUNCTION" \
  --query "logGroups[?logGroupName=='/aws/lambda/$FUNCTION'] | length(@)" --output text | grep -qx 1; then
  aws logs create-log-group --log-group-name "/aws/lambda/$FUNCTION"
fi
aws logs put-retention-policy --log-group-name "/aws/lambda/$FUNCTION" --retention-in-days 14

# Code: the single file from HA's reference gist.
curl -fsS "https://api.github.com/gists/$GIST_ID" >"$WORK/gist.json"
GIST_REV="$(python3 - "$WORK" <<'EOF'
import json, sys, zipfile
work = sys.argv[1]
gist = json.load(open(f"{work}/gist.json"))
code = gist["files"]["lambda_function.py"]["content"]
with zipfile.ZipFile(f"{work}/function.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("lambda_function.py", code)
print(gist["history"][0]["version"])
EOF
)"
DESCRIPTION="Alexa Smart Home -> ha-london. HA reference gist $GIST_ID rev ${GIST_REV:0:12}"
echo "gist revision $GIST_REV"

if aws lambda get-function --function-name "$FUNCTION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION" --zip-file fileb:///work/function.zip >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION"
  aws lambda update-function-configuration --function-name "$FUNCTION" --runtime "$RUNTIME" \
    --description "$DESCRIPTION" --timeout 8 --memory-size 128 \
    --environment "Variables={BASE_URL=$BASE_URL}" >/dev/null
  echo "updated $FUNCTION"
else
  # A role created a moment ago is not yet assumable by Lambda.
  [ "${NEW_ROLE:-0}" = 1 ] && sleep 15
  aws lambda create-function --function-name "$FUNCTION" --runtime "$RUNTIME" --architectures arm64 \
    --role "$ROLE_ARN" --handler lambda_function.lambda_handler \
    --zip-file fileb:///work/function.zip --description "$DESCRIPTION" \
    --timeout 8 --memory-size 128 --environment "Variables={BASE_URL=$BASE_URL}" >/dev/null
  echo "created $FUNCTION"
fi
aws lambda wait function-updated --function-name "$FUNCTION"

# Only the skill may invoke the function. Skipped until the skill exists.
if [ -n "$SKILL_ID" ]; then
  if ! aws lambda get-policy --function-name "$FUNCTION" --query Policy --output text 2>/dev/null | grep -q "$SKILL_ID"; then
    aws lambda remove-permission --function-name "$FUNCTION" --statement-id alexa-skill >/dev/null 2>&1 || true
    aws lambda add-permission --function-name "$FUNCTION" --statement-id alexa-skill \
      --action lambda:InvokeFunction --principal alexa-connectedhome.amazon.com \
      --event-source-token "$SKILL_ID" >/dev/null
    echo "granted skill $SKILL_ID"
  fi
else
  echo "no skill id yet (skill/skill-id); skill trigger not added"
fi

echo "function arn: arn:aws:lambda:$REGION:$ACCOUNT:function:$FUNCTION"
