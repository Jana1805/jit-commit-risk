#!/bin/bash
# Creates everything the API needs on AWS and starts it. Run in AWS CloudShell:
#   bash deploy/aws/launch.sh
# Safe to re-run: existing resources (tagged/named jit-commit-risk) are reused.
set -euo pipefail

NAME="jit-commit-risk"
REPO_URL="${REPO_URL:-https://github.com/Jana1805/jit-commit-risk.git}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
BUDGET_USD="${BUDGET_USD:-10}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || true)}}"
[ -n "$REGION" ] || { echo "Set AWS_REGION first, e.g. export AWS_REGION=us-east-1"; exit 1; }
export AWS_DEFAULT_REGION="$REGION"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "Region: $REGION"

existing=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$existing" ]; then
  echo "Instance already exists: $existing. Use redeploy.sh to update, or teardown.sh first."
  exit 1
fi

# --- API key (kept in SSM Parameter Store so you can read it again later) ---
if API_KEY=$(aws ssm get-parameter --name "/$NAME/api-key" --with-decryption \
      --query Parameter.Value --output text 2>/dev/null); then
  echo "Reusing API key from SSM /$NAME/api-key"
else
  API_KEY=$(openssl rand -hex 24)
  aws ssm put-parameter --name "/$NAME/api-key" --type SecureString --value "$API_KEY" >/dev/null
  echo "Created API key in SSM /$NAME/api-key"
fi

# --- Security group: only HTTP/HTTPS in, no SSH ---
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" != "None" ] || { echo "No default VPC in $REGION."; exit 1; }
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$NAME" --description "$NAME API (80/443)" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  for port in 80 443; do
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port "$port" --cidr 0.0.0.0/0 >/dev/null
  done
fi
echo "Security group: $SG_ID"

# --- IAM role so you can run commands on the box via SSM (no SSH keys) ---
ROLE="$NAME-ec2"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
if ! aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
  echo "Waiting for IAM instance profile to propagate..."
  sleep 15
fi

# --- Elastic IP so the URL never changes ---
ALLOC_ID=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$NAME" --query 'Addresses[0].AllocationId' --output text)
if [ "$ALLOC_ID" = "None" ]; then
  ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME}]" --query AllocationId --output text)
fi
PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
HOST="${PUBLIC_IP//./-}.sslip.io"
echo "Elastic IP: $PUBLIC_IP  ->  $HOST"

# --- Launch the instance ---
AMI_ID=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
USER_DATA=$(mktemp)
sed -e "s|__REPO_URL__|$REPO_URL|" -e "s|__HOST__|$HOST|" -e "s|__API_KEY__|$API_KEY|" \
  "$HERE/user-data.sh" > "$USER_DATA"

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$ROLE" \
  --metadata-options HttpTokens=required \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=10,VolumeType=gp3,DeleteOnTermination=true}' \
  --user-data "file://$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text)
rm -f "$USER_DATA"
echo "Instance: $INSTANCE_ID (waiting for it to start)"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" >/dev/null

# --- Monthly budget alert ---
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if ! aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$NAME" >/dev/null 2>&1; then
  read -r -p "Email for the \$$BUDGET_USD/month budget alert (Enter to skip): " EMAIL || true
  if [ -n "${EMAIL:-}" ]; then
    aws budgets create-budget --account-id "$ACCOUNT_ID" \
      --budget "{\"BudgetName\":\"$NAME\",\"BudgetLimit\":{\"Amount\":\"$BUDGET_USD\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
      --notifications-with-subscribers "[
        {\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80,\"ThresholdType\":\"PERCENTAGE\"},
         \"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]},
        {\"Notification\":{\"NotificationType\":\"FORECASTED\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":100,\"ThresholdType\":\"PERCENTAGE\"},
         \"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"$EMAIL\"}]}]"
    echo "Budget alert created."
  fi
fi

# --- Wait for the API to come up (docker build runs on first boot) ---
echo "Waiting for https://$HOST/health (first boot builds the image, ~3-6 min)..."
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "https://$HOST/health" 2>/dev/null; then
    echo; break
  fi
  sleep 10
done

cat <<EOF

==================================================================
 API URL : https://$HOST
 API key : $API_KEY
 Docs    : https://$HOST/docs

 VS Code settings:
   "jitRisk.apiUrl": "https://$HOST",
   "jitRisk.apiKey": "$API_KEY"

 Show key again : aws ssm get-parameter --name /$NAME/api-key --with-decryption --query Parameter.Value --output text
 Update after git push : bash deploy/aws/redeploy.sh
 Delete everything     : bash deploy/aws/teardown.sh
==================================================================
EOF
