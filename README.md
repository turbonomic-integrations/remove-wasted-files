# Motivation

This is a standalone PowerShell script designed to removed wasted files from VMware datastores as identified by Turbonomic. Currently, Turbonomic will only make recommendations for the removal of wasted files. This script is designed to ingest an export of those recommendations from a Turbonomic instance and execute the removal. The solution offers various options for running completely interactive, running completed unattended, and various intervals between.

The default behavior when running with no command line parameters is to:

1. Prompt for the CSV file to ingest.
2. Prompt for credentials to each vCenter instance.
3. Write a log file of files discovered/deleted in the same directory as the script itself.

This behavior can be modified via the command line parameters highlighted below.

# Requirements

The code was designed with PowerShell 7; previous instances have not been tested.

The [PowerCLI](https://www.powershellgallery.com/packages/VMware.PowerCLI/) module is required. If it isn't found, the user will be instructed to install it via:

```powershell
Install-Module -Name VMware.PowerCLI
```

# Assumptions

The code assumes that all vCenter instances it will need to connect with are accessible from where it is running.

It is assumed that no files will need to be excluded at the time of execution. Files which should not be deleted should either be removed from CSV file or, ideally, excluded from the policy within Turbonomic to avoid identifying them as wasted files in the first place.

An export of wasted storage actions from Turbonomic drives the cleanup. Though only the `Entity`, `Target`, and `From` columns are required, it is recommended to leave the file untouched when exported from Turbonomic aside from removing any rows containing files which should _not_ be deleted.

## Exporting Action Report

A CSV report of the deletion recommendations can be generated from the Turbonomic UI. From the landing page after logging in, click on "On-Prem". On the "Pending Actions" widget, click "Show All". Under the categories to the left side of the screen, expand "Delete" and then select "Storage Devices". The actions displayed should now all be for deleting wasted files. Clicking the arrow in the top-right corner of the screen will download all of the actions as a CSV. This CSV file should be updated to remove the lines for any files that should be kept, and then it can be used along with this script to automate the removal of any that remain.

# Execution

The solution offers a variety of ways to execute it based on the situation. All of the CLI parameters can be discovered via PowerShell itself by running (assuming the current shell is at the root of the repository):

```powershell
Get-Help -Name ./src/pwsh/remove-wastedFiles.ps1
```

This can be supplemented by additional switches such as `-Full` or `-Example` for specific parts of the documentation.

## Syntax

```powershell
./remove-wastedFiles.ps1 [[-FilePath] <String>] [-SuppressLogFile] [-Credential] [-StoreCredential] [-LoadCredential] [-NoWarning] [-WhatIf]
```

## Default Behavior

```powershell
./remove-wastedFiles.ps1
```


Running with no parameters will result in an interactive experience. The user will be warned that files will be deleted and anything which should be retained needs to be removed from the CSV file ahead of time. The user will next be prompted to provide the path to the CSV file to ingest. The file will then be processed, one vCenter instance at a time. No assumption is made that every vCenter is accessible via the same credentials, so new creds are prompted for each time (though leaving the prompt blank will re-use the previous credentials.) When the execution finishes, a final tally is printed for how many files were removed and how long the execution took.

## Suppress Logging

```powershell
./remove-wastedFiles.ps1 -SuppressLogFile
```

By default, the script will create a file named `remove_wastedfiles_{timestamp}.log` in the same directory as the script itself. This logs the run history for which files were discovered or deleted against which vCenter instances and datastores. The inclusion of the `-SuppressLogFile` switch will prevent the log file from being written. The information will still be displayed to the shell.

## Single Set of Credentials

```powershell
./remove-wastedFiles.ps1 -Credential
```

Including the `-Credential` switch will result in the _same_ set of credentials being used for all vCenter instances. The user will be prompted to enter the credentials one time prior to the processing of the CSV file.

## File Path at CLI

```powershell
./remove-wastedFiles.ps1 -FilePath ./Pending_Actions.csv
```

The `-FilePath` parameter allows the path to the CSV file to be given at the command line rather than interactively. This can be useful for automated scenarios or simply because entering the path from the CLI will allow for tab completion.

## Avoid Warning

```powershell
./remove-wastedFiles.ps1 -NoWarning
```

By default, the script warns the user at every run to make clear that files will be removed. The user must hit "Enter" to proceed. The `-NoWarning` switch will prevent this warning from showing.

## Store Credentials in a File

```powershell
./remove-wastedFiles.ps1 -StoreCredential
```

For automation scenarios, it can be useful to store credentials rather than forcing them to be entered. The `-StoreCredential` switch will trigger a helper function, causing all other execution in the script to be ignored. Instead, the user will be prompted for credentials which are stored in an encrypted XML file in the same directory as the script itself. If there's an existing credential file, triggering this helper function again will overwrite it.

## Load Credentials from a File

```powershell
./remove-wastedFiles.ps1 -LoadCredential
```

The compliment to `-StoreCredential`, this flag causes the credentials to be read from the encrypted XML file in the same directory as the script. The user will not see any prompt. `-Credential` and `-NoWarning` are both assumed.

## Test Run

```powershell
./remove-wastedFiles.ps1 -WhatIf
```

The `-WhatIf` switch causes the script to go through a test run which validates connectivity and the format of the file without actually removing any files. Instead, the code simply verifies that it can read the files on the target datastore. All other aspects of the script continue as normal. _Note_: The flags `-WhatIf` and `-DryRun` can be used interchangeably.

## Combining Parameters

The above parameters can be combined as needed. For example, the following will run the script without the warning **and** while specifying the path to the file from the CLI:

```powershell
./remove-wastedFiles.ps1 -FilePath ./Pending_Actions.csv -NoWarning
```

The only exception is `-StoreCredential` which will override any other parameters.
