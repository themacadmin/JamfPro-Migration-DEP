#!/bin/bash
# set -x
clear
[ $EUID != 0 ] && echo "This script requires root privileges, please run \"sudo $0\"" && exit 1
[ $(sw_vers | awk -F "." '/ProductVersion:/ { print $2 }') != 13 ] && echo "Halting migration. Prerequisites not met. Migration prerequisites include a minimum OS version of macOS High Sierra v10.13" && exit 1

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# Copyright (c) 2017 Jamf.  All rights reserved.
#
#       Redistribution and use in source and binary forms, with or without
#       modification, are permitted provided that the following conditions are met:
#               * Redistributions of source code must retain the above copyright
#                 notice, this list of conditions and the following disclaimer.
#               * Redistributions in binary form must reproduce the above copyright
#                 notice, this list of conditions and the following disclaimer in the
#                 documentation and/or other materials provided with the distribution.
#               * Neither the name of the Jamf nor the names of its contributors may be
#                 used to endorse or promote products derived from this software without
#                 specific prior written permission.
#
#       THIS SOFTWARE IS PROVIDED BY JAMF SOFTWARE, LLC "AS IS" AND ANY
#       EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#       WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#       DISCLAIMED. IN NO EVENT SHALL JAMF SOFTWARE, LLC BE LIABLE FOR ANY
#       DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#       (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
#       LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
#       ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#       (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#       SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# This script was designed to be used when migration Jamf Pro instances where an MDM profile
# is installed on the systems and needs to be removed prior to the migration.
#
# In addition, this script will also remove the MDM profile installed on a managed Mac, 
# enroll to a new Jamf Pro, and re-establish DEP. 
# This locks User-Approved MDM in place, with minimal user interaction.
#
# To accomplish this the following will be performed:
#           - Record pre-migration state data at /Library/$myOrg/Data/com.$myOrg.jamfLocalExtensionAttributes.plist
#				- Exit with error if FileVault operations are in progress or FileVault state cannot be determined
#			- Attempt MDM profile removal via Jamf binary
#           - Attempt MDM profile removal via Jamf API sending an MDM UnmanageDevice command
#           - Lastly, if failed to remove MDM Profile the /var/db/ConfigurationProfiles
#             folder will be renamed.
#
# REQUIREMENTS:
#       - One Jamf Pro URL to read original data from:
#           - Jamf Pro API User with permission to read computer objects
#           - Jamf Pro API User with permission to send management commands
#       - Another Jamf Pro URL to enroll to
#           -  A reusable enrollment invitation code (from Recon.app or SMTP invitation)
#       - Script must be executed as root (due to profiles command)
#
# EXIT CODES:
#           0 - Everything is Successful
#           1 - Unable to remove MDM Profile
#
#
# Whole chunks of this script come from removeMDM.sh - Written by: Joshua Roskos | Professional Services Engineer | Jamf
# Created On: December 7th, 2017
# For more information, visit https://github.com/kc9wwh/removeJamfProMDM
#
#
# Aditional DEP worklow added on by Doug Worley and Miles Leacy - 22nd February 2018
# Doug Worley - Senior PSE, Jamf
# Miles Leacy - Technical Expert, Apple Technology, Walmart
#
# Reboot and re-run setup assistant added by Miles Leacy - 20th August 2018
# 
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# USER VARIABLES - These can be left blank here and populated by Jamf policy parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

oldJamfPro=""			# Multiple values are stored in this variable,
						# Old Jamf Pro server URL, API username, and API password,
						# separated by ? characters.
						# i.e., https://jamfold.acme.com:8443?apiusername?apipassword

newJamfPro=""			# Multiple values are stored in this variable,
						# Old Jamf Pro server URL, API username, and API password,
						# enrollment invitation ID, management account, separated by ? characters.
						# i.e., https://jamfnew.acme.com:8443?apiusername?apipassword?1234567890?managementaccount

myOrg=""				# Used to generate path and filename for
						# /Library/$myOrg/Data/com.$myOrg.jamfLocalExtensionAttributes.plist
								
internalServiceHandler=""		# SRV record address to validate that computer is on internal network (optional, required if org's management processes require internal resources)

dryRun=""				# Must be non-null for the script to run without user intervention.

assignToSameUser=""		# Must be non-null for the script to retain the Mac's user assignment from the old Jamf instance in the new Jamf instance

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Jamf policy parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

[ "$4" != "" ] && [ "$oldJamfPro" == "" ] && oldJamfPro=$4
[ "$5" != "" ] && [ "$newJamfPro" == "" ] && newJamfPro=$5
[ "$6" != "" ] && [ "$myOrg" == "" ] && myOrg=$6
[ "$7" != "" ] && [ "$internalServiceHandler" == "" ] && internalServiceHandler=$7
[ "$8" != "" ] && [ "$dryRun" == "" ] && dryRun=$8
[ "$9" != "" ] && [ "$assignToSameUser" == "" ] && assignToSameUser=$9

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Parsing Jamf policy parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

oldJamfProURL=$(awk -F "?" '{print $1}' <<< "$oldJamfPro")
oldJamfApiUser=$(awk -F "?" '{print $2}' <<< "$oldJamfPro")
oldJamfApiPass=$(awk -F "?" '{print $3}' <<< "$oldJamfPro")

newJamfProURL=$(awk -F "?" '{print $1}' <<< "$newJamfPro")
newJamfApiUser=$(awk -F "?" '{print $2}' <<< "$newJamfPro")
newJamfApiPass=$(awk -F "?" '{print $3}' <<< "$newJamfPro")
newJamfInvitationCode=$(awk -F "?" '{print $4}' <<< "$newJamfPro")
newJamfManagementAccount=$(awk -F "?" '{print $5}' <<< "$newJamfPro")

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# SYSTEM VARIABLES
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

currentUser=$(stat -f %Su /dev/console)
osMinorVersion=$( /usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f2 )
timeStamp=$(date +"%F %T")
mySerial=$( system_profiler SPHardwareDataType | grep Serial |  awk '{print $NF}' )
computerRecordOldJamf=$( /usr/bin/curl -s -u ${oldJamfApiUser}:${oldJamfApiPass} ${oldJamfProURL}/JSSResource/computers/serialnumber/${mySerial}/subset/general 2>/dev/null)
	oldJamfAssignedUser=$(echo $computerRecordOldJamf | /usr/bin/xpath "//computer/location/username/text()" 2>/dev/null)
	oldJamfCompID=$(echo $computerRecordOldJamf | /usr/bin/xpath "//computer/general/id/text()" 2>/dev/null)
	macMgmtUser=$(echo $computerRecordOldJamf | xpath "//general/remote_management/management_username/text()" 2>/dev/null)
xmlPath="/tmp/tmp.xml"
managementUser="filler"
managementPass="filler"
localDataPath="/Library/$myOrg/Data"
localDataPlist="com.$myOrg.jamfLocalExtensionAttributes.plist"
fileVaultStatusErrorMessage="FileVault operations in progress or FileVault is in an unknown state.

Cancelling this attempt.

If FileVault is encrypting or decrypting, please retry migration after FileVault operations are complete.

If FileVault is idle, please contact support."

# Create localDataPath directory if needed
if [ ! -d "$localDataPath" ]; then
  printf "$timeStamp %s\n" " Creating local data path."
  mkdir -p "$localDataPath"
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# VARIABLES CHECKS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

if [ -z "$dryRun" ]; then
	printf "$timeStamp %s\n" "The following values will be used for migration. Please verify."
	printf "$timeStamp %s\n" "Organization: $myOrg"
	printf "$timeStamp %s\n" "Old Jamf Pro Server Info"	
	printf "$timeStamp %s\n" "Old Jamf Pro URL:  $oldJamfProURL"
	printf "$timeStamp %s\n" "Old Jamf Pro API User:  $oldJamfApiUser"
	printf "$timeStamp %s\n" "Old Jamf Pro API Pass:  $oldJamfApiPass"
	printf "$timeStamp %s\n" "New Jamf Pro Server Info"
	printf "$timeStamp %s\n" "New Jamf Pro URL:  $newJamfProURL"
	printf "$timeStamp %s\n" "New Jamf Pro API User:  $newJamfApiUser"
	printf "$timeStamp %s\n" "New Jamf Pro API Pass:  $newJamfApiPass"
	printf "$timeStamp %s\n" "New Jamf Pro Invitation:  $newJamfInvitationCode"
	printf "$timeStamp %s\n" "New Jamf Pro Management Account:  $newJamfManagementAccount"
	read -r -p "Are you sure? [y/N] " response
	case "$response" in
    	[yY][eE][sS]|[yY]) 
			printf "$timeStamp %s\n" "Continuing with migration."
			;;
		*)
			printf "$timeStamp %s\n" "Halting migration."	
			exit 1
			;;
	esac
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# FUNCTIONS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

checkMDMProfileInstalled() {
    enrolled=$(/usr/bin/profiles -C | /usr/bin/grep "00000000-0000-0000-A000-4A414D460003")
    if [ "$enrolled" != "" ]; then
        printf "$timeStamp %s\n" " MDM Profile Present..." | tee "$localDataPath"/migrationLog.txt
        mdmPresent=1
    else
        printf "$timeStamp %s\n" " MDM Profile Successfully Removed..." | tee "$localDataPath"/migrationLog.txt
        mdmPresent=0
    fi
}


jamfUnmanageDeviceAPI() {
    /usr/bin/curl -s -X POST -H "Content-Type: text/xml" -u ${oldJamfApiUser}:${oldJamfApiPass} ${oldJamfProURL}/JSSResource/computercommands/command/UnmanageDevice/id/${oldJamfCompID} 2>/dev/null
    sleep 10
    checkMDMProfileInstalled
    counter=0
    until [ "$mdmPresent" -eq "0" ] || [ "$counter" -gt "9" ]; do
        ((counter++))
        printf "$timeStamp %s\n" " Check ${counter}/10; MDM Profile Present; waiting 30 seconds to re-check..." | tee "$localDataPath"/migrationLog.txt
        sleep 30
        checkMDMProfileInstalled
    done
    sleep 10
}


enrollToNewJamf() {
    printf "$timeStamp %s\n" " Enrolling with new Jamf..." | tee "$localDataPath"/migrationLog.txt
    printf "$timeStamp %s\n" " Creating plist for new JSS..." | tee "$localDataPath"/migrationLog.txt
    jamf createConf -url "$newJamfProURL"  
        if [ "$?" != "" ]; then
            printf "$timeStamp %s\n" " Successfully created plist for new JSS!" | tee "$localDataPath"/migrationLog.txt
        else
            printf "$timeStamp %s\n" " ALERT - There was a problem with creating plist for the new JSS." | tee "$localDataPath"/migrationLog.txt
			exit 99
        fi

    printf "$timeStamp %s\n" " Enrolling to new Jamf Pro... this might take some time ..." | tee "$localDataPath"/migrationLog.txt
    jamf enroll -invitation "$newJamfInvitationCode"
        if [ "$?" != "" ]; then
            printf "$timeStamp %s\n" " Successfully migrated to new Jamf Pro." | tee "$localDataPath"/migrationLog.txt
            printf "$timeStamp %s\n" "$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)" | tee "$localDataPath"/migrationLog.txt
			if [ -n "$assignToSameUser" ]; then
				if [ -n "$oldJamfAssignedUser" ]; then
					jamf recon -endUsername "$oldJamfAssignedUser"
				fi
			fi
        else
            printf "$timeStamp %s\n" " ALERT - There was a problem with enrolling to the new JSS." | tee "$localDataPath"/migrationLog.txt
			exit 99
        fi

    printf "$timeStamp %s\n" "Configuring Mac to run Setup Assistant at next startup for DEP enrollment." | tee "$localDataPath"/migrationLog.txt
    rm -rf /var/db/.AppleSetUpDone
}


displayMacMgmtUser(){
    macMgmtUser=$(/usr/bin/curl -sk -H "Accept: application/xml" ${oldJamfProURL}/JSSResource/computers/serialnumber/${mySerial} -u ${oldJamfApiUser}:${oldJamfApiPass} | tidy -xml 2>/dev/null | xpath "//general/remote_management/management_username/text()" 2>/dev/null)
    printf "$timeStamp %s\n" " macMgmtUser is: $macMgmtUser" | tee "$localDataPath"/migrationLog.txt
}

createXml() {
printf "$timeStamp %s\n" "generating XML..."
cat <<EndXML > $xmlPath
<?xml version="1.0" encoding="UTF-8"?>
<computer>
    <general>
        <remote_management>
            <managed>true</managed>
            <management_username>$managementUser</management_username>
            <management_password>$managementPass</management_password>
        </remote_management>
    </general>
</computer>
EndXML
}


putXmlApi() {
        curl -sk -u $oldJamfApiUser:$oldJamfApiPass $oldJamfProURL/JSSResource/computers/serialnumber/"${mySerial}"/subset/general -T $xmlPath -X PUT
        displayMacMgmtUser
}

putXmlApiNew() {
        curl -sk -u $newJamfApiUser:$newJamfApiPass $newJamfProURL/JSSResource/computers/serialnumber/"${mySerial}"/subset/general -T $xmlPath -X PUT
        displayMacMgmtUser
	}

removeMDMandEnroll() {
    printf "$timeStamp %s\n" " Removing MDM Profiles ..." | tee "$localDataPath"/migrationLog.txt
    if [ "${osMinorVersion}" -ge 13 ]; then
        printf "$timeStamp %s\n" " macOS $(/usr/bin/sw_vers -productVersion); attempting removal via jamf binary..." | tee "$localDataPath"/migrationLog.txt
        /usr/local/bin/jamf removeMdmProfile -verbose
        sleep 3
        checkMDMProfileInstalled
        if [ "$mdmPresent" == "0" ]; then
            printf "$timeStamp %s\n" " Successfully Removed MDM Profile..." | tee "$localDataPath"/migrationLog.txt
            enrollToNewJamf
        else
            printf "$timeStamp %s\n" " MDM Profile Present; attempting removal via API..." | tee "$localDataPath"/migrationLog.txt
            jamfUnmanageDeviceAPI
            if [ "$mdmPresent" != "0" ]; then
                printf "$timeStamp %s\n" " Unable to remove MDM Profile; exiting..." | tee "$localDataPath"/migrationLog.txt
                exit 1
            elif [ "$mdmPresent" == "0" ]; then
                printf "$timeStamp %s\n" " Successfully Removed MDM Profile..." | tee "$localDataPath"/migrationLog.txt
                enrollToNewJamf
            fi
        fi
    else
        printf "$timeStamp %s\n" "macOS $(/usr/bin/sw_vers -productVersion); attempting removal via jamf binary..." | tee "$localDataPath"/migrationLog.txt
        /usr/local/bin/jamf removeMdmProfile -verbose
        sleep 3
        checkMDMProfileInstalled
        if [ "$mdmPresent" == "0" ]; then
            printf "$timeStamp %s\n" " Successfully Removed MDM Profile..." | tee "$localDataPath"/migrationLog.txt
            enrollToNewJamf
        else
            printf "$timeStamp %s\n" " MDM Profile Present; attempting removal via API..." | tee "$localDataPath"/migrationLog.txt
            jamfUnmanageDeviceAPI
            if [ "$mdmPresent" == "0" ]; then
                printf "$timeStamp %s\n" " Successfully Removed MDM Profile..." | tee "$localDataPath"/migrationLog.txt
                enrollToNewJamf
            else
                printf "$timeStamp %s\n" " macOS $(/usr/bin/sw_vers -productVersion); attempting force removal..." | tee "$localDataPath"/migrationLog.txt
                /bin/mv -v /var/db/ConfigurationProfiles/ /var/db/ConfigurationProfiles-$timestamp
                checkMDMProfileInstalled
                if [ "$mdmPresent" != "0" ]; then
                    printf "$timeStamp %s\n" " Unable to remove MDM Profile; exiting..." | tee "$localDataPath"/migrationLog.txt
                    exit 1
                fi
            fi
        fi
    fi
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Main Application
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

##### Preflight #####

# Grant admin to console user
# Admin is required to receive DEP notification
dscl . -append /groups/admin GroupMembership "$currentUser"
printf "$timeStamp %s\n" "Admin privileges granted to $currentUser" | tee "$localDataPath"/migrationLog.txt

# Determine if on internal network
# comment out this section if internal resourecs are not required for migration
host -t SRV "$internalServiceHandler" > /dev/null
if [ $? -ne 0 ]; then
	printf "$timeStamp %s\n" "Internal network not detected." "Halting migration." | tee "$localDataPath"/migrationLog.txt
	exit 1
fi

##### Capture migration details #####

# Create plist directory if needed
if [ ! -d "$localDataPath" ]; then
  printf "$timeStamp %s\n" " Creating local data path." | tee "$localDataPath"/migrationLog.txt
  mkdir -p "$localDataPath"
fi

# Get FileVault status
fdeState=$(fdesetup status | head -1)
if [ "$fdeState" = "FileVault is Off." ]; then
    preMigrationFileVaultStatus="false"
elif [ "$fdeState" = "FileVault is On." ]; then
    preMigrationFileVaultStatus="true"
else
    printf "$timeStamp %s\n" " FileVault operations in progress or in an unknown state." | tee "$localDataPath"/migrationLog.txt
    osascript -e 'Tell application "System Events" to display alert "'"$fileVaultStatusErrorMessage"'" as warning'
    exit 1
fi

# Clear JamfMigration array
printf "$timeStamp %s\n" " Clearing previous local Jamf migration records." | tee "$localDataPath"/migrationLog.txt
/usr/libexec/PlistBuddy -c "Delete :JamfMigration" "$localDataPath"/"$localDataPlist"

# Record Migration Data
printf "$timeStamp %s\n" " Recording local Jamf migration data." | tee "$localDataPath"/migrationLog.txt
/usr/libexec/PlistBuddy -c "Add :JamfMigration:wasMigrated bool true" "$localDataPath"/"$localDataPlist"
/usr/libexec/PlistBuddy -c "Add :JamfMigration:oldJSS string $oldJamfProURL" "$localDataPath"/"$localDataPlist"
/usr/libexec/PlistBuddy -c "Add :JamfMigration:usernameAtMigration string $currentUser" "$localDataPath"/"$localDataPlist"
/usr/libexec/PlistBuddy -c "Add :JamfMigration:fileVaultedByOldOrg bool $preMigrationFileVaultStatus" "$localDataPath"/"$localDataPlist"

##### Migration #####
displayMacMgmtUser
if [ "$macMgmtUser" == "" ]; then
    printf "$timeStamp %s\n" " Mac is marked as 'unmanaged' - filling with dummy data..." | tee "$localDataPath"/migrationLog.txt
    createXml
        cat "$xmlPath"
    putXmlApi
    removeMDMandEnroll
else
    printf "$timeStamp %s\n" " Mac has local management account: '$macMgmtUser' - continuing..." | tee "$localDataPath"/migrationLog.txt
    removeMDMandEnroll
fi

printf "$timeStamp %s\n" "This Mac should restart shortly." | tee "$localDataPath"/migrationLog.txt

exit 0
