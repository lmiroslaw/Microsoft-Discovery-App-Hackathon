# Microsoft Discovery App Hackathon — AVD Environment

Deployment guide and automation for a hackathon Azure Virtual Desktop environment giving up to
**60 users a personal Windows 11 desktop** preloaded with the Microsoft Discovery App, Azure CLI,
Git and Python.

Everything here is reproducible from scratch in a fresh tenant. No secrets, keys or credentials are
committed — tenant-specific values live in a gitignored `config.sh`.

---

## 1. Architecture

| Component | Value | Notes |
|---|---|---|
| Host pool | `hp-avd-hackathon` | Personal desktops, **Automatic** assignment, Persistent load balancing |
| Workspace | `hackathon-wkspace01` | What users subscribe to in the AVD client |
| Application group | `hp-avd-hackathon-DAG` | Desktop app group — carries the user-facing RBAC |
| Golden image | `DiscoveryGallery / DiscoveryApp-W11 / 1.0.0` | Azure Compute Gallery, replicated to both regions |
| Session hosts | `avd-hack-<n>` | `Standard_D8as_v5` (8 vCPU / 32 GiB), Entra ID joined |
| Identity group | `HackathonUsers` | Holds **all** RBAC — new users just join the group |
| Primary region | UK South | Lowest latency for London-based users |
| Overflow region | Sweden Central | Used once UK South quota is exhausted |

**Identity model — the key design decision.** Both required roles are granted to the `HackathonUsers`
group, never to individual users:

- `Desktop Virtualization User` on the **application group** — lets members see and launch the desktop.
- `Virtual Machine User Login` on the **resource group** — required to sign in to an Entra-joined VM,
  and scoped at RG level so it automatically covers every future session host.

Scaling from 5 to 60 users therefore needs **no new role assignments** — only group membership plus a VM.

### Users

| Purpose | Accounts |
|---|---|
| Platform administrators | 2 admin accounts (Global Administrator, activated via PIM) |
| Partner administrators | `partner1`, `partner2` |
| Test users | `scientist001` … `scientist005`, extensible to `scientist060` |

Each test user gets a dedicated personal-desktop VM.

---

## 2. Prerequisites

```bash
# Azure CLI + the AVD extension
brew install azure-cli
az extension add --name desktopvirtualization

# PowerShell + Microsoft Graph SDK — required ONLY for Conditional Access changes.
# The Azure CLI cannot perform those (see section 7).
brew install powershell
pwsh -NoProfile -Command 'Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Force'
```

Permissions needed:

- **Owner** or **Contributor + User Access Administrator** on the subscription
- **Global Administrator** in Entra ID — for creating users and changing Conditional Access.
  If it is PIM-eligible, activate it first (section 7).

Then:

```bash
git clone <this-repo> && cd Microsoft-Discovery-App-Hackathon
cp config.example.sh config.sh   # fill in subscription ID + tenant domain
az login
```

---

## 3. Deployment

### Step 1 — Foundation

Creates resource groups, both VNets, the host pool, application group and workspace.

```bash
./scripts/01-deploy-foundation.sh
```

### Step 2 — Golden image

Build once, then every session host is a clone. This is a manual step because the app
installation is interactive.

1. Create a Windows 11 **multi-session or Enterprise** VM named `vm-golden` in the image
   resource group.
2. RDP in and install the tooling:
   - Azure CLI — `winget install Microsoft.AzureCLI`
   - Git — `winget install Git.Git`
   - Python 3 — `winget install Python.Python.3.12`
3. Install the **Microsoft Discovery App** into `C:\msft-discovery-app`.

   A fixed path keeps the location identical on every session host, so shortcuts,
   scripts and support instructions work for all users.

   ```powershell
   New-Item -ItemType Directory -Path 'C:\msft-discovery-app' -Force

   # Install to the fixed path. The exact flag depends on the installer type:
   #   MSI      -> msiexec /i <installer>.msi INSTALLDIR="C:\msft-discovery-app" /qn
   #   InstallShield/NSIS -> <installer>.exe /S /D=C:\msft-discovery-app
   #   Portable -> simply expand the archive into the folder
   # Substitute the installer you were supplied with:
   Start-Process -Wait -FilePath msiexec.exe `
     -ArgumentList '/i','C:\temp\MicrosoftDiscoveryApp.msi','INSTALLDIR="C:\msft-discovery-app"','/qn'

   # Make it available to every user of the session host
   [Environment]::SetEnvironmentVariable(
     'Path',
     [Environment]::GetEnvironmentVariable('Path','Machine') + ';C:\msft-discovery-app',
     'Machine')

   # Desktop shortcut for all users (adjust the .exe name to match the install)
   $ws = New-Object -ComObject WScript.Shell
   $sc = $ws.CreateShortcut('C:\Users\Public\Desktop\Microsoft Discovery App.lnk')
   $sc.TargetPath = 'C:\msft-discovery-app\MicrosoftDiscoveryApp.exe'
   $sc.WorkingDirectory = 'C:\msft-discovery-app'
   $sc.Save()

   # Verify before continuing
   Get-ChildItem 'C:\msft-discovery-app'
   ```

   > Install **for all users / machine-wide**, not just the build account. A per-user
   > install lands in the local profile and disappears when the image is generalized.

4. Apply Windows Updates and reboot.
5. Generalize — **the VM is unusable afterwards, so snapshot it first if you want to keep it**:
   ```powershell
   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
   ```
6. Capture into the gallery, replicating to **both** regions:
   ```bash
   source ./config.sh
   az sig create -g "$RG_IMAGE" --gallery-name "$GALLERY_NAME" -l "$REGION_SECONDARY"

   az sig image-definition create \
     -g "$RG_IMAGE" --gallery-name "$GALLERY_NAME" --gallery-image-definition "$IMAGE_DEF" \
     --publisher Microsoft --offer DiscoveryApp --sku W11 \
     --os-type Windows --os-state Generalized --hyper-v-generation V2

   az vm deallocate -g "$RG_IMAGE" -n vm-golden
   az vm generalize -g "$RG_IMAGE" -n vm-golden

   az sig image-version create \
     -g "$RG_IMAGE" --gallery-name "$GALLERY_NAME" \
     --gallery-image-definition "$IMAGE_DEF" --gallery-image-version "$IMAGE_VERSION" \
     --virtual-machine "$(az vm show -g "$RG_IMAGE" -n vm-golden --query id -o tsv)" \
     --target-regions "$REGION_PRIMARY=3" "$REGION_SECONDARY=3"
   ```

> Replication must include every region you deploy session hosts into, or VM creation fails.

### Step 3 — Users and RBAC

```bash
./scripts/02-create-users.sh 1 5
```

Creates the group (if absent), grants both roles to it, creates `scientist001`–`scientist005`,
and writes passwords to `users-credentials.csv` (gitignored).

Management accounts are usually pre-existing — add them to the group:

```bash
source ./config.sh
for u in partner1 partner2; do
  az ad group member add --group "$GROUP_NAME" \
    --member-id "$(az ad user show --id "$u@$TENANT_DOMAIN" --query id -o tsv)"
done
```

### Step 4 — Session hosts

```bash
./scripts/03-provision-session-hosts.sh 1 5 uksouth
```

Per VM this creates a NIC, creates the VM from the golden image, then installs two extensions:
`AADLoginForWindows` (Entra join) and `DSC` (registers the VM with the host pool). Allow
5–10 minutes for the extensions to complete.

### Step 5 — Pin users to hosts (optional)

Automatic assignment binds whoever connects first to a free VM. To make it deterministic:

```bash
for i in 1 2 3 4 5; do
  ./scripts/04-assign-session-hosts.sh "scientist00$i" "$i"
done
```

### Step 6 — Verify

```bash
./scripts/05-verify.sh
```

Every host should report `status=Available`.

---

## 4. Scaling to 60 users

```bash
./scripts/02-create-users.sh 6 60
./scripts/03-provision-session-hosts.sh 6 12 uksouth        # up to UK South quota
./scripts/03-provision-session-hosts.sh 13 60 swedencentral # overflow
```

### Quota is the binding constraint

`Standard_D8as_v5` draws from the **Standard DASv5 Family vCPU** quota, at 8 vCPUs per VM.
Default regional limit is **100 vCPUs — only 12 VMs**.

| Option | vCPUs for 60 VMs | Verdict |
|---|---|---|
| `Standard_D8as_v5` (8 vCPU) | 480 | Needs a large quota increase |
| `Standard_D4as_v5` (4 vCPU) | 240 | **Recommended** — ample for one interactive desktop |
| `Standard_D2as_v5` (2 vCPU) | 120 | Minimum supported for Windows 11 personal desktops |

Check and raise before provisioning:

```bash
az vm list-usage -l uksouth -o table | grep -i DASv5
```

Request increases in **Portal → Subscriptions → Usage + quotas → Compute**. Approval is not instant —
raise it well ahead of the event.

### Region choice and latency

Measured guidance for **London-based users**:

| Region | Round-trip latency | Assessment |
|---|---|---|
| UK South | < 10 ms | Ideal — datacenters are in the London area |
| Sweden Central | ~25–45 ms | Well within AVD's "good" band (< 50 ms) |

Both are comfortably under Microsoft's 150 ms threshold. Sweden Central is fine for standard
dev/office/data-science work; UK South is preferable for latency-sensitive graphical workloads.
**Validate with one test VM before committing to a bulk regional deployment.**

Enabling **RDP Shortpath** (UDP transport) further improves responsiveness on the longer path.

---

## 5. End-user login instructions

Share this with participants.

1. Open the AVD client:
   - **Web:** <https://client.wvd.microsoft.com/arm/webclient>
   - **Desktop:** install the **Windows App** (formerly Remote Desktop client), then add a
     work or school account.
2. Sign in with your `scientistNNN@<tenant>.onmicrosoft.com` account and the temporary password
   you were issued.
3. Complete MFA if prompted.
4. Set a new password when asked — required on first sign-in.
5. Open the workspace **hackathon-wkspace01** and double-click **Default Desktop**.
6. Your personal VM starts automatically (`Start VM on Connect` is enabled), so the first
   connection of the day takes an extra minute or two.

---

## 6. Operations

```bash
./scripts/05-verify.sh                                   # health check

az vm deallocate -g hackathon-prod -n avd-hack-3      # stop billing on one host
az vm start      -g hackathon-prod -n avd-hack-3

# Stop every session host overnight (compute charges stop; disks still bill)
source ./config.sh
az vm list -g "$RG_PROD" --query "[].name" -o tsv \
  | xargs -P 10 -I {} az vm deallocate -g "$RG_PROD" -n {} --no-wait
```

`Start VM on Connect` means deallocated hosts wake automatically when a user connects — safe to
shut everything down between sessions.

---

## 7. Conditional Access and PIM

Hackathon guest accounts are often blocked by tenant Conditional Access policies — typically
surfacing as **AADSTS53003** ("You cannot access this right now").

### Activate Global Administrator (PIM)

Entra admin center → **Identity Governance → Privileged Identity Management → My roles →
Directory roles → Global Administrator → Activate**.

Afterwards **re-run `az login`**. Access tokens are minted with role claims baked in, so a token
issued before activation will keep failing with `AccessDenied` until it is refreshed.

### Toggle the blocking policies

`scripts/ca_policy_toggle.ps1` disables, re-enables or deletes policies by name. Default match is
"Security info registration" and "Multifactor authentication".

```bash
pwsh -NoProfile -File ./scripts/ca_policy_toggle.ps1 -Action list           # read-only
pwsh -NoProfile -File ./scripts/ca_policy_toggle.ps1 -Action disable        # dry run
pwsh -NoProfile -File ./scripts/ca_policy_toggle.ps1 -Action disable -Apply
pwsh -NoProfile -File ./scripts/ca_policy_toggle.ps1 -Action enable  -Apply # revert
```

Flags: `-DeviceCode` for headless sessions, `-Pattern 'name fragment'` to target other policies.
Nothing changes without `-Apply`, and matched policies are backed up to `ca_policy_backups/`
(gitignored) beforehand.

> **Security warning.** Disabling these removes tenant-wide MFA enforcement and protection on
> security-info registration, opening an MFA-registration hijack path. Acceptable for a
> time-boxed hackathon in an isolated tenant. **Re-enable immediately afterwards.**

**Why PowerShell and not `az`?** Conditional Access writes require the
`Policy.ReadWrite.ConditionalAccess` Graph scope. The Azure CLI is a Microsoft first-party
application that cannot be granted it — attempting to do so returns `AADSTS65002`
(preauthorization required). Graph PowerShell can consent to it interactively.
`scripts/ca_policy_toggle.py` remains useful for read-only listing via the CLI.

---

## 8. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `InvalidResourceReference` / "subnet not found" on VM create | `az vm create` defaults to the **resource group's** location, not the NIC's. Always pass `--location`. The provisioning script does this. |
| Desktop won't start; VM stays deallocated | The AVD service principal is missing **Desktop Virtualization Power On Contributor**. See "Start VM on Connect" below. |
| VM start blocked or very slow | `patchMode=AutomaticByPlatform` lets the platform hold the VM for patching. Switch to `AutomaticByOS` — see below. |
| Prompted for credentials twice, or connection rejected after signing in | Host pool is missing the Entra auth RDP properties. See "Single sign-on" below. |
| `AADSTS53003` at sign-in | Conditional Access block — see section 7. |
| `AccessDenied` on Graph writes despite being Global Admin | Token predates PIM activation. Re-run `az login`. |
| `AADSTS65002` when using `az login --scope` | The CLI cannot request arbitrary Graph scopes. Use Graph PowerShell. |
| Session host missing from the pool | Check the DSC extension: `az vm extension show -g <rg> --vm-name <vm> -n DSC --query provisioningState`. Registration tokens expire — re-run the provisioning script to mint a fresh one. |
| User sees no desktop after signing in | Confirm `HackathonUsers` membership; RBAC propagation can take a few minutes. |
| `PermissionScopeNotGranted` reading PIM data | The CLI lacks `RoleManagement.Read.Directory`. Use the portal. |
| `Standard DASv5 Family vCPUs` quota exceeded | Request an increase or use a smaller VM size — see section 4. |

### Start VM on Connect

Deallocated hosts only wake automatically if the Azure Virtual Desktop service principal holds
**Desktop Virtualization Power On Contributor** on the resource group. `01-deploy-foundation.sh`
assigns this, but verify if desktops fail to launch:

```bash
source ./config.sh
az role assignment list --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD" \
  --query "[?contains(roleDefinitionName,'Power On')].{role:roleDefinitionName, type:principalType}" -o json

# Assign if missing (9cdead84-... is the Azure Virtual Desktop first-party app)
az role assignment create \
  --assignee-object-id "$(az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Desktop Virtualization Power On Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD"
```

Also confirm the feature is enabled on the host pool:

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD/providers/Microsoft.DesktopVirtualization/hostPools/$HOSTPOOL?api-version=2024-04-03" \
  --query "properties.{startOnConnect:startVMOnConnect, type:hostPoolType, assignment:personalDesktopAssignmentType}" -o json
```

### Windows Update blocking VM start

Golden images frequently carry `patchMode=AutomaticByPlatform`, which allows the platform to hold
a VM in a patching state and prevent it starting on connect. `03-provision-session-hosts.sh` now
switches new hosts to `AutomaticByOS`. To fix an existing host:

```bash
az vm update -g hackathon-prod -n avd-hack-1 \
  --set osProfile.windowsConfiguration.patchSettings.automaticByPlatformSettings=null \
        osProfile.windowsConfiguration.patchSettings.patchMode=AutomaticByOS \
        osProfile.windowsConfiguration.patchSettings.assessmentMode=ImageDefault

az vm start -g hackathon-prod -n avd-hack-1
```

### Single sign-on to Entra-joined hosts

The host pool must carry both RDP properties, or users authenticate twice — once to AVD and again
to the VM — and Entra-joined hosts may reject the second attempt. `01-deploy-foundation.sh` sets
these at creation; to repair an existing pool:

```bash
az rest --method patch \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_PROD/providers/Microsoft.DesktopVirtualization/hostPools/$HOSTPOOL?api-version=2024-04-03" \
  --body '{"properties":{"customRdpProperty":"targetisaadjoined:i:1;enablerdsaadauth:i:1;"}}'
```

`targetisaadjoined:i:1` tells the client the host is Entra-joined; `enablerdsaadauth:i:1` lets the
same token satisfy both hops.

### Reading recent failures

Control-plane errors that never surface in the client show up in the activity log:

```bash
az monitor activity-log list -g hackathon-prod --offset 1h \
  --query "[].{time:eventTimestamp, op:operationName.value, status:status.value, caller:caller, msg:properties.statusMessage}" -o json
```


---

## 9. Teardown

```bash
source ./config.sh
az group delete -n "$RG_PROD"  --yes --no-wait
az group delete -n "$RG_IMAGE" --yes --no-wait   # omit to keep the golden image

# Re-enable Conditional Access policies BEFORE tearing down
pwsh -NoProfile -File ./scripts/ca_policy_toggle.ps1 -Action enable -Apply

# Remove test users
for i in $(seq -w 1 60); do
  az ad user delete --id "scientist0$i@$TENANT_DOMAIN" 2>/dev/null || true
done
```

Also deactivate the PIM Global Administrator role, or let it expire.

---

## Repository layout

```
config.example.sh                     Template — copy to config.sh (gitignored)
scripts/
  01-deploy-foundation.sh             RGs, VNets, host pool, app group, workspace
  02-create-users.sh                  Group, RBAC, users  [start] [end]
  03-provision-session-hosts.sh       NICs, VMs, extensions  [start] [end] [region]
  04-assign-session-hosts.sh          Pin a user to a VM  [user] [vm-suffix]
  05-verify.sh                        Health check
  ca_policy_toggle.ps1                Conditional Access toggle (read + write)
  ca_policy_toggle.py                 Conditional Access listing (read-only)
```

### Security notes for contributors

- `config.sh`, `users-credentials.csv` and `ca_policy_backups/` are gitignored — keep it that way.
- Passwords are randomly generated at runtime and never committed. Distribute securely and
  delete the CSV once handed out.
- All accounts are created with `--force-change-password-next-sign-in`.
- VM local administrator passwords are random and discarded — access is via Entra ID, so they
  are never needed.
