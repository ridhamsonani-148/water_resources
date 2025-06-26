import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';


export class ForestClassificationStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const projectNameParam = new cdk.CfnParameter(this, 'ProjectName', {
      type: 'String', 
      description: 'The name of the project, used for naming resources.',
      default: 'ForestClassificationProject',
    });
    
    const amplifyBranchNameParam = new cdk.CfnParameter(this, 'AmplifyBranchName', {
      type: 'String',
      description: 'The name of the Amplify branch to deploy the frontend application.',
    });

    // Define CloudFormation parameters
    const assetsBucketNameParam = new cdk.CfnParameter(this, 'AssetsBucketName', {
      type: 'String',
      description: 'The name of the S3 bucket containing Lambda layers and function code.',
    });

    const bucketNameParam = new cdk.CfnParameter(this, 'BucketName', {
      type: 'String',
      description: 'The name of the S3 bucket to store input/output files. Must be globally unique.',
    });

    const geeCredentialsFileParam = new cdk.CfnParameter(this, 'GeeCredentialsFile', {
      type: 'String',
      description: 'Name of the Google Earth Engine credentials file in the S3 bucket (e.g., credentials/custom-gee-credentials.json)',
    });

    // Use parameter values
    const assetsBucketName = assetsBucketNameParam.valueAsString;
    const bucketName = bucketNameParam.valueAsString;
    const geeCredentialsFile = geeCredentialsFileParam.valueAsString;
    const projectName = projectNameParam.valueAsString;
    const amplifyBranchName = amplifyBranchNameParam.valueAsString;

    // Reference the assets bucket
    const assetsBucket = s3.Bucket.fromBucketName(this, 'AssetsBucket', assetsBucketName);

    // Create S3 bucket for input/output files
    const bucket = new s3.Bucket(this, 'ForestClassificationBucket', {
      bucketName: bucketName,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      cors: [{
        allowedOrigins: ['*'],
        allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.PUT],
        allowedHeaders: ['*'],
        exposedHeaders: [],
        maxAge: 3600
      }]
    });

    // Create S3 bucket for frontend build artifacts
    const frontendBuildBucket = new s3.Bucket(this, 'FrontendBuildBucket', {
      bucketName: `${projectName}-builds-${this.account}-${this.region}`.substring(0, 63),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      versioned: false,
      publicReadAccess: false,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      eventBridgeEnabled: true,
    });

    // Add policy to allow Amplify access to frontend bucket
    frontendBuildBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'AllowAmplifyServiceAccess',
        effect: iam.Effect.ALLOW,
        principals: [new iam.ServicePrincipal('amplify.amazonaws.com')],
        actions: [
          's3:GetObject',
          's3:GetObjectAcl',
          's3:GetObjectVersion',
          's3:GetObjectVersionAcl',
          's3:PutObjectAcl',
          's3:PutObjectVersionAcl',
          's3:ListBucket',
          's3:GetBucketAcl',
          's3:GetBucketLocation',
          's3:GetBucketVersioning',
          's3:GetBucketPolicy',
          's3:GetBucketPolicyStatus',
          's3:GetBucketPublicAccessBlock',
          's3:GetEncryptionConfiguration',
        ],
        resources: [`${frontendBuildBucket.bucketArn}/*`, frontendBuildBucket.bucketArn],
        conditions: {
          StringEquals: { 'aws:SourceAccount': this.account },
        },
      })
    );

    // Create Lambda layers
    const earthEngineLayer = new lambda.LayerVersion(this, 'EarthEngineLayer', {
      code: lambda.Code.fromBucket(assetsBucket, 'layers/earth_engine_layer.zip'),
      compatibleRuntimes: [lambda.Runtime.PYTHON_3_13],
      description: 'Earth Engine API and dependencies',
    });

    const imageProcessingLayer = new lambda.LayerVersion(this, 'ImageProcessingLayer', {
      code: lambda.Code.fromBucket(assetsBucket, 'layers/image_processing.zip'),
      compatibleRuntimes: [lambda.Runtime.PYTHON_3_13],
      description: 'PIL, Shapely, and other image processing libraries',
    });

    // Create the Lambda function
    const forestClassificationLambda = new lambda.Function(this, 'ForestClassificationLambda', {
      runtime: lambda.Runtime.PYTHON_3_13,
      handler: 'lambda_function.lambda_handler',
      code: lambda.Code.fromBucket(assetsBucket, 'lambda-function-code.zip'),
      memorySize: 10240,
      timeout: cdk.Duration.seconds(900),
      environment: {
        S3_BUCKET: bucket.bucketName,
        ASSETS_BUCKET: assetsBucketName,
        EE_KEY_S3_KEY: geeCredentialsFile,
        EE_KEY_PATH: '/tmp/ee-key.json',
        DATA_PATH: '/tmp/data.json',
        OUTPUT_PREFIX: 'forest_classification',
        UPLOAD_EXPIRATION: '3600',
        DOWNLOAD_EXPIRATION: '86400',
        ALLOWED_ORIGINS: '*',
        DEBUG: 'false',
      },
      layers: [earthEngineLayer, imageProcessingLayer],
    });

    const functionUrl = forestClassificationLambda.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
    });

    // Grant Lambda permissions
    bucket.grantReadWrite(forestClassificationLambda);
    assetsBucket.grantRead(forestClassificationLambda);
    forestClassificationLambda.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['logs:CreateLogGroup', 'logs:CreateLogStream', 'logs:PutLogEvents'],
        resources: [`arn:aws:logs:${this.region}:${this.account}:log-group:/aws/lambda/*:*`],
      })
    );

    // Create IAM role for AmplifyDeployer Lambda
    const amplifyDeployerRole = new iam.Role(this, 'AmplifyDeployerRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole')],
      inlinePolicies: {
        AmplifyAccess: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                'amplify:StartDeployment',
                'amplify:GetApp',
                'amplify:GetBranch',
                'amplify:ListApps',
                'amplify:ListBranches',
                'amplify:GetJob',
                'amplify:ListJobs',
              ],
              resources: ['*'],
            }),
          ],
        }),
        S3Access: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                's3:GetObject',
                's3:GetObjectVersion',
                's3:GetObjectAcl',
                's3:GetObjectVersionAcl',
                's3:PutObjectAcl',
                's3:PutObjectVersionAcl',
                's3:ListBucket',
                's3:GetBucketAcl',
                's3:GetBucketLocation',
                's3:GetBucketVersioning',
                's3:PutBucketAcl',
                's3:ListBucketVersions',
                's3:GetBucketPolicy',
                's3:GetBucketPolicyStatus',
                's3:GetBucketPublicAccessBlock',
                's3:GetEncryptionConfiguration',
              ],
              resources: [frontendBuildBucket.bucketArn, `${frontendBuildBucket.bucketArn}/*`],
            }),
          ],
        }),
      },
    });

    // Create AmplifyDeployer Lambda
    const amplifyDeployer = new lambda.Function(this, 'AmplifyDeployer', {
      runtime: lambda.Runtime.PYTHON_3_13,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
import boto3
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

amplify_client = boto3.client('amplify')

def handler(event, context):
    try:
        logger.info(f"Received EventBridge event: {json.dumps(event)}")
        if event.get('source') == 'aws.s3' and event.get('detail-type') == 'Object Created':
            detail = event.get('detail', {})
            bucket_name = detail.get('bucket', {}).get('name')
            object_key = detail.get('object', {}).get('key')
            logger.info(f"Processing S3 object: {bucket_name}/{object_key}")
            if object_key and object_key.startswith('builds/') and object_key.endswith('.zip'):
                app_id = os.environ.get('AMPLIFY_APP_ID')
                if not app_id:
                    logger.error("AMPLIFY_APP_ID environment variable not set")
                    return {'statusCode': 400, 'body': json.dumps({'error': 'AMPLIFY_APP_ID not configured'})}
                branch_name = os.environ.get('AMPLIFY_BRANCH_NAME', 'main')
                logger.info(f"Starting Amplify deployment for app {app_id}, branch {branch_name}")
                response = amplify_client.start_deployment(
                    appId=app_id,
                    branchName=branch_name,
                    sourceUrl=f"s3://{bucket_name}/{object_key}"
                )
                job_id = response['jobSummary']['jobId']
                logger.info(f"✅ Started Amplify deployment with job ID: {job_id}")
                return {
                    'statusCode': 200,
                    'body': json.dumps({
                        'message': 'Deployment started successfully',
                        'jobId': job_id,
                        'appId': app_id,
                        'branchName': branch_name,
                        'sourceUrl': f"s3://{bucket_name}/{object_key}"
                    })
                }
            else:
                logger.info(f"Skipping non-build file: {object_key}")
        else:
            logger.info(f"Skipping non-S3 event: {event.get('source')}")
        return {'statusCode': 200, 'body': json.dumps({'message': 'Event processed, no action needed'})}
    except Exception as e:
        logger.error(f"❌ Error: {str(e)}")
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
`),
      timeout: cdk.Duration.minutes(5),
      role: amplifyDeployerRole,
      environment: {
        AMPLIFY_APP_ID: 'placeholder', // Updated by buildspec.yml
        AMPLIFY_BRANCH_NAME: amplifyBranchName,
      },
    });

    // Create EventBridge rule for S3 uploads
    const s3UploadRule = new events.Rule(this, 'S3BuildUploadRule', {
      eventPattern: {
        source: ['aws.s3'],
        detailType: ['Object Created'],
        detail: {
          bucket: { name: [frontendBuildBucket.bucketName] },
          object: { key: [{ prefix: 'builds/' }, { suffix: '.zip' }] },
        },
      },
    });

    s3UploadRule.addTarget(new targets.LambdaFunction(amplifyDeployer));
    amplifyDeployer.addPermission('AllowEventBridgeInvoke', {
      principal: new iam.ServicePrincipal('events.amazonaws.com'),
      sourceArn: s3UploadRule.ruleArn,
    });

    // Outputs
    new cdk.CfnOutput(this, 'LambdaFunctionArn', {
      value: forestClassificationLambda.functionArn,
      description: 'The ARN of the Forest Classification Lambda function',
    });

    new cdk.CfnOutput(this, 'S3BucketName', {
      value: bucket.bucketName,
      description: 'The name of the S3 bucket for input/output files',
    });

    new cdk.CfnOutput(this, 'FrontendBuildBucketName', {
      value: frontendBuildBucket.bucketName,
      description: 'S3 Bucket for Frontend Build Artifacts',
    });

    new cdk.CfnOutput(this, 'UploadInstruction', {
      value: `Upload your data files to s3://${bucket.bucketName}/uploads/ and ensure the GEE credentials file is at s3://${bucket.bucketName}/${geeCredentialsFile}`,
      description: 'Instructions for using the S3 bucket',
    });

    new cdk.CfnOutput(this, 'LambdaFunctionUrl', {
      value: functionUrl.url,
      description: 'The URL of the Forest Classification Lambda function for front-end integration',
    });

    new cdk.CfnOutput(this, 'AmplifyDeployerFunctionName', {
      value: amplifyDeployer.functionName,
      description: 'Amplify Deployer Lambda Function Name',
    });
  }
}