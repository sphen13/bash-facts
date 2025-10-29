# shellcheck shell=bash
# Munki custom-conditions utilities (PlistBuddy-based, Bash 3.2 safe)
# - Atomic writes to ConditionalItems.plist under a lock
# - No extraneous plist keys (only what you set via set_fact)
# - Traps swallow nonzero exits to avoid ProcessError, but log errors

# One-time init
[[ -n "${BFACTS_INIT:-}" ]] && return 0
BFACTS_INIT=1

# Tunables (env-overridable)
: "${BFACTS_TIMEOUT_DEFAULT:=5}"
: "${BFACTS_DISABLE_TRAPS:=0}"
: "${BFACTS_RECORD_ERRORS_IN_LOG:=1}"
: "${BFACTS_SYSLOG:=1}"
: "${BFACTS_SYSLOG_TAG:=bash-facts}"
: "${BFACTS_AUDIT:=1}"

# Identity (used for logging)
_bfacts_script_name="${BFACTS_SCRIPT_NAME_OVERRIDE:-$(basename "${BASH_SOURCE[1]:-${0}}")}"
_bfacts_script_base="${_bfacts_script_name%.*}"

# Preferences and paths
get_mgd_pref() { # domain key -> value
  local domain="$1" key="$2" v
  v=$(/usr/bin/defaults read "/Library/Preferences/${domain}" "$key" 2>/dev/null) || true
  if [[ -n "$v" ]]; then printf '%s' "$v"; else
    /usr/bin/osascript -l JavaScript -e \
      "ObjC.import('Foundation'); ObjC.unwrap($.NSUserDefaults.alloc.initWithSuiteName('$domain').objectForKey('$key'))"
  fi
}

get_munki_dir() {
  local v; v="$(get_mgd_pref ManagedInstalls ManagedInstallDir)"
  [[ -n "$v" ]] && printf '%s\n' "$v" || printf '/Library/Managed Installs\n'
}

readonly _BFACTS_DIR="$(get_munki_dir)"
readonly _BFACTS_PLIST="${_BFACTS_DIR}/ConditionalItems.plist"
readonly _BFACTS_LOG_DIR="${_BFACTS_DIR}/Logs/conditions"
readonly _BFACTS_LOCKDIR="${_BFACTS_DIR}/.ConditionalItems.lock.d"
readonly _PLISTBUDDY="/usr/libexec/PlistBuddy"
readonly _BFACTS_COND_LOG="${_BFACTS_LOG_DIR}/_conditions.log"
/bin/mkdir -p "$_BFACTS_LOG_DIR" 2>/dev/null || true

# Logging
_bfacts_ts()   { /bin/date -u +'%Y-%m-%dT%H:%M:%SZ'; }
_bfacts_warn() { printf '[%s] WARN: %s\n' "$(_bfacts_ts)" "$*" >&2; }
_bfacts_audit() {  # _bfacts_audit EVENT STATUS ELAPSED_SECS
  [[ "$BFACTS_AUDIT" != "1" ]] && return 0
  local event="$1" status="${2:-}" elapsed="${3:-}" ts="$(_bfacts_ts)"
  # fields: ts  event  script  pid  elapsed  status
  /usr/bin/lockf -k "${_BFACTS_COND_LOG}.lock" /bin/sh -c \
    "/usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\n' '$ts' '$event' '$_bfacts_script_base' '$$' '${elapsed}' '${status}' >> '$_BFACTS_COND_LOG'"
}

# stopwatch + START line now (on source)
_BFACTS_START_TS="$(/bin/date +%s)"
_bfacts_elapsed() { echo $(( $(/bin/date +%s) - _BFACTS_START_TS )); }
_bfacts_audit START "" 0

if [[ "$BFACTS_DISABLE_TRAPS" != "1" ]]; then
  # flags for EXIT summary
  _BFACTS_ALREADY_LOGGED=0
  _BFACTS_HAD_ERR=0

  # optional: self-watchdog; if set, TERM yourself a bit before the parent might
  # (set in env or LaunchDaemon: e.g., BFACTS_MAX_RUNTIME_SECS=170)
  if [[ -n "${BFACTS_MAX_RUNTIME_SECS:-}" && "$BFACTS_MAX_RUNTIME_SECS" =~ ^[0-9]+$ ]]; then
    ( /bin/sleep "$BFACTS_MAX_RUNTIME_SECS"; /bin/kill -TERM $$ ) >/dev/null 2>&1 &
    disown || true
  fi

  # polite signal handlers: log + END + exit 0 so Munki sees a clean exit
  _bfacts_on_term() {
    local e="$(_bfacts_elapsed)"
    record_condition_error "received SIGTERM after ${e}s"
    _bfacts_audit END TERM "$e"
    _BFACTS_ALREADY_LOGGED=1
    exit 0
  }
  _bfacts_on_hup()  {
    local e="$(_bfacts_elapsed)"
    record_condition_error "received SIGHUP after ${e}s"
    _bfacts_audit END HUP "$e"
    _BFACTS_ALREADY_LOGGED=1
    exit 0
  }
  _bfacts_on_int()  {
    local e="$(_bfacts_elapsed)"
    record_condition_error "received SIGINT after ${e}s"
    _bfacts_audit END INT "$e"
    _BFACTS_ALREADY_LOGGED=1
    exit 0
  }

  trap '_bfacts_on_term' TERM
  trap '_bfacts_on_hup'  HUP
  trap '_bfacts_on_int'  INT

  # note that a command failed; EXIT will summarize and force 0
  trap 'ec=$?; _BFACTS_HAD_ERR=1; record_condition_error "exit ${ec} (ERR trap)"; true' ERR

  # single END line with duration + reason (ok|err) unless a signal already logged END
  trap '
    ec=$?
    if (( _BFACTS_ALREADY_LOGGED == 0 )); then
      reason=ok
      (( ec != 0 || _BFACTS_HAD_ERR == 1 )) && reason=err
      _bfacts_audit END "$reason" "$(_bfacts_elapsed)"
    fi
    exit 0
  ' EXIT
fi

# Timeouts (portable)
with_timeout() { local t="$1"; shift; /usr/bin/perl -e '$SIG{ALRM}=sub{exit 124}; alarm shift @ARGV; exec @ARGV;' "$t" "$@"; }
safe_run()     { local s="$BFACTS_TIMEOUT_DEFAULT"; [[ "$1" =~ ^[0-9]+$ ]] && { s="$1"; shift; }; with_timeout "$s" "$@" || record_condition_error "timeout/failure: $*"; }

# Locking
_bfacts_with_lock() {
  local waited=0
  while ! /bin/mkdir "$_BFACTS_LOCKDIR" 2>/dev/null; do
    /bin/sleep 0.05; (( waited++ > 200 )) && { _bfacts_warn "lock wait >10s; continuing"; break; }
  done
  trap '/bin/rmdir "'"$_BFACTS_LOCKDIR"'" 2>/dev/null || true' RETURN
  "$@"
}

# Plist helpers
_bfacts_make_empty_plist() {
  /bin/cat >"$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
EOF
}

_bfacts_pb_quote() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
_bfacts_pb()       { "$_PLISTBUDDY" -c "$1" "$2" >/dev/null 2>&1; }

_bfacts_normalize_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|y|yes|true)  printf true;;
    0|n|no|false|'') printf false;;
    *)              printf false;;
  esac
}

# Apply mutation(s) to a temp copy, then atomic mv into place
_bfacts_edit_plist() {
  local file="$_BFACTS_PLIST" dir tmp fn
  dir="$(/usr/bin/dirname "$file")"
  tmp="$(/usr/bin/mktemp -q "$dir/.ConditionalItems.tmp.XXXXXX")" || return 0
  if [[ -f "$file" ]]; then /bin/cp -p "$file" "$tmp" 2>/dev/null || _bfacts_make_empty_plist "$tmp"
  else _bfacts_make_empty_plist "$tmp"; fi
  fn="$1"; shift; "$fn" "$tmp" "$@" || true
  _bfacts_with_lock /bin/mv -f "$tmp" "$file"
}

# Typed writes
_bfacts_pb_set_or_add() { # file key type value
  local file="$1" key="$2" type="$3" raw="$4"
  case "$type" in
    string)  local q; q="$(_bfacts_pb_quote "$raw")"; _bfacts_pb "Set :$key $q" "$file" || { _bfacts_pb "Delete :$key" "$file" || true; _bfacts_pb "Add :$key string $q" "$file"; } ;;
    integer) _bfacts_pb "Set :$key $raw" "$file"    || { _bfacts_pb "Delete :$key" "$file" || true; _bfacts_pb "Add :$key integer $raw" "$file"; } ;;
    real)    _bfacts_pb "Set :$key $raw" "$file"    || { _bfacts_pb "Delete :$key" "$file" || true; _bfacts_pb "Add :$key real $raw" "$file"; } ;;
    bool)    local b; b="$(_bfacts_normalize_bool "$raw")"; _bfacts_pb "Set :$key $b" "$file" || { _bfacts_pb "Delete :$key" "$file" || true; _bfacts_pb "Add :$key bool $b" "$file"; } ;;
    *)       _bfacts_warn "unknown type '$type' for key '$key'";;
  esac
}

_bfacts_pb_set_array() {  # file key item_type [values...]
  local file="$1" key="$2" item_type="$3"; shift 3
  _bfacts_pb "Delete :$key" "$file" || true
  _bfacts_pb "Add :$key array" "$file"
  local i=0 v
  for v in "$@"; do
    case "$item_type" in
      string)  _bfacts_pb "Add :$key:$i string $(_bfacts_pb_quote "$v")" "$file" ;;
      integer|real) _bfacts_pb "Add :$key:$i $item_type $v" "$file" ;;
      bool)    _bfacts_pb "Add :$key:$i bool $(_bfacts_normalize_bool "$v")" "$file" ;;
      *)       _bfacts_warn "array item_type '$item_type' unsupported; storing as string"; _bfacts_pb "Add :$key:$i string $(_bfacts_pb_quote "$v")" "$file" ;;
    esac; i=$((i+1))
  done
}

_bfacts_set() { # key type value... | array item_type vals...
  local key="$1" type="$2"
  case "$type" in
    string|integer|real|bool)
      _bfacts_edit_plist _bfacts_pb_set_or_add "$key" "$type" "$3"
      ;;
    array)
      local item_type="${3:-string}"; shift 3
      _bfacts_edit_plist _bfacts_pb_set_array "$key" "$item_type" "$@"
      ;;
    *) _bfacts_warn "unknown type '$type' for key '$key'";;
  esac
}

# Back-compat shims (first arg plist path ignored, we always target ConditionalItems.plist)
plistbuddy_write()       { local _plist="$1" key="$2" type="$3" value="$4"; _bfacts_set "$key" "$type" "$value"; }
plistbuddy_write_array() { local _plist="$1" key="$2" item_type="$3"; shift 3; _bfacts_set "$key" array "$item_type" "$@"; }

# Public API
set_fact() {
  local key="$1" v="${2-}"
  case "$v" in
    string|integer|real|bool) _bfacts_set "$key" "$v" "$3" ;;
    array) local t="$3"; shift 3; _bfacts_set "$key" array "$t" "$@" ;;
    dict|date|data) _bfacts_warn "$v is unsupported" ;;
    *) _bfacts_set "$key" string "$v" ;;
  esac
}

# System helpers
ioreg_platform()  { /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/grep "\"$1\"" | /usr/bin/cut -d\" -f4; }
mac_model()       { ioreg_platform "model"; }
board_id()        { ioreg_platform "board-id"; }
hw_target()       { /usr/sbin/sysctl -n hw.target; }
macos_major()     { /usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1; }
is_virtual() {
  if [[ $(macos_major) -ge 11 ]]; then
    [[ $(/usr/sbin/sysctl -n kern.hv_vmm_present) -eq 0 ]] && return 1 || return 0
  else
    /usr/sbin/sysctl -n machdep.cpu.features | /usr/bin/grep -q '\bVMM\b' && return 1 || return 0
  fi
}

# Error recording (no plist writes)
record_condition_error() {
  local msg="${1:-unknown error}"
  [[ "$BFACTS_RECORD_ERRORS_IN_LOG" == "1" ]] && printf '%s %s\n' "$(_bfacts_ts)" "$msg" >> "${_BFACTS_LOG_DIR}/${_bfacts_script_base}.log" 2>/dev/null || true
  [[ "$BFACTS_SYSLOG" == "1" ]] && /usr/bin/logger -t "$BFACTS_SYSLOG_TAG[$_bfacts_script_base]" -- "$msg" 2>/dev/null || true
}
