# Lab 3 — User Manual

This manual walks you through deploying, testing, and cleaning up all lab resources step by step.

---

## Prerequisites

- **AWS Academy account** with active lab session (check the Learner Lab console)
- **AWS CLI v2** installed and configured with your Academy credentials
- **Docker** installed and running (Docker Desktop on Windows/Mac, or native on Linux)
- **Python 3.10+** with `pip` (for query generation and optional Lambda load testing)
- **Terminal/shell** access (bash recommended)

### Verify Prerequisites

```bash
# Check AWS credentials
aws sts get-caller-identity
# Expected: your Academy account ID and role

# Check Docker
docker --version

# Check Python
python3 --version
```

### Configure AWS Credentials

Your AWS Academy credentials are temporary. From the Learner Lab console:

1. Click **AWS Details** → **Show** next to "AWS CLI"
2. Copy the credentials block
3. Paste into `~/.aws/credentials` (replace existing `[default]` section)

```ini
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

Set the region:
```bash
aws configure set region us-east-1
```

> **Warning:** These credentials expire after ~4 hours. If commands start failing with `ExpiredTokenException`, repeat this step.

---

## Project Structure

```
lsc_aws/
├── workload/           # Application code (all environments share this)
│   ├── app.py          # Flask app with /search endpoint
│   ├── handler.py      # Lambda handler for zip deployment
│   ├── generate_dataset.py  # Deterministic dataset generation
│   ├── Dockerfile      # Dual-mode image (Lambda + Flask server)
│   ├── entrypoint.sh   # Mode switch script
│   └── requirements.txt
├── deploy/             # Deployment scripts (run in order)
│   ├── 00-config.sh    # Shared configuration variables
│   ├── 01-ecr.sh       # Build & push Docker image to ECR
│   ├── 02-lambda-zip.sh    # Deploy Lambda zip variant
│   ├── 03-lambda-container.sh  # Deploy Lambda container variant
│   ├── 04-fargate.sh   # Deploy ECS Fargate + ALB
│   ├── 05-ec2-app.sh   # Deploy EC2 app instance
│   ├── 06-loadgen.sh   # Deploy load generator instance
│   └── 99-cleanup.sh   # Tear down all resources
├── loadtest/           # Load testing scripts
│   ├── generate_query.py   # Generate fixed query vector
│   ├── query.json      # Pre-generated query payload
│   ├── lambda_loadtest.py  # Python load tester (for IAM-auth Lambda)
│   ├── scenario-a.sh   # Cold start test
│   ├── scenario-b.sh   # Warm throughput test
│   └── scenario-d.sh   # Burst test
├── results/            # Output directory for test results
└── docs/               # This documentation
```

---

## Step 1: Review Configuration

Open `deploy/00-config.sh` and verify:

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=<your-account-id>        # ← UPDATE THIS
export LAB_ROLE_ARN="arn:aws:iam::<your-account-id>:role/LabRole"
```

Find your account ID:
```bash
aws sts get-caller-identity --query 'Account' --output text
```

Find the LabRole ARN:
```bash
aws iam get-role --role-name LabRole --query 'Role.Arn' --output text
```

---

## Step 2: Build & Push Docker Image (ECR)

```bash
bash deploy/01-ecr.sh
```

**What it does:**
1. Creates an ECR repository named `lsc-knn-app`
2. Logs Docker into ECR
3. Builds the Docker image from `workload/Dockerfile`
4. Tags and pushes to ECR

**Verify:**
```bash
aws ecr describe-images --repository-name lsc-knn-app --query 'imageDetails[0].imageTags'
# Expected: ["latest"]
```

**If it fails:**
- "no basic auth credentials" → re-run `aws ecr get-login-password` (credentials may have expired)
- "Cannot connect to the Docker daemon" → start Docker Desktop or `systemctl start docker`

---

## Step 3: Deploy Lambda (Zip)

```bash
bash deploy/02-lambda-zip.sh
```

**What it does:**
1. Builds a NumPy Lambda layer using Docker
2. Publishes the layer to Lambda
3. Packages `handler.py`, `app.py`, `generate_dataset.py` into a zip
4. Creates the Lambda function with the NumPy layer, 512MB memory, X-Ray tracing
5. Creates a public Function URL

**The script outputs the Function URL.** Save it — you'll need it for testing.

**Verify:**
```bash
# If Function URL uses NONE auth (may not work on Academy accounts):
curl -X POST -H "Content-Type: application/json" -d @loadtest/query.json \
    <FUNCTION_URL>/search

# If you get a 403, use awscurl with IAM signing:
pip install awscurl
awscurl --service lambda -X POST -H "Content-Type: application/json" \
    -d @loadtest/query.json <FUNCTION_URL>/search

# Or test via CLI invoke:
aws lambda invoke --function-name lsc-knn-zip \
    --payload '{"body": "{\"query\": [0.1, 0.2, 0.3]}"}' /tmp/out.json
cat /tmp/out.json
```

> **Academy note:** Some Academy accounts block unauthenticated Lambda Function URLs via Service Control Policies. If you get `403 Forbidden`, switch to IAM auth:
> ```bash
> aws lambda update-function-url-config --function-name lsc-knn-zip --auth-type AWS_IAM
> ```
> Then use `awscurl` or the Python load tester (`loadtest/lambda_loadtest.py`) which handles SigV4 signing.

---

## Step 4: Deploy Lambda (Container)

```bash
bash deploy/03-lambda-container.sh
```

Same as Step 3 but uses the ECR container image instead of a zip package. Save the Function URL.

---

## Step 5: Deploy Fargate

```bash
bash deploy/04-fargate.sh
```

**What it does:**
1. Finds the default VPC and subnets
2. Creates security groups (ALB: port 80, Task: port 8080 from ALB only)
3. Creates an ECS cluster
4. Registers a Fargate task definition (0.5 vCPU, 1 GB, `MODE=server`)
5. Creates an ALB with a target group and listener
6. Creates an ECS service with 1 task
7. Waits for the service to stabilize (~2 minutes)

**The script outputs the ALB DNS name.** Save it.

**Verify:**
```bash
curl -X POST -H "Content-Type: application/json" -d @loadtest/query.json \
    http://<ALB_DNS>/search
```

**If it fails:**
- "Unable to assume role" → verify LabRole has `ecs:*` and `elasticloadbalancing:*` permissions
- Task stays in PROVISIONING → check CloudWatch logs at `/ecs/lsc-knn-task`
- 502 Bad Gateway from ALB → wait longer (task may still be starting); check target group health:
  ```bash
  aws elbv2 describe-target-health --target-group-arn <TG_ARN>
  ```

---

## Step 6: Deploy EC2 App Instance

```bash
bash deploy/05-ec2-app.sh
```

**What it does:**
1. Creates a security group allowing port 8080 and SSH (port 22)
2. Finds the latest Amazon Linux 2023 AMI
3. Checks for/creates an instance profile with LabRole
4. Launches a t3.small with a user-data script that installs Docker, pulls the image from ECR, and starts the container

**The script outputs the public IP.** Wait ~2 minutes for user-data to complete.

**Verify:**
```bash
curl -X POST -H "Content-Type: application/json" -d @loadtest/query.json \
    http://<EC2_IP>:8080/search
```

**If it fails:**
- Connection refused → user-data may still be running. SSH in and check:
  ```bash
  ssh ec2-user@<EC2_IP>
  sudo docker ps         # should show knn-app container
  sudo docker logs knn-app  # check for errors
  cloud-init status      # should show "done"
  ```
- "No instance profile" → create one manually in the IAM console or run:
  ```bash
  aws iam create-instance-profile --instance-profile-name LabInstanceProfile
  aws iam add-role-to-instance-profile --instance-profile-name LabInstanceProfile --role-name LabRole
  ```

---

## Step 7: Deploy Load Generator (Optional)

```bash
bash deploy/06-loadgen.sh
```

This deploys a t3.micro in the same region with `hey` pre-installed. This is optional — you can run tests from your local machine or any EC2 instance.

**If you use the load generator:**
```bash
ssh ec2-user@<LOADGEN_IP>
# Upload query.json and test scripts
hey -n 10 -c 5 -m POST -H "Content-Type: application/json" \
    -d '{"query": [0.1, ...]}' http://<EC2_IP>:8080/search
```

> **Tip:** For the most accurate measurements, run the load generator from within AWS (same region). Cross-region/internet latency adds a constant offset to all measurements.

---

## Step 8: Run Load Tests

### Generate the Query Vector

```bash
python3 loadtest/generate_query.py > loadtest/query.json
```

This creates a fixed 128-dimensional query vector (seed=42) used across all tests for reproducibility.

### Save Your Endpoint URLs

Create or edit `loadtest/endpoints.sh`:
```bash
export LAMBDA_ZIP_URL="https://<your-lambda-zip>.lambda-url.us-east-1.on.aws"
export LAMBDA_CONTAINER_URL="https://<your-lambda-container>.lambda-url.us-east-1.on.aws"
export FARGATE_URL="http://<your-alb-dns>"
export EC2_URL="http://<your-ec2-ip>:8080"
```

### Scenario A — Cold Start (requires 20-min idle)

```bash
# Ensure NO requests have been sent to Lambda for 20+ minutes
source loadtest/endpoints.sh
bash loadtest/scenario-a.sh "$LAMBDA_ZIP_URL" "$LAMBDA_CONTAINER_URL"
```

Or use the Python load tester for Lambda:
```bash
python3 loadtest/lambda_loadtest.py "$LAMBDA_ZIP_URL/search" \
    -n 30 --sequential-delay 1.0 --query-file loadtest/query.json \
    --output results/scenario-a-zip.json --label "Scenario A: Zip"
```

After running, check CloudWatch Logs for REPORT lines with Init Duration:
```bash
aws logs filter-log-events \
    --log-group-name "/aws/lambda/lsc-knn-zip" \
    --filter-pattern "Init Duration" \
    --start-time $(date -d '30 minutes ago' +%s000) \
    --query 'events[*].message' --output text
```

### Scenario B — Warm Throughput

```bash
source loadtest/endpoints.sh
bash loadtest/scenario-b.sh "$LAMBDA_ZIP_URL" "$LAMBDA_CONTAINER_URL" "$FARGATE_URL" "$EC2_URL"
```

For Lambda (if using IAM auth), use the Python load tester:
```bash
python3 loadtest/lambda_loadtest.py "$LAMBDA_ZIP_URL/search" \
    -n 500 -c 10 --query-file loadtest/query.json \
    --output results/scenario-b-lambda-zip-c10.json

python3 loadtest/lambda_loadtest.py "$LAMBDA_ZIP_URL/search" \
    -n 500 -c 50 --query-file loadtest/query.json \
    --output results/scenario-b-lambda-zip-c50.json
```

### Scenario C — Cost Analysis

No commands needed. See Assignment 4 in the Student Guide.

### Scenario D — Burst from Zero (requires 20-min idle)

```bash
# Ensure Lambda has been idle 20+ minutes
source loadtest/endpoints.sh
bash loadtest/scenario-d.sh "$LAMBDA_ZIP_URL" "$LAMBDA_CONTAINER_URL" "$FARGATE_URL" "$EC2_URL"
```

---

## Step 9: Collect Results

All `hey` output is saved to `results/`. Additionally collect:

```bash
# Export CloudWatch REPORT lines (Lambda cold start data)
aws logs filter-log-events \
    --log-group-name "/aws/lambda/lsc-knn-zip" \
    --filter-pattern "REPORT" \
    --start-time $(date -d '3 hours ago' +%s000) \
    --query 'events[*].message' --output text > results/cloudwatch-zip-reports.txt

aws logs filter-log-events \
    --log-group-name "/aws/lambda/lsc-knn-container" \
    --filter-pattern "REPORT" \
    --start-time $(date -d '3 hours ago' +%s000) \
    --query 'events[*].message' --output text > results/cloudwatch-container-reports.txt
```

Take screenshots of:
- AWS pricing pages (Lambda, Fargate, EC2) with the date visible
- X-Ray traces showing cold start Init segments (optional but recommended)

---

## Step 10: Clean Up

**Critical — do this before closing your session!**

```bash
bash deploy/99-cleanup.sh
```

This terminates EC2 instances, deletes the ECS service/cluster/ALB, removes Lambda functions and layers, deletes the ECR repository, and removes security groups.

**Verify cleanup:**
```bash
# Should show no running instances with lsc-knn tags
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=lsc-knn-*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text

# Should fail (repo deleted)
aws ecr describe-repositories --repository-names lsc-knn-app 2>&1 | head -1
```

---

## Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---|---|---|
| `ExpiredTokenException` | Academy session expired (~4hr) | Re-export credentials from Learner Lab console |
| `403 Forbidden` on Lambda URL | Academy SCP blocks public Lambda URLs | Switch to `--auth-type AWS_IAM` and use `awscurl` |
| Fargate task stuck in PROVISIONING | Image pull failure or role permissions | Check `/ecs/lsc-knn-task` CloudWatch logs; verify LabRole has ECR permissions |
| EC2 `Connection refused` on port 8080 | User-data still running | Wait 2 min; SSH in and check `docker ps` |
| ALB returns 502 | Target not yet healthy | Wait for health check to pass; check target group health |
| `hey` not found | Not installed on load generator | `wget https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64 -O hey && chmod +x hey` |
| Lambda zip import error | NumPy not in layer or handler imports Flask | Verify layer is attached; `handler.py` should NOT import Flask |
| Different `results` arrays across endpoints | Different dataset seed or query | All must use seed=0 for dataset and seed=42 for query |

### Checking Logs

```bash
# Lambda logs
aws logs tail /aws/lambda/lsc-knn-zip --since 10m

# Fargate/ECS logs
aws logs tail /ecs/lsc-knn-task --since 10m

# EC2 user-data output
ssh ec2-user@<IP> 'sudo cat /var/log/cloud-init-output.log'
```

### Re-running a Single Deployment Step

All deploy scripts are idempotent — they check for existing resources before creating new ones. You can safely re-run any script if it failed partway through.

To force re-creation, delete the specific resource first:
```bash
# Example: delete and re-create Lambda zip
aws lambda delete-function --function-name lsc-knn-zip
bash deploy/02-lambda-zip.sh
```
