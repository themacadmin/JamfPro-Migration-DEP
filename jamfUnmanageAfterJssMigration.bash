#!/bin/bash
reset
# set -x

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# This script is designed to be run on Macs that were migrated from one Jamf Pro instance
# to another.
#
# It will mark the Mac's computer record in its old Jamf Pro instance as "Unmanaged"
#
# This script is meant to be run by Jamf policy supplied by the new Jamf Pro instance
# after migration is complete.
#
# If migrating Macs using reDEP.bash from https://github.com/themacadmin/JamfPro-Migration-DEP,
# the suggested scope is a smart computer group where the value of wasMigrated in $localDataPlist
# is "true".
#  
# REQUIREMENTS:
#       - URL of the Mac's former Jamf Pro instance
#           - Jamf Pro API credentials with permission modify (update) computer records
#       - Script must be executed as root
#
# Created On: 2018 08 24 by Miles Leacy
# 
# Includes elements created by Doug Worley
# 
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Jamf policy parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# OLD JSS URL - to be marked as "Unmanaged" based on the array pulled from the "New" Jamf server
		oldJamfUrl=""
	# Full URL and credentials to the Old JSS. 
		oldApiUser=""
		oldApiPass=""
		
internalServiceHandler=""		# SRV record address to validate that computer is on internal network (optional, required if org's old Jamf Pro instance is not Internet-facing.)

# read parameters
	[ "$4" != "" ] && [ "$oldJamfUrl" == "" ] && oldJamfUrl=$4
	[ "$5" != "" ] && [ "$oldApiUser" == "" ] && oldApiUser=$5
	[ "$6" != "" ] && [ "$oldApiPass" == "" ] && oldApiPass=$6
	[ "$7" != "" ] && [ "$internalServiceHandler" == "" ] && internalServiceHandler=$7

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# SYSTEM VARIABLES
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

xmlPath="/tmp/TempXml.xml"
timeStamp=$(date +"%F %T")
macSerial=$( system_profiler SPHardwareDataType | grep Serial |  awk '{print $NF}' )

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# FUNCTIONS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

checkForOldJamf(){
if [ -n "$internalServiceHandler" ]; then
	host -t SRV "$internalServiceHandler" > /dev/null
	if [ $? -ne 0 ]; then
		printf "$timeStamp %s\n" "Internal network not detected."
		printf "$timeStamp %s\n" "Cannot access old Jamf Pro."
		printf "$timeStamp %s\n" "Exiting."
		exit 1
	fi
fi
}

getOldJamfData() {
	computerRecordOldJamf=$( /usr/bin/curl -s -u ${oldApiUser}:${oldApiPass} ${oldJamfUrl}/JSSResource/computers/serialnumber/${macSerial}/subset/general 2>/dev/null)
	oldJssId=$(echo $computerRecordOldJamf | /usr/bin/xpath "//computer/general/id/text()" 2>/dev/null)
	oldRemoteManagement=$(echo $computerRecordOldJamf | /usr/bin/xpath "//computer/general/remote_management/managed/text()" 2>/dev/null)
	if [[ "$oldRemoteManagement" == "false" ]]; then
	    printf "$timeStamp %s\n" "$macSerial is already "unmanaged" in $oldJamfUrl."
		printf "$timeStamp %s\n" "No action taken."
		exit 0
	fi
}

createXml() {
# echo "generating XML..."
cat <<EndXML > $xmlPath
<?xml version="1.0" encoding="UTF-8"?>
<computer>
<general>
<remote_management>
<managed>false</managed>
</remote_management>
</general>
</computer>
EndXML
}

putXmlApiToOldJamf() {
    printf "$timeStamp %s\n" "Attempting to mark $macSerial Unmanaged on $oldJamfUrl"
    xmlPutResponse=$(curl -sk -u $oldApiUser:$oldApiPass $oldJamfUrl/JSSResource/computers/id/"${oldJssId}"/subset/general -T $xmlPath -X PUT 2>/dev/null)
    # echo ${xmlPutResponse}

    if [[ $xmlPutResponse == *"The server has not found anything matching the request URI"* ]]; then
	    printf "$timeStamp %s\n" "$oldJamfUrl has no match for $macSerial. No action taken."
		exit 0
	elif [[ $xmlPutResponse == *"Error"* ]]; then
		printf "$timeStamp %s\n" "An API error occurred."
		printf "$timeStamp %s\n" "Exiting."
		exit 2
	elif [[ $xmlPutResponse == *"oldJssId"* ]]; then
		printf "$timeStamp %s\n" "$macSerial is marked unmanaged in $oldJamfUrl"
	else
		printf "$timeStamp %s\n" "An unknown error occurred."
		printf "$timeStamp %s\n" "Exiting."
		exit 3
	fi 
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Main Application
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

checkForOldJamf
getOldJamfData
printf "$timeStamp %s\n" "Marking $macSerial "unmanaged" in $oldJamfUrl"
createXml
putXmlApiToOldJamf
rm $xmlPath

exit 0
