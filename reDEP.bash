#!/bin/bash
# set -x 
clear


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
#       - Record pre-migration state data at /Library/$myOrg/Data/com.$myOrg.jamfLocalExtensionAttributes.plist
#         - Exit with error if FileVault operations are in progress or FileVault state cannot be determined
#       - Remove old MDM profile
#         - Attempt MDM profile removal via Jamf binary
#         - Attempt MDM profile removal via Jamf API sending an MDM UnmanageDevice command
#         - Lastly, if failed to remove MDM Profile the /var/db/ConfigurationProfiles folder will be renamed.
#        -Enroll to new Jamf Pro instance
#         - Enroll to new Jamf Pro via invitation
#         - Call DEP nag
#       - Compensate for Jamf PI-005441 (causes computer to become unmanaged after issuing DEP nag)
#         - Pause to allow user to accept DEP enrollment
#         - Set correct values for remote_management fields via Jamf API
#         - Reassert management framework and continue enrollment policies
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
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# USER VARIABLES - These can be left blank here and populated by Jamf policy parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

oldJamfProURL=""				    # Old Jamf Pro server URL - for API (ie. https://jamfold.acme.com:8443)
	oldJamfApiUser=""			    # API user account in Jamf Pro w/ Update permission
	oldJamfApiPass=""			    # Password for above API user account

newJamfProURL=""				    # New Jamf Pro server URL - for enrolling (ie. https://jamfnew.acme.com:8443)
	newJamfInvitationCode=""	# Re-usable invitation code from Recon.app or SMTP invitation

myOrg=""		                # Used to generate path and filename for
								            # /Library/$myOrg/Data/com.$myOrg.jamfLocalExtensionAttributes.plist

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Jamf policy parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

[ "$4" != "" ] && [ "$oldJamfProURL" == "" ] && oldJamfProURL=$4
[ "$5" != "" ] && [ "$oldJamfApiUser" == "" ] && oldJamfApiUser=$5
[ "$6" != "" ] && [ "$oldJamfApiPass" == "" ] && oldJamfApiPass=$6
[ "$7" != "" ] && [ "$newJamfProURL" == "" ] && newJamfProURL=$7
[ "$8" != "" ] && [ "$newJamfInvitationCode" == "" ] && newJamfInvitationCode=$8
# Parameter 9 is used to populate the "real" Jamf SSH/management username in $managementUser for the second execution of the createXml function
# Parameter 10 is used to populate the "real" Jamf SSH/management password in $managementPass for the second execution of the createXml function
  # NOTE: Parameter 9 & 10 values should match the management account used by user initiated enrollment in the new Jamf Pro
[ "${11}" != "" ] && [ "$myOrg" == "" ] && myOrg=${11}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# SYSTEM VARIABLES
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

osMinorVersion=$( /usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f2 )
timestamp=$( /bin/date '+%Y-%m-%d-%H-%M-%S' )
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
        fi

    echo " Enrolling to new Jamf Pro... this might take some time ..."
    jamf enroll -invitation "$newJamfInvitationCode"
        if [ "$?" != "" ]; then
            echo " Successfully migrated to new Jamf Pro."
            echo "$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)"
        else
            echo " ALERT - There was a problem with enrolling to the new JSS."
        fi

    echo " Attempting to lock MDM in place with DEP."
    profiles -N
        if [ "$?" != "" ]; then
            echo " DEP Successful!"
        else
            echo " ALERT - There was a problem with enrolling with DEP."
        fi
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
/usr/libexec/PlistBuddy -c "Add :JamfMigration:usernameAtMigration string $(stat -f %Su /dev/console)" "$localDataPath"/"$localDataPlist"
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

##### Compensate for Jamf PI-005441 #####

# pause to allow user to accept DEP enrollment
sleep 30

# set correct values for management account credentials
managementUser=$9
managementPass="${10}" # note: curly braces required for 2-digit parameters

# Set computer as managed in Jamf Pro
createXml
    cat "$xmlPath"
putXmlApi

# Reassert management framework and continue enrollment policies
/usr/local/bin/jamf manage
/usr/local/bin/jamf policy -event enrollmentComplete

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# CLEANUP & EXIT
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

exit 0
