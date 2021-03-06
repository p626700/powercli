Write-Host "             __________________________"
Write-Host "            /++++++++++++++++++++++++++\"           
Write-Host "           /++++++++++++++++++++++++++++\"           
Write-Host "          /++++++++++++++++++++++++++++++\"         
Write-Host "         /++++++++++++++++++++++++++++++++\"        
Write-Host "        /++++++++++++++++++++++++++++++++++\"       
Write-Host "       /++++++++++++/----------\++++++++++++\"     
Write-Host "      /++++++++++++/            \++++++++++++\"    
Write-Host "     /++++++++++++/              \++++++++++++\"   
Write-Host "    /++++++++++++/                \++++++++++++\"  
Write-Host "   /++++++++++++/                  \++++++++++++\" 
Write-Host "   \++++++++++++\                  /++++++++++++/" 
Write-Host "    \++++++++++++\                /++++++++++++/" 
Write-Host "     \++++++++++++\              /++++++++++++/"  
Write-Host "      \++++++++++++\            /++++++++++++/"    
Write-Host "       \++++++++++++\          /++++++++++++/"     
Write-Host "        \++++++++++++\"                   
Write-Host "         \++++++++++++\"                           
Write-Host "          \++++++++++++\"                          
Write-Host "           \++++++++++++\"                         
Write-Host "            \------------\"
Write-Host
Write-host "Pure Storage VMware UNMAP Script"
write-host "----------------------------------------------"
write-host

#Enter the following parameters. Put all entries inside the quotes:
#**********************************
$vcenter = ""
$vcuser = ""
$vcpass = ""
$purevip = ""
$pureuser = ""
$purepass = ""
$UNMAPBlockCount = "60000"
$logfolder = "C:\Users\cody\Documents\UNMAP\"
#End of parameters

If (!(Test-Path -Path $logfolder)) { New-Item -ItemType Directory -Path $logfolder }
$logfile = $logfolder + (Get-Date -Format o |ForEach-Object {$_ -Replace ":", "."}) + "unmap.txt"

#Connect to FlashArray via REST
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$AuthAction = @{
    password = ${purepass}
    username = ${pureuser}
}
$ApiToken = Invoke-RestMethod -Method Post -Uri "https://${purevip}/api/1.2/auth/apitoken" -Body $AuthAction 
$SessionAction = @{
    api_token = $ApiToken.api_token
}
Invoke-RestMethod -Method Post -Uri "https://${purevip}/api/1.2/auth/session" -Body $SessionAction -SessionVariable Session |out-null
write-host "Connection to FlashArray successful" -foregroundcolor green
write-host
add-content $logfile "Connected to FlashArray:"
add-content $logfile $purevip
add-content $logfile "----------------"

#Important PowerCLI and connected to vCenter
Add-PSSnapin VMware.VimAutomation.Core
set-powercliconfiguration -invalidcertificateaction "ignore" -confirm:$false |out-null
connect-viserver -Server $vcenter -username $vcuser -password $vcpass|out-null
write-host "Connection to vCenter successful" -foregroundcolor green
write-host
add-content $logfile "Connected to vCenter:"
add-content $logfile $vcenter
add-content $logfile "----------------"

#Gather VMFS Datastores and identify how many are Pure Storage volumes
write-host "Initiating VMFS UNMAP for all Pure Storage volumes in the vCenter" -foregroundcolor Cyan
write-host "Searching for VMFS volumes to reclaim (UNMAP)"
$datastores = get-datastore
write-host "Found " $datastores.count " VMFS volume(s)."
write-host
write-host "Iterating through VMFS volumes and running a reclamation on Pure Storage volumes only"
write-host
write-host "UNMAP will use a block count iteration of" $UNMAPBlockCount
write-host
write-host "Please be patient, this process can take a long time depending on how many volumes and their capacity"
write-host "------------------------------------------------------------------------------------------------------"
write-host
add-content $logfile "Found the following datastores:"
add-content $logfile $datastores
add-content $logfile "***************"

#Starting UNMAP Process on datastores
$volcount=0
$purevolumes = Invoke-RestMethod -Method Get -Uri "https://${purevip}/api/1.2/volume" -WebSession $Session
foreach ($datastore in $datastores)
{
    write-host "--------------------------------------------------------------------------"
    write-host "Analyzing the following volume:"
    write-host
    $esx = $datastore | get-vmhost |Select-object -last 1
    if ($datastore.Type -ne "VMFS")
    {
        write-host "This volume is not a VMFS volume and cannot be reclaimed. Skipping..."
        write-host $datastore.Type
        add-content $logfile "This volume is not a VMFS volume and cannot be reclaimed. Skipping..."
        add-content $logfile $datastore.Type
    }
    else
    {
        $lun = get-scsilun -datastore $datastore | select-object -last 1
        $esxcli=get-esxcli -VMHost $esx
        add-content $logfile "The following datastore is being examined:"
        add-content $logfile $datastore 
        add-content $logfile "The following ESXi is the chosen source:"
        add-content $logfile $esx 
        write-host "VMFS Datastore:" $datastore.Name $lun.CanonicalName
        if ($lun.canonicalname -like "naa.624a9370*")
        {
            write-host $datastore.name "is a Pure Storage Volume and will be reclaimed." -foregroundcolor Cyan 
            write-host
            $volserial = $lun.CanonicalName
            $volserial = $volserial.substring(12)
            $purevol = $purevolumes |where-object {$_.serial -like "*$volserial*"}
            $purevolname = $purevol.name
            $volinfo = Invoke-RestMethod -Method Get -Uri "https://${purevip}/api/1.2/volume/${purevolname}?space=true" -WebSession $Session
            $volreduction = "{0:N3}" -f ($volinfo.data_reduction)
            $volphysicalcapacity = "{0:N3}" -f ($volinfo.volumes/1024/1024/1024)
            add-content $logfile "This datastore is a Pure Storage Volume."
            add-content $logfile $lun.CanonicalName
            add-content $logfile "The current data reduction for this volume prior to UNMAP is:"
            add-content $logfile $volreduction
            add-content $logfile "The current physical space consumption in GB of this device prior to UNMAP is:"
            add-content $logfile $volphysicalcapacity
        
            write-host "This volume has a data reduction ratio of" $volreduction "to 1 prior to reclamation." -foregroundcolor green
            write-host "This volume has" $volphysicalcapacity "GB of data physically written to the SSDs on the FlashArray prior to reclamation." -foregroundcolor green
            write-host
            write-host "Initiating reclaim...Operation time will vary depending on block count, size of volume and other factors."
            $esxcli.storage.vmfs.unmap($UNMAPBlockCount, $datastore.Name, $null) |out-null
            write-host
            Start-Sleep -s 60
            write-host "Reclaim complete."
            write-host
            write-host "Results:"
            write-host "-----------"
            $volinfo = Invoke-RestMethod -Method Get -Uri "https://${purevip}/api/1.2/volume/${purevolname}?space=true" -WebSession $Session
            $volreduction = "{0:N3}" -f ($volinfo.data_reduction)
            $volphysicalcapacitynew = "{0:N3}" -f ($volinfo.volumes/1024/1024/1024)
            write-host "This volume now has a data reduction ratio of" $volreduction "to 1 after reclamation." -foregroundcolor green
            write-host "This volume now has" $volphysicalcapacitynew "GB of data physically written to the SSDs on the FlashArray after reclamation." -foregroundcolor green
            $unmapsavings = ($volphysicalcapacity - $volphysicalcapacitynew)
            write-host
            write-host "The UNMAP process has reclaimed" $unmapsavings "GB of space from this volume on the FlashArray." -foregroundcolor green
            $volcount=$volcount+1
            add-content $logfile "The new data reduction for this volume after UNMAP is:"
            add-content $logfile $volreduction
            add-content $logfile "The new physical space consumption in GB of this device after UNMAP is:"
            add-content $logfile $volphysicalcapacitynew
            add-content $logfile "The following capacity in GB has been reclaimed from the FlashArray from this volume:"
            add-content $logfile $unmapsavings
            add-content $logfile "---------------------"
            Start-Sleep -s 5
        }
        else
        {
            add-content $logfile "This datastore is NOT a Pure Storage Volume. Skipping..."
            add-content $logfile $lun.CanonicalName
            add-content $logfile "---------------------"
            write-host $datastore.name " is not a Pure Volume and will not be reclaimed. Skipping..." -foregroundcolor red
        }
    }
}
write-host "--------------------------------------------------------------------------"
write-host "Reclamation finished. A total of" $volcount "Pure Storage volume(s) were reclaimed"

#disconnecting sessions
disconnect-viserver -Server $vcenter -confirm:$false
Invoke-RestMethod -Method Delete -Uri "https://${purevip}/api/1.2/auth/session" -WebSession $Session |out-null