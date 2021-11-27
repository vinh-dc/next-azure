$NextAzureConfigFileName = '.nextazure.json'
$AzDevOpsApiVersion = '6.0-preview'

function Get-NextAzureConfig {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ($Path) {
        $ConfigFileName = Split-Path -Path $Path -Leaf

        if ($ConfigFileName -ne $NextAzureConfigFileName) {
            Throw "Config path '$Path' must be to a '$NextAzureConfigFileName' file"
        }
    }

    $ConfigPath = $Path ? $Path : (Get-NextAzureConfigPath -ConfigDir $MyInvocation.PSScriptRoot)

    if (!$ConfigPath) {
        Write-Information "Could not find '$NextAzureConfigFileName' config file in project"

        return $null
    }

    if (Test-Path -Path $ConfigPath -PathType Leaf) {
        Write-Information "Loading config file '$ConfigPath'"

        $Settings = Get-Content -Path $ConfigPath | ConvertFrom-JSON

        return @{
            Settings = $Settings
            Path = $ConfigPath
        }
    }

    Throw "Could not read config file '$ConfigPath'"
}

function Get-NextAzureConfigPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ConfigDir
    )

    $ConfigPath = Join-Path $ConfigDir $NextAzureConfigFileName

    Write-Verbose "Searching for '$NextAzureConfigFileName' config file in '$ConfigPath'"

    if (Test-Path -Path $ConfigPath -PathType Leaf) {
        return $ConfigPath
    }

    # `next.config.js` is at the root of a Next.js project so if we have reached that and still not found our config file then there is no need to go further - assume it doesn't exist

    $NextConfigFileName = 'next.config.js'
    $NextConfigPath = Join-Path $ConfigDir $NextConfigFileName

    if (Test-Path -Path $NextConfigPath -PathType Leaf) {
        return $null
    }

    $ParentConfigDir = Split-Path -Path $ConfigDir -Parent

    if ($ParentConfigDir) {
        return Get-NextAzureConfigPath -ConfigDir $ParentConfigDir
    }

    return $null
}

function Set-NextAzureConfig {
    [CmdletBinding()]
    param(
        $Config,
        [Parameter(Mandatory=$true)]
        [hashtable]$Settings
    )

    $ConfigPath = $null
    $ConfigSettings = $null

    if ($Config) {
        # Check config path is valid

        $ConfigPath = $Config.Path
        $ConfigFileName = Split-Path -Path $ConfigPath -Leaf

        if ($ConfigFileName -ne $NextAzureConfigFileName) {
            Throw "Config path '$ConfigPath' must be to a '$NextAzureConfigFileName' file"
        }

        # "Merge" in each setting

        Write-Information "Updating config file '$ConfigPath'"

        $ConfigSettings = $Config.Settings

        foreach ($Key in $Settings.Keys) {
            $ConfigSetting = $ConfigSettings.$Key

            $Value = $Settings[$Key]

            if ($ConfigSetting) {
                $ConfigSettings.$Key = $Value
            }
            else {
                $ConfigSettings | Add-Member -MemberType NoteProperty -Name $Key -Value $Value
            }
        }
    }
    else {
        # Create new config from settings

        $ConfigPath = Join-Path $MyInvocation.PSScriptRoot $NextAzureConfigFileName

        Write-Information "Creating config file '$ConfigPath'"

        $ConfigSettings = [pscustomobject]$Settings
    }

    # Write settings as json to path

    $ConfigSettings | ConvertTo-Json -depth 1 | Set-Content -Path $ConfigPath

    # Return the new or updated settings

    return @{
        Settings = $ConfigSettings
        Path = $ConfigPath
    }
}

function Set-AzCliDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Config
    )

    az account set --subscription $($Config.Settings.SubscriptionId)

    Write-Information "az account set"

    az devops configure --defaults organization=$($Config.Settings.OrgUrl) project=$($Config.Settings.ProjectName)

    Write-Information "az devops config set"
}

function Set-NextAzureDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Config,
        [Parameter(Mandatory=$true)]
        [string]$WebAppSkuName,
        [int]$WebAppSkuCapacity = 1
    )

    # Set Variable Group

    Write-Information "--- Setting up defaults ---"

    Write-Information "Setting Variable Group"

    $ResourcePrefix = $Config.Settings.ResourcePrefix

    $Variables = @{
        AzureResourcePrefix = $ResourcePrefix
        WebAppSkuName = $WebAppSkuName
        WebAppSkuCapacity = $WebAppSkuCapacity
    }

    $null = Set-AzVariableGroup -ResourcePrefix $ResourcePrefix -Variables $Variables
}

function Set-NextAzureEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Config,
        [Parameter(Mandatory=$true)]
        [string]$Environment
    )

    $ResourcePrefix = $Config.Settings.ResourcePrefix

    Write-Information "--- Setting up '$Environment' environment ---"

    # Set Resource Group

    Write-Information "Setting Resource Group"

    $AzResourceGroup = Set-AzResourceGroup `
    -ResourcePrefix $ResourcePrefix `
    -Environment $Environment `
    -Location $($Config.Settings.Location)

    Write-Line

    # Set Service Connection

    Write-Information "Setting Service Connection"

    $AzServiceConnection = Set-AzServiceConnection `
    -ResourcePrefix $ResourcePrefix `
    -Environment $Environment

    Write-Line

    # Give `Contributor` access to Service Connection Principal on the Resource Group

    Write-Information "Setting Role Assignment on Resource Group for Service Connection"

    $AzServicePrincipal = Get-AzServicePrincipal `
    -ResourcePrefix $ResourcePrefix `
    -Environment $Environment

    $null = Set-AzRoleAssignment `
    -Role 'Contributor' `
    -Assignee $AzServicePrincipal.objectId `
    -Scope $AzResourceGroup.id

    Write-Line

    # Set Environment

    Write-Information "Setting Environment"

    $AzEnvironment = Set-AzEnvironment `
    -ResourcePrefix $ResourcePrefix `
    -Environment $Environment `
    -OrgUrl $($Config.Settings.OrgUrl) `
    -ProjectName $($Config.Settings.ProjectName)

    Write-Line

    # Set Variable Group

    Write-Information "Setting Variable Group"

    $Variables = @{
        EnvironmentName = $Environment
        AzureEnvironment = $AzEnvironment.name
        AzureResourceGroup = $AzResourceGroup.name
        AzureServiceConnection = $AzServiceConnection.name
        WebAppCertName = ''
        WebAppDomainName = ''
        WebAppSlotName = ''
        WebAppSwapSlotName = ''
    }

    $null = Set-AzVariableGroup `
    -ResourcePrefix $ResourcePrefix `
    -Environment $Environment `
    -Variables $Variables

    if ($Config.Settings.UseDeploymentSlots) {
        Write-Line

        # Get shared resource group
        $AzSharedResourceGroup = Get-AzResourceGroup $ResourcePrefix

        $null = Set-NextAzureEnvironmentAppServiceSlot `
        -ResourcePrefix $ResourcePrefix `
        -Environment $Environment `
        -SharedResourceGroupId $AzSharedResourceGroup.id
    }
}

function Set-NextAzureUseAppServiceSlots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Config,
        [Parameter(Mandatory=$true)]
        [string]$ProductionEnvironment,
        [Parameter(Mandatory=$true)]
        [string]$WebAppSkuName
    )

    $ResourcePrefix = $Config.Settings.ResourcePrefix

    Write-Information "--- Setting up deployment slots ---"

    Write-Information "Setting shared Resource Group"

    $AzResourceGroup = Set-AzResourceGroup `
    -ResourcePrefix $ResourcePrefix `
    -Location $($Config.Settings.Location)

    Write-Line

    Write-Information "Setting default Variable Group"

    $Variables = @{
        AzureSharedResourceGroup = $AzResourceGroup.name
        WebAppSkuName = $WebAppSkuName
    }

    $null = Set-AzVariableGroup -ResourcePrefix $ResourcePrefix -Variables $Variables

    Write-Line

    # Set existing environments

    $Environments = Get-NextAzureEnvironments -ResourcePrefix $ResourcePrefix

    foreach ($Environment in $Environments) {
        $null = Set-NextAzureEnvironmentAppServiceSlot `
        -ResourcePrefix $ResourcePrefix `
        -Environment $Environment `
        -SharedResourceGroupId $($AzResourceGroup.id)

        Write-Line
    }
}

function Set-NextAzureEnvironmentAppServiceSlot {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [Parameter(Mandatory=$true)]
        [string]$Environment,
        [Parameter(Mandatory=$true)]
        [string]$SharedResourceGroupId
    )

    Write-Information "--- Setting up '$Environment' deployment slot"

    Write-Information "Setting Role Assignment on Resource Group for Service Connection"

    $AzServicePrincipal = Get-AzServicePrincipal `
    -ResourcePrefix $ResourcePrefix `
    -Environment $Environment

    $null = Set-AzRoleAssignment `
    -Role 'Contributor' `
    -Assignee $AzServicePrincipal.objectId `
    -Scope $SharedResourceGroupId

    Write-Line

    Write-Information "Setting Variable Group"

    $WebAppSlotName = $Environment -eq $ProductionEnvironment ? 'production' : $Environment

    $Variables = @{
        WebAppSlotName = $WebAppSlotName
        WebAppSkuName = $null
    }

    $null = Set-AzVariableGroup `
    -ResourcePrefix $ResourcePrefix `
    -Environment $Environment `
    -Variables $Variables `
    -UpdateOnly
}

function Get-NextAzureEnvironments {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix
    )

    $Environments = (az pipelines variable-group list `
    --query "[?starts_with(name, ``$ResourcePrefix-env-vars-``)].variables.EnvironmentName.value" `
    | ConvertFrom-Json)

    return $Environments
}

function Test-NextAzureEnvironment {
    param(
        [Parameter(Mandatory=$true)]
        $Config,
        [Parameter(Mandatory=$true)]
        [string]$Environment
    )

    $Environments = Get-NextAzureEnvironments -ResourcePrefix $($Config.Settings.ResourcePrefix)

    return $Environments -contains $Environment
}

function Get-NextAzureResourceName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prefix,
        [string]$Environment,
        [string]$Suffix,
        [string]$Delimiter = '-'
    )

    $Name = @($Prefix)

    if ($Environment) {
        $Name += $Environment
    }

    if ($Suffix) {
        $Name += $Suffix
    }

    return $Name -join $Delimiter
}

function Get-CurrentAzSubscription {
    $Subscription = (az account show | ConvertFrom-Json)

    return $Subscription
}

function Get-AzResourceGroup {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment
    )

    $Name = Get-AzResourceGroupName -ResourcePrefix $ResourcePrefix -Environment $Environment

    $ResourceGroup = (az group show --name $Name | ConvertFrom-Json)

    return $ResourceGroup
}

function Get-AzResourceGroupName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment
    )

    return Get-NextAzureResourceName -Prefix $ResourcePrefix -Environment $Environment -Suffix 'rg'
}

function Set-AzResourceGroup {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment,
        [Parameter(Mandatory=$true)]
        [string]$Location
    )

    $Name = Get-AzResourceGroupName -ResourcePrefix $ResourcePrefix -Environment $Environment

    Write-Information "Creating (or updating existing) Resource Group '$Name'"

    $ResourceGroup = (az group create --name $Name --location $Location | ConvertFrom-Json)

    return $ResourceGroup
}

function Get-AzServicePrincipal {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment
    )

    $Name = Get-AzServicePrincipalName -ResourcePrefix $ResourcePrefix -Environment $Environment

    $ServicePrincipal = (az ad sp list --display-name $Name --query '[0]' | ConvertFrom-Json)

    return $ServicePrincipal
}

function Get-AzServicePrincipalName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment
    )

    return Get-NextAzureResourceName -Prefix $ResourcePrefix -Environment $Environment -Suffix 'sp'
}

function Set-AzServicePrincipal {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment
    )

    $Name = Get-AzServicePrincipalName -ResourcePrefix $ResourcePrefix -Environment $Environment

    Write-Information "Creating (or updating existing) Service Principal '$Name'"

    $ServicePrincipal = (az ad sp create-for-rbac --name $Name  --skip-assignment | ConvertFrom-Json)

    # We need to update the Service Prinipal to add SPN auth, but we suppress the output
    $VsSpnUrl = 'https://VisualStudio/SPN'

    $null = az ad app update --id $ServicePrincipal.appId --reply-urls $VsSpnUrl --homepage $VsSpnUrl

    return $ServicePrincipal
}

function Set-AzRoleAssignment {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Role,
        [Parameter(Mandatory=$true)]
        [string]$Assignee,
        [Parameter(Mandatory=$true)]
        [string]$Scope
    )

    Write-Information "Creating (or updating existing) '$Role' Role Assignment"

    $RoleAssignment = (az role assignment create `
    --role $Role `
    --assignee $Assignee `
    --scope $Scope `
    | ConvertFrom-Json)

    return $RoleAssignment
}

function Get-AzServiceConnection {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $ServiceConnection = (az devops service-endpoint list --query "[?name == '$Name'] | [0]" | ConvertFrom-Json)

    return $ServiceConnection
}

function Set-AzServiceConnection {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment
    )

    $Name = Get-NextAzureResourceName -Prefix $ResourcePrefix -Environment $Environment

    $ServiceConnection = Get-AzServiceConnection -Name $Name

    if ($ServiceConnection) {
        # If the Service Connection already exists there is nothing more to do

        Write-Information "Service Connection '$Name' already exists - no action taken"

        return $ServiceConnection
    }

    # To create a Service Connection we need a Service Principal

    $ServicePrincipal = Set-AzServicePrincipal -ResourcePrefix $ResourcePrefix -Environment $Environment

    $ServicePrincipalId = $ServicePrincipal.appId
    $ServicePrincipalPassword = $ServicePrincipal.password

    # The Service Principal password must be available via an environment variable for the Service Connection
    $env:AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY=$ServicePrincipalPassword

    # We also need Subscription info

    $Subscription = Get-CurrentAzSubscription
    $SubscriptionId = $Subscription.id
    $SubscriptionName = $Subscription.name
    $TenantId = $Subscription.tenantId

    # Now we can create the Service Connection

    Write-Information "Creating Service Connection '$Name'"

    $ServiceConnection = (az devops service-endpoint azurerm create `
    --azure-rm-service-principal-id $ServicePrincipalId `
    --azure-rm-subscription-id $SubscriptionId `
    --azure-rm-subscription-name $SubscriptionName `
    --azure-rm-tenant-id $TenantId `
    --name $Name `
    | ConvertFrom-Json)

    if ($ServiceConnection) {
        $ServiceConnectionId = $ServiceConnection.id

        # Grant access permission to all pipelines and suppress output
        $null = az devops service-endpoint update --id $ServiceConnectionId --enable-for-all
    }
    else {
        Write-Error "Service Connection could not be created"
    }

    return $ServiceConnection
}

function Get-AzEnvironment {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [Parameter(Mandatory=$true)]
        [string]$Project,
        [Parameter(Mandatory=$true)]
        [string]$Organization
    )

    # There is no `environment` subcommand so we have to use `invoke`, but the invoke command doesn't pick up the default project from config so we use a param

    $Environment = (az devops invoke `
    --area distributedtask `
    --resource environments `
    --route-parameters "project=$Project" `
    --org $Organization `
    --query "value[?name=='$Name'] | [0]" `
    --api-version $AzDevOpsApiVersion `
    --output json `
    | ConvertFrom-Json)

    return $Environment
}

function Set-AzEnvironment {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [Parameter(Mandatory=$true)]
        [string]$Environment,
        [Parameter(Mandatory=$true)]
        [string]$OrgUrl,
        [Parameter(Mandatory=$true)]
        [string]$ProjectName
    )

    $Name = Get-NextAzureResourceName -Prefix $ResourcePrefix -Environment $Environment

    # There is no `environment` subcommand so we have to use `invoke`

    $AzEnvironment = Get-AzEnvironment -Name $Name -Project $ProjectName -Organization $OrgUrl

    if ($AzEnvironment) {
        # If the Environment already exists there is nothing more to do

        Write-Information "Environment '$Name' already exists - no action taken"

        return $AzEnvironment
    }

    # Create the Environment

    Write-Information "Creating Environment '$Name'"

    # This `invoke` request requires that we send json via the `--in-file` param so we will create a temporary file
    $RequestPayload = @{
        name = $Name
    }

    $TempDrive = Get-PSDrive Temp
    $TempPath = $TempDrive.Root

    $RequestPayloadPath = Join-Path $TempPath 'AzDevOpsEnvBody.json'

    Set-Content -Path $RequestPayloadPath -Value ($RequestPayload | ConvertTo-Json)

    $null = az devops invoke `
    --area distributedtask `
    --resource environments `
    --route-parameters "project=$ProjectName" `
    --org $OrgUrl `
    --http-method POST `
    --in-file $RequestPayloadPath `
    --api-version $AzDevOpsApiVersion

    # Remove the temp payload file
    Remove-Item $RequestPayloadPath -Force

    # The command to create the Environment doesn't return a useful response so we will fetch it and return
    $AzEnvironment = Get-AzEnvironment -Name $Name -Project $ProjectName -Organization $OrgUrl

    return $AzEnvironment
}

function Get-AzVariableGroup {
    param(
        [int]$Id,
        [string]$Name
    )

    if ($Id) {
        $VariableGroup = (az pipelines variable-group show --group-id $Id | ConvertFrom-Json)

        return $VariableGroup
    }

    if ($Name) {
        $VariableGroup = (az pipelines variable-group list `
        --query "[?name=='$Name'] | [0]" `
        | ConvertFrom-Json)

        return $VariableGroup
    }

    return $null
}

function Set-AzVariableGroup {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourcePrefix,
        [string]$Environment,
        [Parameter(Mandatory=$true)]
        [hashtable]$Variables,
        [switch]$UpdateOnly
    )

    $Name = Get-NextAzureResourceName -Prefix "$ResourcePrefix-env-vars" -Environment $Environment

    $VariableGroup = Get-AzVariableGroup -Name $Name

    if ($VariableGroup) {
        # Update the Variable Group

        Write-Information "Updating Variable Group '$Name'"

        $VariableGroup = Set-AzVariableGroupVariables `
        -VariableGroupId $($VariableGroup.id) `
        -Variables $Variables `
        -UpdateOnly:$UpdateOnly

        return $VariableGroup
    }

    if ($UpdateOnly) {
        return $null
    }

    # Create the Variable Group

    Write-Information "Creating Variable Group '$Name'"

    $VariablesArgs = @()
    foreach($Key in $Variables.Keys)
    {
        $VariablesArgs += '{0}="{1}"' -f $Key, $Variables[$Key]
    }

    $VariableGroup = (az pipelines variable-group create `
    --name $Name `
    --authorize `
    --variables $VariablesArgs `
    | ConvertFrom-Json)

    return $VariableGroup
}

function Set-AzVariableGroupVariables {
    param(
        [Parameter(Mandatory=$true)]
        [int]$VariableGroupId,
        [Parameter(Mandatory=$true)]
        [hashtable]$Variables,
        [switch]$UpdateOnly
    )

    $GroupVariables = (az pipelines variable-group variable list --group-id $VariableGroupId | ConvertFrom-Json)

    foreach($Key in $Variables.Keys) {
        $GroupVariable = $GroupVariables.$Key

        $Value = $Variables[$Key]

        if ($GroupVariable) {
            $CurrentValue = $GroupVariables.$Key.value

            if ($Value -eq $CurrentValue) {
                Write-Information "Value of Variable '$Key' has not changed"
            }
            else {
                Write-Information "Updating Variable '$Key'"

                $null = Set-AzVariableGroupVariable -VariableGroupId $VariableGroupId -Name $Key -Value $Value
            }
        }
        elseif (!$UpdateOnly) {
            Write-Information "Creating Variable '$Key'"

            $null = New-AzVariableGroupVariable -VariableGroupId $VariableGroupId -Name $Key -Value $Value
        }
        else {
            Write-Information "Variable '$Key' does not exist - ignoring"
        }
    }

    $VariableGroup = Get-AzVariableGroup -Id $VariableGroupId

    return $VariableGroup
}

function New-AzVariableGroupVariable {
    param(
        [Parameter(Mandatory=$true)]
        [int]$VariableGroupId,
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [string]$Value
    )

    $Variable = $null

    if ($Value) {
        $Variable = (az pipelines variable-group variable create `
        --group-id $VariableGroupId `
        --name $Name `
        --value $Value `
        | ConvertFrom-Json)
    }
    else {
        # If there is no value we omit the `--value` arg
        $Variable = (az pipelines variable-group variable create `
        --group-id $VariableGroupId `
        --name $Name `
        | ConvertFrom-Json)
    }

    return $Variable
}

function Set-AzVariableGroupVariable {
    param(
        [Parameter(Mandatory=$true)]
        [int]$VariableGroupId,
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [string]$Value
    )

    # Cannot "clear" a value - setting `value` to $null is an error; omitting the `value` is an error
    #TODO: Raise issue upstream - cannot "clear" a variable using update; cannot delete as the delete command hangs
    $Variable = (az pipelines variable-group variable update `
    --group-id $VariableGroupId `
    --name $Name `
    --value $($Value ? $Value : $null) `
    | ConvertFrom-Json)

    return $Variable
}

function Write-Line {
    [CmdletBinding()]
    param()

    Write-Information ''
}

Export-ModuleMember -Function Get-NextAzureConfig
Export-ModuleMember -Function Set-NextAzureConfig
Export-ModuleMember -Function Set-AzCliDefaults
Export-ModuleMember -Function Set-NextAzureDefaults
Export-ModuleMember -Function Set-NextAzureEnvironment
Export-ModuleMember -Function Set-NextAzureUseAppServiceSlots
Export-ModuleMember -Function Test-NextAzureEnvironment
Export-ModuleMember -Function Write-Line
