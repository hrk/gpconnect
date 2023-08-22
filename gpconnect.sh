#! /usr/bin/env bash

# Read configuration from file and perform some validation checks.
CONF=/etc/gpconnect.conf

if [[ -f "${CONF}" ]]; then
	source "${CONF}";
fi;

if [[ -z "${GP_SERVER}" || -z "${GP_GATEWAY}" ]]; then
	echo -e "Please check that both GP_SERVER and GP_GATEWAY are properly configured in ${CONF}".
fi;


# Start connection process.
GP_OS="${GP_OS:-win}"

if [[ ! -z "${HIP_REPORT}" ]]; then
	GP_WRAPPER='--csd-wrapper="${HIP_REPORT}"'
fi;
if [[ ! -z "${VPNC_SCRIPT}" ]]; then
	GP_SCRIPT='--script="${VPNC_SCRIPT}"'
fi;

# If user is unset, read it from stdin...
if [[ -z "${GP_USER}" ]]; then
	read -p "Username: " GP_USER
fi;

# ... then make sure it's lowercase:
GP_USER=${GP_USER,,}

RESPONSE=$(openconnect --protocol=gp "${GP_SERVER}" --user="${GP_USER}" 2>/dev/null)

LOGIN=$(echo "${RESPONSE}" | grep -oP 'via (.*SAMLRequest.*)' | cut -c 4- | xargs)

echo -e "Connect to the following URL:\n${LOGIN}\nand, when the authentication is complete, copy the resulting HTML."

#open -u ${LOGIN} && sleep 5
#
#GP_PRELOGIN_COOKIE=$((
#osascript <<'END'
#tell application "Safari" to set my_html to source of document 1
#tell application "Safari" to close current tab of front window without saving
#return my_html
#end run
#END
#) | grep -oP 'cookie>(.*)</prelogin' | cut -c8- | rev | cut -c11- | rev)

read -p "Paste full HTML or pre-login cookie: " GP_PRELOGIN_COOKIE

if [[ "${GP_PRELOGIN_COOKIE}" =~ "cookie>" ]]; then
	GP_PRELOGIN_COOKIE=$(echo -e "$GP_PRELOGIN_COOKIE" | grep -oP 'cookie>(.*)</prelogin' | cut -c8- | rev | cut -c11- | rev)
	echo -e "Detected HTML fragment, Cookie value: ${GP_PRELOGIN_COOKIE}"
fi;

echo -e "When asked, enter your sudo password.\n"

echo "${GP_PRELOGIN_COOKIE}" | sudo openconnect --protocol=gp --user="${GP_USER}" --os=win --authgroup="${GP_GATEWAY}" --usergroup=portal:prelogin-cookie ${GP_WRAPPER} --passwd-on-stdin ${GP_SCRIPT} ${GP_SERVER} --background
