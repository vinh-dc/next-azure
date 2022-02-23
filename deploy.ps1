echo "--Unzipping and copy files over"

#Expand-Archive -LiteralPath $Env:DEPLOYMENT_SOURCE\release.zip -DestinationPath $Env:DEPLOYMENT_SOURCE\_build

robocopy "$Env:DEPLOYMENT_SOURCE" "$Env:DEPLOYMENT_TARGET" /E /XF "$Env:DEPLOYMENT_SOURCE\.deployment" "$Env:DEPLOYMENT_SOURCE\deploy.ps1"

powershell $Env:DEPLOYMENT_TARGET\CreateDeployContentPackage.ps1
