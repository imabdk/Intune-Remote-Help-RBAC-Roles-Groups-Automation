# Intune Remote Help RBAC Roles Groups Automation

Automate the creation of custom RBAC roles, security groups, and role assignments for Microsoft Intune Remote Help.

## Overview

This PowerShell script creates five custom RBAC roles in Microsoft Intune, each with specific Remote Help permissions, along with corresponding Entra ID security groups. Optionally, it binds each role to its paired group automatically with `-AssignRoles`.

The script is idempotent - roles and groups that already exist are skipped. It also handles removal of everything it creates with `-Remove`.

**Multi Admin Approval (MAA)**: On tenants where Intune RBAC changes are gated by an approval policy, the script detects the pending approval response, reports it in the output, and lists pending items with instructions at the end of the run.

### Created Roles

| Role Name | Security Group | Use Case |
|-----------|---------------|----------|
| Remote Help - View Screen Only | `Intune-RemoteHelp-ViewScreenOnly` | Level 1 support, read-only assistance |
| Remote Help - Full Control | `Intune-RemoteHelp-FullControl` | Level 2/3 support, active troubleshooting |
| Remote Help - Elevation | `Intune-RemoteHelp-Elevation` | Elevated administrative tasks (UAC) |
| Remote Help - Unattended (Android) | `Intune-RemoteHelp-Unattended` | Managed Android dedicated device support |
| Remote Help - Unattended Remote Sign-In (Windows) | `Intune-RemoteHelp-UnattendedWindows` | Windows support without a user present |

All roles include base permissions:
- Remote Tasks - Offer remote assistance
- Remote Assistance Connector - Read

### Windows unattended remote sign-in

The built-in **Help Desk Operator** role does not include the *Remote Help app - Windows unattended control remote sign-in* permission, which is why a custom role is needed. Before this role is usable, the target devices must meet the prerequisites:

- Physical, corporate-owned, Intune-managed Windows devices. Devices marked as personal (BYOD) are not supported.
- The [Azure Virtual Desktop Agent](https://go.microsoft.com/fwlink/?linkid=2310011) and [Azure Virtual Desktop Agent Bootloader](https://go.microsoft.com/fwlink/?linkid=2311028) must be installed, in that order. Leave the registration token as `INVALID_TOKEN` when prompted.

Microsoft recommends scoping this role to the specific device groups that need unattended support. The script assigns with scope **All devices and All users**, so narrow the scope afterwards under **Tenant administration > Roles > Select role > Assignments**.

## Prerequisites

### Required Modules
```powershell
Install-Module Microsoft.Graph.DeviceManagement.Administration
Install-Module Microsoft.Graph.Groups
Install-Module Microsoft.Graph.Authentication
```

### Required Permissions
- `DeviceManagementRBAC.ReadWrite.All`
- `Group.ReadWrite.All`

### Account Requirements
- Global Administrator or Intune Administrator role

## Usage

### Create roles and groups
```powershell
.\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1
```

### Create roles, groups, and role assignments
```powershell
.\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -AssignRoles
```

Role assignments are scoped to **All devices and All users**. The assignment step is idempotent - existing assignments targeting the same group are skipped.

### Preview changes without making them
```powershell
.\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -AssignRoles -WhatIf
```

### Remove all roles, groups, and assignments
```powershell
.\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -Remove
```

Deleting a role definition cascades to its child role assignments automatically - no separate assignment cleanup needed.

### Suppress confirmation prompts
```powershell
.\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -AssignRoles -Confirm:$false
```

The script declares `ConfirmImpact = 'High'`, so with PowerShell's default `$ConfirmPreference` of `High` every create and delete prompts for confirmation. On a fresh tenant that is roughly 15 prompts - one per role, group, and assignment. Pass `-Confirm:$false` to run unattended, for example from a pipeline or scheduled task.

This applies to `-Remove` as well, so use it there deliberately:

```powershell
.\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -Remove -Confirm:$false
```

Run with `-WhatIf` first to see exactly what would be deleted. `-WhatIf` takes precedence over `-Confirm:$false` if both are supplied.

### Custom approval justification (MAA tenants)
```powershell
.\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -AssignRoles -ApprovalJustification "Remote Help rollout - July 2026"
```

## Multi Admin Approval (MAA)

Some tenants have an MAA policy enabled for the Role-based access control profile type. When this is the case, role and assignment creates/deletes are queued for a second admin to approve before taking effect.

The script handles this automatically. At the end of the run, pending items are listed with the path to approve them:

> **Intune admin center > Tenant administration > Multi Admin Approval > Received requests**

### Running on an MAA tenant with -AssignRoles

Because role assignments require an existing role ID, the script must be run twice on MAA-protected tenants:

1. **First run** - creates roles (queued in MAA) and Entra groups
2. Approve role creation requests in MAA, then **Complete** them under **My requests**
3. **Second run with `-AssignRoles`** - roles are found, assignments are created (may also queue in MAA)

## Post-Installation

After running the script, add support staff to the appropriate security groups:

- `Intune-RemoteHelp-ViewScreenOnly` - view-only helpers
- `Intune-RemoteHelp-FullControl` - full control helpers
- `Intune-RemoteHelp-Elevation` - helpers who need UAC elevation
- `Intune-RemoteHelp-Unattended` - Android unattended helpers
- `Intune-RemoteHelp-UnattendedWindows` - Windows unattended remote sign-in helpers

If you ran without `-AssignRoles`, assign roles manually:
**Intune admin center > Tenant administration > Roles > Select role > Assignments**

## Documentation

- [Blog post - imab.dk](https://www.imab.dk/remote-help-is-included-in-e3-and-e5-from-july-1-heres-my-updated-powershell-script-to-roll-out-the-rbac/)
- [Planning for Remote Help with Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/remote-help-plan)
- [Using Remote Help on Windows - unattended support](https://learn.microsoft.com/en-us/intune/remote-help/start-session?tabs=windows%2Cwindowsintune#unattended-support)
- [Deploying Remote Help with Microsoft Intune](https://learn.microsoft.com/en-us/intune/remote-help/deploy)
- [Role-based access control (RBAC) with Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control)

## Author

Martin Bengtsson - [imab.dk](https://imab.dk)
