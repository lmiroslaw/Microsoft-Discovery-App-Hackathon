#!/usr/bin/env bash
# Provisions session-host VMs from the golden image and registers them with the
# host pool. Re-runnable: existing VMs are skipped.
#
# Usage:
#   ./03-provision-session-hosts.sh 2 5  uksouth        # avd-hack-2 .. -5 in UK South
#   ./03-provision-session-hosts.sh 6 60 swedencentral  # scale-out in Sweden Central
#
# The registration token is generated once per run and expires in 2 days.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./config.sh

START="${1:?usage: $0 <start> <end> <region>}"
END="${2:?usage: $0 <start> <end> <region>}"
REGION="${3:?usage: $0 <start> <end> <region>}"

case "$REGION" in
  "$REGION_PRIMARY")   VNET="$VNET_PRIMARY";   SUBNET="$SUBNET_PRIMARY" ;;
  "$REGION_SECONDARY") VNET="$VNET_SECONDARY"; SUBNET="$SUBNET_SECONDARY" ;;
  *) echo "Unknown region '$REGION' - expected $REGION_PRIMARY or $REGION_SECONDARY" >&2; exit 1 ;;
esac

az account set --subscription "$SUBSCRIPTION_ID"

IMAGE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_IMAGE/providers/Microsoft.Compute/galleries/$GALLERY_NAME/images/$IMAGE_DEF/versions/$IMAGE_VERSION"
SUBNET_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD/providers/Microsoft.Network/virtualNetworks/$VNET/subnets/$SUBNET"

echo "==> Capacity check for $REGION"
az vm list-usage -l "$REGION" -o table | grep -iE "DASv5|Total Regional vCPUs" || true
echo "    Each VM of size $VM_SIZE consumes 8 vCPUs from the DASv5 family quota."

echo "==> Fresh host pool registration token"
EXPIRY=$(date -u -v+2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 days' +%Y-%m-%dT%H:%M:%SZ)
TOKEN=$(az desktopvirtualization hostpool update \
          --resource-group "$RG_PROD" --name "$HOSTPOOL" \
          --registration-info expiration-time="$EXPIRY" registration-token-operation=Update \
          --query "registrationInfo.token" -o tsv)

DSC_SETTINGS=$(mktemp)
trap 'rm -f "$DSC_SETTINGS"' EXIT
cat > "$DSC_SETTINGS" <<EOF
{
  "modulesUrl": "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_8-16-2021.zip",
  "configurationFunction": "Configuration.ps1\\\\AddSessionHost",
  "properties": {
    "hostPoolName": "$HOSTPOOL",
    "aadJoin": true,
    "registrationInfoToken": "$TOKEN",
    "sessionHostConfigurationLastUpdateTime": ""
  }
}
EOF

echo "==> Creating NICs and VMs $START..$END in $REGION"
for i in $(seq "$START" "$END"); do
  vm="${VM_NAME_PREFIX}-${i}"

  if az vm show -g "$RG_PROD" -n "$vm" -o none 2>/dev/null; then
    echo "    $vm exists - skipping"
    continue
  fi

  # Create the NIC explicitly. Letting 'az vm create' build it implicitly makes
  # the NIC inherit the RESOURCE GROUP's location rather than the VM's, which
  # fails with a cross-region "subnet not found" error.
  az network nic create -g "$RG_PROD" -n "${vm}-nic" \
    --subnet "$SUBNET_ID" --location "$REGION" -o none

  # --location is mandatory: az vm create otherwise defaults to the resource
  # group's location, which may not match the NIC's region.
  az vm create \
    -g "$RG_PROD" -n "$vm" \
    --location "$REGION" \
    --computer-name "$vm" \
    --image "$IMAGE_ID" \
    --size "$VM_SIZE" \
    --nics "${vm}-nic" \
    --admin-username "$VM_ADMIN_USER" \
    --admin-password "Vm$(openssl rand -hex 6)!Aa1" \
    --storage-sku Standard_LRS \
    --license-type Windows_Client \
    --assign-identity '[system]' \
    --os-disk-delete-option Detach \
    --no-wait -o none

  echo "    $vm submitted"
done

echo "==> Waiting for VMs to finish provisioning"
for i in $(seq "$START" "$END"); do
  az vm wait -g "$RG_PROD" -n "${VM_NAME_PREFIX}-${i}" --created 2>/dev/null || true
done

echo "==> Switching patch mode to AutomaticByOS"
# Images often carry patchMode=AutomaticByPlatform, which lets the platform hold
# the VM in a patching state and block Start VM on Connect. AutomaticByOS leaves
# patching to Windows Update inside the guest instead.
for i in $(seq "$START" "$END"); do
  az vm update -g "$RG_PROD" -n "${VM_NAME_PREFIX}-${i}" \
    --set osProfile.windowsConfiguration.patchSettings.automaticByPlatformSettings=null \
          osProfile.windowsConfiguration.patchSettings.patchMode=AutomaticByOS \
          osProfile.windowsConfiguration.patchSettings.assessmentMode=ImageDefault \
    --no-wait -o none
done

echo "==> Installing extensions (Entra join + AVD agent registration)"
for i in $(seq "$START" "$END"); do
  vm="${VM_NAME_PREFIX}-${i}"
  az vm extension set -g "$RG_PROD" --vm-name "$vm" \
    --name AADLoginForWindows --publisher Microsoft.Azure.ActiveDirectory --no-wait -o none
  az vm extension set -g "$RG_PROD" --vm-name "$vm" \
    --name DSC --publisher Microsoft.Powershell --version 2.73 \
    --settings "$DSC_SETTINGS" --no-wait -o none
  echo "    $vm extensions submitted"
done

echo
echo "Extensions install in the background (typically 5-10 minutes)."
echo "Check progress with: ./scripts/05-verify.sh"
