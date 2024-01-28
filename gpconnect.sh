#! /usr/bin/env bash

# Check that no more than one argument is passed
if [ $# -eq 1 ]; then
    # Check the first argument
    case "$1" in
        -c)
            action="connect";;
        --connect)
            action="connect";;
        -d)
            action="disconnect";;
        --disconnect)
            action="disconnect";;
        *)
            echo "Error: Invalid argument."
            exit 1;;
    esac
elif [ $# -eq 0 ]; then
    # Set default value
    action="connect"
else
    echo "Error: This script takes at most one argument (-c / --connect, which is the default, or -d / --disconnect)."
    exit 1
fi

function parse_prelogin_html () {
    echo -e "${1}" | grep -oE 'cookie>(.*)</prelogin' | cut -c8- | rev | cut -c11- | rev
}

function read_config() {
    # Read configuration from file and perform some validation checks.
    CONF=/etc/gpconnect.conf

    if [[ -f "${CONF}" ]]; then
        source "${CONF}";
    fi;

    if [[ -z "${GP_SERVER}" || -z "${GP_DEFAULT_REGION}" || -z "${GP_DEFAULT_GW}" ]]; then
        echo -e "Please check that GP_SERVER, GP_DEFAULT_REGION and GP_DEFAULT_GW are properly configured in ${CONF}".
        exit 1
    fi;
}

function get_prelogin_cookie () {

    RESPONSE="${1}"
    GP_PRELOGIN_MODE="${2}"

    if [[ -z "${RESPONSE}" ]]; then
            echo "Prelogin failed. Please check your configuration before trying again." >$(tty)
            exit 1
    fi;

    LOGIN=$(echo "${RESPONSE}" | grep -oE 'via (.*SAMLRequest.*)' | cut -c 4- | xargs)

    if [[ ${GP_PRELOGIN_MODE} = "manual" ]]; then
        echo -e "Connect to the following URL:\n${LOGIN}\nand, when the authentication is complete, copy the resulting HTML." >$(tty)
        read -p "Paste full HTML or pre-login cookie: " GP_PRELOGIN_COOKIE

        if [[ "${GP_PRELOGIN_COOKIE}" =~ "cookie>" ]]; then
            GP_PRELOGIN_COOKIE=$(parse_prelogin_html ${GP_PRELOGIN_COOKIE})
            echo -e "Detected HTML fragment, Cookie value: ${GP_PRELOGIN_COOKIE}" >$(tty)
        fi;
    elif [[ ${GP_PRELOGIN_MODE} = "automatic" ]]; then
        echo -e "A new browser window will now be opened automatically. If you don't have an open session you will have to authenticate manually: once you're done, please return to this window." >$(tty)
        read -p "Press 'enter' to continue."
        open -u ${LOGIN}

        GP_PRELOGIN_HTML=$(
            osascript <<'END'
                activate application "Safari"
                display dialog "Once authenticated, the webpage should show 'Login Successful'. You may then press OK to continue." buttons {"OK"} default button "OK"
                tell application "Safari"
                    set my_html to source of document 1
                    close current tab of front window without saving
                end tell
                return my_html
                end run
END
        )
        GP_PRELOGIN_COOKIE=$(parse_prelogin_html "${GP_PRELOGIN_HTML}")
    fi

    echo ${GP_PRELOGIN_COOKIE}
}


function get_gateways() {

    GATEWAYS=$(echo -e "${1}" |  grep -Eo '^.*\((.*gw\.gpcloudservice\.com)\).*$')
    
    GW_ARR=()
    IFS=$'\n'
    
    while read -r line; do
      GW_ARR+=(${line})
    done <<< "$GATEWAYS"

    echo -e "The portal offers the following gateways for connection:" >$(tty)

    GW_IDX=1
    for GW in "${GW_ARR[@]}"; do
      echo "$GW_IDX) $GW" >$(tty)
      ((GW_IDX++))
    done

    while :
    do
        read -p "Enter the item number corresponding to the gateway of your choice: " USER_CHOICE

        if [[ $USER_CHOICE =~ ^[0-9]+$ ]] && [[ $USER_CHOICE -ge 1 ]] && [[ $USER_CHOICE -le $(($GW_IDX - 1)) ]]
        then
            echo "${GW_ARR[$(($USER_CHOICE-1))]}"
            break
        else
            echo "Invalid choice, please try again."
            continue
        fi
    done
}

function connect() {

    case "$OSTYPE" in
    darwin*)   GP_PRELOGIN_MODE=automatic ;;
    *)         GP_PRELOGIN_MODE=manual ;;
    esac

    # Start connection process.
    GP_OS="${GP_OS:-win}"

    if [[ ! -z "${HIP_REPORT}" ]]; then
    GP_WRAPPER="--csd-wrapper=${HIP_REPORT}"
    fi;
    if [[ ! -z "${VPNC_SCRIPT}" ]]; then
    GP_SCRIPT="--script=${VPNC_SCRIPT}"
    fi;

    # If user is unset, read it from stdin...
    if [[ -z "${GP_USER}" ]]; then
        read -p "Username: " GP_USER
    fi;

    # ... then make sure it's lowercase:
    GP_USER=${GP_USER,,}

    echo -e "Will now perform a portal prelogin attempt.\n"

    PORTAL_RESPONSE=$(openconnect --protocol=gp "${GP_SERVER}" --user="${GP_USER}" 2>/dev/null)
    PORTAL_PRELOGIN_COOKIE=$(get_prelogin_cookie "${PORTAL_RESPONSE}" "${GP_PRELOGIN_MODE}")

    echo -e "Will now perform a portal login attempt. When asked, enter your sudo password.\n"

    # Login on portal
    PORTAL_LOGIN=$(echo "${PORTAL_PRELOGIN_COOKIE}" | sudo openconnect \
    --dump-http-traffic \
    --passwd-on-stdin \
    --background \
    --protocol=gp \
    --user="${GP_USER}" \
    --os="${GP_OS}" \
    --authgroup="${GP_DEFAULT_REGION}" \
    --usergroup=portal:prelogin-cookie \
    "${GP_SERVER}" \
    "${GP_WRAPPER}" \
    "${GP_SCRIPT}")


    if [[ "${PORTAL_LOGIN}" =~ "Login fails" ]]; then
        
        echo -e "Portal login not allowed. Follow the procedure to choose a gateway to login.\n"
        
        GATEWAY=$(get_gateways "${PORTAL_LOGIN}")

        echo -e "${GATEWAY} will be used to perform login.\n"

        AUTHGROUP="$(echo ${GATEWAY} | grep -Eo '^(.*) ' | xargs)"
        GATEWAY_ADDRESS="$(echo ${GATEWAY} | grep -Eo '\((.*)\)' | cut -c2- | rev | cut -c2- | rev)"

        # Perform prelogin on gateway instead of portal
        GW_RESPONSE=$(openconnect --protocol=gp ${GP_DEFAULT_GW} --user="${GP_USER}" 2>/dev/null)
        GW_PRELOGIN_COOKIE=$(get_prelogin_cookie "${GW_RESPONSE}" "${GP_PRELOGIN_MODE}")

        # Login on gateway
        echo "${GW_PRELOGIN_COOKIE}" | sudo openconnect \
        --passwd-on-stdin \
        --background \
        --protocol=gp \
        --user="${GP_USER}" \
        --os="${GP_OS}" \
        --authgroup="${AUTHGROUP}" \
        --usergroup=gateway:prelogin-cookie \
        "${GATEWAY_ADDRESS}" \
        "${GP_WRAPPER}" \
        "${GP_SCRIPT}"
    fi

    echo -e "Login succeeded."

    exit 0
}

function disconnect () {
    sudo pkill -SIGINT -f "${GP_USER}" && echo "Disconnected" || echo "Could not terminate the tunnel."
}

read_config
if [ "$action" = "connect" ]; then
    if ! pgrep -f "${GP_SERVER}" >/dev/null; then
        connect
    else
        echo "There seems to be another open tunnel to the same server, aborting."
        exit 1
    fi
elif  [ "$action" = "disconnect" ]; then
    disconnect
else
    echo "Action not implemented"
    exit 1;
fi
