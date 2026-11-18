#!/bin/bash
# Deletes everything launch.sh created, so the deployment stops costing money. Run in CloudShell.
set -uo pipefail
NAME="jit-commit-risk"
ROLE="$NAME-ec2"

read -r -p "Delete the $NAME server, IP address and API key? Type yes: " answer
[ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }

IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  echo "Terminating $IDS..."
  aws ec2 wait instance-terminated --instance-ids $IDS
fi

for alloc in $(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$NAME" --query 'Addresses[].AllocationId' --output text); do
  aws ec2 release-address --allocation-id "$alloc" && echo "Released Elastic IP $alloc"
done

for sg in $(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME" --query 'SecurityGroups[].GroupId' --output text); do
  aws ec2 delete-security-group --group-id "$sg" && echo "Deleted security group $sg"
done

aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" 2>/dev/null
aws iam delete-instance-profile --instance-profile-name "$ROLE" 2>/dev/null
aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "Deleted IAM role $ROLE"

aws ssm delete-parameter --name "/$NAME/api-key" 2>/dev/null && echo "Deleted API key parameter"

echo "Done. (The budget alert, if created, is free and was kept.)"
