<#
Picks up Parameters send as URI queries to the Jenkins build job, and runs Actions against CVAD, such as:

- Log off a Session
- Restart a Single Session VDA
- Power On a VDA
- Hide and Unhide a Session
- Remote a user's associated with a Desktop
- Remove a Machine entirely from the Broker (Machine catalog and Delivery group)

Not all of the functions work. I got the basics done and had to give up.

This code is not suitable for production, and is absolutely not supported by Citrix - it works, but it shouldn't be relied on. It's the result of a Hackathon, after all ;)

This code assume you're using the CVAD Service from Citrix Cloud, but it's certainly possible to make it work for on-prem CVAD, too. You'd need to tweak the Set-XDCredentials line
Making it work across multiple CVAD sites is beyond the scope of the hackathon, but again, entirely possible. You'd need a way to add the siteID to the database entry, 
and then you'd need to pass that back through the Jenkins Service Action to the Perform Self Service Action knows what site to run against.

Original concept: Phil Wiffen, Daniel Peacock
Most code here is by Phil, who is dangerous with PowerShell, and not even close to good :)

#> 

#Set secrets from Jenkins credential store (this keeps them secure, in Jenkins, and not sitting in the code)
$CvadApiKey = "$env:CvadApiKey"
$CvadApiSecret = "$env:CvadApiSecret"


#Set this to be your customerID in Citrix Cloud
$CustomerId = "$env:CitrixCloudCustomerID"

# We need the Citrix Remote Powershell SDK to pull information from CVAD
add-pssnapin citrix*

#Get common parameters and variables from the remote Job URI query
#Makes it cleaner to write functions later, knowing they are already set or pulled in

	
    $MachineName = "$env:MachineName"
	$UPN = "$env:UPN"
    $newPublishedName = "$env:newPublishedName"
    $sessionUid = "$env:sessionUid"


# Tasks below are defined as functions. At the bottom of this code, are the function calls themselves, if you want to see easily what's been defined

Function removeUserFromDesktop {
#Removes a User from an assigned Desktop. Useful for Remote PCs that have had multiple people log on, but who no longer want to see it in their Workspace
  
	Remove-BrokerUser -Name "$UPN" -Machine "$MachineName"

}


Function changePublishedName {
#Change name of Desktop in Workspace - useful for Remote PC customization use cases

  if ($newPublishedName -eq "") {
    Write-Host "PublishedName is blank. Halting job, as this could break the Published App"
  }
  
  else {
    Write-Host "Setting Published name of $MachineName to $newPublishedName for $UPN"
    Set-BrokerMachine -MachineName "$MachineName" -PublishedName "$newPublishedName"
  }
  
}

Function restartMachine {
    #Restarts a Machine
    
    <# 
    
        It is possible for the user to not be associated the Desktop when this is called. This might sound innocuous, but it isn't.
        Because there is a delay in the Status sync between CVADS and Microapps, the microapp user could have logged off, the machine rebooted,
        and then another user logged on before microapps gets the new synced data.
        If we let that reboot command happen, it would reboot the VDA for the new user who's logged in. Not cool.
        Because of this, we need to check the microapp user still is associated with the VDA before running a power command.
        We do that by using Get-BrokerMachine along with the User's UPN - because if that UPN from the microapp is no longer associated with
        the Machine, it won't return anything, and therefore the Power Option won't do anything. Win ;)
    #>
    Get-BrokerMachine -AssociatedUserUPN "$UPN" -MachineName "$MachineName" | New-BrokerHostingPowerAction -Action Restart
    
}

Function resetMachine {
    #Resets a Machine

       <# 
    
        It is possible for the user to not be associated the Desktop when this is called. This might sound innocuous, but it isn't.
        Because there is a delay in the Status sync between CVADS and Microapps, the microapp user could have logged off, the machine rebooted,
        and then another user logged on before microapps gets the new synced data.
        If we let that reboot command happen, it would reboot the VDA for the new user who's logged in. Not cool.
        Because of this, we need to check the microapp user still is associated with the VDA before running a power command.
        We do that by using Get-BrokerMachine along with the User's UPN - because if that UPN from the microapp is no longer associated with
        the Machine, it won't return anything, and therefore the Power Option won't do anything. Win ;)
    #>

    Get-BrokerMachine -AssociatedUserUPN "$UPN" -MachineName "$MachineName" | New-BrokerHostingPowerAction -Action Reset
    
}

Function powerOnMachine {
    #Powers On a Machine. Useful if you have Persistent desktops for users.
    
    <# 
    
        It is possible for the user to not be associated the Desktop when this is called. This might sound innocuous, but it isn't.
        Because there is a delay in the Status sync between CVADS and Microapps, the microapp user could have logged off, the machine rebooted,
        and then another user logged on before microapps gets the new synced data.
        If we let that reboot command happen, it would reboot the VDA for the new user who's logged in. Not cool.
        Because of this, we need to check the microapp user still is associated with the VDA before running a power command.
        We do that by using Get-BrokerMachine along with the User's UPN - because if that UPN from the microapp is no longer associated with
        the Machine, it won't return anything, and therefore the Power Option won't do anything
    #>
    Get-BrokerMachine -AssociatedUserUPN "$UPN" -MachineName "$MachineName" | New-BrokerHostingPowerAction -Action TurnOn
    
}

Function hideSession {
    Write-Host "Processing Session Hide Request for $UPN on $MachineName"
    #Hides a session, so that a user can login elsewhere: https://www.jgspiers.com/user-stuck-citrix-desktop-force-log-off/
    Get-BrokerSession -MachineName "$MachineName" -UserUPN "$UPN" | Set-BrokerSession -Hidden $true

}

Function unHideSession {
    Write-Host "Processing Session Unhide Request for $UPN on $MachineName"
    #Unhides a session, in case hiding doesn't fix the issue: https://www.jgspiers.com/user-stuck-citrix-desktop-force-log-off/
    Get-BrokerSession -MachineName "$MachineName" -UserUPN "$UPN" | Set-BrokerSession -Hidden $false

}

Function disconnectSession {

    Write-Host "Processing Session Disconnect Request for $UPN on $MachineName"
    #Disconnects the user's session on a machine

    #Get-BrokerSession can sometimes return a blank UPN for the associated user (I don't know why). So passing UPN could cause this to fail
    #However, it looks like there's always an "UntrustedUsername" property, so we get the User details via the UPN, and then call the Username later

    $UserNameObject = Get-BrokerUser -UPN "$UPN" -Property Name
    $UserName = $UserNameObject.Name

    # this is a little brute-force, but sometimes the untrusted username way doesn't work. So we try both UserUPN and untrustedusername
    # thinking about this, I suspect Untrusted username was populated in the past, because of a one-way trust.
    Get-BrokerSession -MachineName "$MachineName" -UserUPN "$UPN" | Disconnect-BrokerSession
    Get-BrokerSession -MachineName "$MachineName" -UntrustedUserName "$UserName" | Disconnect-BrokerSession
}


Function logOffSession {

    Write-Host "Processing Session Log Off Request for $UPN on $MachineName"
    #Logs off the user's session on a machine

    #Get-BrokerSession can sometimes return a blank UPN for the associated user (I don't know why). So passing UPN could cause this to fail
    #However, it looks like there's always an "UntrustedUsername" property, so we get the User details via the UPN, and then call the Username later

    $UserNameObject = Get-BrokerUser -UPN "$UPN" -Property Name
    $UserName = $UserNameObject.Name
    
    
    # this is a little brute-force, but sometimes the untrusted username way doesn't work. So we try both UserUPN and untrustedusername
    # thinking about this, I suspect Untrusted username was populated in the past, because of a one-way trust.
    Get-BrokerSession -MachineName "$MachineName" -UserUPN "$UPN" | Stop-BrokerSession
    Get-BrokerSession -MachineName "$MachineName" -UntrustedUserName "$UserName" | Stop-BrokerSession
}

Function removeDesktopFromWorkspace {
    #Removes a user's Desktop from Workspace and the CVADS backend. Only applies to Remote PCs. We enable this to allow people to self-remove old Remote PC VDAs they've since abandoned.
    
    #Some interesting reading on the Remote PC aspect is here: https://developer-docs.citrix.com/projects/delivery-controller-sdk/en/latest/Broker/Remove-BrokerDesktopGroup/

    #Find Remote PC Catalogs and groups with:
    #Get-BrokerDesktopGroup -IsRemotePC $true
    #Get-BrokerCatalog -IsRemotePC $true
    
    #Remove-BrokerMachine will remove from both a MachineCatalog, and a Delivery Group, but can only do one of these at a time. Desktop Group must be done first.
    
    #First, get the machine details using the variables we get from the
    $machine = Get-BrokerMachine -AssociatedUserUPN "$UPN" -MachineName "$MachineName"

    # only find Remote PC groups and catalogs - use IsRemotePC for this.
    $machineDeliveryGroup = Get-BrokerDesktopGroup -IsRemotePC $true -UUID $machine.DesktopGroupUUID
    $machineCatalog = Get-BrokerCatalog -IsRemotePC $true -UUID $machine.CatalogUUID
    
    #we don't want to run this against non-RemotePC groups and catalogs, so we need to warn/stop if the result of either is null
    if (($null -eq $machineDeliveryGroup) -or ($null -eq $machineCatalog)) { 
        
        Write-Host "!! This is not a Remote PC Delivery Group or Catalog !!"
    }

	# if both machine catalog and delivery group are RemotePC, then...
    if (($null -ne $machineDeliveryGroup) -and ($null -ne $machineCatalog)) {
        
        Write-Host "This is a Remote PC Delivery Group and Catalog, removing Machine"
        #pipe the machine object to the Remove-Broker Machine cmdlet
        # Have to push it with -DesktopGroup first, otherwise it won't be removed from the catalog.
        $machine | Remove-BrokerMachine -DesktopGroup $machineDeliveryGroup
        #this will then remove from the catalog, too
        $machine | Remove-BrokerMachine

    }
}

Function resetUPMProfile {
    #https://developer-docs.citrix.com/projects/citrix-virtual-apps-desktops-sdk/en/latest/Broker/New-BrokerMachineCommand/
    # sends a message to the broker to reset the User's UPM profile

    #get the MachineUid from the MachineName we passed from the Service Action
    $Machine = Get-BrokerMachine -MachineName "$MachineName" -Property Uid
    #get the UserName from the UPN we passed from the ServiceAction
    $UserName = Get-BrokerUser -UPN "$UPN"

    #Pass the .Uid and the .UserName from the objects above
    # apparently "-SendTrigger Broker" might work, but it doesn't seem to. Jobs just get stuck in Pending.
    New-BrokerMachineCommand -Category UserProfileManager -CommandName "ResetUpmProfile" -DesktopGroups $Machine.DesktopGroupUid -User $UserName.Name -SendTrigger Logon
}

Function resetRoamingProfile {
    #https://developer-docs.citrix.com/projects/citrix-virtual-apps-desktops-sdk/en/latest/Broker/New-BrokerMachineCommand/
    # sends a message to the broker to reset the User's Roaming Profile

    #get the MachineUid from the MachineName we passed from the Service Action
    $Machine = Get-BrokerMachine -MachineName "$MachineName"
    #get the UserName from the UPN we passed from the ServiceAction
    $UserName = Get-BrokerUser -UPN "$UPN"

    #Pass the .Uid and the .UserName from the objects above
    New-BrokerMachineCommand -Category UserProfileManager -CommandName "ResetRoamingProfile" -SendTrigger logon -MachineUid $Machine.Uid -user $UserName.Name
}



# CVADS (Citrix Virtual Apps and Desktops Service) connectivity

Write-Host "Connecting to CVAD..."

Set-XDCredentials -CustomerId "$CustomerId" -APIKey $CvadApiKey -SecretKey "$CvadApiSecret" -ProfileType CloudAPI

#Get the task to be done from the URI
$TaskToDo = "$env:TaskToDo"

#Using Switch instead of if and ifelse, because it is prettier and easier to follow

Switch ($TaskToDo)
{
  # if task is ... then { run Function named ... }
  # anything commented out doesn't work or hasn't been tested
  	"" { Write-Host "TaskToDo is blank, no further action"}
    "disconnectSession" { disconnectSession }
  	"removeUserFromDesktop" { removeUserFromDesktop }
    "changePublishedName" { changePublishedName }
    "restartMachine" { restartMachine }
    "resetMachine" { resetMachine }
    "powerOnMachine" { powerOnMachine }
    "hideSession" { hideSession }
    "unHideSession" { unHideSession }
    "logOffSession" { logOffSession }
    "removeDesktopFromWorkspace" { removeDesktopFromWorkspace }
    #"resetUPMProfile" { resetUPMProfile }
    #"resetRoamingProfile" { resetRoamingProfile }
}

