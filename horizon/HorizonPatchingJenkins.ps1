<#
    HORIZON VDI  ·  3-PHASE AUTOMATED PATCHING

    Written by Bill Gernert

    THE STORY
    The companion to my Horizon monitoring script. The monitor watches the
    pools; this one does the work. It automates the whole patch cycle for a
    VMware / Omnissa Horizon VDI environment: snapshot the gold images, push
    them to TEST, let them bake, then promote the tested image to PRODUCTION.
    Driven entirely from Jenkins parameters, so the change window runs on a
    schedule without anyone sitting at a desk.

    WHY THIS EXISTS  ·  THE SNAPSHOT MODEL
    In production I run five gold images, and you only want to keep a small
    number of snapshots per image before it gets unwieldy (I hold two).
    Doing this by hand across five images and many pools, every patch cycle,
    is slow and easy to get wrong. This automation made it repeatable and
    safe.

    The snapshot for each image is named with today's date (e.g. Jul06).
    Every image uses the same snapshot name for a given cycle, which is what
    lets the push logic stay simple: the script reads the latest snapshot
    from the first image and pushes that same-named snapshot across all the
    pools.

    THE FLOW
    Phase 1 snapshots the images and pushes them to TEST. You then log in to
    the test desktops and run your checks to validate the new image. Once it
    passes, Phase 2 trims old snapshots (keeping two) and refreshes TEST.
    Phase 3 promotes the validated image to PRODUCTION, with the
    scheduled-window pools deferred to a start time you provide.

      Phase 1  -  Take snapshots, push to TEST
      Phase 2  -  Trim snapshots (keep 2), push to TEST
      Phase 3  -  Push to PRODUCTION (LATE-prefixed pools deferred to $StartTime)

    RUNNING IT FROM JENKINS
    Set this up as a Jenkins freestyle job with a Choice parameter for the
    phase (the three Environment values used below) and a String parameter
    for the Phase 3 scheduled start time. Pick the phase, and for Phase 3
    provide the time; the job passes them in as $env:Environment and
    $env:StartTime.

    THE FAILSAFE  ·  READ THIS
    Phase 1 aborts the entire run if ANY gold image is powered on. This is
    deliberate. Snapshotting a running parent image corrupts it, and a bad
    parent image ruins the day for everyone downstream. The script assumes
    you have prepared and powered off your parent images first. Better to
    stop and fix it than to patch on top of a broken image.

    A NOTE ON POOL NAMES
    Matching is done on the Horizon POOL ID (the internal name), not the
    display name that users see. The two can differ. The conventions below
    (TEST in the id, LATE prefix for the deferred production pools) refer to
    the pool id.

    COMPATIBILITY
    Tested up to Horizon 8.2503.
    Built on VMware.VimAutomation.Core (vCenter / PowerCLI) and the Horizon
    modules (VMware.VimAutomation.HorizonView for Connect-HVServer, plus the
    Hv.Helper advanced functions). Since the Omnissa split these are
    rebranded Omnissa.* but the cmdlets are unchanged, so this works with
    either generation. Docs: developer.omnissa.com/horizon-powercli

    SETUP
    Sections marked "CHANGE" must be set for your environment before first
    run. Pools are matched by naming convention on the pool id: TEST for test
    pools, LATE prefix for the scheduled-window production pools. Credentials
    come from your secret store, never hardcoded.
#>


# CHANGE - GET CREDS FROM YOUR VAULT / SECRET STORE HERE
# Retrieve $username and the plaintext password for your Horizon/vCenter
# service account from your secret manager. Never hardcode credentials.
$username = "svc-horizon-patching@yourdomain.com"
# $password = <plaintext password pulled from your secret store>
$securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$creds = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $username, $securePassword

# CHANGE - SET YOUR SERVER NAMES HERE
$vCenterServer  = "vcenter.yourdomain.com"
$horizonServer  = "horizon.yourdomain.com"

# Jenkins passes these in as job parameters
$Environment = $env:Environment   # which phase to run (see header)
$StartTime   = $env:StartTime     # scheduled start time for the ADMIN production pools


# ---- Connect to vCenter, get gold-image VMs and the latest snapshot ----
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
Connect-VIServer $vCenterServer -Credential $creds | Out-Null

# CHANGE - the resource pool that holds your gold/parent images
$resourcePool = Get-ResourcePool -Name "Gold Images"

# Get all VMs within the resource pool
$VMsInResourcePool = Get-VM -Location $resourcePool

# Use the first gold image to determine the latest snapshot name to push
$firstVM = $VMsInResourcePool[0]
$latestSnapshot = Get-Snapshot -VM $firstVM | Sort-Object -Property Created -Descending | Select-Object -First 1
$ParentSnapshot = $latestSnapshot.Name


# ---- Connect to Horizon, get pool names, sort into TEST and PROD ----
Connect-HVServer -Server $horizonServer -User $username -Password $password

# Retrieve pool names from Horizon
$desktopNames = Get-HVPoolSummary -UserAssignment Floating -PoolType AUTOMATED |
                Select-Object -ExpandProperty DesktopSummaryData |
                Select-Object -ExpandProperty Name

# Split into Production, Test, and the LATE-prefixed scheduled-window pools.
# NOTE: matching is on the pool ID (internal name), not the display name users see.
$ProductionDesktops  = $desktopNames -split "`n" | Where-Object { $_ -notmatch 'Test' -and $_ -notmatch '^late' -and $_ -notmatch '^dev' }
$TestDesktops        = $desktopNames -split "`n" | Where-Object { $_ -match 'Test'  -and $_ -notmatch '^dev' }
$LateWindowDesktops  = $desktopNames | Where-Object { $_ -match '^Late' -and $_ -notmatch 'Test' -and $_ -notmatch '^dev' }


# ================= PHASE 2 : Trim snapshots, push to TEST =================
if ($Environment -eq "Phase2-RemoveSnapshots-Push-to-Test-Pools")
{
    ForEach ($TestDesktop in $TestDesktops)
    {
        # Iterate through each gold image
        foreach ($vm in $VMsInResourcePool) {
            # Keep the two most recent snapshots, delete the rest
            $snapshots = Get-VM -Name $vm.Name | Get-Snapshot | Sort-Object Created -Descending
            if ($snapshots.Count -gt 2) {
                $snapshotsToDelete = $snapshots[2..($snapshots.Count - 1)]
                foreach ($snapshot in $snapshotsToDelete) {
                    Write-Host "Deleting snapshot $($snapshot.Name) from $($vm.Name)"
                    Remove-Snapshot -Snapshot $snapshot -Confirm:$false
                }
            }
        }
        # Push the image to the test pool after trimming snapshots
        $parentImage = (Get-HVPool -PoolName $TestDesktop).AutomatedDesktopData.VirtualCenterNamesData.ParentVmPath -split "/" | Select-Object -Last 1
        Start-HVPool -SchedulePushImage -Pool $TestDesktop -LogoffSetting WAIT_FOR_LOGOFF -ParentVM $parentImage -SnapshotVM $ParentSnapshot
    }
}

# ================= PHASE 3 : Push to PRODUCTION =================
elseif ($Environment -eq "Phase3-Push-to-Production-Pools")
{
    # Standard production pools: push immediately
    ForEach ($ProductionDesktop in $ProductionDesktops)
    {
        $parentImage = (Get-HVPool -PoolName $ProductionDesktop).AutomatedDesktopData.VirtualCenterNamesData.ParentVmPath -split "/" | Select-Object -Last 1
        Start-HVPool -SchedulePushImage -Pool $ProductionDesktop -LogoffSetting WAIT_FOR_LOGOFF -ParentVM $parentImage -SnapshotVM $ParentSnapshot
    }

    # LATE-prefixed pools: schedule for the defined maintenance window ($StartTime)
    ForEach ($LateWindowDesktop in $LateWindowDesktops)
    {
        $parentImage = (Get-HVPool -PoolName $LateWindowDesktop).AutomatedDesktopData.VirtualCenterNamesData.ParentVmPath -split "/" | Select-Object -Last 1
        Start-HVPool -SchedulePushImage -Pool $LateWindowDesktop -LogoffSetting WAIT_FOR_LOGOFF -ParentVM $parentImage -SnapshotVM $ParentSnapshot -StartTime "$($StartTime)"
    }
}

# ================= PHASE 1 : Take snapshots, push to TEST =================
elseif ($Environment -eq "Phase1-TakeSnapshots-Push-to-Test-Pools")
{
    # Snapshot name is the month + day, e.g. Jul06
    $today = Get-Date
    $ParentSnapshot = $today.ToString('MMM') + $today.Day.ToString("00")

    # Get all gold images
    $VMsInResourcePool = Get-VM -Location $resourcePool

    # FAILSAFE: if ANY gold image is powered on, abort the whole run.
    # Snapshotting a running parent image corrupts it. Power off all gold
    # images before patching. Better to stop here than patch a broken image.
    foreach ($vm in $VMsInResourcePool)
    {
        Write-Host "Checking power state for VM $($vm.Name)"
        $powerState = (Get-VM -Name $vm.Name).PowerState

        if ($powerState -eq "PoweredOn") {
            Write-Host "FAILSAFE: $($vm.Name) is powered on. Aborting the entire run."
            Write-Host "Snapshotting a running parent image will corrupt it. Power off all gold images before patching."
            Exit 1
        }

        Write-Host "Creating snapshot for VM $($vm.Name)"
        New-Snapshot -VM $vm -Name $ParentSnapshot -Description "Patching snapshot (automated)"
    }

    # Stagger the pushes to the test pools so they don't all fire at once.
    # First pool starts 7 minutes out, each subsequent pool 5 minutes later.
    $currentTime = Get-Date -Format "HH:mm"
    $offset = 7

    ForEach ($TestDesktop in $TestDesktops)
    {
        $currentTimeDT = [DateTime]::ParseExact($currentTime, "HH:mm", $null)
        $startTime = $currentTimeDT.AddMinutes($offset).ToString("HH:mm")

        $parentImage = (Get-HVPool -PoolName $TestDesktop).AutomatedDesktopData.VirtualCenterNamesData.ParentVmPath -split "/" | Select-Object -Last 1
        Start-HVPool -SchedulePushImage -Pool $TestDesktop -LogoffSetting WAIT_FOR_LOGOFF -ParentVM $parentImage -SnapshotVM $ParentSnapshot -StartTime "$($startTime)"

        # Next pool starts 5 minutes after this one
        $offset += 5
    }
}


# ---- Disconnect ----
Disconnect-VIServer -Confirm:$false -Force | Out-Null
Disconnect-HVServer -Confirm:$false
