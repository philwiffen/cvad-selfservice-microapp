<#
Gets Sessions from CVAD and then loads them into restdb.io)

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


#Set this to be your customerID in Citrix Cloud
$CustomerId = "$env:CitrixCloudCustomerID"

#restdb.io URI (path to collection) example: https://managemysessionsanddesktop.restdb.io/rest/sessions
$restdbioURI = "$env:restdbioURI"

# set this to the max number of Desktops or Sessions you wants CVADS to return. Bigger environments will need a higher number. Default is 30000
$maximumRecordCount = "60000"

#function to simplify API calls - thanks to Daniel Peacock for this!
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

# Now get all the sessions from CVADS, ensuring we don't pull in sessions with a Null UserUPN, as we can't show those anyway in Microapps (because we filter based on UPN/email)

#Pull in only the neccessary Properties for the microapp                                                                                                                                     
$sessionsfromCVADS = Get-BrokerSession -Property SessionKey, Uid, UserUPN, UntrustedUserName, SessionState, SessionType, LaunchedViaPublishedName, DesktopGroupName, MachineName, MachineUid, IPAddress, DNSName -MaxRecordCount $maximumRecordCount

#Get sessions from the NoSQL database - this will give us normal Powershell Objects, so no need to convert from JSON with convertfrom-json
$sessionsinNoSQLDB = New-APICall -URI "$restdbioURI" -Method "GET"



# Now to address the empty UPN problem...
# sometimes the User UPN is Null. I don't know why. When it is, we need to lookup the UntrustedUserName and get the UPN that way.
# Because with no UPN, Microapps won't work and we can't show people their sessions if the session doesn't have UPN that matches their email.
# (Update: I now think this was related to one-way domain trusts. I'll keep this code in, as it does no harm, and may help others)
foreach ($session in $sessionsfromCVADS) {

# for efficiency, only do this is the UserUPN property is indeed null:
  if ($null -eq $session.UserUPN) {

    #Because we can't use -UserName with Get-BrokerUser, means we can't use the value of UnTrustedUserName :()
    #Instead, to get the UPN and put it into the UserUPN value, we do something super-hacky, and filter the results of get-broker user to look for the UntrustedUsername (as their Username)
    $session.UserUPN = (Get-BrokerUser -MaxRecordCount $maximumRecordCount | Where-Object {$_.Name -eq $session.UntrustedUserName}).UPN
  }
}

#if there's still no UPN for a session, we need to remove it, as it's an invalid entry and wouldn't be shown to anyone in the Microapp, as the Microapp will only show entries that match the user's UPN. To do this, we use Where-object to only get us good results
$sessionsfromCVADS = $sessionsfromCVADS | Where-Object {$_.UserUPN -ne $null }

# Compare sessions from each source
$sessionDifferences = Compare-Object -ReferenceObject $sessionsinNoSQLDB -DifferenceObject $sessionsfromCVADS -Property Uid


# now we run through each difference identified and either add or delete it from the NoSQL DB
foreach ($difference in $sessionDifferences) {

  #new sessions from CVADS, that are not in the NoSQL DB (so need to be added to the NoSQL DB)
  if ($difference.sideIndicator -eq "=>") { 
    Write-Host "Uid "$difference.Uid" is in CVADS, but not in NoSQL, so needs to be added to the NoSQL DB"
    # now get the object from CVADS based on the Uid we know, then convert it to JSON so it can be the payload for the API call
    $sessionToAdd = $sessionsfromCVADS | Where-Object {$_.Uid -eq $difference.Uid} | ConvertTo-JSON
    #add the entry to NoSQL:
    New-APICall -URI "$restdbioURI" -Method "POST" -Body "$sessionToAdd"

  }

   #sessions in the NoSQL DB, that are not in CVADS (so need to be deleted from the NoSQL DB)
   if ($difference.sideIndicator -eq "<=") {
    Write-Host "Uid "$difference.Uid" is no longer in CVADS, so needs to be removed from the NoSQL DB"
          # now get the object from CVADS based on the Uid we know
          $sessionToRemove = $sessionsinNoSQLDB | Where-Object {$_.Uid -eq $difference.Uid}
          # get the ID of the entry in NoSQL:
          $noSQLIDtoRemove = $sessionToRemove._id
          # request to delete that specific entry:
          New-APICall -URI "$restdbioURI/$noSQLIDtoRemove" -Method "Delete" -Body ""

   }



}

# that's new and old sorted, now to find sessions whose SessionState has changed:


#refresh what's in the NoSQL DB, because if we don't, this next phase fails on new entries:
$sessionsinNoSQLDB = New-APICall -URI "$restdbioURI" -Method "GET"

#because SessionState is stored as a number in NoSQL and as a label in CVADS, they will always be different. So we need to convert CVADS data to JSON and back again
# so the value goes from for example "Active" to "2" and then we convert the JSON back into powershell objects so we can use it in the comparison, but it now says "2"
$sessionsfromCVADS = $sessionsfromCVADS | ConvertTo-JSON | ConvertFrom-JSON

#compare SessionState:
$sessionStateChanges = Compare-Object -ReferenceObject $sessionsinNoSQLDB -DifferenceObject $sessionsfromCVADS -Property Uid,SessionState

foreach ($difference in $sessionStateChanges) {

  #get the change from the CVADS side, as that's the "source of truth"
  if ($difference.sideIndicator -eq "=>") { 
    Write-Host "Uid "$difference.Uid" has changed to "$difference.SessionState" in CVADS."
    # now get the object from CVADS based on the Uid we know, then convert it to JSON

    $sessionToChange = $sessionsfromCVADS | Where-Object {$_.Uid -eq $difference.Uid}
    # don't convert SessiontoChange to JSON immediately, as we need it in PowerShell Object format to get the _id
    $sessiontoChangeJSON = $sessiontoChange | ConvertTo-JSON
     # get the ID of the entry in NoSQL - note we have to pull in the sessionsinNoSQL DB, because that's the only place that has the ID :)
     $sessionToChangeNoSQLID = $sessionsinNoSQLDB | Where-Object {$_.Uid -eq $difference.Uid}
     $noSQLIDtoChange = $sessionToChangeNoSQLID._id
    #PUT changed entry to NoSQL:
    New-APICall -URI "$restdbioURI/$noSQLIDtoChange" -Method "PUT" -Body "$sessiontoChangeJSON"

  }

}