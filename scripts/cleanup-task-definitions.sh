#!/usr/bin/env bash
# Видаляє всі ревізії task definition проєкту.
#
# Навіщо: кожен деплой з GitHub Actions реєструє нову ревізію. Terraform знає
# лише про першу (свою), тому `terraform destroy` решту не прибирає.
# Запускати ПІСЛЯ `terraform destroy`:
#
#   ./scripts/cleanup-task-definitions.sh [family] [region]
#
set -euo pipefail

FAMILY="${1:-smartbite}"
REGION="${2:-${AWS_REGION:-eu-central-1}}"

# 1. Активні ревізії → INACTIVE
for arn in $(aws ecs list-task-definitions --region "$REGION" --family-prefix "$FAMILY" \
               --status ACTIVE --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --region "$REGION" --task-definition "$arn" > /dev/null
  echo "deregistered $arn"
done

# 2. INACTIVE → видалення
for arn in $(aws ecs list-task-definitions --region "$REGION" --family-prefix "$FAMILY" \
               --status INACTIVE --query 'taskDefinitionArns[]' --output text); do
  aws ecs delete-task-definitions --region "$REGION" --task-definitions "$arn" > /dev/null
  echo "deleted $arn"
done

echo "Done."
