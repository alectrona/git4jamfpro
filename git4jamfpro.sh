#!/bin/bash

numCores=$(getconf _NPROCESSORS_ONLN)
maxParallelJobs="$(( numCores * 2 ))"
unameType=$(uname -s)
scriptSummariesFile="/tmp/script_summaries.xml"
eaSummariesFile="/tmp/ea_summaries.xml"

unset jamfProURL apiUser apiPass dryRun downloadScripts downloadEAs pushChangesToJamfPro apiToken

# Clean up function that will run upon exiting
function finish() {

    # Expire the Bearer Token
    [[ -n "$apiToken" ]] && curl -s -H "Authorization: Bearer $apiToken" "$jamfProURL/uapi/auth/invalidateToken" -X POST

    rm "$scriptSummariesFile" 2>/dev/null
    rm "$eaSummariesFile" 2>/dev/null
}
trap "finish" EXIT

# Function to get a Jamf Pro API Bearer Token
function get_jamf_pro_api_token() {
    local healthCheckHttpCode validityHttpCode

    # Make sure we can contact the Jamf Pro server
    healthCheckHttpCode=$(curl -s "$jamfProURL/healthCheck.html" -X GET -o /dev/null -w "%{http_code}")
    [[ "$healthCheckHttpCode" != "200" ]] && echo "Unable to contact the Jamf Pro server; exiting" && exit 1

    # Attempt to obtain the token
    apiToken=$(curl -s -u "$apiUser:$apiPass" "$jamfProURL/api/v1/auth/token" -X POST 2>/dev/null | jq -r '.token | select(.!=null)')
    [[ -z "$apiToken" ]] && echo "Unable to obtain a Jamf Pro API Bearer Token; exiting" && exit 2

    # Validate the token
    validityHttpCode=$(curl -s -H "Authorization: Bearer $apiToken" "${jamfProURL}/api/v1/auth" -X GET -o /dev/null -w "%{http_code}")
    parse_jamf_pro_api_http_codes "$validityHttpCode" || exit 3

    return
}

# Function to process changes scripts and potentially upload to Jamf Pro
function process_changed_script() {
    local change="$1"
    local changedFile="./${change}"
    local record name script cleanRecord id xml httpCode

    # Bail if the file does not exist
    [[ ! -e "$changedFile" ]] && echo "File does not exist: $changedFile"

    # If the changed file is xml, then we need to locate the accompanying script
    if [[ "$change" == *.xml ]]; then

        record="$changedFile"

        if [[ "$unameType" == "Darwin" ]]; then
            script=$(find -E "$(dirname "$changedFile")" -regex '.*(.py|.swift|.pl|.rb|.applescript|.zsh|.sh)$' -maxdepth 1 -mindepth 1 | head -1)
        else
            script=$(find "$(dirname "$changedFile")" -regextype posix-extended -regex '.*(.py|.swift|.pl|.rb|.applescript|.zsh|.sh)$' -maxdepth 1 -mindepth 1 | head -1)
        fi
    fi

    # If the changed file is a script, we need to find the accompanying xml file
    if [[ "$change" =~ .*(.py|.swift|.pl|.rb|.applescript|.zsh|.sh)$ ]]; then
        script="$changedFile"
        record=$(find "$(dirname "$changedFile")" -name "*.xml" -maxdepth 1 -mindepth 1 | head -1)
    fi

    # Exit if there is no xml record file
    if [[ -z "$record" ]]; then
        echo "No record xml found for: $change"
        return 1
    fi

    # Exit if there is no script
    if [[ -z "$script" ]]; then
        echo "Script not found for script: $change"
        return 1
    fi

    # Make sure the record xml doesn't include things we don't want
    cleanRecord=$(cat "$record" | xmlstarlet ed --delete '/script/id' \
        --delete '/script/script_contents' \
        --delete '/script/script_contents_encoded' \
        --delete '/script/filename')

    # Ensure we can get a name from the xml record
    name=$(echo "$cleanRecord" | xmlstarlet sel -T -t -m '/script' -v name)
    [[ -z "$name" ]] && echo "Could not determine name of script from the xml record, skipping." && return 1

    # Determine the id of a script that may exist in Jamf Pro with the same name
    id=$(get_script_summaries | xmlstarlet sel -T -t -m "//script[name=\"$name\"]" -v id 2>/dev/null)

    # Create xml containing both the original xml record and the script contents
    xml=$(echo "$cleanRecord" | xmlstarlet ed -s '/script' -t elem -n script_contents -v "$(cat "$script" | xmlstarlet esc)" | xmlstarlet fo -n -o)

    # Bail if the xml didn't get encoded properly
    if [[ -z "$xml" ]]; then
        echo "Failed to encode the script xml record and script contents properly."
        return 1
    fi

    # Update the script in Jamf Pro if it already exists
    # Otherwise, create a new script in Jamf Pro
    if [[ -n "$id" ]]; then
        
        # If configured to backup updated items, do that now
        [[ "$backupUpdated" == "true" ]] && download_script "$id" "$name" "./backups/scripts"

        # Handle dry run and return
        [[ "$dryRun" == "true" ]] && echo "Simulating updating script \"$name\"..." && sleep 1 && return

        echo "Updating script: $name..."
        httpCode=$(curl -s -H "Authorization: Bearer $apiToken" -H "Content-Type: application/xml" \
            "$jamfProURL/JSSResource/scripts/id/$id" -d "$xml" -X PUT -o /dev/null -w "%{http_code}")
        parse_jamf_pro_api_http_codes "$httpCode" || return 1
    else
        [[ "$dryRun" == "true" ]] && echo "Simulating creating script \"$name\"..." && sleep 1 && return

        echo "Creating script: $name..."
        httpCode=$(curl -s -H "Authorization: Bearer $apiToken" -H "Content-Type: application/xml" \
            "$jamfProURL/JSSResource/scripts/id/0" -d "$xml" -X POST -o /dev/null -w "%{http_code}")
        parse_jamf_pro_api_http_codes "$httpCode" || return 1
    fi

    return
}

# Function to process changed EAs and potentially upload to Jamf Pro
function process_changed_ea() {
    local change="$1"
    local changedFile="./${change}"
    local record name script cleanRecord id xml httpCode

    # Bail if the file does not exist
    [[ ! -e "$changedFile" ]] && echo "File does not exist: $changedFile"

    # If the changed file is xml, then we need to locate the accompanying script
    if [[ "$change" == *.xml ]]; then

        record="$changedFile"

        if [[ "$unameType" == "Darwin" ]]; then
            script=$(find -E "$(dirname "$changedFile")" -regex '.*(.py|.swift|.pl|.rb|.applescript|.zsh|.sh)$' -maxdepth 1 -mindepth 1 | head -1)
        else
            script=$(find "$(dirname "$changedFile")" -regextype posix-extended -regex '.*(.py|.swift|.pl|.rb|.applescript|.zsh|.sh)$' -maxdepth 1 -mindepth 1 | head -1)
        fi
    fi

    # If the changed file is a script, we need to find the accompanying xml file
    if [[ "$change" =~ .*(.py|.swift|.pl|.rb|.applescript|.zsh|.sh)$ ]]; then
        script="$changedFile"
        record=$(find "$(dirname "$changedFile")" -name "*.xml" -maxdepth 1 -mindepth 1 | head -1)
    fi

    # Exit if there is no xml record file
    if [[ -z "$record" ]]; then
        echo "No record xml found for: $change"
        return 1
    fi

    # Make sure the record xml doesn't include things we don't want
    cleanRecord=$(cat "$record" | xmlstarlet ed --delete '/computer_extension_attribute/id' \
        --delete '/computer_extension_attribute/input_type/script')

    # Ensure we can get a name of the EA from the xml record
    name=$(echo "$cleanRecord" | xmlstarlet sel -T -t -m '/computer_extension_attribute' -v name)
    [[ -z "$name" ]] && echo "Could not determine name of extension attribute from the xml record, skipping." && return 1

    # Create xml containing both the original xml record and the script contents (if exists)
    if [[ -n "$script" ]]; then
        xml=$(echo "$cleanRecord" | xmlstarlet ed -s '/computer_extension_attribute/input_type' -t elem -n script -v "$(cat "$script" | xmlstarlet esc)" | xmlstarlet fo -n -o)
    else
        xml=$(echo "$cleanRecord")
    fi

    # Bail if the xml didn't get encoded properly
    if [[ -z "$xml" ]]; then
        echo "Failed to encode the extension attribute xml record properly."
        return 1
    fi

    # Determine the id of an ea that may exist in Jamf Pro with the same name
    id=$(get_ea_summaries | xmlstarlet sel -T -t -m "//computer_extension_attribute[name=\"$name\"]" -v id 2>/dev/null)

    # Update the EA in Jamf Pro if it already exists
    # Otherwise, create a new EA in Jamf Pro
    if [[ -n "$id" ]]; then
        
        # If configured to backup updated items, do that now
        [[ "$backupUpdated" == "true" ]] && download_ea "$id" "$name" "./backups/extension_attributes"

        # Handle dry run and return
        [[ "$dryRun" == "true" ]] && echo "Simulating updating extension attribute \"$name\"..." && sleep 1 && return

        echo "Updating extension attribute: $name..."
        httpCode=$(curl -s -H "Authorization: Bearer $apiToken" -H "Content-Type: application/xml" \
            "$jamfProURL/JSSResource/computerextensionattributes/id/$id" -d "$xml" -X PUT -o /dev/null -w "%{http_code}")
        parse_jamf_pro_api_http_codes "$httpCode" || return 1
    else
        [[ "$dryRun" == "true" ]] && echo "Simulating creating extension attribute \"$name\"..." && sleep 1 && return

        echo "Creating extension attribute: $name..."
        httpCode=$(curl -s -H "Authorization: Bearer $apiToken" -H "Content-Type: application/xml" \
            "$jamfProURL/JSSResource/computerextensionattributes/id/0" -d "$xml" -X POST -o /dev/null -w "%{http_code}")
        parse_jamf_pro_api_http_codes "$httpCode" || return 1
    fi

    return
}

# Write the summaries (ID & Name) of each script locally for later parsing
function get_script_summaries() {

    if [[ -e "$scriptSummariesFile" ]]; then
        cat "$scriptSummariesFile"
    else
        curl -s -H "Authorization: Bearer $apiToken" -H "accept: application/xml" \
        "$jamfProURL/JSSResource/scripts" -X GET 2>/dev/null | xmlstarlet fo > "$scriptSummariesFile"
        cat "$scriptSummariesFile"
    fi
}

# Write the summaries (ID & Name) of each EA locally for later parsing
function get_ea_summaries() {

    if [[ -e "$eaSummariesFile" ]]; then
        cat "$eaSummariesFile"
    else
        curl -s -H "Authorization: Bearer $apiToken" -H "accept: application/xml" \
        "$jamfProURL/JSSResource/computerextensionattributes" -X GET 2>/dev/null | xmlstarlet fo > "$eaSummariesFile"
        cat "$eaSummariesFile"
    fi
}

# Function to parse Jamf Pro API http codes
# https://developer.jamf.com/jamf-pro/docs/jamf-pro-api-overview#response-codes
function parse_jamf_pro_api_http_codes() {
    local httpCode="$1"

    case "$httpCode" in
        200) # Request successful.
            return
            ;;
        201) # Request to create or update resource successful.
            return
            ;;
        202) # The request was accepted for processing, but the processing has not completed.
            return
            ;;
        204) # Request successful. Resource successfully deleted.
            return
            ;;
        # Anything past this point is an error and will return 1
        400)
            echo "Bad request. Verify the syntax of the request, specifically the request body."
            ;;
        401)
            echo "Authentication failed. Verify the credentials being used for the request."
            ;;
        403)
            echo "Invalid permissions. Verify the account being used has the proper permissions for the resource you are trying to access."
            ;;
        404)
            echo "Resource not found. Verify the URL path is correct."
            ;;
        409)
            echo "The request could not be completed due to a conflict with the current state of the resource."
            ;;
        412)
            echo "Precondition failed. See error description for additional details."
            ;;
        414)
            echo "Request-URI too long."
            ;;
        500)
            echo "Internal server error. Retry the request or contact support if the error persists."
            ;;
        503)
            echo "Service unavailable."
            ;;
        *)
            echo "Unknown error occured ($httpCode)."
            ;;
    esac

    return 1
}

# Function to parse a script's shebang and determine the appropriate file extension
function get_script_extension() {
    local shebang="$1"

    # Switch the shebang and determine the script extension
    # There are other possible script extensions but these are the most likely types
    # https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Scripts.html#
    case "$shebang" in
        *python*)
            echo "py"
            ;;
        *swift*)
            echo "swift"
            ;;
        *perl*)
            echo "pl"
            ;;
        *ruby*)
            echo "rb"
            ;;
        *osascript*)
            echo "applescript"
            ;;
        *zsh*)
            echo "zsh"
            ;;
        # Everything else falls into a sh script
        # Other types can easily be added above this point if necessary
        *)
            echo "sh"
            ;;
    esac

    return
}

# Function to download a script from Jamf Pro by ID
function download_script() {
    local id="$1"
    local name="$2"
    local dlPath="$3"
    local script shebang extension

    # Pull the full script object from Jamf Pro
    script=$(curl --request GET -H "Authorization: Bearer $apiToken" \
            "$jamfProURL/JSSResource/scripts/id/$id" -H "accept: application/xml" 2>/dev/null)

    [[ -z "$script" ]] && echo "Error getting script." && return 1

    # Get the shebang from the script
    shebang=$(echo "$script" | xmlstarlet sel -T -t -m '/script' -v script_contents | head -1)

    # Determine the file extension from the script's shebang
    extension=$(get_script_extension "$shebang")

    echo "Writing script \"$name\" to disk."

    # Make a directory for the script
    mkdir -p "${dlPath}/${name}"

    # Write the xml script object to disk
    echo "$script" | xmlstarlet ed --delete '/script/id' \
        --delete '/script/script_contents' \
        --delete '/script/script_contents_encoded' \
        --delete '/script/filename' > "${dlPath}/${name}/record.xml"

    # Write the script file to disk
    echo "$script" | xmlstarlet sel -T -t -m '/script' -v script_contents | tr -d '\r' > "${dlPath}/${name}/script.${extension}"

    return
}

# Function to download an EA from Jamf Pro by ID
function download_ea() {
    local id="$1"
    local name="$2"
    local dlPath="$3"
    local ea shebang extension

    # Pull the full EA object from Jamf Pro
    ea=$(curl --request GET -H "Authorization: Bearer $apiToken" \
            "$jamfProURL/JSSResource/computerextensionattributes/id/$id" -H "accept: application/xml" 2>/dev/null)

    [[ -z "$ea" ]] && echo "Error getting extension attribute." && return 1

    # Get the shebang from the EAs script
    shebang=$(echo "$ea" | xmlstarlet sel -T -t -m '/computer_extension_attribute/input_type' -v script | head -1)

    # Determine the file extension by the script's shebang
    extension=$(get_script_extension "$shebang")

    echo "Writing extension attribute \"$name\" to disk."

    # Make a directory for the object
    mkdir -p "${dlPath}/${name}"

    # Write the xml script object to disk
    echo "$ea" | xmlstarlet ed --delete '/computer_extension_attribute/id' \
        --delete '/computer_extension_attribute/input_type/script' > "${dlPath}/${name}/record.xml"

    # Write the script file to disk
    echo "$ea" | xmlstarlet sel -T -t -m '/computer_extension_attribute/input_type' -v script | tr -d '\r' > "${dlPath}/${name}/script.${extension}"

    return
}

# Begin main logic

# Determine if we have jq installed, and exit if not
if ! command -v jq > /dev/null ; then
    echo "Error: jq is not installed, can't continue."

    if [[ "$unameType" == "Darwin" ]]; then
        echo "Suggestion: Install jq with Homebrew: \"brew install jq\""
    else
        echo "Suggestion: Install jq with your distro's package manager."
    fi

    exit 1
fi

# Determine if we have xmlstarlet installed, and exit if not
if ! command -v xmlstarlet > /dev/null ; then
    echo "Error: xmlstarlet is not installed, can't continue."

    if [[ "$unameType" == "Darwin" ]]; then
        echo "Suggestion: Install xmlstarlet with Homebrew: \"brew install xmlstarlet\""
    else
        echo "Suggestion: Install xmlstarlet with your distro's package manager."
    fi

    exit 1
fi

# Parse our command line arguments
while test $# -gt 0
do
    case "$1" in
        --url)
            shift
            jamfProURL="${1%/}"
            ;;
        --username)
            shift
            apiUser="$1"
            ;;
        --password)
            shift
            apiPass="$1"
            ;;
        --download-scripts)
            downloadScripts="true"
            ;;
        --download-eas)
            downloadEAs="true"
            ;;
        --push-changes-to-jamf-pro)
            pushChangesToJamfPro="true"
            ;;
        --backup-updated)
            backupUpdated="true"
            ;;
        --limit)
            shift
            maxParallelJobs="$1"
            ;;
        --dry-run) dryRun="true"
            ;;
        *)
            # Exit if we received an unknown option/flag/argument
            [[ "$1" == --* ]] && echo "Unknown option/flag: $1" && exit 4
            [[ "$1" != --* ]] && echo "Unknown argument: $1" && exit 4
            ;;
    esac
    shift
done

# Bail if our required cli options are missing
[[ -z "$jamfProURL" ]] && echo "Error: Missing Jamf Pro URL (--url); exiting." && exit 1
[[ -z "$apiUser" ]] && echo "Error: Missing API User (--username); exiting." && exit 2
[[ -z "$apiPass" ]] && echo "Error: Missing API Password (--password); exiting." && exit 3

# Get out Jamf Pro API Bearer Token
get_jamf_pro_api_token

# Push any scripts/EAs changed in the last `git commit` to Jamf Pro
if [[ "$pushChangesToJamfPro" == "true" ]]; then

    # Make sure we are running from a git repository
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: Not a git repository."
        echo "Hint: This is designed to upload changes to scripts/EAs that are changed between two git commits."
        exit 1
    fi

    echo "Determining changes between the last two git commits..."

    # Loop through each file changed between the last to commits
    while read -r change; do
 
        # Determine if the change was a script or EA and process accordingly
        if [[ "$change" == scripts/* ]]; then
            process_changed_script "$change"
        elif [[ "$change" == extension_attributes/* ]]; then
            process_changed_ea "$change"
        else
            echo "Ignoring non-tracked changed file: $change"
            continue
        fi

    # Coalesce multiple changes within the same directory so we don't process twice
    done < <(git diff --name-only HEAD HEAD~1 2>/dev/null | grep -E '^(scripts|extension_attributes).*' | rev | sort -u -t '/' -k2 | rev | sort)
    exit 0
fi

# Download scripts if configured to do so with two jobs per core (unless --limit is set)
if [[ "$downloadScripts" == "true" ]]; then

    echo "Getting identifying info for all scripts in Jamf Pro..."

    # Loop through each script ID/Name from a summary obtained from Jamf Pro
    while read -r summary; do
 
        # Limit the parallel jobs to what we've set as the max
        until [[ "$(jobs -lr 2>&1 | wc -l)" -lt "$maxParallelJobs" ]]; do
            sleep 1
        done

        # Extract the id and name of each script
        id=$(echo "$summary" | xmlstarlet sel -T -t -m '/script' -v id)
        name=$(echo "$summary" | xmlstarlet sel -T -t -m '/script' -v name)

        # Download the script in a background thread
        download_script "$id" "$name" "./scripts" &
    done < <(get_script_summaries | xmllint --xpath '/scripts/script' --format -)
    wait
fi

# Download EAs if configured to do so with two jobs per core (unless --limit is set)
if [[ "$downloadEAs" == "true" ]]; then

    echo "Getting identifying info for all computer extension attributes in Jamf Pro..."

    # Loop through each EA ID/Name from a summary obtained from Jamf Pro
    while read -r summary; do
 
        # Limit the parallel jobs to what we've set as the max
        until [[ "$(jobs -lr 2>&1 | wc -l)" -lt "$maxParallelJobs" ]]; do
            sleep 1
        done

        # Extract the id and name of each EA
        id=$(echo "$summary" | xmlstarlet sel -T -t -m '/computer_extension_attribute' -v id)
        name=$(echo "$summary" | xmlstarlet sel -T -t -m '/computer_extension_attribute' -v name)

        # Download the script in a background thread
        download_ea "$id" "$name" "./extension_attributes" &
    done < <(get_ea_summaries | xmllint --xpath '/computer_extension_attributes/computer_extension_attribute' --format -)
    wait
fi

exit 0