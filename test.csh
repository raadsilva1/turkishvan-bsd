#!/bin/csh -f
#
# turkishvan-bsd-bootstrap-core.csh
# minimal pure-csh bootstrap and preflight validator for DragonFlyBSD
# this script is intentionally limited to phase 0 and phase 1 only
# it does not install packages or modify system configuration
#

umask 022
set path = ( /usr/local/sbin /usr/local/bin /sbin /bin /usr/sbin /usr/bin )

/bin/echo "turkishvan-bsd bootstrap core: starting"

set SCRIPT_NAME = "turkishvan-bsd-bootstrap-core"
set VERSION = "0.1"
set EXIT_CODE = 0

set EXIT_CODE_SUCCESS = 0
set EXIT_CODE_USAGE = 20
set EXIT_CODE_PLATFORM = 30
set EXIT_CODE_VALIDATE = 60
set EXIT_CODE_LOCK = 70
set EXIT_CODE_INTERNAL = 90

set TARGET_USER = ""
set TARGET_HOME = ""
set KEYBOARD_LAYOUT = ""
set RESUME = 1
set FORCE = 0
set VERBOSE = 0

set HOSTNAME_SHORT = `hostname -s 2>/dev/null`
if ( "$HOSTNAME_SHORT" == "" ) set HOSTNAME_SHORT = `hostname 2>/dev/null`
if ( "$HOSTNAME_SHORT" == "" ) set HOSTNAME_SHORT = "unknown-host"

set RUN_TS = `date -u "+%Y%m%dT%H%M%SZ"`
set RUN_ID = "${RUN_TS}.$$"

set LOG_DIR = "/var/log/turkishvan-bsd"
set STATE_DIR = "/var/db/turkishvan-bsd"
set BACKUP_DIR = "/var/backups/turkishvan-bsd"

set LOCK_FILE = "${STATE_DIR}/run.lock"
set CHECKPOINT_FILE = "${STATE_DIR}/checkpoint.state"
set LAST_RUN_FILE = "${STATE_DIR}/last-run.state"
set LOG_FILE = "${LOG_DIR}/${RUN_ID}.log"

while ( $#argv > 0 )
    switch ( "$1" )
        case "--username":
            if ( $#argv < 2 ) then
                /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose]"
                exit ${EXIT_CODE_USAGE}
            endif
            set TARGET_USER = "$2"
            shift
            shift
            breaksw

        case "--keyboard":
            if ( $#argv < 2 ) then
                /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose]"
                exit ${EXIT_CODE_USAGE}
            endif
            set KEYBOARD_LAYOUT = "$2"
            shift
            shift
            breaksw

        case "--resume":
            set RESUME = 1
            shift
            breaksw

        case "--force":
            set FORCE = 1
            set RESUME = 0
            shift
            breaksw

        case "--verbose":
            set VERBOSE = 1
            shift
            breaksw

        default:
            /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose]"
            exit ${EXIT_CODE_USAGE}
    endsw
end

if ( "$TARGET_USER" == "" || "$KEYBOARD_LAYOUT" == "" ) then
    /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose]"
    exit ${EXIT_CODE_USAGE}
endif

/bin/echo "turkishvan-bsd bootstrap core: phase0 create directories"
/bin/mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
if ( $status != 0 ) then
    /bin/echo "fatal: unable to create state directories"
    exit ${EXIT_CODE_INTERNAL}
endif

/usr/bin/touch "${CHECKPOINT_FILE}"
if ( $status != 0 ) then
    /bin/echo "fatal: unable to create checkpoint file ${CHECKPOINT_FILE}"
    exit ${EXIT_CODE_INTERNAL}
endif

set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} INFO phase0 start initializing logging and lock" | tee -a "${LOG_FILE}"

if ( -e "${LOCK_FILE}" ) then
    set LOCK_PID = `awk -F= '/^pid=/{print $2}' "${LOCK_FILE}" 2>/dev/null`
    set LOCK_HOST = `awk -F= '/^hostname=/{print $2}' "${LOCK_FILE}" 2>/dev/null`
    if ( "$LOCK_PID" != "" && "$LOCK_HOST" == "${HOSTNAME_SHORT}" ) then
        kill -0 "${LOCK_PID}" >& /dev/null
        if ( $status == 0 ) then
            set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
            /bin/echo "${_ts} ERROR phase0 lock active lock held by pid ${LOCK_PID} on ${LOCK_HOST}" | tee -a "${LOG_FILE}"
            set EXIT_CODE = ${EXIT_CODE_LOCK}
            goto CLEAN_EXIT
        endif
    endif
    /bin/rm -f "${LOCK_FILE}.stale"
    /bin/mv -f "${LOCK_FILE}" "${LOCK_FILE}.stale" >& /dev/null
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} WARN phase0 lock stale lock detected and rotated" | tee -a "${LOG_FILE}"
endif

/bin/echo "pid=$$" >! "${LOCK_FILE}"
/bin/echo "hostname=${HOSTNAME_SHORT}" >> "${LOCK_FILE}"
/bin/echo "timestamp=${RUN_TS}" >> "${LOCK_FILE}"
/bin/echo "run_id=${RUN_ID}" >> "${LOCK_FILE}"
if ( $status != 0 ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase0 lock failed to write lock file ${LOCK_FILE}" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_LOCK}
    goto CLEAN_EXIT
endif

set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase0 lock lock acquired" | tee -a "${LOG_FILE}"
/bin/echo "${_ts} INFO phase0 args username=${TARGET_USER} keyboard=${KEYBOARD_LAYOUT} resume=${RESUME} force=${FORCE}" | tee -a "${LOG_FILE}"

grep -qx "phase0" "${CHECKPOINT_FILE}" >/dev/null 2>&1
if ( $status != 0 ) /bin/echo "phase0" >> "${CHECKPOINT_FILE}"

set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} INFO phase1 start running platform and input validation" | tee -a "${LOG_FILE}"

set OS_NAME = `uname -s 2>/dev/null`
if ( "$OS_NAME" != "DragonFly" ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 detect-os uname -s returned ${OS_NAME}; DragonFly required" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif
set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 detect-os DragonFlyBSD confirmed" | tee -a "${LOG_FILE}"

set EXEC_SHELL = `ps -p $$ -o comm= 2>/dev/null | awk '{print $1}' | sed 's#^.*/##'`
if ( "$EXEC_SHELL" == "" ) set EXEC_SHELL = "unknown"
if ( "$EXEC_SHELL" != "csh" ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 detect-shell executing shell is ${EXEC_SHELL}; csh required" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif
set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 detect-shell csh confirmed" | tee -a "${LOG_FILE}"

set CURRENT_UID = `id -u 2>/dev/null`
if ( "$CURRENT_UID" != "0" ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 detect-root root privileges required" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif
set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 detect-root root privileges confirmed" | tee -a "${LOG_FILE}"

id "${TARGET_USER}" >/dev/null 2>&1
if ( $status != 0 ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 validate-user user ${TARGET_USER} does not exist" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif

if ( "${TARGET_USER}" == "root" ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 validate-user target user must not be root" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif

set TARGET_HOME = `awk -F: -v u="${TARGET_USER}" '$1==u{print $6}' /etc/passwd`
if ( "$TARGET_HOME" == "" ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 validate-user failed to resolve home directory for ${TARGET_USER}" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif

if ( ! -d "${TARGET_HOME}" ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 validate-user home directory ${TARGET_HOME} does not exist" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif

set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 validate-user user ${TARGET_USER} with home ${TARGET_HOME} confirmed" | tee -a "${LOG_FILE}"

set PKG_BIN = ""
foreach PKG_CANDIDATE ( /usr/local/sbin/pkg /usr/sbin/pkg /usr/bin/pkg )
    if ( -x "${PKG_CANDIDATE}" ) set PKG_BIN = "${PKG_CANDIDATE}"
end
if ( "$PKG_BIN" == "" ) then
    rehash
    set PKG_BIN = `which pkg 2>/dev/null`
endif
if ( "$PKG_BIN" == "" ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 validate-pkg pkg command not found" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_PLATFORM}
    goto CLEAN_EXIT
endif
set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 validate-pkg pkg command available at ${PKG_BIN}" | tee -a "${LOG_FILE}"

foreach CMD ( awk sed grep cp mv cmp mkdir mktemp find date hostname uname id sysctl kldstat pciconf pw )
    which "${CMD}" >/dev/null 2>&1
    if ( $status != 0 ) then
        set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
        /bin/echo "${_ts} ERROR phase1 validate-cmd required command ${CMD} is missing" | tee -a "${LOG_FILE}"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif
end
set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 validate-cmd essential command set available" | tee -a "${LOG_FILE}"

if ( "${KEYBOARD_LAYOUT}" !~ [A-Za-z0-9_-]* ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 validate-keyboard keyboard layout ${KEYBOARD_LAYOUT} contains invalid characters" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif

set XKB_RULES_FILE = ""
foreach RULEFILE ( /usr/local/share/X11/xkb/rules/base.lst /usr/local/share/X11/xkb/rules/evdev.lst )
    if ( -r "${RULEFILE}" ) set XKB_RULES_FILE = "${RULEFILE}"
end

set KEYBOARD_VALID = 0
if ( "${XKB_RULES_FILE}" != "" ) then
    awk -v want="${KEYBOARD_LAYOUT}" '
        BEGIN { in_layout = 0; ok = 0 }
        /^! layout/ { in_layout = 1; next }
        /^!/ { if (in_layout) exit }
        in_layout && $1 == want { ok = 1; exit }
        END { exit(ok ? 0 : 1) }
    ' "${XKB_RULES_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set KEYBOARD_VALID = 1
else
    foreach BUILTIN_LAYOUT ( us uk br de fr es it se no dk fi jp ru ua pl tr pt nl be ch hu cz sk si hr rs bg ro ee lv lt is ie )
        if ( "${KEYBOARD_LAYOUT}" == "${BUILTIN_LAYOUT}" ) set KEYBOARD_VALID = 1
    end
endif

if ( ${KEYBOARD_VALID} == 0 ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR phase1 validate-keyboard keyboard layout ${KEYBOARD_LAYOUT} is not valid" | tee -a "${LOG_FILE}"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif
set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 validate-keyboard keyboard layout ${KEYBOARD_LAYOUT} accepted" | tee -a "${LOG_FILE}"

grep -qx "phase1" "${CHECKPOINT_FILE}" >/dev/null 2>&1
if ( $status != 0 ) /bin/echo "phase1" >> "${CHECKPOINT_FILE}"

set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
/bin/echo "${_ts} OK phase1 end bootstrap core completed successfully" | tee -a "${LOG_FILE}"

goto CLEAN_EXIT

CLEAN_EXIT:
if ( ! -d "${STATE_DIR}" ) /bin/mkdir -p "${STATE_DIR}"
/bin/echo "run_id=${RUN_ID}" >! "${LAST_RUN_FILE}"
/bin/echo "timestamp=${RUN_TS}" >> "${LAST_RUN_FILE}"
/bin/echo "hostname=${HOSTNAME_SHORT}" >> "${LAST_RUN_FILE}"
/bin/echo "username=${TARGET_USER}" >> "${LAST_RUN_FILE}"
/bin/echo "keyboard=${KEYBOARD_LAYOUT}" >> "${LAST_RUN_FILE}"
/bin/echo "exit_code=${EXIT_CODE}" >> "${LAST_RUN_FILE}"
/bin/echo "log_file=${LOG_FILE}" >> "${LAST_RUN_FILE}"

if ( -e "${LOCK_FILE}" ) /bin/rm -f "${LOCK_FILE}"

if ( ${EXIT_CODE} == 0 ) then
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} OK final exit success" | tee -a "${LOG_FILE}"
else
    set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`
    /bin/echo "${_ts} ERROR final exit failed with exit code ${EXIT_CODE}" | tee -a "${LOG_FILE}"
endif

exit ${EXIT_CODE}
