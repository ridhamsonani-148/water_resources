#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { ForestClassificationStack } from '../lib/classification_stack';

const app = new cdk.App();
const githubUrl = app.node.tryGetContext("githubUrl") || process.env.GITHUB_URL
const projectName = app.node.tryGetContext("projectName") || process.env.PROJECT_NAME 
const amplifyAppName = app.node.tryGetContext("amplifyAppName") || process.env.AMPLIFY_APP_NAME
const amplifyBranchName = app.node.tryGetContext("amplifyBranchName") || process.env.AMPLIFY_BRANCH_NAME
new ForestClassificationStack(app, 'ForestClassificationStack', {
  githubUrl,
  projectName,
  amplifyAppName,
  amplifyBranchName,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});