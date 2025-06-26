#!/bin/bash
set -euo pipefail

# Prompt for GitHub URL
if [ -z "${GITHUB_URL:-}" ]; then
  read -rp "Enter source GitHub repository URL (e.g., https://github.com/OWNER/REPO): " GITHUB_URL
fi

# Normalize URL
clean_url=${GITHUB_URL%.git}
clean_url=${clean_url%/}

# # Extract owner/repo
# if [[ $clean_url =~ ^https://github\.com/([^/]+/[^/]+)$ ]]; then
#   path="${BASH_REMATCH[1]}"
# elif [[ $clean_url =~ ^git@github\.com:([^/]+/[^/]+)$ ]]; then
#   path="${BASH_REMATCH[1]}"
# else
#   echo "Unable to parse owner/repo from '$GITHUB_URL'"
#   read -rp "Enter GitHub owner: " GITHUB_OWNER
#   read -rp "Enter GitHub repo: " GITHUB_REPO
# fi

# if [ -z "${GITHUB_OWNER:-}" ] || [ -z "${GITHUB_REPO:-}" ]; then
#   GITHUB_OWNER=${path%%/*}
#   GITHUB_REPO=${path##*/}
#   echo "Detected GitHub Owner: $GITHUB_OWNER"
#   echo "Detected GitHub Repo: $GITHUB_REPO"
#   read -rp "Is this correct? (y/n): " CONFIRM
#   CONFIRM=$(printf '%s' "$CONFIRM" | tr '[:upper:]' '[:lower:]')
#   if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
#     read -rp "Enter GitHub owner: " GITHUB_OWNER
#     read -rp "Enter GitHub repo: " GITHUB_REPO
#   fi
# fi

# Prompt for deployment parameters
if [ -z "${PROJECT_NAME:-}" ]; then
  read -rp "Enter project name [default: open-earth-classification]: " PROJECT_NAME
fi

if [ -z "${BUCKET_NAME:-}" ]; then
  read -rp "Enter S3 bucket name for data storage (must be globally unique): " BUCKET_NAME
fi

if [ -z "${ASSETS_BUCKET:-}" ]; then
  read -rp "Enter S3 bucket name for assets: " ASSETS_BUCKET
fi

if [ -z "${GEE_CREDENTIALS_FILE:-}" ]; then
  read -rp "Enter the path to GEE credentials file in assets bucket (e.g., credentials/gee-key.json): " GEE_CREDENTIALS_FILE
fi

if [ -z "${AMPLIFY_APP_NAME:-}" ]; then
  read -rp "Enter Amplify app name [default: ${PROJECT_NAME}-frontend]: " AMPLIFY_APP_NAME
  AMPLIFY_APP_NAME=${AMPLIFY_APP_NAME:-${PROJECT_NAME}-frontend}
fi

if [ -z "${AMPLIFY_BRANCH_NAME:-}" ]; then
  read -rp "Enter Amplify branch name [default: main]: " AMPLIFY_BRANCH_NAME
  AMPLIFY_BRANCH_NAME=${AMPLIFY_BRANCH_NAME:-main}
fi

if [ -z "${ACTION:-}" ]; then
  read -rp "Enter action [deploy/destroy]: " ACTION
  ACTION=$(printf '%s' "$ACTION" | tr '[:upper:]' '[:lower:]')
fi

if [[ "$ACTION" != "deploy" && "$ACTION" != "destroy" ]]; then
  echo "Invalid action: '$ACTION'. Choose 'deploy' or 'destroy'."
  exit 1
fi


# Create IAM role for CodeBuild
ROLE_NAME="${PROJECT_NAME}-service-role"
echo "Checking for IAM role: $ROLE_NAME"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "✓ IAM role exists"
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
else
  echo "✱ Creating IAM role: $ROLE_NAME"
  TRUST_DOC='{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"codebuild.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }'

  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_DOC" \
    --query 'Role.Arn' --output text)

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess

  echo "Waiting for IAM role to propagate..."
  sleep 10
fi

# Create CodeBuild project
echo "Creating CodeBuild project: ${PROJECT_NAME}"

BACKEND_ENV='{
  "type": "LINUX_CONTAINER",
  "image": "aws/codebuild/standard:7.0",
  "computeType": "BUILD_GENERAL1_SMALL",
  "environmentVariables": [
    {"name": "PROJECT_NAME", "value": "'"$PROJECT_NAME"'", "type": "PLAINTEXT"},
    {"name": "BUCKET_NAME", "value": "'"$BUCKET_NAME"'", "type": "PLAINTEXT"},
    {"name": "ASSETS_BUCKET", "value": "'"$ASSETS_BUCKET"'", "type": "PLAINTEXT"},
    {"name": "GEE_CREDENTIALS_FILE", "value": "'"$GEE_CREDENTIALS_FILE"'", "type": "PLAINTEXT"},
    {"name": "AMPLIFY_APP_NAME", "value": "'"$AMPLIFY_APP_NAME"'", "type": "PLAINTEXT"},
    {"name": "AMPLIFY_BRANCH_NAME", "value": "'"$AMPLIFY_BRANCH_NAME"'", "type": "PLAINTEXT"},
    {"name": "ACTION", "value": "'"$ACTION"'", "type": "PLAINTEXT"}
  ]
}'

ARTIFACTS='{"type":"NO_ARTIFACTS"}'
SOURCE='{
  "type":"GITHUB",
  "location":"'"$GITHUB_URL"'",
  "buildspec":"buildspec.yml"
}'

aws codebuild create-project \
  --name "$PROJECT_NAME" \
  --source "$SOURCE" \
  --artifacts "$ARTIFACTS" \
  --environment "$BACKEND_ENV" \
  --service-role "$ROLE_ARN" \
  --output json \
  --no-cli-pager

if [ $? -eq 0 ]; then
  echo "✓ CodeBuild project '$PROJECT_NAME' created."
else
  echo "✗ Failed to create CodeBuild project."
  exit 1
fi

# Start build
echo "Starting build for '$PROJECT_NAME'..."
aws codebuild start-build \
  --project-name "$PROJECT_NAME" \
  --no-cli-pager \
  --output json

if [ $? -eq 0 ]; then
  echo "✓ Build started."
else
  echo "✗ Failed to start build."
  exit 1
fi

echo "Current CodeBuild projects:"
aws codebuild list-projects --output table

exit 0