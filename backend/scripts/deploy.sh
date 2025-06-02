#!/bin/bash
set -euo pipefail

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

# Deploy backend via CodeBuild
echo "Creating CodeBuild project for backend: ${PROJECT_NAME}-backend"

BACKEND_ENV='{
  "type": "LINUX_CONTAINER",
  "image": "aws/codebuild/standard:7.0",
  "computeType": "BUILD_GENERAL1_SMALL",
  "environmentVariables": [
    {"name": "BUCKET_NAME", "value": "'"$BUCKET_NAME"'", "type": "PLAINTEXT"},
    {"name": "ASSETS_BUCKET", "value": "'"$ASSETS_BUCKET"'", "type": "PLAINTEXT"}
  ]
}'

aws codebuild create-project \
  --name "${PROJECT_NAME}-backend" \
  --source "{\
    \"type\":\"GITHUB\",\
    \"location\":\"$(git config --get remote.origin.url)\",\
    \"buildspec\":\"Backend/buildspec.yml\"\
  }" \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment "$BACKEND_ENV" \
  --service-role "$ROLE_ARN"

# Start backend build and wait for completion
echo "Starting backend deployment..."
BUILD_ID=$(aws codebuild start-build \
  --project-name "${PROJECT_NAME}-backend" \
  --query 'build.id' \
  --output text)

# Wait for backend build to complete and get Lambda URL
echo "Waiting for backend deployment to complete..."
aws codebuild wait build-completed --id "$BUILD_ID"

# Get Lambda Function URL from CloudFormation outputs
LAMBDA_URL=$(aws cloudformation describe-stacks \
  --stack-name OpenEarthStack \
  --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionUrl`].OutputValue' \
  --output text)

# Create/update .env file for frontend
echo "Updating frontend environment configuration..."
echo "REACT_APP_API_URL=$LAMBDA_URL" > "../Frontend/.env"

# Build and deploy frontend to Amplify
echo "Building frontend application..."
cd ../Frontend
npm install
npm run build

# Create Amplify app
echo "Creating Amplify app..."
AMPLIFY_APP_ID=$(aws amplify create-app \
  --name "${PROJECT_NAME}-frontend" \
  --repository "$(git config --get remote.origin.url)" \
  --query 'app.appId' \
  --output text)

# Create build zip
cd build
zip -r ../build.zip .
cd ..

# Deploy to Amplify
aws amplify start-deployment \
  --app-id "$AMPLIFY_APP_ID" \
  --branch-name main \
  --source-url build.zip

echo "Deployment complete!"
echo "Backend Lambda URL: $LAMBDA_URL"
echo "Frontend will be available at: https://${AMPLIFY_APP_ID}.amplifyapp.com"