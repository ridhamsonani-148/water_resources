#!/bin/bash
set -euo pipefail

# Store the root directory path
ROOT_DIR=$(pwd)

# Prompt for deployment parameters
if [ -z "${PROJECT_NAME:-}" ]; then
  read -rp "Enter project name (e.g., OpenEarthProject): " PROJECT_NAME
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
# Verify project structure
if [ ! -d "backend" ] || [ ! -d "Frontend" ]; then
    echo "Error: Backend or Frontend directory not found!"
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

  echo "Waiting for IAM role to propagate..."
  sleep 10
fi

# Create main CodeBuild project
echo "Creating CodeBuild project: ${PROJECT_NAME}"

BACKEND_ENV='{
  "type": "LINUX_CONTAINER",
  "image": "aws/codebuild/standard:7.0",
  "computeType": "BUILD_GENERAL1_SMALL",
  "environmentVariables": [
    {"name": "PROJECT_NAME", "value": "'"$PROJECT_NAME"'", "type": "PLAINTEXT"},
    {"name": "BUCKET_NAME", "value": "'"$BUCKET_NAME"'", "type": "PLAINTEXT"},
    {"name": "ASSETS_BUCKET", "value": "'"$ASSETS_BUCKET"'", "type": "PLAINTEXT"},
    {"name": "GEE_CREDENTIALS_FILE", "value": "'"$GEE_CREDENTIALS_FILE"'", "type": "PLAINTEXT"}
  ]
}'

aws codebuild create-project \
  --name "${PROJECT_NAME}" \
  --source "{\
    \"type\":\"GITHUB\",\
    \"location\":\"$(git config --get remote.origin.url)\",\
    \"buildspec\":\"buildspec.yml\"\
  }" \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment "$BACKEND_ENV" \
  --service-role "$ROLE_ARN"

# Start deployment
echo "Starting deployment process..."
BUILD_ID=$(aws codebuild start-build \
  --project-name "$PROJECT_NAME" \
  --query 'build.id' \
  --output text)

echo "Deployment initiated. Check AWS CodeBuild console for progress."
echo "Build ID: $BUILD_ID"

