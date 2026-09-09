#!/usr/bin/env bash
# Creates the shared blob storage that session hosts read from and write to.
# Safe to re-run: every step is idempotent.
#
# Why private endpoints rather than a public container: tenants with the usual
# secure-storage guardrails force allowBlobPublicAccess=false, allowSharedKeyAccess=false
# and publicNetworkAccess=Disabled on every new storage account, and silently
# ignore attempts to turn them back on. That removes anonymous containers AND
# account-key SAS, so the only route to the data plane is a private endpoint
# inside each AVD VNet, authenticated with Entra ID.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./config.sh

az account set --subscription "$SUBSCRIPTION_ID"

ZONE="privatelink.blob.core.windows.net"
SA_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

echo "==> Storage account $STORAGE_ACCOUNT"
az storage account create -n "$STORAGE_ACCOUNT" -g "$RG_PROD" -l "$REGION_PRIMARY" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 -o none

echo "==> Container $STORAGE_CONTAINER"
# Created through ARM, not the data plane: with publicNetworkAccess=Disabled the
# blob endpoint is unreachable from outside the VNet, so `az storage container
# create` would fail from an operator laptop. Container creation is also a
# control-plane operation, which is not subject to that restriction.
az rest --method put \
  --url "https://management.azure.com$SA_ID/blobServices/default/containers/$STORAGE_CONTAINER?api-version=2023-05-01" \
  --body '{"properties":{"publicAccess":"None"}}' -o none

# One private endpoint per region, each with its OWN private DNS zone. The two
# AVD VNets are not peered, so a single zone linked to both would resolve the
# storage FQDN to one region's private IP for every VM - unreachable from the
# other region. A zone name can exist only once per resource group, hence the
# separate RG for the secondary zone.
deploy_pe() {
  local name=$1 vnet=$2 subnet=$3 region=$4 dns_rg=$5

  echo "==> Private endpoint $name ($region)"
  az network private-endpoint create -n "$name" -g "$RG_PROD" -l "$region" \
    --vnet-name "$vnet" --subnet "$subnet" \
    --private-connection-resource-id "$SA_ID" --group-id blob \
    --connection-name "$name-conn" -o none

  if [[ "$dns_rg" != "$RG_PROD" ]]; then
    az group create -n "$dns_rg" -l "$region" -o none
  fi

  az network private-dns zone create -g "$dns_rg" -n "$ZONE" -o none
  az network private-dns link vnet create -g "$dns_rg" --zone-name "$ZONE" \
    --name "link-$vnet" --registration-enabled false \
    --virtual-network "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD/providers/Microsoft.Network/virtualNetworks/$vnet" -o none

  # Auto-registers the A record for the endpoint's private IP in that zone.
  az network private-endpoint dns-zone-group create -g "$RG_PROD" \
    --endpoint-name "$name" --name default --zone-name blob \
    --private-dns-zone "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$dns_rg/providers/Microsoft.Network/privateDnsZones/$ZONE" -o none
}

deploy_pe "pe-blob-avd-primary"   "$VNET_PRIMARY"   "$SUBNET_PRIMARY"   "$REGION_PRIMARY"   "$RG_PROD"
deploy_pe "pe-blob-avd-secondary" "$VNET_SECONDARY" "$SUBNET_SECONDARY" "$REGION_SECONDARY" "$RG_DNS_SECONDARY"

echo "==> RBAC"
# Entra-only: there is no key or SAS-from-key path on this account. Re-running
# is fine - a duplicate assignment returns an error we deliberately swallow.
GROUP_ID=$(az ad group show --group "$GROUP_NAME" --query id -o tsv)
az role assignment create --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Storage Blob Data Reader" --scope "$SA_ID" -o none 2>/dev/null || true

if [[ -n "${UPLOADER_GROUP_NAME:-}" ]]; then
  UPLOADER_ID=$(az ad group show --group "$UPLOADER_GROUP_NAME" --query id -o tsv)
  az role assignment create --assignee-object-id "$UPLOADER_ID" --assignee-principal-type Group \
    --role "Storage Blob Data Contributor" --scope "$SA_ID" -o none 2>/dev/null || true
fi

echo
echo "==> Private IPs registered"
az network private-dns record-set a list -g "$RG_PROD" -z "$ZONE" \
  --query "[].{name:name,ip:join(',',aRecords[].ipv4Address)}" -o tsv | sed 's/^/  primary   /'
az network private-dns record-set a list -g "$RG_DNS_SECONDARY" -z "$ZONE" \
  --query "[].{name:name,ip:join(',',aRecords[].ipv4Address)}" -o tsv | sed 's/^/  secondary /'

echo
echo "Done. Reachable from a session host only:"
echo "  https://$STORAGE_ACCOUNT.blob.core.windows.net/$STORAGE_CONTAINER/<file>"
