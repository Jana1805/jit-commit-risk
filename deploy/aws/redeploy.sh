#!/bin/bash
# Pulls the latest main on the instance, rebuilds and restarts the API. Run in CloudShell.
set -euo pipefail
NAME="jit-commit-risk"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$INSTANCE_ID" != "None" ] || { echo "No running $NAME instance."; exit 1; }

CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sed -i \"/^API_KEY=/d\" /opt/jit/api.env","/opt/jit/redeploy.sh"]' \
  --timeout-seconds 900 \
  --query Command.CommandId --output text)
echo "Redeploying on $INSTANCE_ID (command $CMD_ID)..."

until status=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
      --query Status --output text 2>/dev/null) && [[ "$status" != "Pending" && "$status" != "InProgress" ]]; do
  sleep 5
done

aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text | tail -20
[ "$status" = "Success" ]
