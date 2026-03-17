#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 6: Load Generator Instance (t3.micro) ==="

# --- Get default VPC ---
VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")

# --- Security Group ---
echo "Creating load generator security group..."
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${LG_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$LG_SG_NAME" \
        --description "Load generator for k-NN lab" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        --region "$AWS_REGION"
fi
echo "Security Group: ${SG_ID}"

# --- Find AMI ---
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$AWS_REGION")

# --- User data ---
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
curl -sL https://github.com/hatoo/oha/releases/latest/download/oha-linux-amd64 -o /usr/local/bin/oha
chmod +x /usr/local/bin/oha
yum install -y python3 jq
USERDATA
)

# --- Check for existing instance ---
EXISTING_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=lsc-knn-loadgen" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text \
    --region "$AWS_REGION" 2>/dev/null)

if [ "$EXISTING_ID" != "None" ] && [ -n "$EXISTING_ID" ]; then
    echo "Instance already running: ${EXISTING_ID}"
    INSTANCE_ID="$EXISTING_ID"
else
    # Check for instance profile for load gen
    INSTANCE_PROFILE_NAME=""
    if aws iam get-instance-profile --instance-profile-name LabInstanceProfile &>/dev/null; then
        INSTANCE_PROFILE_NAME="LabInstanceProfile"
    fi

    echo "Launching load generator..."
    LAUNCH_ARGS=(
        --image-id "$AMI_ID"
        --instance-type t3.micro
        --security-group-ids "$SG_ID"
        --user-data "$USER_DATA"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=lsc-knn-loadgen}]"
        --query 'Instances[0].InstanceId' --output text
        --region "$AWS_REGION"
    )
    if [ -n "$INSTANCE_PROFILE_NAME" ]; then
        LAUNCH_ARGS+=(--iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}")
    fi

    INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_ARGS[@]}")
fi
echo "Instance ID: ${INSTANCE_ID}"

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text \
    --region "$AWS_REGION")

echo "=== Load Generator done. Public IP: ${PUBLIC_IP} ==="
echo "SSH: ssh ec2-user@${PUBLIC_IP}"
echo "NOTE: Wait ~1 minute for user-data to complete, then verify: ssh ec2-user@${PUBLIC_IP} 'oha --version'"
