#!/bin/bash

# Declare variables
# LDAP
LDAP_SERVER="ldaps://authorise.is.ed.ac.uk"
LDAP_BASE="dc=authorise,dc=ed,dc=ac,dc=uk"
LDAP_SCHOOL="eduniSchoolCode"

# EdLAN DB location
EDLAN_DB="https://www.edlan-db.ucs.ed.ac.uk/webservice/pie.cfm"

# Lock file location. DO NOT CHANGE THIS! Other processes and policies specifically check for this file.
LOCK_FILE="/var/run/UoEDEPRunning"

# Jamf binary location
JAMF_BINARY=/usr/local/jamf/bin/jamf

# BOM file to indicate setup has completed
SETUP_DONE="/var/db/receipts/is.ed.provisioning.done.bom"

# DEP Notify log location
DEP_NOTIFY_LOG="/Library/Logs/depnotify.log"

# Log file location
LOGFILE="/Library/Logs/jamf-enrolment.log"

# DEP Notify variables
# Registration bom file    
DEP_NOTIFY_REGISTER_DONE="/var/tmp/com.depnotify.registration.done"

# Main DEP Notify image and message    
DEP_NOTIFY_IMAGE="/usr/local/jamf/UoELogo.png"
DEP_NOTIFY_MAIN_TITLE="UoE macOS Supported Desktop Installation"
DEP_NOTIFY_MAIN_TEXT="Your computer is now being set up with the University of Edinburgh Supported macOS build.\n\nPlease do not interrupt this process.\n\nThis process may take some time. Please be patient."
    
# DEPNotify Help bubble settings
HELP_BUBBLE_TITLE="Need Help?"
HELP_BUBBLE_BODY="Please contact IS Helpline on \n\n0131 651 51 51\n\nor visit\n\nhttps://edin.ac/helpline"

# DEPNotify warning sign    
DEP_NOTIFY_ERROR="/usr/local/jamf/warning.png"

# DEPNotify setup complete image
DEP_NOTIFY_COMPLETE_IMAGE="/usr/local/jamf/tick.png"

# DEPNotify error messages for Desktops and laptops
DEP_NOTIFY_DESKTOP_ERROR="Setup is unable to find an EdLAN DB registration for this device.\n\nSetup will continue in approximately 1 minute however it will use the same naming convention as laptops until resolved.\nOnce built, you should be able to resolve this using the Set-Desktop-Name JAMF event trigger.\n\nThe computer will also need to be bound to Active Directory by running the JAMF event trigger Bind-AD after the hostname has been correctly set.\n\nPlease contact IS Helpline if you require any more assistance."

# Jamf helper location
JAMF_HELPER="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"

# Function for obtaining timestamp
timestamp() {
    while read -r line
    do
        TIMESTAMP=`date`
        echo "[$TIMESTAMP] $line"
    done
}

# Get model of device
get_mobility() {
  	PRODUCT_NAME=$(ioreg -l | awk '/product-name/ { split($0, line, "\""); printf("%s\n", line[4]); }')
  	if echo "${PRODUCT_NAME}" | grep -qi "macbook" 
  	then
    	MOBILITY=mobile
  	else
    	MOBILITY=desktop
  	fi 
  	echo ${MOBILITY}  
}

# Get serial number
get_serial() {
  	# Full serial is a bit long, use the last 8 chars instead.
  	SERIAL_NO=$(ioreg -c IOPlatformExpertDevice -d 2 | awk -F\" '/IOPlatformSerialNumber/{print $(NF-1)}' | tail -c 9)
  	echo ${SERIAL_NO}
}

# Get associated school code
get_school() {
  	UUN=${1}
  	SCHOOL_CODE=$(ldapsearch -x -H "${LDAP_SERVER}" -b"${LDAP_BASE}" -s sub "(uid=${UUN})" "${LDAP_SCHOOL}" | awk -F ': ' '/^'"${LDAP_SCHOOL}"'/ {print $2}')
  	# Just return raw eduniSchoolCode for now - ideally we'd like the human-readable abbreviation
  	[ -z "${SCHOOL_CODE}" ] && SCHOOL_CODE="Unknown"
  	echo ${SCHOOL_CODE}
}

# Get mac address
get_macaddr() {
  	ACTIVE_ADAPTER=`route get ed.ac.uk | grep interface | awk '{print $2}'`
  	MAC_ADDRESS=$(ifconfig $ACTIVE_ADAPTER ether | awk '/ether/ {print $NF}')
  	echo "MAC Address: ${MAC_ADDRESS}."
  	echo ${MAC_ADDRESS}
}

# Get DNS name form EdLAN DB
get_edlan_dnsname() {
  	MAC=$(get_macaddr)
  	if ! [ -z ${MAC} ]; then
    	DNSFULL=$(curl --insecure "${EDLAN_DB}?MAC=${MAC}&return=DNS" 2>/dev/null) # This won't work with 10.13, pending edlan changes.
   		if [ -z ${DNSFULL} ]; then
        	DNSFULL=`python -c "import urllib2, ssl;print urllib2.urlopen('${EDLAN_DB}?MAC=${MAC}&return=DNS', context=ssl._create_unverified_context()).read()"`
    	fi
    	# Remove anything potentially dodgy 
    	DNS_NAME=`echo ${DNSFULL} | awk -F "." '{print $1}'`
    	echo ${DNS_NAME}
  	fi  
}

# Set the copmuter name
set_computer_name() {
	NAME="${1}"
  	/usr/sbin/scutil --set LocalHostName "${NAME}"
    /usr/sbin/scutil --set ComputerName "${NAME}"
    /usr/sbin/scutil --set HostName "${NAME}"
}

set_desktop_name(){
    NAME="${1}"
    echo "Obtained computer name is $NAME" | timestamp 2>&1 | tee -a $LOGFILE
    echo "Setting local computer name..." | timestamp 2>&1 | tee -a $LOGFILE
    set_computer_name ${NAME}
    echo "Attempting to bind to UoE domain..." | timestamp 2>&1 | tee -a $LOGFILE
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    echo "Status: Binding computer to UoE domain..." >> $DEP_NOTIFY_LOG
    $JAMF_BINARY policy -event Bind-AD 
}

# Function to return whether local account exists or not
has_local_account() {
  	# Does a local account exist with ${uun}
  	UUN=${1}
  	if ACCT=$(dscl . -list /Users | grep "^${UUN}$")
  	then
    	echo "Local Account for ${UUN} exists"
    	true 
  	else
    	echo "Local Account for ${UUN} does not exist"
    	false
  	fi
}

# Validate username
validate_username() {
    # Determine validity of a username by checking whether we can find the school code.
  	uun=${1}  
  	[ ! -z "$(get_school ${1})" ]
}

get_username() {
  	uun=$(osascript -e 'tell application "Finder"
        activate
            set uun to text returned of (display dialog "Welcome to the Mac Supported Desktop.\n\nPlease enter the University Username of the primary user of this computer:\n"¬
            with title "University of Edinburgh Mac Supported Desktop" default answer ""¬
            with icon file "usr:local:jamf:UoELogo.png"¬
            buttons {"OK"} default button {"OK"})
        end tell
        return uun'
	)
	
	until [ $(get_school ${uun}) != "Unknown" ] && [ $(get_school ${uun}) != "" ]
	do
		MESSAGE="The setup detected an error due to not being able to find a valid school code for University Login username $uun.
        
This process cannot continue without a valid University Login username.

Select the button below to re-enter.

If any help is required please contact the IS Helpline - https://edin.ac/helpline

"
		"$JAMF_HELPER" -windowType utility \
						-title "WARNING!" \
						-heading "INVALID UNIVERSITY LOGIN USERNAME!" \
						-icon "$DEP_NOTIFY_ERROR" \
						-description "$MESSAGE" \
						-button1 "Retry" \
                        -defaultButton 1
        get_username		
	done
  	echo ${uun}
}

get_secure_token_admin(){
    # Grab the current user
    CURRENT_USER=${1}
    # Link for assistance
    LINK="https://edin.ac/helpline"
    # We need to request logged in users password as this is the only account that has a secure token    
    # Loop until we are sure password is correct
    while true
    do
        PASS=$(/usr/bin/osascript -e 'tell application "Finder"
            activate
                set PASS to text returned of (display dialog "To enable an account for encryption, this process requires you to enter your password :"¬
                with title "Enter password" default answer ""¬
                with text buttons {"Ok"} default button 1 with hidden answer¬
                with icon file "usr:local:jamf:warning.png")
            end tell'
        )
        
        DSCL_CHECK=`dscl /Local/Default authonly $CURRENT_USER $PASS; echo $?`
        echo "DSCL Check for $CURRENT_USER is $((DCSL_CHECK))" | timestamp 2>&1 | tee -a $LOGFILE
        
        if [[ $DSCL_CHECK == 0 ]]; then
            # If password is correct then break from loop
            echo "User password passed check" | timestamp 2>&1 | tee -a $LOGFILE
            break;
        else
            "$JAMF_HELPER"  -windowType utility \
							-title "WARNING" \
							-heading "Password incorrect" \
							-icon "$DEP_NOTIFY_ERROR" \
							-description "The password for your account appears to be incorrect!

Please attempt to re-enter your password.

Please contact IS Helpline for further help $LINK

" \
							-button1 "Retry" \
                            -defaultButton 1
        fi           
    done
    
    # We need to grant the local admin account a secure token. Get a list of local admin accounts on the computer
    # LOCAL_ADMINS=$(dscl . -read Groups/admin GroupMembership | cut -c 18- | sed -E -e 's/(root|uoemanage)//g')
    
    # Declare array of department admin accounts
    ADMIN_ACCS=("ahsssupport" "sbsadmin" "camsupport" "csesupport" "csgsupport" "divsupport" "ecasupport" "econsupport" "educsupport" "eusasupport" "geossupport" "hcasupport" "healthsupport" "infsupport" "isgsupport" "lawsupport" "llcsupport" "mathsupport" "mvmsupport" "pplssupport" "ppssupport" "scecollsupport" "sopasupport" "sspsitadmin" "srssupport" "uebs_support")
    
    # For each entry in the list of departmental admin accounts, check to see if one of them exists
    for i in "${ADMIN_ACCS[@]}"
    do
        # For each user in /Users/Users
        for user in "/Users/"/*; do 
            # Get foldername
            folderName=`basename $user`
            # If folder name equals an entry in the array, then most likely this is our local admin account
            if [ $folderName == "$i" ];
            then
                LOCAL_ADMIN_ACCOUNT=$folderName
            fi
        done
    done

    echo "The local admin account is $LOCAL_ADMIN_ACCOUNT" | timestamp 2>&1 | tee -a $LOGFILE
    while true
    do
        ADMIN_PASS=$(/usr/bin/osascript -e 'tell application "Finder"
            activate
                set PASS to text returned of (display dialog "To enable the local IT admin account for encryption, please enter the pasword for '$LOCAL_ADMIN_ACCOUNT':"¬
                with title "Enter password" default answer ""¬
                with text buttons {"Ok"} default button 1 with hidden answer¬
                with icon file "usr:local:jamf:warning.png")
            end tell'
        )
    
        DSCL_CHECK_ADMIN=`dscl /Local/Default authonly $LOCAL_ADMIN_ACCOUNT $ADMIN_PASS; echo $?`
        echo "DSCL Check for $LOCAL_ADMIN_ACCOUNT is $((DCSL_CHECK_ADMIN))" | timestamp 2>&1 | tee -a $LOGFILE
    
        if [[ $DSCL_CHECK_ADMIN == 0 ]]; then
            # If password is correct then break from loop
            echo "Admin password has passed check" | timestamp 2>&1 | tee -a $LOGFILE
            break;
        else
            # Show warning
            "$JAMF_HELPER"  -windowType utility \
                            -title "WARNING" \
							-heading "Password incorrect" \
							-icon "$DEP_NOTIFY_ERROR" \
							-description "The password for $LOCAL_ADMIN_ACCOUNT appears to be incorrect!

Please attempt to re-enter the password for $LOCAL_ADMIN_ACCOUNT.

Please contact IS Helpline for further help $LINK

" \
							-button1 "Retry" \
                            -defaultButton 1
        fi  
    done
    
    # We should hopefully now have all details required to grant the local admin account a secure token. Let's make sure it doesn't have one first
    CURRENT_STATUS=$(sysadminctl -secureTokenStatus "$LOCAL_ADMIN_ACCOUNT")
    if [[ "$CURRENT_STATUS" == *"ENABLED"* ]]
    then
        echo "$LOCAL_ADMIN_ACCOUNT already has a secure token." | timestamp 2>&1 | tee -a $LOGFILE
    else
        echo "$LOCAL_ADMIN_ACCOUNT does not have a secure token. Attempting to apply token..." | timestamp 2>&1 | tee -a $LOGFILE
        sysadminctl -secureTokenOn "$LOCAL_ADMIN_ACCOUNT" -password "$ADMIN_PASS" -adminUser "$CURRENT_USER" -adminPassword "$PASS"
    fi       
}

get_secure_token_other_user(){
    OTHER_USER=${1}
    CURRENT_USER=${2}   
    
    CURRENT_STATUS=$(sysadminctl -secureTokenStatus "$OTHER_USER")
    if [[ "$CURRENT_STATUS" == *"ENABLED"* ]]
    then
        echo "$OTHER_USER already has a secure token." | timestamp 2>&1 | tee -a $LOGFILE
    else
        # Get mobility. If it's a laptop, grant the primary user a secure token. If it's a desktop don't.
        MOBILILTY=$(get_mobility)
        if [[ "$MOBILITY" == "mobile" ]]
        then
            echo "$OTHER_USER does not have a secure token. Attempting to apply token..." | timestamp 2>&1 | tee -a $LOGFILE
            sysadminctl -secureTokenOn "$OTHER_USER" -password "$OTHER_USER" -adminUser "$CURRENT_USER" -adminPassword "$PASS"
        else
            echo "As it's a desktop, don't grant the primary user a secure token." | timestamp 2>&1 | tee -a $LOGFILE
        fi
    fi
}
  	
dep_notify_status(){
    STATUS="${1}"
    echo "${STATUS}" | timestamp 2>&1 | tee -a $LOGFILE
    echo "Status: ${STATUS}" >> $DEP_NOTIFY_LOG   
}

dep_notify_error(){
    MAIN_TITLE="${1}"
    MAIN_TEXT="${2}"
    STATUS="${3}"
    echo "Command: MainTitle: $MAIN_TITLE" >> $DEP_NOTIFY_LOG
    echo "Command: MainText: $MAIN_TEXT" >> $DEP_NOTIFY_LOG
    echo "Command: Image: $DEP_NOTIFY_ERROR" >> $DEP_NOTIFY_LOG
    echo "Status: $STATUS" >> $DEP_NOTIFY_LOG
    sleep 60
}

dep_notify_main_message(){
    echo "Command: MainTitle: $DEP_NOTIFY_MAIN_TITLE" >> $DEP_NOTIFY_LOG
    echo "Command: MainText: $DEP_NOTIFY_MAIN_TEXT" >> $DEP_NOTIFY_LOG    
    echo "Command: Image: $DEP_NOTIFY_IMAGE" >> $DEP_NOTIFY_LOG    
}

# ---- MAIN ---- #

# If the receipt is found, DEP already ran so let's remove this script and
# the launch Daemon. This helps if someone re-enrolls a machine for some reason.
if [ -f "${SETUP_DONE}" ]; then
	# Remove the Launch Daemon
	/bin/rm -Rf /Library/LaunchDaemons/is.ed.launch.plist
	# Remove this script
	/bin/rm -- "$0"
	exit 0
fi

# Drop a lock file so that other processes know we are running
echo "Dropping lock file at ${LOCK_FILE}..." | timestamp 2>&1 | tee -a $LOGFILE
touch "${LOCK_FILE}" 

# Get current logged in user
CURRENT_USER=$(/usr/bin/python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
echo "Logged in user is $CURRENT_USER" | timestamp 2>&1 | tee -a $LOGFILE

# Wait for setup to finish, Finder process to start and for Dock to appear
if pgrep -x "Finder" \
&& pgrep -x "Dock" \
&& [ "$CURRENT_USER" != "_mbsetupuser" ] \
&& [ ! -f "${SETUP_DONE}" ]; then  
    # Kill any installer process running
    killall Installer
    # Wait a few seconds
    sleep 5
       
    # Enable SSH   
    systemsetup -setremotelogin on
              
    # Set Time zone and loop until it's set
    while true
    do
        TIME_ZONE=$(/usr/sbin/systemsetup -gettimezone)
        echo "Current Time zone is $TIME_ZONE." | timestamp 2>&1 | tee -a $LOGFILE
        if [[ $TIME_ZONE != *"London"* ]]; then
            echo "Changing time zone to London..." | timestamp 2>&1 | tee -a $LOGFILE
            /usr/sbin/systemsetup -settimezone "Europe/London"            
        else
            echo "Time zone already set to London." | timestamp 2>&1 | tee -a $LOGFILE
            break
        fi
    done
    
    # What OS is running?
    OS_VERSION=`sw_vers -productVersion | awk -F . '{print $2}'`
    echo "Operating System is 10.$OS_VERSION." | timestamp 2>&1 | tee -a $LOGFILE
                
    # Attempt to enable Remote Desktop sharing
    echo "Enabling ARD Agent..." | timestamp 2>&1 | tee -a $LOGFILE
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -activate -configure -allowAccessFor -allUsers -privs -all -clientopts -setmenuextra -menuextra no
    
    # Set location of plist files
    DEP_NOTIFY_USER_INPUT_PLIST="/Users/$CURRENT_USER/Library/Preferences/menu.nomad.DEPNotifyUserInput.plist"
    DEP_NOTIFY_CONFIG_PLIST="/Users/$CURRENT_USER/Library/Preferences/menu.nomad.DEPNotify.plist"
    
    # If files currently exist then remove them
    if [ -f "$DEP_NOTIFY_CONFIG_PLIST" ]; then
        rm "$DEP_NOTIFY_CONFIG_PLIST"
    fi
    
    if [ -f "$DEP_NOTIFY_USER_INPUT_PLIST" ]; then
        rm "$DEP_NOTIFY_USER_INPUT_PLIST"
    fi
      
    # Set values for DEPNotify
    echo "Setting plist values for DEP Notify..." | timestamp 2>&1 | tee -a $LOGFILE
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" helpBubble -array-add "$HELP_BUBBLE_TITLE"
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" helpBubble -array-add "$HELP_BUBBLE_BODY"
    
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" pathToPlistFile "$DEP_NOTIFY_USER_INPUT_PLIST"
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" registrationMainTitle "Select primary user"    
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" registrationButtonLabel "Continue Setup"
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" registrationPicturePath "/usr/local/jamf/UoELogo.png"
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" popupButton1Label "Who will be the primary user of this device?"
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" popupButton1Content -array-add "Currently logged in user" "Other user"
    defaults write "$DEP_NOTIFY_CONFIG_PLIST" popupButton1Bubble -array-add "Primary user" "Please select who will be the primary user.\n\nIf you are a computing officer setting the device up for another user then select \"Other user\""
    
    # Set inital display text on DEPNotify Window
    echo "Command: MainTitle: $DEP_NOTIFY_MAIN_TITLE" >> $DEP_NOTIFY_LOG
    echo "Command: MainText: Starting this process will enrol your device into the university macOS supported service." >> $DEP_NOTIFY_LOG
    echo "Command: Image: $DEP_NOTIFY_IMAGE" >> $DEP_NOTIFY_LOG
    echo "Status: " >> $DEP_NOTIFY_LOG 
    echo "Command: DeterminateManual: 14" >> $DEP_NOTIFY_LOG  
        
    # Set permissions on user input plist file
    chown "$CURRENT_USER":staff "$DEP_NOTIFY_CONFIG_PLIST"
    chmod 600 "$DEP_NOTIFY_CONFIG_PLIST"
    
    # Open DEPNotify
    echo "Opening DEPNotify..." | timestamp 2>&1 | tee -a $LOGFILE
    sudo -u "$CURRENT_USER" open -a /Applications/Utilities/DEPNotify.app --args -path "$DEP_NOTIFY_LOG" &
        
    # Let's caffinate the mac because this can take long
    echo "Running caffeinate to make sure machine doesn't sleep." | timestamp 2>&1 | tee -a $LOGFILE
    /usr/bin/caffeinate -d -i -m -u &
    caffeinatepid=$!
    
    # Get user input...
    echo "Command: ContinueButtonRegister: Begin setup" >> $DEP_NOTIFY_LOG
    while [ ! -f "$DEP_NOTIFY_REGISTER_DONE" ]; do
      echo "Waiting for currently logged in user to select primary user..." | timestamp 2>&1 | tee -a $LOGFILE
      sleep 5
    done
    
    # Sleep for a few seconds just to make sure selection has been registered in plist
    sleep 3
    
    USERNAME=""
    OTHER_USER=""
    
    # Get the selection value
    PRIMARY_USER=$(defaults read $DEP_NOTIFY_USER_INPUT_PLIST "Who will be the primary user of this device?")    
    echo "Primary user selection is $PRIMARY_USER" | timestamp 2>&1 | tee -a $LOGFILE
    
    # If it's the currently logged in user then great - we don't even need to validate against AD as logging in using NoMAD LoginAD has already confirmed uun is valid
    if [ "$PRIMARY_USER" == "Currently logged in user" ];then
        USERNAME="$CURRENT_USER"
        "$JAMF_HELPER" -windowType utility \
								-title "NOTICE" \
								-heading "Primary user Account" \
								-icon "$DEP_NOTIFY_IMAGE" \
								-description "Primary user of the device has been set to the currently logged in UUN
        
        $USERNAME
                                
Please use Your University Login from now on to login to this device." \
								-button1 "Continue" \
                                -defaultButton 1
        echo "Primary username will be $USERNAME" | timestamp 2>&1 | tee -a $LOGFILE
    else
        # Set the other user flag - this is required to grant a secure token
        OTHER_USER="TRUE"
        UUN=$(get_username)      
        USERNAME="$UUN"
        echo "Primary username will be $USERNAME" | timestamp 2>&1 | tee -a $LOGFILE
        
    fi
    
    dep_notify_main_message
    
    # Get school code of primary user
    dep_notify_status "Obtaining school code for username..."
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    SCHOOL="$(get_school ${USERNAME})"
    sleep 1
    echo "School code for $USERNAME is $SCHOOL." | timestamp 2>&1 | tee -a $LOGFILE
    
    # Get device type
    dep_notify_status "Obtaining device type..."
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    MOBILITY=$(get_mobility)
    
    # Beginning device specific config
    dep_notify_status "Beginning device specific configuration..."
    case $MOBILITY in
        # If it's a laptop
    	mobile)
            echo "Status: Performing laptop configuration..." >> $DEP_NOTIFY_LOG
            echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG            
  	  		# Create a local account
  	  		echo "Is a laptop. Creating local account..." | timestamp 2>&1 | tee -a $LOGFILE
            if ! $(has_local_account ${USERNAME}); then
                echo "No local account for $USERNAME Found. Creating local account for $USERNAME..." | timestamp 2>&1 | tee -a $LOGFILE
                $JAMF_BINARY createAccount -username $USERNAME -realname $USERNAME -password $USERNAME
                NAME=${SCHOOL}-$(get_serial)
                set_computer_name ${NAME}
            else
                # Local account for ${USERNAME} Appears to already exist.
                echo "Local account for ${USERNAME} already appears to exist. Moving on..." | timestamp 2>&1 | tee -a $LOGFILE     
                NAME=${SCHOOL}-$(get_serial)
                set_computer_name ${NAME}
                # Laptops need an extra step to fill up the DEPNotify bar, so adding a step below.
                echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
                echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
            fi
    	;;
        # If it's a Desktop
    	desktop)
            echo "Status: Performing Desktop configuration..." >> $DEP_NOTIFY_LOG
            echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG 
            echo "Is a desktop." | timestamp 2>&1 | tee -a $LOGFILE
            # Switch wifi off, it's not needed
            echo "Switching off wifi..." | timestamp 2>&1 | tee -a $LOGFILE            
  	  		networksetup -setairportpower $(networksetup -listallhardwareports | awk '/AirPort|Wi-Fi/{getline; print $NF}') off
            # Attempt to get dns name from EdLAN DB
            echo "Attempting to obtain name from EdLAN DB..." | timestamp 2>&1 | tee -a $LOGFILE
            NAME=$(get_edlan_dnsname)
            # If we get a name, then attempt a bind!
            if [ ${NAME} ]; then
                set_desktop_name ${NAME}
            else            
                echo "Looks like we couldn't obtain a name. Performing a dig to find DNS name..." | timestamp 2>&1 | tee -a $LOGFILE
                IP_ADDRESS=`ipconfig getifaddr en0`
                NAME=`dig +short -x ${IP_ADDRESS} | awk -F '.' '{print $1}'`
                if [ ${NAME} ]; then
                    set_desktop_name ${NAME}
                else
                    # Send warning to log and just use the same naming scheme as for laptops.
                    echo "*** Failed to find DNS name from edlan or dig lookup ***" | timestamp 2>&1 | tee -a $LOGFILE
                    [ -z ${NAME} ] && NAME=${SCHOOL}-$(get_serial)
                    set_computer_name ${NAME}
                    #sleep 60
                    # Display JAMF Helper warning                    
                    "$JAMF_HELPER" -windowType utility \
								-title "WARNING!" \
								-heading "Cannot obtain Computer Name from EdLAN DB!" \
								-icon "$DEP_NOTIFY_ERROR" \
								-description "Setup is unable to communicate with EdLAN DB to obtain a Computer name.
                    
Setup can continue however it will use the same naming convention as laptops until resolved - $NAME.

Once built, you should be able to resolve this using the Set-Desktop-Name JAMF event trigger.

The computer will also need to be bound to Active Directory by running the JAMF event trigger Bind-AD after the Computer name has been set correctly.

Information on JAMF event triggers can be found here : https://edin.ac/36zzsfX

Please contact IS Helpline if you require any more assistance :

https://edin.ac/helpline

" \
								-button1 "Continue" \
                                -defaultButton 1
                    # Change DEPNotify message to main message
                    dep_notify_main_message
                    #echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
                fi
            fi     		
    	;;
    	*)
  			NAME=${SCHOOL}-"Unknown"
        ;;
  	esac    
    
    # Update JSS with the primary username
    dep_notify_status "Sending primary user details to JSS..."
    $JAMF_BINARY recon -endUsername ${USERNAME}
    
    # Create the local admin account
    dep_notify_status "Creating local admin account..."
    $JAMF_BINARY policy -event Check-Local-Admin
     echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    
    # Install Core-Apps
    echo "Installing Core Applications. Check the following logs for more details :" | timestamp 2>&1 | tee -a $LOGFILE
    echo " " | tee -a $LOGFILE
    echo "            /var/log/jamf.log" | tee -a $LOGFILE
    echo "            /var/log/install.log" | tee -a $LOGFILE
    echo " " | tee -a $LOGFILE
    dep_notify_status "Installing Core applications. This may take some time..."   
    $JAMF_BINARY policy -event Core-Apps
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    
    # Run Health Check
    dep_notify_status "Running Health Check..."
    $JAMF_BINARY policy -event Health-Check
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    
    # Set up Dock
    dep_notify_status "Setting up Dock..."
    $JAMF_BINARY policy -event Dock
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    
    # Install Login items
    dep_notify_status "Installing login items..."
    $JAMF_BINARY policy -event LoginItem
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    
    dep_notify_status "Checking if a more recent major OS is available..."
    $JAMF_BINARY policy -event Check-OS-Installer
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
       
    dep_notify_status "Updating inventory..."
    $JAMF_BINARY recon
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    
    # Checking for software updates
    dep_notify_status "Checking for software updates..."
    $JAMF_BINARY policy -event SoftwareUpdateDEP
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
               
    dep_notify_status "Removing NoMAD Login AD..."
    $JAMF_BINARY policy -event removeNoLoAD
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    
    dep_notify_status "Granting secure tokens..."
    echo "Command: DeterminateManualStep:" >> $DEP_NOTIFY_LOG
    # Attempt to grant local admin account a secure token
    get_secure_token_admin ${CURRENT_USER}
    
    # Sometimes there's problems creating the local admin account, so try again.
    $JAMF_BINARY policy -event Check-Local-Admin
    
    # If other user was selected at the start of the DEP process, attempt to grant the other user a secure token
    if [ "$OTHER_USER" == "TRUE" ]
    then
        get_secure_token_other_user ${USERNAME} ${CURRENT_USER}
    fi        
        
    # Done
    echo "Enrolment complete!" | timestamp 2>&1 | tee -a $LOGFILE
    
    kill "$caffeinatepid"
    
    # Nice completion text
    echo "Command: Image: $DEP_NOTIFY_COMPLETE_IMAGE" >> $DEP_NOTIFY_LOG
    echo "Command: MainText: Your Mac is now finished with initial configuration.\n\nPlease restart the device to complete setup.\n\nIf Software Updates were found they will be installed after restarting and may take some time." >> $DEP_NOTIFY_LOG
    echo "Status: Configuration Complete!" >> $DEP_NOTIFY_LOG   
    echo "Command: ContinueButtonRestart: Restart" >> $DEP_NOTIFY_LOG  
    
    # Remove lock file
    rm "${LOCK_FILE}"

    # Wait a few seconds
    sleep 5
    # Create a bom file that allow this script to stop launching DEPNotify after done
    /usr/bin/touch /var/db/receipts/is.ed.provisioning.done.bom
    # Remove the Launch Daemon
    /bin/rm -Rf /Library/LaunchDaemons/is.ed.launch.plist
    
    # Remove the temporary admin account
    echo "Removing the temporary admin account..." | timestamp 2>&1 | tee -a $LOGFILE
    dscl . delete /Users/uoeadmin
    rm -rf /Users/uoeadmin
    sleep
    # Remove this script
    /bin/rm -- "$0"    
fi

exit 0