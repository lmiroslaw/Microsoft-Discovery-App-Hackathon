#!/usr/bin/env bash
# Creates the resource groups, networking and AVD control-plane objects.
# Safe to re-run: every step is idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./config.sh

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Resource groups"
# NOTE: a resource group's own location is only metadata for the group itself.
# Resources inside it can live in any region - we deploy to both UK South and
# Sweden Central regardless of what these are set to.
az group create -n "$RG_PROD"  -l "$REGION_PRIMARY"   -o none
az group create -n "$RG_IMAGE" -l "$REGION_SECONDARY" -o none

echo "==> Virtual networks"
az network vnet create -g "$RG_PROD" -n "$VNET_PRIMARY" -l "$REGION_PRIMARY" \
  --address-prefix 10.1.0.0/16 --subnet-name "$SUBNET_PRIMARY" --subnet-prefix 10.1.1.0/24 -o none

az network vnet create -g "$RG_PROD" -n "$VNET_SECONDARY" -l "$REGION_SECONDARY" \
  --address-prefix 10.2.0.0/16 --subnet-name "$SUBNET_SECONDARY" --subnet-prefix 10.2.1.0/24 -o none

echo "==> AVD host pool"
# Personal + Automatic: each user is permanently bound to one VM, assigned on
# first connect unless we pin them explicitly in 03-assign-session-hosts.sh.
# The custom RDP properties are what enable Entra ID (AAD) auth to the session host.
az desktopvirtualization hostpool create \
  --resource-group "$RG_PROD" --name "$HOSTPOOL" --location "$REGION_PRIMARY" \
  --host-pool-type Personal \
  --personal-desktop-assignment-type Automatic \
  --load-balancer-type Persistent \
  --preferred-app-group-type Desktop \
  --start-vm-on-connect true \
  --max-session-limit 999999 \
  --custom-rdp-property "targetisaadjoined:i:1;enablerdsaadauth:i:1;" \
  -o none

echo "==> Application group"
HOSTPOOL_ID=$(az desktopvirtualization hostpool show -g "$RG_PROD" -n "$HOSTPOOL" --query id -o tsv)
az desktopvirtualization applicationgroup create \
  --resource-group "$RG_PROD" --name "$APPGROUP" --location "$REGION_PRIMARY" \
  --application-group-type Desktop --host-pool-arm-path "$HOSTPOOL_ID" -o none

echo "==> Workspace"
APPGROUP_ID=$(az desktopvirtualization applicationgroup show -g "$RG_PROD" -n "$APPGROUP" --query id -o tsv)
az desktopvirtualization workspace create \
  --resource-group "$RG_PROD" --name "$WORKSPACE" --location "$REGION_PRIMARY" \
  --application-group-references "$APPGROUP_ID" -o none

echo "==> Start VM on Connect permission"
# Without this the AVD service cannot power on a deallocated session host, and
# users get "We couldn't connect..." instead of their desktop starting.
# 9cdead84-a844-4324-93f2-b2e6bb768d07 is the well-known Azure Virtual Desktop app ID.
AVD_SP_ID=$(az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv 2>/dev/null || true)
if [[ -n "${AVD_SP_ID:-}" ]]; then
  az role assignment create \
    --assignee-object-id "$AVD_SP_ID" --assignee-principal-type ServicePrincipal \
    --role "Desktop Virtualization Power On Contributor" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD" \
    -o none 2>/dev/null || echo "    (already assigned)"
else
  echo "    WARNING: Azure Virtual Desktop service principal not found in this tenant."
  echo "    Start VM on Connect will not work until the role is assigned manually."
fi

echo
echo "Foundation ready."
echo "  Host pool:   $HOSTPOOL"
echo "  App group:   $APPGROUP"
echo "  Workspace:   $WORKSPACE"
echo "Next: build the golden image (see README section 3), then run 02-create-users.sh"
