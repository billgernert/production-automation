<#
    IIS FARM  ·  ROLLING ZERO-DOWNTIME DEPLOYMENT

    Written by Bill Gernert

    THE STORY
    This deployed application code to a load-balanced IIS farm without taking
    the site down and without me sitting at my desk during the change window.
    Driven by Jenkins parameters, it could update the front-end IIS servers,
    the back-end API servers, or both. When it finished it emailed the app
    team from the sender's own address, so the developer just had to watch for
    the deployment mail and reply that testing looked good.

    HOW IT WORKS  ·  ROLLING DEPLOYMENT
    The farm has two front-end (IIS) servers and two back-end (API) servers
    behind a load balancer. The script updates ONE server completely before
    touching the next, so there is always a healthy server serving traffic.
    For each server it: stops the app pool, backs up the current code and zips
    it, clears the deployment directory, copies the new build in, then starts
    the pool and site again. Then it moves to the next server and repeats.

    FAILSAFES  ·  WHY THIS WAS SAFE TO RUN UNATTENDED
      1. Empty-source check. Before wiping any server, it verifies the new
         build actually exists in the source location. An empty source would
         mean deploying nothing over a live site, so it aborts and emails
         instead.
      2. Stubborn-file handling. Sometimes a locked file refuses Remove-Item.
         The ClearDeploymentDirectory function falls back to mirroring an
         empty directory over the target with robocopy /MIR, then verifies the
         directory is actually empty before continuing. It retries rather than
         charging ahead on a half-cleared directory.
      3. Backups first. Every server's current code is backed up and zipped
         with a timestamp before anything is deleted, so a bad deploy can be
         rolled back.
      4. Monitoring maintenance mode. The affected hosts are put into
         monitoring maintenance before the deploy so the expected app-pool
         restarts don't trigger false alerts.

    RUNNING IT FROM JENKINS
    Set up as a Jenkins job with parameters for the pool name, whether to
    update IIS / API / both, whether to skip backups, the change ticket, the
    source and backup locations, and the sender name/email so the completion
    mail comes from whoever ran it.

    A NOTE FOR SHARING
    This is a de-identified, representative version. In the real environment
    the pool-to-server and pool-to-API mapping was driven by a lookup table of
    many applications; here that is collapsed into a small config block with
    example values so the pattern is clear without publishing an internal app
    inventory. Sections marked "CHANGE" must be set for your environment.
    Credentials come from your secret store, never hardcoded.
#>


# ---- Jenkins job parameters ----
$IISPoolName    = $env:IISPoolName      # the app pool / site name to deploy
$UpdateIIS      = $env:UpdateIIS        # "YES" or "NO"
$UpdateAPI      = $env:UpdateAPI        # "YES" or "NO"
$SkipBackup     = $env:SkipBackup       # "Yes" or "No"
$CTASK          = $env:CTASK            # change ticket number, used in the email subject
$SenderName     = $env:SenderName       # name of whoever ran it (email signature)
$SenderEmail    = $env:SenderEmail      # sender address, so the app team replies to the right person
$IISSourceLocation = $env:IISSourceLocation   # network path to the new IIS build
$APISourceLocation = $env:APISourceLocation   # network path to the new API build
$BackupLocation    = $env:BackupLocation      # network path where timestamped backups are written

$IISBackupLocation = $BackupLocation
$APIBackupLocation = $BackupLocation
$Date = Get-Date -Format 'yyyy-MM-dd'

# CHANGE - your deployment infrastructure
$smtpServer        = "mailhost.yourdomain.com"
$failureSender     = "ScriptFailure@yourdomain.com"
$deployRootShare   = "E$\IISRoot"                       # per-server share where sites live
$tempEmptyDirectory = "\\fileserver\share\IISDeploy\EmptyDirectory"  # empty dir used by the stubborn-file failsafe

# CHANGE - who gets the "deployment complete" email
$notifyUsers  = @("appteam@yourdomain.com")
$ToEmailUsers = "App Team"


# ---- Trim any trailing backslash from the path parameters ----
$paths = @($IISSourceLocation, $APISourceLocation, $IISBackupLocation, $APIBackupLocation)
for ($i = 0; $i -lt $paths.Count; $i++) {
    $value = $paths[$i].Trim()
    if ($value.Length -gt 0 -and $value[-1] -eq '\') {
        $value = $value.Substring(0, $value.Length - 1)
    }
    $paths[$i] = $value
}
$IISSourceLocation = $paths[0]
$APISourceLocation = $paths[1]
$IISBackupLocation = $paths[2]
$APIBackupLocation = $paths[3]


# ---- Stubborn-file failsafe ----
# Ensure the empty directory used for the robocopy /MIR fallback exists
if (-not (Test-Path -Path $tempEmptyDirectory -PathType Container)) {
    New-Item -Path $tempEmptyDirectory -ItemType Directory | Out-Null
    Write-Host "Empty directory created for deletion fallback."
}

# Clears $DeploymentDirectory. Tries Remove-Item first; if a locked file blocks
# it, mirrors an empty directory over the target with robocopy and verifies the
# result is actually empty before moving on. Retries rather than proceeding on a
# half-cleared directory.
function ClearDeploymentDirectory {
    $success = $false
    while (-not $success) {
        try {
            Remove-Item -Path "$DeploymentDirectory" -Recurse -Force -ErrorAction Stop
            Write-Host "$DeploymentDirectory contents deleted successfully."
            $success = $true
        }
        catch {
            Write-Host "Remove-Item failed: $_"
            robocopy $tempEmptyDirectory $DeploymentDirectory /E /MIR /NFL /NDL /NJH /NJS /PURGE | Out-Null
            if ((Get-ChildItem -Path $DeploymentDirectory | Measure-Object).Count -eq 0) {
                Write-Host "$DeploymentDirectory cleared via robocopy mirror."
                $success = $true
            }
            else {
                Write-Host "Directory still not empty. Retrying in 1 minute..."
                Write-Host "If this persists you can RDP in and clear it by hand, then let the run continue."
                Start-Sleep -Seconds 60
            }
        }
    }
}


# ---- Resolve environment, servers, and API pool from the pool name ----
# CHANGE - in the real environment this was a lookup over many applications.
# Collapsed here into a small example: a naming convention picks the
# environment, and matching servers/API pool are set from it.
if ($IISPoolName -like "*QA*") {
    $Environment = "QA"
    $WebServer1 = "WEB-QA-01"; $WebServer2 = "WEB-QA-02"
    $APIServer1 = "API-QA-01"; $APIServer2 = "API-QA-02"
}
elseif ($IISPoolName -like "*ProdExt*") {
    $Environment = "PRODEXT"
    $WebServer1 = "WEB-EXT-01"; $WebServer2 = "WEB-EXT-02"
    $APIServer1 = "API-EXT-01"; $APIServer2 = "API-EXT-02"
}
elseif ($IISPoolName -like "*Prod*") {
    $Environment = "PRODINT"
    $WebServer1 = "WEB-INT-01"; $WebServer2 = "WEB-INT-02"
    $APIServer1 = "API-INT-01"; $APIServer2 = "API-INT-02"
}
else {
    Write-Error "ERROR: could not determine environment from pool name '$IISPoolName'."
    exit 1
}

# CHANGE - derive the matching API pool name for sites that have one.
# Real version mapped this per-application; here we assume a simple convention.
if ($IISPoolName -match 'Web') {
    $APIPoolName = $IISPoolName -replace 'Web', 'Api'
} else {
    $UpdateAPI = "NO"
    Write-Output "This site has no associated API pool."
}


# ---- Put the affected hosts into monitoring maintenance mode ----
# CHANGE - your monitoring API details. Creds from your secret store.
# This suppresses expected app-pool-restart alerts during the deploy.
# (Example calls a helper that talks to the monitoring API.)
$maintenanceMinutes = 30
if ($UpdateIIS -eq "YES") {
    Write-Output "Placing IIS hosts $WebServer1,$WebServer2 into monitoring maintenance for $maintenanceMinutes min."
    # Invoke your monitoring-maintenance helper here.
}
if ($UpdateAPI -eq "YES") {
    Write-Output "Placing API hosts $APIServer1,$APIServer2 into monitoring maintenance for $maintenanceMinutes min."
    # Invoke your monitoring-maintenance helper here.
}


# ---- Credentials ----
# CHANGE - GET CREDS FROM YOUR VAULT / SECRET STORE HERE.
# Deployment service account with rights to the app pools and deploy shares.
$username = "svc-iis-deploy@yourdomain.com"
# $password = <plaintext pulled from your secret store>
$securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$creds = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $username, $securePassword


# =========================================================================
#  Deploy a single server: stop pool, back up, clear, copy, start pool+site.
#  Called once per server so the farm updates in a rolling fashion.
# =========================================================================
function Deploy-Server {
    param(
        [string]$Server,
        [string]$PoolName,
        [string]$SourceLocation,
        [string]$BackupRoot
    )

    $deployPath = "\\$Server\$deployRootShare\$PoolName"
    $driveName  = "Deploy_$Server"
    New-PSDrive -Name $driveName -PSProvider FileSystem -Root $deployPath -Credential $creds | Out-Null

    # Stop the app pool
    Write-Host "Stopping app pool $PoolName on $Server ($(Get-Date -Format 'HH:mm'))"
    Invoke-Command -ComputerName $Server -Credential $creds -ArgumentList $PoolName -ScriptBlock {
        Param($PoolName) Stop-WebAppPool -Name $PoolName -ErrorAction 'SilentlyContinue'
    }

    # Backup + zip current code
    if ($SkipBackup -eq "No") {
        $stamp = Get-Date -Format 'HHmm'
        $backupPath = "$BackupRoot\$PoolName-$Server-$Date-$stamp"
        Write-Host "Backing up $PoolName on $Server to $backupPath"
        New-Item -ItemType Directory -Path $backupPath | Out-Null
        Copy-Item -Path "$deployPath\*" -Destination $backupPath -Recurse -Force
        Compress-Archive -Path $backupPath -DestinationPath "$backupPath.zip" -Force
        Remove-Item -Path $backupPath -Recurse
        $script:LastBackupPath = "$backupPath.zip"
    }

    # Clear the deployment directory (with stubborn-file failsafe)
    Write-Host "Clearing $PoolName on $Server"
    $script:DeploymentDirectory = "$deployPath\*"
    ClearDeploymentDirectory

    # Copy the new build in
    Write-Host "Deploying new code to $Server ($(Get-Date -Format 'HH:mm'))"
    Copy-Item "$SourceLocation\*" -Destination $deployPath -Force -Recurse

    # Start the pool, then restart the site
    Invoke-Command -ComputerName $Server -Credential $creds -ArgumentList $PoolName -ScriptBlock {
        Param($PoolName) Start-WebAppPool -Name $PoolName
    }
    Invoke-Command -ComputerName $Server -Credential $creds -ArgumentList $PoolName -ScriptBlock {
        Param($PoolName)
        Stop-Website  -Name $PoolName -ErrorAction 'SilentlyContinue'
        Start-Website -Name $PoolName -ErrorAction 'SilentlyContinue'
    }

    Remove-PSDrive -Name $driveName
}


# =========================================================================
#  IIS front-end servers (rolling: server 1 fully done before server 2)
# =========================================================================
if ($UpdateIIS -eq "YES") {
    Write-Output "Updating IIS front-end servers"

    New-PSDrive -Name IISSource -PSProvider FileSystem -Root $IISSourceLocation -Credential $creds -Scope Script | Out-Null

    # Empty-source failsafe: never wipe a live server to deploy nothing
    if (-not (Test-Path -Path "$IISSourceLocation\*" -PathType Leaf)) {
        Write-Host "IIS source $IISSourceLocation is empty. Aborting and emailing."
        Send-MailMessage -From $failureSender -To $SenderEmail -Subject "$CTASK - $IISPoolName - Deployment Failure" `
            -Body "$SenderName,`n`nThe package was NOT deployed to $IISPoolName for $CTASK.`nThe source directory $IISSourceLocation is empty.`n`n$SenderName" `
            -SmtpServer $smtpServer -ErrorAction SilentlyContinue
        Remove-PSDrive -Name IISSource
        Start-Sleep -Seconds 60
        exit 1
    }

    Deploy-Server -Server $WebServer1 -PoolName $IISPoolName -SourceLocation $IISSourceLocation -BackupRoot $IISBackupLocation
    $BackupPathWeb = $script:LastBackupPath
    Deploy-Server -Server $WebServer2 -PoolName $IISPoolName -SourceLocation $IISSourceLocation -BackupRoot $IISBackupLocation

    Remove-PSDrive -Name IISSource
}


# =========================================================================
#  API back-end servers (rolling)
# =========================================================================
if ($UpdateAPI -eq "YES") {
    Write-Output "Updating API back-end servers"

    New-PSDrive -Name APISource -PSProvider FileSystem -Root $APISourceLocation -Credential $creds | Out-Null

    if (-not (Test-Path -Path "$APISourceLocation\*" -PathType Leaf)) {
        Write-Host "API source $APISourceLocation is empty. Aborting."
        Remove-PSDrive -Name APISource
        Start-Sleep -Seconds 60
        exit 1
    }

    Deploy-Server -Server $APIServer1 -PoolName $APIPoolName -SourceLocation $APISourceLocation -BackupRoot $APIBackupLocation
    $BackupPathAPI = $script:LastBackupPath
    Deploy-Server -Server $APIServer2 -PoolName $APIPoolName -SourceLocation $APISourceLocation -BackupRoot $APIBackupLocation

    Remove-PSDrive -Name APISource
}


# ---- If backups were skipped, set placeholder values for the email ----
if ($SkipBackup -eq "Yes") {
    $BackupPathWeb = "Backups were skipped"
    $BackupPathAPI = "Backups were skipped"
}


# =========================================================================
#  Notify the app team that the deployment is done
#  Sent from the runner's own address so the reply comes back to them.
# =========================================================================
if ($UpdateAPI -eq "YES" -and $UpdateIIS -eq "YES") {
    Send-MailMessage -From $SenderEmail -To $notifyUsers -Cc $SenderEmail -Subject "$CTASK - $IISPoolName - Deployed Successfully" `
        -Body "$ToEmailUsers,`n`nThe package has been deployed to $IISPoolName for $CTASK.`n`nIIS deployed from $IISSourceLocation to $WebServer1 and $WebServer2`nAPI deployed from $APISourceLocation to $APIServer1 and $APIServer2`n`nIIS backup: $BackupPathWeb`nAPI backup: $BackupPathAPI`n`nThanks!`n`n$SenderName" `
        -SmtpServer $smtpServer -ErrorAction SilentlyContinue
}
elseif ($UpdateAPI -eq "YES" -and $UpdateIIS -eq "NO") {
    Send-MailMessage -From $SenderEmail -To $notifyUsers -Cc $SenderEmail -Subject "$CTASK - $APIPoolName - Deployed Successfully" `
        -Body "$ToEmailUsers,`n`nThe package has been deployed to $APIPoolName for $CTASK.`n`nAPI deployed from $APISourceLocation to $APIServer1 and $APIServer2`n`nAPI backup: $BackupPathAPI`n`nThanks!`n`n$SenderName" `
        -SmtpServer $smtpServer -ErrorAction SilentlyContinue
}
elseif ($UpdateAPI -eq "NO" -and $UpdateIIS -eq "YES") {
    Send-MailMessage -From $SenderEmail -To $notifyUsers -Cc $SenderEmail -Subject "$CTASK - $IISPoolName - Deployed Successfully" `
        -Body "$ToEmailUsers,`n`nThe package has been deployed to $IISPoolName for $CTASK.`n`nIIS deployed from $IISSourceLocation to $WebServer1 and $WebServer2`n`nIIS backup: $BackupPathWeb`n`nThanks!`n`n$SenderName" `
        -SmtpServer $smtpServer -ErrorAction SilentlyContinue
}
else {
    Write-Output "Error: neither IIS nor API was selected for update."
}
