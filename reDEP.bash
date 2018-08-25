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
#           - Compensate for Jamf PI-005441
#				- Pause to allow user to accept DEP enrollment
#				- Set correct values for remote_management fields via Jamf API
#				- Reassert management framework and continue enrollment policies
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

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Jamf policy parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

[ "$4" != "" ] && [ "$oldJamfPro" == "" ] && oldJamfPro=$4
[ "$5" != "" ] && [ "$newJamfPro" == "" ] && newJamfPro=$5
[ "$6" != "" ] && [ "$myOrg" == "" ] && myOrg=$6
[ "$7" != "" ] && [ "$internalServiceHandler" == "" ] && internalServiceHandler=$7
[ "$8" != "" ] && [ "$dryRun" == "" ] && dryRun=$8

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
jamfProCompID=$( /usr/bin/curl -s -u ${oldJamfApiUser}:${oldJamfApiPass} ${oldJamfProURL}/JSSResource/computers/serialnumber/${mySerial}/subset/general 2>/dev/null | /usr/bin/xpath "//computer/general/id/text()" 2>/dev/null)
macMgmtUser=$(/usr/bin/curl -sk -H "Accept: application/xml" ${oldJamfProURL}/JSSResource/computers/serialnumber/${mySerial} -u ${oldJamfApiUser}:${oldJamfApiPass} | tidy -xml 2>/dev/null | xpath "//general/remote_management/management_username/text()" 2>/dev/null)
xmlPath="/tmp/tmp.xml"
managementUser="filler"
managementPass="filler"
localDataPath="/Library/$myOrg/Data"
localDataPlist="com.$myOrg.jamfLocalExtensionAttributes.plist"
fileVaultStatusErrorMessage="FileVault operations in progress or FileVault is in an unknown state.

Cancelling this attempt.

If FileVault is encrypting or decrypting, please retry migration after FileVault operations are complete.

If FileVault is idle, please contact support."

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
        echo " MDM Profile Present..."
        mdmPresent=1
    else
        echo " MDM Profile Successfully Removed..."
        mdmPresent=0
    fi
}


jamfUnmanageDeviceAPI() {
    /usr/bin/curl -s -X POST -H "Content-Type: text/xml" -u ${oldJamfApiUser}:${oldJamfApiPass} ${oldJamfProURL}/JSSResource/computercommands/command/UnmanageDevice/id/${jamfProCompID} 2>/dev/null
    sleep 10
    checkMDMProfileInstalled
    counter=0
    until [ "$mdmPresent" -eq "0" ] || [ "$counter" -gt "9" ]; do
        ((counter++))
        echo " Check ${counter}/10; MDM Profile Present; waiting 30 seconds to re-check..."
        sleep 30
        checkMDMProfileInstalled
    done
    sleep 10
}


enrollToNewJamf() {
    echo " Enrolling with new Jamf..."
    echo " Creating plist for new JSS..."
    jamf createConf -url "$newJamfProURL"  
        if [ "$?" != "" ]; then
            echo " Successfully created plist for new JSS!"
        else
            echo " ALERT - There was a problem with creating plist for the new JSS."
			exit 99
        fi

    echo " Enrolling to new Jamf Pro... this might take some time ..."
    jamf enroll -invitation "$newJamfInvitationCode"
        if [ "$?" != "" ]; then
            echo " Successfully migrated to new Jamf Pro."
            echo "$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)"
        else
            echo " ALERT - There was a problem with enrolling to the new JSS."
			exit 99
        fi

    echo " Rebooting into Setup Assistant for DEP enrollment."
    rm -rf /var/db/.AppleSetUpDone
	/sbin/shutdown -r now
}


displayMacMgmtUser(){
    macMgmtUser=$(/usr/bin/curl -sk -H "Accept: application/xml" ${oldJamfProURL}/JSSResource/computers/serialnumber/${mySerial} -u ${oldJamfApiUser}:${oldJamfApiPass} | tidy -xml 2>/dev/null | xpath "//general/remote_management/management_username/text()" 2>/dev/null)
    echo ""
    echo " macMgmtUser is: $macMgmtUser"
}

createXml() {
echo "generating XML..."
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
    echo " Removing MDM Profiles ..."
    if [ "${osMinorVersion}" -ge 13 ]; then
        echo " macOS $(/usr/bin/sw_vers -productVersion); attempting removal via jamf binary..."
        /usr/local/bin/jamf removeMdmProfile -verbose
        sleep 3
        checkMDMProfileInstalled
        if [ "$mdmPresent" == "0" ]; then
            echo " Successfully Removed MDM Profile..."
            enrollToNewJamf
        else
            echo " MDM Profile Present; attempting removal via API..."
            jamfUnmanageDeviceAPI
            if [ "$mdmPresent" != "0" ]; then
                echo " Unable to remove MDM Profile; exiting..."
                exit 1
            elif [ "$mdmPresent" == "0" ]; then
                echo " Successfully Removed MDM Profile..."
                enrollToNewJamf
            fi
        fi
    else
        echo "macOS $(/usr/bin/sw_vers -productVersion); attempting removal via jamf binary..."
        /usr/local/bin/jamf removeMdmProfile -verbose
        sleep 3
        checkMDMProfileInstalled
        if [ "$mdmPresent" == "0" ]; then
            echo " Successfully Removed MDM Profile..."
            enrollToNewJamf
        else
            echo " MDM Profile Present; attempting removal via API..."
            jamfUnmanageDeviceAPI
            if [ "$mdmPresent" == "0" ]; then
                echo " Successfully Removed MDM Profile..."
                enrollToNewJamf
            else
                echo " macOS $(/usr/bin/sw_vers -productVersion); attempting force removal..."
                /bin/mv -v /var/db/ConfigurationProfiles/ /var/db/ConfigurationProfiles-$timestamp
                checkMDMProfileInstalled
                if [ "$mdmPresent" != "0" ]; then
                    echo " Unable to remove MDM Profile; exiting..."
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
printf "$timeStamp %s\n" "Admin privileges granted to $currentUser"

# Determine if on internal network
# comment out this section if internal resourecs are not required for migration
host -t SRV "$internalServiceHandler" > /dev/null
if [ $? -ne 0 ]; then
	printf "$timeStamp %s\n" "Internal network not detected." "Halting migration."
	exit 1
fi

##### Capture migration details #####

# Create plist directory if needed
if [ ! -d "$localDataPath" ]; then
  echo " Creating local data path."
  mkdir -p "$localDataPath"
fi

# Get FileVault status
fdeState=$(fdesetup status | head -1)
if [ "$fdeState" = "FileVault is Off." ]; then
    preMigrationFileVaultStatus="false"
elif [ "$fdeState" = "FileVault is On." ]; then
    preMigrationFileVaultStatus="true"
else
    echo " FileVault operations in progress or in an unknown state."
    osascript -e 'Tell application "System Events" to display alert "'"$fileVaultStatusErrorMessage"'" as warning'
    exit 1
fi

# Clear JamfMigration array
echo " Clearing previous local Jamf migration records."
/usr/libexec/PlistBuddy -c "Delete :JamfMigration" "$localDataPath"/"$localDataPlist"

# Record Migration Data
echo " Recording local Jamf migration data."
/usr/libexec/PlistBuddy -c "Add :JamfMigration:wasMigrated bool true" "$localDataPath"/"$localDataPlist"
/usr/libexec/PlistBuddy -c "Add :JamfMigration:oldJSS string $oldJamfProURL" "$localDataPath"/"$localDataPlist"
/usr/libexec/PlistBuddy -c "Add :JamfMigration:usernameAtMigration string $currentUser" "$localDataPath"/"$localDataPlist"
/usr/libexec/PlistBuddy -c "Add :JamfMigration:fileVaultedByOldOrg bool $preMigrationFileVaultStatus" "$localDataPath"/"$localDataPlist"

##### Migration #####
displayMacMgmtUser
if [ "$macMgmtUser" == "" ]; then
    echo " Mac is marked as 'unmanaged' - filling with dummy data..."
    createXml
        cat "$xmlPath"
    putXmlApi
    removeMDMandEnroll
else
    echo " Mac has local management account: '$macMgmtUser' - continuing..."
    removeMDMandEnroll
fi

exit 0
