#!/usr/bin/env bash
# Creates the HackathonUsers group, grants it the two roles AVD needs, and
# creates test users. Group-level RBAC means new users need no role assignments
# of their own - membership alone grants access.
#
# Usage:
#   ./02-create-users.sh 1 5        # creates scientist001 .. scientist005
#   ./02-create-users.sh 6 60       # adds scientist006 .. scientist060
#
# Passwords are random, printed once, and written to a gitignored CSV.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./config.sh

START="${1:?usage: $0 <start-index> <end-index>}"
END="${2:?usage: $0 <start-index> <end-index>}"
CRED_FILE="users-credentials.csv"

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Security group: $GROUP_NAME"
if ! az ad group show -g "$GROUP_NAME" -o none 2>/dev/null; then
  az ad group create --display-name "$GROUP_NAME" --mail-nickname "$GROUP_NAME" -o none
fi
GROUP_ID=$(az ad group show -g "$GROUP_NAME" --query id -o tsv)

echo "==> Role assignments on the group (idempotent)"
# Desktop Virtualization User -> lets members see and launch the published desktop.
az role assignment create --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Desktop Virtualization User" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RG_PROD/providers/Microsoft.DesktopVirtualization/applicationgroups/$APPGROUP" \
  -o none 2>/dev/null || echo "    (Desktop Virtualization User already assigned)"

# Virtual Machine User Login -> required to RDP into an Entra-joined VM.
# Scoped to the resource group so it automatically covers every future session host.
az role assignment create --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Virtual Machine User Login" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD" \
  -o none 2>/dev/null || echo "    (Virtual Machine User Login already assigned)"

echo "==> Users scientist$(printf '%03d' "$START") .. scientist$(printf '%03d' "$END")"
[[ -f "$CRED_FILE" ]] || echo "userPrincipalName,temporaryPassword" > "$CRED_FILE"

for i in $(seq "$START" "$END"); do
  n=$(printf "%03d" "$i")
  upn="scientist${n}@${TENANT_DOMAIN}"

  if az ad user show --id "$upn" -o none 2>/dev/null; then
    echo "    scientist${n} exists - skipping"
    continue
  fi

  pw="Hack$(openssl rand -hex 4)!Aa1"
  uid=$(az ad user create \
          --display-name "Scientist $n" \
          --user-principal-name "$upn" \
          --password "$pw" \
          --force-change-password-next-sign-in true \
          --query id -o tsv)

  az ad group member add --group "$GROUP_NAME" --member-id "$uid" -o none
  echo "$upn,$pw" >> "$CRED_FILE"
  echo "    created scientist${n}"
done

echo
echo "Credentials written to $CRED_FILE (gitignored - distribute securely, then delete)."
