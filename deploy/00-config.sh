#!/bin/bash
# Shared configuration for all deployment scripts

export AWS_REGION=us-east-1
export ACCOUNT_ID=YOUR_ACCOUNT_ID
export LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"

# ECR
export ECR_REPO_NAME=lsc-knn-app
export ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

# Lambda
export LAMBDA_ZIP_NAME=lsc-knn-zip
export LAMBDA_CONTAINER_NAME=lsc-knn-container
export LAMBDA_MEMORY=512
export LAMBDA_TIMEOUT=30

# ECS / Fargate
export ECS_CLUSTER_NAME=lsc-knn-cluster
export ECS_SERVICE_NAME=lsc-knn-service
export ECS_TASK_FAMILY=lsc-knn-task
export ECS_CONTAINER_NAME=knn-app

# ALB
export ALB_NAME=lsc-knn-alb
export TG_NAME=lsc-knn-tg

# EC2
export APP_SG_NAME=lsc-knn-app-sg
export LG_SG_NAME=lsc-knn-lg-sg

# Paths
export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKLOAD_DIR="${PROJECT_DIR}/workload"
export DEPLOY_DIR="${PROJECT_DIR}/deploy"

echo "Config loaded: ACCOUNT_ID=${ACCOUNT_ID}, REGION=${AWS_REGION}"
