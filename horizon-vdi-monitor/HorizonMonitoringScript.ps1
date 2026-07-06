<#
    HORIZON VDI  ·  LOW-DESKTOP & HEALTH MONITOR
    Written by Bill Gernert

    THE STORY
    The API was built for patching, but the data was available to monitor.
    I built this over a weekend, along with my patching script, after
    getting a quote for a monitoring solution. Run from a Jenkins platform
    so script failures alert outside of the script itself.

    Ran every 15 minutes during business hours (M-F 7AM-4:30PM) in a
    VMware / Omnissa Horizon VDI environment. That let me patch pools with
    another script starting at 4:30. It saved me from multiple production
    outages and eliminated the need for a third-party solution.

    WHAT IT ALERTS ON
      1. Minimum available desktops per pool (re-alerts every 15 minutes)
      2. Total error desktops across all Horizon pools
      3. Any Horizon connection server in an unhealthy state

    COMPATIBILITY
    Tested up to Horizon 8.2503.
    Built on the VMware.Hv.Helper module (with
    VMware.VimAutomation.HorizonView providing Connect-HVServer). Since
    the Omnissa split these are rebranded Omnissa.Horizon.Helper and
    Omnissa.VimAutomation.HorizonView. The cmdlets are unchanged, so this
    script works with either generation of the modules.
    Docs: developer.omnissa.com/horizon-powercli

    SETUP
    Pools are matched by naming convention: PROD and TEST in the pool
    name. Change that to fit your environment. Sections marked "CHANGE"
    must be set for your environment before first run.
#>


# CHANGE - SET YOUR MAIL AND SERVER VARS HERE
$smtpServer       = "mail.yourdomain.com"
$smtpFrom         = "HorizonAlerts@yourdomain.com"
$smtpTo           = "TeamDistributionGroup@yourdomain.com"
$horizonServerURL = "horizon.yourdomain.com"

# CHANGE - DEFINE YOUR POOL NAMES AND MINIMUM DESKTOP THRESHOLDS HERE. SCRIPT ALERTS WHEN AVAILABLE DESKTOPS DROP BELOW THE NUMBER.
$poolThresholds = @{
    "Prod-Labs-Desktop" = 10
    "Prod-GPU-Desktop"  = 10
    "Prod-Task"         = 10
}

# CHANGE - TOTAL NUMBER OF ERROR DESKTOPS ACROSS ALL POOLS BEFORE ALERTING
$ErrorDesktopThreshold = 10

# CHANGE - GET CREDS FROM YOUR VAULT / SECRET STORE HERE
# Credential block here to securely retrieve $username and $password for your service account.
# Never hardcode credentials in this file.

# Connect to your Horizon View environment
Connect-HVServer -Server $horizonServerURL -User $username -Password $password

# Pools are split by naming convention: PROD pools contain 'Prod', TEST pools contain 'Test'.
$ProdPools = Get-HVPoolSummary -UserAssignment Floating -PoolType AUTOMATED |
                Select-Object -ExpandProperty DesktopSummaryData |
                Where-Object { $_.Name -like '*Prod*' -and $_.Name -notlike '*Test*' }

# Separate test pools
$testPools = Get-HVPoolSummary -UserAssignment Floating -PoolType AUTOMATED |
                Select-Object -ExpandProperty DesktopSummaryData |
                Where-Object { $_.Name -like '*Test*' -and $_.Name -notlike '*Prod*' }

# Define email body template. These colors work for dark mode and light mode, but set them how you like.
$emailBodyTemplate = @"
<html>
<head>
<style>
    h1 {text-align: center;}
    th {background-color: #7CA2D3; text-align: left;}
    td {background-color: #B4C6E8; text-align: left;}
</style>
</head>
<body>
"@

# Function to generate table rows for pools and count error desktops
function GeneratePoolRows {
    param (
        [Parameter(Mandatory = $true)]
        [array]$pools
    )
    $errorDesktopCountTotal = 0
    $rows = foreach ($pool in $pools) {
        $availableDesktopCount = (Get-HVMachineSummary -PoolName $pool.Name | Where-Object { $_.Base.BasicState -eq 'Available' }).Count
        $errorDesktopCount = (Get-HVMachineSummary -PoolName $pool.Name | Where-Object { $_.Base.BasicState -ne 'Available' -and $_.Base.BasicState -ne 'Connected' -and $_.Base.BasicState -ne 'Disconnected' }).Count
        $errorDesktopCountTotal += $errorDesktopCount
        $ProdPoolstatus = $pool.Enabled
        $displayName = $pool.DisplayName
        $poolProvisioningStatus = $pool.ProvisioningEnabled
        $snapshot = (Get-HVPool -PoolName $pool.Name).AutomatedDesktopData.VirtualCenterNamesData.SnapshotPath -split '/' | Select-Object -Last 1

        "<tr><td>$($pool.Name)</td><td>$displayName</td><td>$availableDesktopCount</td><td>$errorDesktopCount</td><td>$snapshot</td><td>$ProdPoolstatus</td><td>$poolProvisioningStatus</td></tr>"
    }
    return @($rows, $errorDesktopCountTotal)
}

# Generate HTML and count error desktops
$prodRowsResult = GeneratePoolRows -pools $ProdPools
$testRowsResult = GeneratePoolRows -pools $testPools

$prodRows = $prodRowsResult[0]
$prodErrorDesktopCount = $prodRowsResult[1]

$testRows = $testRowsResult[0]
$testErrorDesktopCount = $testRowsResult[1]

$totalErrorDesktopCount = $prodErrorDesktopCount + $testErrorDesktopCount

$emailBody = $emailBodyTemplate + "<h2>Production Pools</h2>" + "<table border='1'>" + "<tr><th>Pool Name</th><th>Display Name</th><th>Available Desktops</th><th>Error Desktops</th><th>Current Snapshot</th><th>Pool Enabled</th><th>Provisioning Enabled</th></tr>" + $prodRows + "</table>" + "<br><br>" + "<h2>Test Pools</h2>" + "<table border='1'>" + "<tr><th>Test Pool Name</th><th>Display Name</th><th>Available Desktops</th><th>Error Desktops</th><th>Current Snapshot</th><th>Pool Enabled</th><th>Provisioning Enabled</th></tr>" + $testRows + "</table>" + "</body></html>"

# Check total error desktops and send alert if necessary
if ($totalErrorDesktopCount -gt $ErrorDesktopThreshold) {
    $alertMessage = "Alert: There are more than $ErrorDesktopThreshold error desktops in total. Total error desktops: $totalErrorDesktopCount"

    # Send email with the alert message
    Send-MailMessage -To $smtpTo -From $smtpFrom -Subject "Action Required: High Number of Error Desktops" -Body "$alertMessage <br><br><br> $emailBody" -BodyAsHtml -SmtpServer $smtpServer
}

# Flag to check if all production pools are good
$allPoolsGood = $true

# Initialize a variable to store alert messages
$alertMessage = @()

foreach ($poolName in $poolThresholds.Keys) {
    # Retrieve available desktop count
    $availableDesktopCount = (Get-HVMachineSummary -PoolName $poolName | Where-Object { $_.Base.BasicState -eq 'Available' }).Count
    # Retrieve pool status
    $ProdPoolstatus = (Get-HVPoolSummary -PoolName $poolName).DesktopSummaryData.Enabled
    # Retrieve pool provisioning status
    $poolProvisioningStatus = (Get-HVPoolSummary -PoolName $poolName).DesktopSummaryData.ProvisioningEnabled

    # Output pool information
    Write-Host "Pool Name: $poolName, Available Desktops: $availableDesktopCount, Threshold: $($poolThresholds[$poolName]), Pool Enabled: $ProdPoolstatus, Pool Provisioning Status: $poolProvisioningStatus"

    # Initialize array to store pool issues
    $poolIssues = @()

    # Check if available desktop count is below threshold
    if ($availableDesktopCount -lt $poolThresholds[$poolName]) {
        $poolIssues += "Available desktops: $availableDesktopCount, Threshold: $($poolThresholds[$poolName])"
    }

    # Check if pool is not enabled
    if ($ProdPoolstatus -ne "True") {
        $poolIssues += "Pool is not enabled"
    }

    # Check if pool provisioning status is not true
    if ($poolProvisioningStatus -ne "True") {
        $poolIssues += "Pool provisioning status is not true"
    }

    # If issues are found, construct alert message
    if ($poolIssues.Count -gt 0) {
        $alertMessage += "There is an issue with Horizon pool '$poolName':`n`n"
        $alertMessage += $poolIssues -join "`n`n"
        $alertMessage += "`nPlease check immediately.<br>`n`n"
        $allPoolsGood = $false
    }
}

Write-Host "All Pools Good: $allPoolsGood"

if (-not $allPoolsGood) {
    $emailBody2 = $alertMessage -join "`n`n"
    Send-MailMessage -To $smtpTo -From $smtpFrom -Subject "Action Required VDI Available Desktops Low" -Body "$emailBody2 <br><br><br> $emailBody" -BodyAsHtml -SmtpServer $smtpServer
}

# Now check the connection server status
$healthData = Get-HVHealth
$sendEmail = $false
$serverTable = "<table border='1'><tr><th>Server Name</th><th>Status</th></tr>"

# Loop through the health data for each connection server
foreach ($server in $healthData) {
    $serverName = $server.Name
    $serverStatus = $server.Status

    # Add server data to the HTML table
    $serverTable += "<tr><td>$serverName</td><td>$serverStatus</td></tr>"

    # Alert if any server status is not OK (an "Unknown" status means the server is unreachable)
    if ($serverStatus -ne "OK") {
        $sendEmail = $true
    }
}

# Close the HTML table
$serverTable += "</table>"

# If any server is not OK, send an email
if ($sendEmail) {
    $emailBody = @"
    <html>
    <style>
    h1 {text-align: center;}
    th {background-color: #7CA2D3; text-align: left;}
    td {background-color: #B4C6E8; text-align: left;}
</style>
    <body>
    <p>One or more Horizon VDI Connection server status is not 'OK' <br> An 'Unknown' status means the server is down!!!</p>
    $serverTable
    </body>
    </html>
"@

    # Set up email parameters
    $subject = "Connection Server Health Alert"
    # Send the email
    Send-MailMessage -From $smtpFrom -To $smtpTo -Subject $subject `
        -Body $emailBody -SmtpServer $smtpServer -BodyAsHtml
}

# Disconnect
Disconnect-HVServer -Server $horizonServerURL -Confirm:$false
