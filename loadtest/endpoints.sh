#!/bin/bash
# Endpoint URLs for load testing
# Fill in after deploying with the URLs printed by each deploy script
export LAMBDA_ZIP_URL=""        # e.g. https://<id>.lambda-url.us-east-1.on.aws
export LAMBDA_CONTAINER_URL=""  # e.g. https://<id>.lambda-url.us-east-1.on.aws
export FARGATE_URL=""           # e.g. http://<alb-dns>.us-east-1.elb.amazonaws.com
export EC2_URL=""               # e.g. http://<public-ip>:8080
