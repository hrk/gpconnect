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

    if [[ -z "${GP_SERVER}" || -z "${GP_GATEWAY}" ]]; then
        echo -e "Please check that both GP_SERVER and GP_GATEWAY are properly configured in ${CONF}".
    fi;
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

    RESPONSE=$(openconnect --protocol=gp "${GP_SERVER}" --user="${GP_USER}" 2>/dev/null)

    if [[ -z "${RESPONSE}" ]]; then
            echo "Prelogin failed. Please check your configuration before trying again."
            exit 1
    fi;

    LOGIN=$(echo "${RESPONSE}" | grep -oE 'via (.*SAMLRequest.*)' | cut -c 4- | xargs)

    if [[ ${GP_PRELOGIN_MODE} = "manual" ]]; then
        echo -e "Connect to the following URL:\n${LOGIN}\nand, when the authentication is complete, copy the resulting HTML."
        read -p "Paste full HTML or pre-login cookie: " GP_PRELOGIN_COOKIE
        
        if [[ "${GP_PRELOGIN_COOKIE}" =~ "cookie>" ]]; then
            GP_PRELOGIN_COOKIE=$(parse_prelogin_html ${GP_PRELOGIN_COOKIE})
            echo -e "Detected HTML fragment, Cookie value: ${GP_PRELOGIN_COOKIE}"
        fi;
    elif [[ ${GP_PRELOGIN_MODE} = "automatic" ]]; then
        echo -e "A new browser window will now be opened automatically. If you don't have an open session you will have to authenticate manually: once you're done, please return to this window."
        read -p "Press 'enter' to continue."
        open -u ${LOGIN}
        
        GP_PRELOGIN_HTML=$(
            osascript <<'END'
                activate application "Safari"
                display dialog "If needed, manually authenticate and press OK to continue." buttons {"OK"} default button "OK"
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

    echo -e "When asked, enter your sudo password.\n"

    echo "${GP_PRELOGIN_COOKIE}" | sudo openconnect --passwd-on-stdin --background --quiet "${GP_SERVER}" --protocol=gp --user="${GP_USER}" --os="${GP_OS}" --authgroup="${GP_GATEWAY}" --usergroup=portal:prelogin-cookie "${GP_WRAPPER}" "${GP_SCRIPT}"
}

function disconnect () {
    sudo pkill -SIGINT -f "${GP_SERVER}" && echo "Disconnected" || echo "Could not terminate the tunnel."
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
