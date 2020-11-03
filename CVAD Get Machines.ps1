<#
Gets SingleSession VDAs (including Remote PC and non-persistent Desktops in CVADS and loads them into restdb.io)

Making this get Multi-Session Machines is trivial, but not advised. As you'll need to create logic in the Microapp to handle Restarts for multi-session machines. 
My preference was to err on the side of caution, and only allow people to restart their own single-session Machines

This code is not suitable for production, and is absolutely not supported by Citrix - it works, but it shouldn't be relied on. It's the result of a Hackathon, after all ;)

This code assume you're using the CVAD Service from Citrix Cloud, but it's certainly possible to make it work for on-prem CVAD, too. You'd need to tweak the Set-XDCredentials line
Making it work across multiple CVAD sites is beyond the scope of the hackathon, but again, entirely possible. You'd need a way to add the siteID to the database entry, 
and then you'd need to pass that back through the Jenkins Service Action to the Perform Self Service Action knows what site to run against.

Original concept: Phil Wiffen, Daniel Peacock
Most code here is by Phil, who is dangerous with PowerShell, and not even close to good :)

#> 


# We need the Citrix Remote Powershell SDK to pull information from CVAD
add-pssnapin citrix*


#Set secrets from Jenkins credential store (this keeps them secure, in Jenkins, and not sitting in the code)
$restDbToken = "$env:restDbToken"
$CvadApiKey = "$env:CvadApiKey"
$CvadApiSecret = "$env:CvadApiSecret"

# set this to the max number of Desktops or Sessions you wants CVADS to return. Bigger environments will need a higher number. Default is 30000
$maximumRecordCount = "60000"

#Set this to be your customerID in Citrix Cloud
$CustomerId = "$env:CitrixCloudCustomerID"

#restdb.io URI (path to collection) example: https://managemysessionsanddesktop.restdb.io/rest/machines
$restdbioURI = "$env:restdbioURI"

#this function acts as a "helper" to call the restdb.io service and get or push JSON. Credit for this goes to Daniel Peacock. Thanks Dan!
function New-APICall($URI, $Method, $Body){
    $RestParams = @{
        Headers     = @{ 'x-apikey' = $restDbToken }
        ContentType = 'application/json'
        Uri         = $URI
        Method      = $Method
    }
    if($Method -ne "GET"){
      $RestParams.Add("Body", $Body)
    }
    return Invoke-RestMethod @RestParams
}

# CVADS (Citrix Virtual Apps and Desktops Service) connectivity
Write-Host "Connecting to CVAD..."

# set credentials to use while the script runs
Set-XDCredentials -CustomerId "$CustomerId" -APIKey $CvadApiKey -SecretKey "$CvadApiSecret" -ProfileType CloudAPI

#get all single-session VDAs (both Server and Desktop OS) - pull in only essential Properties:
$singleSessionVDAs = Get-BrokerMachine -MaxRecordCount $maximumRecordCount -SessionSupport SingleSession -Property Uid,MachineName,PublishedName,RegistrationState,LastDeregistrationReason,LastDeregistrationTime,PowerState,LastConnectionTime,DNSName,IPAddress,AssociatedUserUPNs,AllocationType,DesktopGroupName,InMaintenanceMode,ProvisioningType,AgentVersion,OSType,LastErrorReason,LastErrorTime

#we want to get only VDAs that have an associated UserUPN. Because we should only allow people to control Machines if they're associated with it.
$associatedSingleSessionVDAs = $singleSessionVDAs | where-object {$_.AssociatedUserUPNs -ne $null }

#next we need to expand out any Machine which has multiple people associated with it - to give each person an entry in the NoSQL database:
$everyUserWithAssociatedSingleSessionVDAs = $associatedSingleSessionVDAs | Select-Object -ExpandProperty AssociatedUserUPNs -Property *

#This is a terrible hack to make it so that I can remove the "value" property. We convert to JSON, then back again:
$everyUserWithAssociatedSingleSessionVDAs = $everyUserWithAssociatedSingleSessionVDAs | ConvertTo-JSON | ConvertFrom-JSON

# now we effectively change the AssociatedUserUPNs column name to UPN, and delete the "value" column, as it's redundant.
foreach ($user in $everyUserWithAssociatedSingleSessionVDAs)
{

        # add the UPN from the Value property to a new PropertyName (or column) called UPN:
        $associatedUserUPN = $user | Select-Object -ExpandProperty value
        $user | Add-Member -NotePropertyName "UPN" -NotePropertyValue $associatedUserUPN

        # We then drop the Value property, as it's no longer needed (it's just the UPN, again)
        # and we drop AssociatedUserUPNs for the same reason
        $user.psobject.properties.remove("value")
        $user.psobject.properties.remove("AssociatedUserUPNs")

}

# we now have a clean per-person entry for each Machine in CVAD.


# now we need to compare what's in the NoSQL database, with what's in CVAD right now, and upload the changes. Changes could be: New entry in CVAD. An entry is done from CVAD. The state of an existing entry has changed (such as Active > Disconnected)
# this is done on a "per entry" basis to keep the API json payload small.

#pull in the NoSQL DB:
$singleSessionVDAsinNoSQLDB = New-APICall -URI "$restdbioURI" -Method "GET"

#compare it what we got from CVAD and then massaged earlier:
$singleSessionVDAsDifferences = Compare-Object -ReferenceObject $singleSessionVDAsinNoSQLDB -DifferenceObject $everyUserWithAssociatedSingleSessionVDAs -Property Uid,UPN

# now we run through each difference identified and either add or delete it from the NoSQL DB. This typically occurs when someone either logs off of, or on to, a single session VDA
foreach ($difference in $singleSessionVDAsDifferences) {

  #new VDA assigned in CVADS, that is not in the NoSQL DB (so need to be added to the NoSQL DB)
  if ($difference.sideIndicator -eq "=>") { 
    Write-Host "Uid "$difference.Uid" and "$difference.UPN" is in CVADS, but not in NoSQL, so needs to be added to the NoSQL DB"
    # now get the object from CVADS based on the Uid and UPN we know, then convert it to JSON
    $singleSessionToAdd = $everyUserWithAssociatedSingleSessionVDAs | Where-Object {($_.Uid -eq $difference.Uid) -and ($_.UPN -eq $difference.UPN)} | ConvertTo-JSON
    #add the entry to NoSQL:
    New-APICall -URI "$restdbioURI" -Method "POST" -Body "$singleSessionToAdd"

  }

#sessions in the NoSQL DB, that are not in CVADS (so need to be deleted from the NoSQL DB)
   if ($difference.sideIndicator -eq "<=") {
    Write-Host "Uid "$difference.Uid"  and "$difference.UPN" is no longer in CVADS, so needs to be removed from the NoSQL DB"
          # now get the object from CVADS based on the Uid we know and the UPN - we need the UPN, otherwise a desktop with multiple users assigned, would return an array and break this function :)
          #$singleSessionToRemove = $singleSessionVDAsinNoSQLDB | Where-Object {($_.Uid -eq $difference.Uid) -and ($_.UPN -eq $difference.UPN)}
          # added Select-Object -First 1, becasue i had an instance where the same desktop uid + UPN appearedmultiple times in the database. I don't know why.
          # By adding the "first 1" it limits the response - so the delete will complete. The next number of times the script is run, it should delete the other entries too - eventually reaching sanity.
          $singleSessionToRemove = $singleSessionVDAsinNoSQLDB | Where-Object UPN -eq $difference.UPN | Where-Object Uid -eq $difference.Uid | Select-Object -First 1
          # get the ID of the entry in NoSQL, because that's what we have to pass to the API endpoint to delete the entry:
          $noSQLIDtoRemove = $singleSessionToRemove._id
          # request to delete that specific entry:
          New-APICall -URI "$restdbioURI/$noSQLIDtoRemove" -Method "Delete" -Body ""

   }

}


<# now to check for any state changes, such as powerstate, or registrationstate, or published name#>
#refresh what's in the NoSQL DB, because if we don't, this next phase fails on new entries:
$singleSessionVDAsinNoSQLDB = New-APICall -URI "$restdbioURI" -Method "GET"

#now find sessions whose SessionState has changed:

#because SessionState is stored as a number in NoSQL and as a label in CVADS, they will always be different. So we need to convert CVADS data to JSON and back again
# so the value goes from for example "Active" to "2" and then we convert the JSON back into powershell objects so we can use it in the comparison, but it now says "2"
$everyUserWithAssociatedSingleSessionVDAs = $everyUserWithAssociatedSingleSessionVDAs| ConvertTo-JSON | ConvertFrom-JSON


<# TODO: handle changes to date-based states. Right now, they don't compare properly because the formatting differs. #>

$singleSessionVDAsStateChanges = Compare-Object -ReferenceObject $singleSessionVDAsinNoSQLDB -DifferenceObject $everyUserWithAssociatedSingleSessionVDAs -Property Uid,UPN,PowerState,PublishedName,DNSName,MachineName,InMaintenanceMode,OSType,AgentVersion,RegistrationState,LastErrorReason,LastErrorTime

foreach ($difference in $singleSessionVDAsStateChanges) {

  #get the change from the CVADS side, as that's the "source of truth"
  if ($difference.sideIndicator -eq "=>") {
    Write-Host "The Status of Machine Uid "$difference.Uid" associated with "$difference.UPN" has changed in CVADS. Updating State..."
    # now get the object from CVADS based on the Uid and UPN we know. If we only get the Machine Uid, we may get multiple results (Because multiple users could be using a machine)...
    # so we look for UPN, too, to make the lookup unique
    $singleSessionToChange = $everyUserWithAssociatedSingleSessionVDAs | Where-Object {($_.Uid -eq $difference.Uid) -and ($_.UPN -eq $difference.UPN)}
    # create the JSON payload for the Body:
    $sessiontoChangeJSON = $singleSessiontoChange | ConvertTo-JSON
     # get the ID of the entry in NoSQL - note we have to pull in the singleSessionVDAsinNoSQLDB DB, because that's the only place that has the ID :)
     $sessionToChangeNoSQLID = $singleSessionVDAsinNoSQLDB | Where-Object {($_.Uid -eq $difference.Uid) -and ($_.UPN -eq $difference.UPN)}
     $noSQLIDtoChange = $sessionToChangeNoSQLID._id
    #PUT changed entry to NoSQL:
    New-APICall -URI "$restdbioURI/$noSQLIDtoChange" -Method "PUT" -Body "$sessiontoChangeJSON"

  }

}