#!/usr/bin/env pwsh

<#
.SYNOPSIS
This script is designed to ingest a CSV file export of the Wasted Files actions from Turbonomic. Requires PowerShell 7 or greater. Also requires the VMware PowerCLI module. If the PowerCLI module is not found, install it by running:

Install-Module -Name VMware.PowerCLI

.DESCRIPTION
It will process each file in the CSV, attempting to remove it. All VSphere instances and datastores are processed in order. Any files which should not be deleted should be removed from the file prior to execution. The headings of the file should be left as they are specified from Turbonomic. By default, it is assumed that different credentials will be required for every VSphere instance. This behavior can be overriden with the '-Credential' switch. The logging of each discovery or deletion action will happen by default to file per-run in the same directory as the script itself.

All parameters are completely optional. If not included, the script will interactively prompt for information on an as-needed basis.

.PARAMETER FilePath
Path to the CSV file which has been downloaded from Turbonomic. Can be useful since this will allow for tab-completion of the path.

.PARAMETER Credential
Switch that instructs the code to prompt once for credentials and then use those credentials to connect to all VSphere instances. By default the code will prompt for fresh credentials each time a new VSphere instance must be used.

.PARAMETER NoWarning
Switch which instructs the code to avoid displaying the splash warning about validating that the CSV file has had any files the use wishes to keep removed.

.PARAMETER StoreCredential
Prompts for the creation of a creds.xml file in the same directory as the script. Used for unattended execution.

.PARAMETER LoadCredential
Causes credentials to be loaded from a local file rather than prompted. Implies -Credential and -NoWarning. Used for unattended execution.

.PARAMETER SuppressLogFile
Causes the log file which is created by default per run to be suppressed.

.PARAMETER DebugLog
Switch to enable debug logging. Should only be used for troubleshooting.

.PARAMETER WhatIf
Switch to enable a dry run of the script that will test connectivity to everything without removing any files.

.EXAMPLE
remove-wastedFiles.ps1

Simplest method of execution which will prompt for the CSV warning, the path to the CSV file, and credentials for each VSphere instance.

.EXAMPLE
remove-wastedFiles.ps1 -SuppressLogFile

Executes with full prompts but suppresses the creation of the log file.

.EXAMPLE
remove-wastedFiles.ps1 -FilePath ./Pending_Actions.csv -NoWarning

Provides the CSV file from the CLI and prevents the CSV warning from displaying.

.EXAMPLE
remove-wastedFiles.ps1 -Credential

Prompts for credentials only once and uses the same set of credentials for all VSphere instances.

.EXAMPLE
remove-wastedFiles.ps1 -StoreCredential

Prompts for credentials only and then exits. Credentials will be stored in creds.xml in the same directory as the script itself.

.EXAMPLE
remove-wastedFiles.ps1 -LoadCredential -FilePath ./Pending_Actions.csv

A completed unattended option for execution.

.EXAMPLE
remove-wastedFiles.ps1 -WhatIf

Runs the script with default settings to test connectivity and file accessibility without removing any files.
#>

# CLI parameters.
param(
    [Parameter(Mandatory=$false)][string]$FilePath,
    [Parameter(Mandatory=$false)][switch]$Credential,
    [Parameter(Mandatory=$false)][switch]$NoWarning,
    [Parameter(Mandatory=$false)][switch]$DebugLog,
    [Parameter(Mandatory=$false)][switch]$StoreCredential,
    [Parameter(Mandatory=$false)][switch]$LoadCredential,
    [Parameter(Mandatory=$false)][switch]$WhatIf,
    [Parameter(Mandatory=$false)][switch]$SuppressLogFile,
    [Parameter(Mandatory=$false)][switch]$DryRun
)

# Ensure WhatIf and DryRun can be used interchangeably.
if($WhatIf) {
    $DryRun = $WhatIf
}

# Logging function for the default log file and debug to STDOUT.
function write-log {
    param (
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][string]$Level,
        [Parameter(Mandatory=$false)][string]$FilePath
    )
    if($Level -eq "DEBUG" -and $DebugLog) {
        Write-Host "$(Get-Date -Format "yyyy/MM/dd-HH:mm:ss") [$Level] $Message"
    }

    if($FilePath -and -not $SuppressLogFile) {
        Write-Output "$(Get-Date -Format "yyyy/MM/dd-HH:mm:ss") [$Level] $Message" |`
            Out-File -FilePath $FilePath -Encoding ascii -Append -NoClobber
    }
}

# Class for managing connections to vCenter.
class VSphere {
    [String]$Target
    [pscredential]$Cred
    [Hashtable]$DataStoreNames
    [int]$FileCount

    # Constructor.
    VSphere([String]$Target, [pscredential]$Cred) {
        $this.Target = $Target
        $this.Cred = $Cred
        $this.DataStoreNames = @{}
        $this.FileCount = 0

        # Create an initial session. Can be overriden later.
        $this.CreateSession()
    }

    # Cleans characters from a datastore name that cannot be in a PSDrive name.
    [string]CleanName([String]$DataStoreName) {
        $cleanedName = $DataStoreName.Replace(":", "_")
        $cleanedName = $cleanedName.Replace(";", "_")
        $cleanedName = $cleanedName.Replace("~", "_")
        $cleanedName = $cleanedName.Replace("/", "_")
        $cleanedName = $cleanedName.Replace("\", "_")
        return $cleanedName.Replace(".", "_")
    }

    # Adds a file to the list of known files for a given datastore.
    [void]AddFile([String]$FilePath, [String]$DataStoreName) {
        if($this.DataStoreNames.ContainsKey($DataStoreName)) {
            $this.DataStoreNames[$DataStoreName] += $FilePath
        } else {
            $this.DataStoreNames[$DataStoreName] = @($FilePath)
        }
    }

    # Wrapper for starting a new connection.
    [void]NewConnection([String]$Target, [pscredential]$NewCred) {
        $this.UpdateTarget($Target)
        $this.UpdateCredential($NewCred)
        $this.CreateSession()
    }

    # Relace the target.
    [void]UpdateTarget([String]$Target) {
        write-log -Message "Updating VSphere target to: $Target" -Level "DEBUG"
        $this.Target = $Target
    }

    # Replace the credentials.
    [void]UpdateCredential([pscredential]$NewCred) {
        write-log -Message "Updating credentials." -Level "DEBUG"
        $this.Cred = $NewCred
    }

    # Create new session.
    [void]CreateSession() {
        Write-Host "`n$('#' * 85)"
        Write-Host "`nCreating connection to: $($this.Target)"
        Write-Host "$('-' * 70)"
        try {
            Connect-VIServer -Server $this.Target -Credential $this.Cred -ErrorAction Stop
        } catch {
            Write-Host "ERROR: Failed to create session with $($this.Target) with error: $($Error[0])"
            exit 1
        }
    }

    # Kill an existing session.
    [void]DestroySession() {
        Write-Host "`nDestroying connection to: $($this.Target)"
        try {
            Disconnect-VIServer -Server $this.Target -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Host "WARNING: Failed to remove session with $($this.Target) with error: $($Error[0])"
        }
    }

    # Remove current drives.
    [void]RemoveDatastores() {
        # Reset the tracking list.
        write-log -Message "Clearing the list of datastores." -Level "DEBUG"
        $this.DataStoreNames.Clear()
    }

    # Delete all files for a given VSphere instance.
    [void]RemoveFiles([bool]$DryRun, [string]$FilePath, [string]$Vsphere) {
        # Iterate over each datastore.
        foreach($datastore in $this.DataStoreNames.GetEnumerator()) {
            # Create a PSDrive.
            $cleanedName = $this.CleanName($datastore.Name)
            Write-Host "`nCreating PSDrive for $($datastore.Name) called $cleanedName"

            # Get the Datastore object first.
            write-log -Message "Getting datastore object for $($datastore.Name)" `
                -Level "DEBUG"
            try {
                $currentDatastore = Get-Datastore -Name $datastore.Name -ErrorAction Stop
            } catch {
                Write-Host "ERROR: Skipping datastore $($datastore.Name) as it failed to retrieve with error: $($Error[0])"
                continue
            }

            # Check if there are multiple options in a single datastore.
            if($currentDatastore -is [Object[]]) {
                write-log -Message "Using sub-datastore." -Level "DEBUG"
                $currentDS = $currentDatastore[0]
            } else {
                write-log -Message "Using base datastore." -Level "DEBUG"
                $currentDS = $currentDatastore
            }

            try {
                New-PSDrive -Name $cleanedName -PSProvider VimDatastore `
                    -Location $currentDS -Root "/" -ErrorAction Stop
            } catch {
                Write-Host "ERROR: Skipping datastore $currentDS since connecting failed with error: $($Error[0])"
                continue
            }

            # Remove the files.
            foreach($file in $datastore.Value) {
                $fullPath = $cleanedName + ":" + $file
                $message = "On server $Vsphere "
                if($DryRun) {
                    Write-Host "Found file: $fullPath"
                    try {
                        Get-Item -Path $fullPath | Out-Null
                        $message += "found: $fullPath"
                        write-log -Message $message -Level "INFO" -FilePath $FilePath
                        $this.FileCount++
                    } catch {
                        $message += "failed to find $fullPath with error: $($Error[0])"
                        Write-Host $message
                        write-log -Message $message -Level "WARNING" -FilePath $FilePath
                    }
                    
                } else {
                    Write-Host "Deleting file: $fullPath"
                    try {
                        Remove-Item -Path $fullPath -ErrorAction Stop
                        $message += "deleted: $fullPath"
                        write-log -Message $message -Level "INFO" -FilePath $FilePath
                        $this.FileCount++
                    } catch {
                        $message += "failed to delete $fullPath with error: $($Error[0])"
                        Write-Host $message
                        write-log -Message $message -Level "WARNING" -FilePath $FilePath
                    }
                }
            }

            # Clean up the drive.
            Write-Host "Removing PSDrive: $cleanedName"
            try {
                Remove-PSDrive -Name $cleanedName -ErrorAction Stop
            } catch {
                Write-Host "WARNING: Failed to remove PSDrive: $cleanedName with error: $($Error[0])"
            }
        }

        # Do cleanup.
        $this.RemoveDatastores()
        $this.DestroySession()
    }
}

# Shows a greeting (and potential warning) at initial execution.
function write-greeting {
    $banner = @"
████████╗██╗   ██╗██████╗ ██████╗  ██████╗ ███╗   ██╗ ██████╗ ███╗   ███╗██╗ ██████╗
╚══██╔══╝██║   ██║██╔══██╗██╔══██╗██╔═══██╗████╗  ██║██╔═══██╗████╗ ████║██║██╔════╝
   ██║   ██║   ██║██████╔╝██████╔╝██║   ██║██╔██╗ ██║██║   ██║██╔████╔██║██║██║
   ██║   ██║   ██║██╔══██╗██╔══██╗██║   ██║██║╚██╗██║██║   ██║██║╚██╔╝██║██║██║
   ██║   ╚██████╔╝██║  ██║██████╔╝╚██████╔╝██║ ╚████║╚██████╔╝██║ ╚═╝ ██║██║╚██████╗
   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝╚═╝ ╚═════╝
"@
    Write-Host "`n$banner"
    Write-Host "`nThis script will remove wasted files detected on VMware"
    Write-Host "datastores. Export the CSV from your Turbonomic instance to"
    Write-Host "get started."

    Write-Host "`nCSV column titles should NOT be modified. Leave them as they are"
    Write-Host "from Turbonomic."

    if(-not $NoWarning -and -not $LoadCredential -and -not $DryRun) {
        Write-Host "`n--== WARNING: PROCEED AT YOUR OWN RISK! ==--"
        Write-Host "Remove any lines from the CSV for files you wish to keep"
        Write-Host "before proceeding! An attempt will be made to delete EVERY"
        Write-Host "file contained within the CSV."
        Read-Host "Enter to continue"
    }
    if($DryRun -and -not $NoWarning) {
        Write-Host "`n--== WhatIf Flag Detected ==--"
        Write-Host "The ability to connect and pull information on each file will"
        Write-Host "be tested, but no files will be removed during this execution."
        Write-Host "To remove files, re-run without the -WhatIf switch."
        Read-Host "Enter to continue"
    }
}

# Shows the closing information.
function write-closing {
    param(
        [Parameter(Mandatory=$true)]$StartTime,
        [Parameter(Mandatory=$true)]$EndTime,
        [Parameter(Mandatory=$true)]$FileCount
    )

    $timeDifference = $EndTime - $StartTime
    $message = "`nScript complete. $FileCount files"

    if($DryRun) {
        $message += " found in "
    } else {
        $message += " removed in "
    }

    if($timeDifference.Hours) {
        $message += "$($timeDifference.Hours) hours, "
    }
    $message += "$($timeDifference.Minutes) minutes and "
    $message += "$($timeDifference.Seconds) seconds."
    Write-Host $message
}

# Prompts the user to enter the path to the CSV file to ingest.
function get-csvPath {
    Write-Host "Enter the path (either full or relative) to the CSV file to import."
    $filePath = Read-Host "Path"
    return $filePath
}

# Validates that the CSV path is legitimate.
function test-filePath {
    param(
        [Parameter(Mandatory=$true)]$FilePath
    )
    if(-not (Test-Path -Path $FilePath -PathType Leaf)) {
        Write-Host "ERROR: No file found at: $FilePath. Did you enter the right path?"
        exit 1
    } else {
        Write-Host "File loaded successfully from: $FilePath"
    }
}

# Prompts for credentials. Used through the script unless Credential is specified.
# Otherwise this prompt will happen per-VSphere. PSCredential object is returned.
# Offers option to enter nothing for a username to continue with current credential.
function update-credential {
    param(
        [Parameter(Mandatory=$false)]$VSphere,
        [Parameter(Mandatory=$false)]$CurrentCreds
    )

    if(-not $Credential -and (-not $VSphere -and -not $StoreCredential)) {
        Write-Host "-VSphere must be provided if not using the Credential switch."
        exit 1
    }

    if($VSphere) {
        $message = "Enter credentials for: $VSphere."
    } else {
        $message = "Enter credentials for all VSphere instances. If these are not the"
        $message += "same, re-run without the -Credential switch."
        return Get-Credential -Message "Enter master credential for all VSphere instances."
    }

    # Force credential entry if there aren't any.
    if(-not $CurrentCreds) {
        do {
            Write-Host "`n$message"
            $username = Read-Host "Username"
        } while(-not $username)

        return new-credential -Username $username
    }

    Write-Host "`n$message Leave blank to keep using current credentials."
    $username = Read-Host "Username"
    if($username) {
        return new-credential -Username $username
    }

    # Return the current creds if making it this far.
    return $CurrentCreds
}

function new-credential {
    param(
        [Parameter(Mandatory=$true)]$Username
    )

    $password = Read-Host "Password" -AsSecureString
    return New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $Username,$password
}

function test-module {
    param(
        [Parameter(Mandatory=$true)]$ModuleName
    )

    if(-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Host "ERROR: Missing module: $ModuleName."
        Write-Host "Please install it and try again..."
        Write-Host "Installation Command: Install-Module -Name VMware.PowerCLI"
        return $false
    }
    return $true
}

function add-credFile {
    param(
        [Parameter(Mandatory=$true)]$CredFileName
    )
    Write-Host "This will create a creds.xml file in the same directory as the script."
    Write-Host "NOTE: The creds should be valid for EVERY vCenter that will be accessed."
    update-credential
 | Export-Clixml -Path "$($PSScriptRoot)/$($CredFileName)"
    Write-Host "File written to: $($PSScriptRoot)/$($CredFileName)"
}

function get-credFile {
    param(
        [Parameter(Mandatory=$true)]$CredFileName
    )
    $credPath = "$($PSScriptRoot)/$($CredFileName)"
    Write-Host "Loading credential file from: $credPath"
    if(Test-Path -PathType Leaf -Path $credPath) {
        return Import-Clixml -Path $credPath
    }
    Write-Host "ERROR: Credential file doesn't exist. Please run with -StoreCredential to create it first."
    return $false
}

# Main function.
function start-script {
    # Log the start time.
    $startTime = Get-Date

    # Confirm the PowerCLI module is available.
    if(-not(test-module -ModuleName "VMware.PowerCLI")) {
        exit 1
    }

    # Create a log file name.
    $logStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logFile = "$($PSScriptRoot)/remove_wastedfiles_$($logStamp).log"
    write-log -Message "Beginning script." -Level "INFO" -FilePath $logFile

    # Store credentials and quit if flagged.
    $credentialFile = "creds.xml"
    if($StoreCredential) {
        add-credFile -CredFileName $credentialFile
        exit 0
    }

    # Display the greeting.
    write-greeting

    # Load the credentials from file if flagged.
    if($LoadCredential) {
        $currentCredential = get-credFile -CredFileName $credentialFile
        if(-not $currentCredential) {
            exit 1
        }
        Write-Host "Using stored account: $($currentCredential.Username)"
    }

    # Ensure there's a file path and that it's valid.
    if(-not $FilePath) {
        $FilePath = get-csvPath
    }
    test-filePath -FilePath $FilePath

    # Verify the module can ignore certificate warnings.
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false `
        -DefaultVIServerMode Single | Out-Null

    # Get the single set of credentials.
    if($Credential -and -not $LoadCredential) {
        write-log -Message "Prompting for the single set of credentials." `
            -Level "DEBUG"
        $currentCredential = update-credential
    
    }

    # Import the CSV and sort the data by target to avoid unnecessary reconnections.
    $csvData = Import-Csv -Path $FilePath -Encoding ascii
    $csvData = $csvData | Sort-Object -Property Target

    # Get the initial data to instantiate the class, accounting for blank Target fields.
    $initialIndex = 0
    $currentVSphere = $null
    while(-not $currentVSphere) {
        $currentVSphere = $csvData[$initialIndex].Target
        $initialIndex++
    }
    write-log -Message "Initial VSphere instance: $currentVSphere" `
        -Level "DEBUG"
    write-log -Message "Starting at index: $($initialIndex - 1)" `
        -Level "DEBUG"
    if(-not $Credential -and -not $LoadCredential) {
        $currentCredential = update-credential -VSphere $currentVSphere
    }
    $vsphereClient = [VSphere]::new($currentVSphere, $currentCredential)
    foreach($singleAction in $csvData[$($initialIndex-1)..$csvData.Length]) {
        # Verify that the line has the required data.
        if($null -eq $singleAction.Target -or "" -eq $singleAction.Target) {
            Write-Host "WARNING: Skipping line with missing Target data."
            continue
        } elseif($null -eq $singleAction.Entity -or "" -eq $singleAction.Entity) {
            Write-Host "WARNING: Skipping line with missing Entity data."
            continue
        } elseif($null -eq $singleAction.From -or "" -eq $singleAction.From) {
            Write-Host "WARNING: Skipping line with missing From data."
            continue
        }

        # Track if the VSphere instance changes since new credentials may be needed.
        if($singleAction.Target -ne $currentVSphere) {
            # Execute the removal prior to swapping VSphere targets.
            $vsphereClient.RemoveFiles($DryRun, $logFile, $currentVSphere)

            # Update the client to point to the next VSphere instance.
            $currentVSphere = $singleAction.Target

            if(-not $Credential -and -not $LoadCredential) {
                $currentCredential = update-credential -VSphere $currentVSphere `
                    -CurrentCreds $currentCredential
            }

            # Update the client.
            $vsphereClient.NewConnection($currentVSphere, $currentCredential)
        }

        # Append the file to the tracked list.
        $vsphereClient.AddFile($singleAction.Entity, $singleAction.From)
    }
    # Do a final removal for the last entry.
    $vsphereClient.RemoveFiles($DryRun, $logFile, $currentVSphere)

    # Print completion.
    $endTime = Get-Date
    write-closing -StartTime $startTime -EndTime $endTime -FileCount $vsphereClient.FileCount
    write-log -Message "Script completed." -FilePath $logFile -Level "INFO"
}

# Entrypoint.
$Error.Clear()
start-script
