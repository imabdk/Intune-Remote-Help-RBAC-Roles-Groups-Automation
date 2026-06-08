# Intune Remote Help RBAC Roles Groups Automation

Automate the creation of custom RBAC roles, security groups, and role assignments for Microsoft Intune Remote Help.

## Overview

This PowerShell script creates four custom RBAC roles in Microsoft Intune, each with specific Remote Help permissions, along with corresponding Entra ID security groups. Optionally, it binds each role to its paired group automatically with `-AssignRoles`.

The script is idempotent - roles and groups that already exist are skipped. It also handles removal of everything it creates with `-Remove`.

**Multi Admin Approval (MAA)**: On tenants where Intune RBAC changes are gated by an approval policy, the script detects the pending approval response, reports it in the output, and lists pending items with instructions at the end of the run.

### Created Roles

| Role Name | Security Group | Use Case |
|-----------|---------------|----------|
| Remote Help - View Screen Only | `Intune-RemoteHelp-ViewScreenOnly` | Level 1 support, read-only assistance |
| Remote Help - Full Control | `Intune-RemoteHelp-FullControl` | Level 2/3 support, active troubleshooting |
| Remote Help - Elevation | `Intune-RemoteHelp-Elevation` | Elevated administrative tasks (UAC) |
| Remote Help - Unattended (Android) | `Intune-RemoteHelp-Unattended` | Managed Android dedicated device support |

All roles include base permissions:
- Remote Tasks - Offer remote assistance
- Remote Assistance Connector - Read

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

> **Note**: Both permissions are broad and cover the entire tenant. They are the minimum required for this script to create and remove roles and groups. If you run this as a one-off, consider revoking the consent afterwards under **Entra admin center > Identity > Enterprise applications > Microsoft Graph Command Line Tools > Permissions > User consent**.

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

If you ran without `-AssignRoles`, assign roles manually:
**Intune admin center > Tenant administration > Roles > Select role > Assignments**

## Documentation

- [Blog post - imab.dk](https://www.imab.dk/remote-help-is-included-in-e3-and-e5-from-july-1-heres-my-updated-powershell-script-to-roll-out-the-rbac/)
- [Planning for Remote Help with Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/remote-help-plan)
- [Role-based access control (RBAC) with Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control)

## Author

Martin Bengtsson - [imab.dk](https://imab.dk)
