

get_mgd_pref() {
    local domain="$1"
    local key="$2"

    osascript -l JavaScript -e "ObjC.import('Foundation'); ObjC.unwrap($.NSUserDefaults.alloc.initWithSuiteName('$domain').objectForKey('$key'))"
}


get_munki_dir() {
    local munki_dir=$( get_mgd_pref ManagedInstalls ManagedInstallDir )
    if [[ -z "$munki_dir" ]]; then
        echo "/Library/Managed Installs"
    else
        echo "$munki_dir"
    fi
}


plistbuddy_write() {
    local plist="$1"
    local key="$2"
    local type="$3"
    local value="$4"

    if [[ "$type" == "string" ]]; then
        value="\"$value\""
    fi
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist"
}


plistbuddy_write_array() {
    local plist="$1"
    local key="$2"
    local item_type="$3"

    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :$key array" "$plist"
    shift 3
    local values=("$@")
    for (( i=0; i < $#; i++ )); do
        if [[ "$item_type" == "string" ]]; then
            value="\"${values[$i]}\""
        else
            value="${values[$i]}"
        fi
        /usr/libexec/PlistBuddy -c "Add :${key}:$i $item_type $value" "$plist"
    done
}


set_fact() {
    # Usage:
    # set_fact KEY (string|integer|real|bool) VALUE
    # set_fact KEY array (string|integer|real|bool) VALUE VALUE ...
    local key="$1"
    local value_or_type="$2"

    #local ci_plist="$( get_munki_dir )/ConditionalItems.plist"
    local script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    local ci_plist="$script_dir/../../ConditionalItems.plist"
    echo "👹 Writing to $( realpath "$ci_plist" )"

    case "$value_or_type" in
    string|integer|real|bool)
        local type="$value_or_type"
        local value="$3"
        plistbuddy_write "$ci_plist" "$key" "$type" "$value"
        ;;
    array)
        local type="array"
        local item_type="$3"
        shift 3
        plistbuddy_write_array "$ci_plist" "$key" "$item_type" "$@"
        ;;
    dict|date|data)
        echo "🛑 $value_or_type is unsupported"
        ;;
    *)
        local type="string"
        local value="$value_or_type"
        if [[ -n "$3" ]]; then
            echo "⚠️ Superfluous string argument"
        fi
        plistbuddy_write "$ci_plist" "$key" "$type" "$value"
        ;;
    esac
}


is_virtual() {
    if [[ $( macos_major ) -ge 11 ]]; then
        if [[ $( sysctl -n kern.hv_vmm_present ) -eq 0 ]]; then
            return 1
        else
            return 0
        fi
    else
        if sysctl -n machdep.cpu.features | grep -q '\bVMM\b'; then
            return 1
        else
            return 0
        fi
    fi
}


ioreg_platform() {
    ioreg -rd1 -c IOPlatformExpertDevice | grep "\"$1\"" | cut -d\" -f4
}


mac_model() {
    ioreg_platform "model"
}


board_id() {
    ioreg_platform "board-id"
}


hw_target() {
    sysctl -n hw.target
}


macos_major() {
    sw_vers -productVersion | cut -d. -f1
}

