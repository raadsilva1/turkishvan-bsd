#!/bin/csh -f
# csh-only provisioning and convergence for DragonFlyBSD desktop use

umask 022
set path = ( /usr/local/sbin /usr/local/bin /sbin /bin /usr/sbin /usr/bin )

onintr HANDLE_INTERRUPT

set SCRIPT_NAME = "turkishvan-bsd"
set PROJECT_NAME = "turkishvan-bsd"
set STATUS_TEXT = "draft-v1"
set VERSION = "1.0"
set MANAGED_BEGIN = "# BEGIN turkishvan-bsd managed block"
set MANAGED_END   = "# END turkishvan-bsd managed block"

set EXIT_CODE_SUCCESS = 0
set EXIT_CODE_REBOOT  = 10
set EXIT_CODE_USAGE   = 20
set EXIT_CODE_PLATFORM = 30
set EXIT_CODE_PACKAGE = 40
set EXIT_CODE_CONFIG  = 50
set EXIT_CODE_VALIDATE = 60
set EXIT_CODE_LOCK    = 70
set EXIT_CODE_ROLLBACK = 80
set EXIT_CODE_INTERNAL = 90

set EXIT_CODE = 0
set NEED_REBOOT = 0
set NEED_RELOGIN = 0
set ROLLBACK_OCCURRED = 0
set TTYS_CHANGED = 0
set XDM_ACTIVATION_MODE = "SUCCESS_PENDING_REBOOT"
set SELECTED_AUDIO_UNIT = ""
set AUDIO_PLAN_CLASS = "no-detected-audio"
set AUDIO_PLAN_REASON = ""
set AUDIO_COUNT = 0
set GPU_PLAN = "unknown-generic"
set BACKLIGHT_MANAGEABLE = 0
set VERBOSE = 0
set RESUME = 1
set FORCE = 0
set ACTIVATE_NOW = 0
set SKIP_UPGRADE = 0
set TARGET_USER = ""
set TARGET_HOME = ""
set TARGET_GROUP = ""
set KEYBOARD_LAYOUT = ""
set HOSTNAME_SHORT = `hostname -s 2>/dev/null`
if ( "$HOSTNAME_SHORT" == "" ) set HOSTNAME_SHORT = `hostname 2>/dev/null`
if ( "$HOSTNAME_SHORT" == "" ) set HOSTNAME_SHORT = "unknown-host"
set RUN_TS = `date -u "+%Y%m%dT%H%M%SZ"`
set RUN_ID = "${RUN_TS}.$$"
set STATE_DIR = "/var/db/turkishvan-bsd"
set LOG_DIR = "/var/log/turkishvan-bsd"
set BACKUP_DIR = "/var/backups/turkishvan-bsd"
set LOCK_FILE = "${STATE_DIR}/run.lock"
set CHECKPOINT_FILE = "${STATE_DIR}/checkpoint.state"
set LAST_RUN_FILE = "${STATE_DIR}/last-run.state"
set HARDWARE_SNAPSHOT = "${STATE_DIR}/hardware.snapshot"
set PACKAGE_SNAPSHOT = "${STATE_DIR}/package.snapshot"
set CHANGE_MANIFEST = "${STATE_DIR}/change.manifest"
set ROLLBACK_MANIFEST = "${STATE_DIR}/rollback.manifest"
set LOG_FILE = "${LOG_DIR}/${RUN_ID}.log"
set MERGE_AWK = "${STATE_DIR}/merge-managed-block.awk"
set CHOSEN_PACKAGES_FILE = "${STATE_DIR}/chosen-packages.state"
set PLAN_FILE = "${STATE_DIR}/hardware.plan"
set PKG_BIN = ""
set XDM_BIN = ""
set XORG_BIN = ""
set GNUSTEP_ENV = ""
set XKB_RULES_FILE = ""

alias log_msg 'set _ts = `date -u "+%Y-%m-%dT%H:%M:%SZ"`; /bin/echo "${_ts} \!:1 \!:2 \!:3 \!:4"; /bin/echo "${_ts} \!:1 \!:2 \!:3 \!:4" >>! "${LOG_FILE}"'
alias mark_checkpoint '/usr/bin/touch "${CHECKPOINT_FILE}"; grep -qx "\!:1" "${CHECKPOINT_FILE}" >/dev/null 2>&1; if ( $status != 0 ) /bin/echo "\!:1" >>! "${CHECKPOINT_FILE}"'

#
# argument parsing
#

while ( $#argv > 0 )
    switch ( "$1" )
        case "--username":
            if ( $#argv < 2 ) then
                /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--activate-now] [--skip-upgrade] [--verbose]"
                exit ${EXIT_CODE_USAGE}
            endif
            set TARGET_USER = "$2"
            shift
            shift
            breaksw

        case "--keyboard":
            if ( $#argv < 2 ) then
                /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--activate-now] [--skip-upgrade] [--verbose]"
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

        case "--activate-now":
            set ACTIVATE_NOW = 1
            shift
            breaksw

        case "--skip-upgrade":
            set SKIP_UPGRADE = 1
            shift
            breaksw

        case "--verbose":
            set VERBOSE = 1
            shift
            breaksw

        default:
            /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--activate-now] [--skip-upgrade] [--verbose]"
            exit ${EXIT_CODE_USAGE}
    endsw
end

if ( "$TARGET_USER" == "" || "$KEYBOARD_LAYOUT" == "" ) then
    /bin/echo "usage: $0 --username <name> --keyboard <kbd-layout> [--resume] [--force] [--activate-now] [--skip-upgrade] [--verbose]"
    exit ${EXIT_CODE_USAGE}
endif

#
# phase 0: bootstrap logging and lock
#

/bin/mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
if ( $status != 0 ) then
    /bin/echo "fatal: unable to create state directories"
    exit ${EXIT_CODE_INTERNAL}
endif

if ( ! -e "${CHECKPOINT_FILE}" ) /usr/bin/touch "${CHECKPOINT_FILE}"
if ( ! -e "${CHANGE_MANIFEST}" ) /usr/bin/touch "${CHANGE_MANIFEST}"
if ( ! -e "${ROLLBACK_MANIFEST}" ) /usr/bin/touch "${ROLLBACK_MANIFEST}"

cat >! "${MERGE_AWK}" <<'AWK_EOF'
BEGIN {
    begin = ENVIRON["TVB_BEGIN"]
    end = ENVIRON["TVB_END"]
    content = ENVIRON["TVB_CONTENT_FILE"]
    inblock = 0
    emitted = 0
}
{
    if ($0 == begin) {
        if (!emitted) {
            while ((getline line < content) > 0) print line
            close(content)
            emitted = 1
        }
        inblock = 1
        next
    }
    if ($0 == end) {
        inblock = 0
        next
    }
    if (!inblock) print
}
END {
    if (!emitted) {
        while ((getline line < content) > 0) print line
        close(content)
    }
}
AWK_EOF

if ( $status != 0 ) then
    /bin/echo "fatal: unable to initialize merge helper"
    exit ${EXIT_CODE_INTERNAL}
endif

log_msg INFO phase0 start "initializing logging, state directories, and lock"

if ( -e "${LOCK_FILE}" ) then
    set LOCK_PID = `awk -F= '/^pid=/{print $2}' "${LOCK_FILE}" 2>/dev/null`
    set LOCK_HOST = `awk -F= '/^hostname=/{print $2}' "${LOCK_FILE}" 2>/dev/null`
    if ( "$LOCK_PID" != "" && "$LOCK_HOST" == "${HOSTNAME_SHORT}" ) then
        kill -0 "${LOCK_PID}" >& /dev/null
        if ( $status == 0 ) then
            log_msg ERROR phase0 lock "active lock held by pid ${LOCK_PID} on ${LOCK_HOST}"
            set EXIT_CODE = ${EXIT_CODE_LOCK}
            goto CLEAN_EXIT
        endif
    endif
    /bin/mv -f "${LOCK_FILE}" "${LOCK_FILE}.stale.${RUN_ID}" >& /dev/null
    log_msg WARN phase0 lock "stale lock detected and rotated"
endif

set LOCK_TMP = `mktemp "${STATE_DIR}/run.lock.XXXXXX"`
cat >! "${LOCK_TMP}" <<EOF
pid=$$
hostname=${HOSTNAME_SHORT}
timestamp=${RUN_TS}
run_id=${RUN_ID}
script=${SCRIPT_NAME}
EOF
/bin/mv -f "${LOCK_TMP}" "${LOCK_FILE}"
if ( $status != 0 ) then
    log_msg ERROR phase0 lock "failed to acquire lock file ${LOCK_FILE}"
    set EXIT_CODE = ${EXIT_CODE_LOCK}
    goto CLEAN_EXIT
endif

log_msg OK phase0 lock "lock acquired"
log_msg INFO phase0 args "username=${TARGET_USER} keyboard=${KEYBOARD_LAYOUT} resume=${RESUME} force=${FORCE} activate_now=${ACTIVATE_NOW} skip_upgrade=${SKIP_UPGRADE}"

#
# phase 1: preflight validation
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase1" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase1 resume "checkpoint already completed"
else
    log_msg INFO phase1 start "running platform and input validation"

    set OS_NAME = `uname -s 2>/dev/null`
    if ( "$OS_NAME" != "DragonFly" ) then
        log_msg ERROR phase1 detect-os "uname -s returned ${OS_NAME}; DragonFly required"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif
    log_msg OK phase1 detect-os "DragonFlyBSD confirmed"

    set EXEC_SHELL = `ps -p $$ -o comm= 2>/dev/null | awk '{print $1}' | sed 's#^.*/##'`
    if ( "$EXEC_SHELL" == "" ) set EXEC_SHELL = "unknown"
    if ( "$EXEC_SHELL" != "csh" ) then
        log_msg ERROR phase1 detect-shell "executing shell is ${EXEC_SHELL}; csh required"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif
    log_msg OK phase1 detect-shell "csh confirmed"

    set CURRENT_UID = `id -u 2>/dev/null`
    if ( "$CURRENT_UID" != "0" ) then
        log_msg ERROR phase1 detect-root "root privileges required"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif
    log_msg OK phase1 detect-root "root privileges confirmed"

    id "${TARGET_USER}" >/dev/null 2>&1
    if ( $status != 0 ) then
        log_msg ERROR phase1 validate-user "user ${TARGET_USER} does not exist"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif

    if ( "${TARGET_USER}" == "root" ) then
        log_msg ERROR phase1 validate-user "target user must not be root"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif

    set TARGET_HOME = `awk -F: -v u="${TARGET_USER}" '$1==u{print $6}' /etc/passwd`
    if ( "$TARGET_HOME" == "" ) then
        log_msg ERROR phase1 validate-user "failed to resolve home directory for ${TARGET_USER}"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif
    if ( ! -d "${TARGET_HOME}" ) then
        log_msg ERROR phase1 validate-user "home directory ${TARGET_HOME} does not exist"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif
    set TARGET_GROUP = `id -gn "${TARGET_USER}" 2>/dev/null`
    if ( "$TARGET_GROUP" == "" ) set TARGET_GROUP = "${TARGET_USER}"
    log_msg OK phase1 validate-user "user ${TARGET_USER} with home ${TARGET_HOME} confirmed"

    foreach PKG_CANDIDATE ( /usr/local/sbin/pkg /usr/sbin/pkg /usr/bin/pkg )
        if ( -x "${PKG_CANDIDATE}" ) set PKG_BIN = "${PKG_CANDIDATE}"
    end
    if ( "$PKG_BIN" == "" ) then
        rehash
        set PKG_BIN = `which pkg 2>/dev/null`
    endif
    if ( "$PKG_BIN" == "" ) then
        log_msg ERROR phase1 validate-pkg "pkg command not found and not bootstrap-capable"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
        goto CLEAN_EXIT
    endif
    log_msg OK phase1 validate-pkg "pkg command available at ${PKG_BIN}"

    foreach CMD ( awk sed grep cp mv cmp mkdir mktemp find date hostname uname id sysctl kldstat pciconf pw )
        which "${CMD}" >/dev/null 2>&1
        if ( $status != 0 ) then
            log_msg ERROR phase1 validate-cmd "required command ${CMD} is missing"
            set EXIT_CODE = ${EXIT_CODE_PLATFORM}
            goto CLEAN_EXIT
        endif
    end
    log_msg OK phase1 validate-cmd "essential command set available"

    if ( "${KEYBOARD_LAYOUT}" !~ [A-Za-z0-9_-]* ) then
        log_msg ERROR phase1 validate-keyboard "keyboard layout ${KEYBOARD_LAYOUT} contains invalid characters"
        set EXIT_CODE = ${EXIT_CODE_PLATFORM}
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
        if ( ${KEYBOARD_VALID} == 1 ) then
            log_msg WARN phase1 validate-keyboard "xkb rules file not yet present; accepted ${KEYBOARD_LAYOUT} via conservative fallback list"
        endif
    endif

    if ( ${KEYBOARD_VALID} == 0 ) then
        log_msg ERROR phase1 validate-keyboard "keyboard layout ${KEYBOARD_LAYOUT} is not valid"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase1 validate-keyboard "keyboard layout ${KEYBOARD_LAYOUT} accepted"

    mark_checkpoint phase1
    log_msg OK phase1 end "preflight validation completed"
endif

#
# phase 2: discovery snapshot
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase2" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase2 resume "checkpoint already completed"
else
    log_msg INFO phase2 start "collecting discovery snapshots"

    cat >! "${HARDWARE_SNAPSHOT}" <<EOF
run_id=${RUN_ID}
hostname=${HOSTNAME_SHORT}
timestamp=${RUN_TS}

[uname]
`uname -a 2>/dev/null`

[pkg_status]
`"${PKG_BIN}" -N 2>&1`

[pciconf]
`pciconf -lv 2>&1`

[kldstat]
`kldstat 2>&1`

[sndstat]
EOF
    if ( -r /dev/sndstat ) then
        cat /dev/sndstat >>! "${HARDWARE_SNAPSHOT}"
    else
        /bin/echo "/dev/sndstat not present" >>! "${HARDWARE_SNAPSHOT}"
    endif

    cat >>! "${HARDWARE_SNAPSHOT}" <<EOF

[relevant_sysctls]
`sysctl -a 2>/dev/null | egrep '^(hw\.snd|hw\.backlight|kern\.syscons_async|vm\.dma_reserved|hw\.drm|drm|hw\.dri)'`

[target_user_groups]
`id -Gn "${TARGET_USER}" 2>&1`

[etc_x11_tree]
`(find /etc/X11 -maxdepth 3 -type f -print 2>/dev/null | sort)`

[user_x_files]
`(ls -ld "${TARGET_HOME}/.xsession" "${TARGET_HOME}/.xinitrc" "${TARGET_HOME}/GNUstep" "${TARGET_HOME}/.config" 2>/dev/null || true)`
EOF

    if ( "${PKG_BIN}" != "" ) then
        "${PKG_BIN}" info 2>&1 >! "${PACKAGE_SNAPSHOT}"
    else
        /bin/echo "pkg unavailable during discovery" >! "${PACKAGE_SNAPSHOT}"
    endif

    foreach SNAP_TARGET ( /etc/rc.conf /boot/loader.conf /etc/sysctl.conf /etc/ttys )
        if ( -e "${SNAP_TARGET}" ) then
            set SNAP_SAFE = `echo "${SNAP_TARGET}" | sed 's#^/##; s#[/[:space:]]#_#g'`
            /bin/cp -p "${SNAP_TARGET}" "${STATE_DIR}/${SNAP_SAFE}.${RUN_ID}.snapshot" >& /dev/null
            if ( $status == 0 ) log_msg INFO phase2 snapshot "captured ${SNAP_TARGET}"
        endif
    end

    mark_checkpoint phase2
    log_msg OK phase2 end "discovery snapshot completed"
endif

#
# phase 3: conservative desktop tuning first
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase3" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase3 resume "checkpoint already completed"
else
    log_msg INFO phase3 start "applying conservative runtime tuning"

    set SYSCTL_LINES = ()
    set AUDIO_PLAN_TMP = `mktemp "${STATE_DIR}/audio-plan.XXXXXX"`

    if ( -r /dev/sndstat ) then
        awk '
            BEGIN {
                best = -1
                bestunit = ""
                bestline = ""
                count = 0
                analog = 0
                usb = 0
                hdmi = 0
            }
            /^pcm[0-9]+:/ {
                line = $0
                unit = line
                sub(/^pcm/, "", unit)
                sub(/:.*/, "", unit)
                lower = tolower(line)
                score = 100
                if (lower ~ /(speaker|headphone|headset|analog|line[ -]?out|front|rear)/) {
                    score = 400
                    analog = 1
                } else if (lower ~ /(usb|uaudio|dac)/) {
                    score = 300
                    usb = 1
                } else if (lower ~ /(hdmi|displayport|display port|dp[ -]?audio)/) {
                    score = 200
                    hdmi = 1
                }
                count++
                if (score > best) {
                    best = score
                    bestunit = unit
                    bestline = line
                }
            }
            END {
                class = "no-detected-audio"
                if (count == 1 && analog == 1) class = "single-device-analog"
                else if (count > 1 && analog == 1 && hdmi == 1) class = "multi-device-analog+HDMI"
                else if (usb == 1) class = "USB-audio-present"
                else if (count > 0) class = "single-device-analog"
                print "COUNT=" count
                print "CLASS=" class
                print "SELECTED=" bestunit
                print "REASON=" bestline
            }
        ' /dev/sndstat >! "${AUDIO_PLAN_TMP}"
    else
        cat >! "${AUDIO_PLAN_TMP}" <<EOF
COUNT=0
CLASS=no-detected-audio
SELECTED=
REASON=/dev/sndstat not present
EOF
    endif

    set AUDIO_COUNT = `awk -F= '/^COUNT=/{print $2}' "${AUDIO_PLAN_TMP}"`
    set AUDIO_PLAN_CLASS = `awk -F= '/^CLASS=/{print $2}' "${AUDIO_PLAN_TMP}"`
    set SELECTED_AUDIO_UNIT = `awk -F= '/^SELECTED=/{print $2}' "${AUDIO_PLAN_TMP}"`
    set AUDIO_PLAN_REASON = `awk -F= '/^REASON=/{print $2}' "${AUDIO_PLAN_TMP}"`

    sysctl -n kern.syscons_async >/dev/null 2>&1
    if ( $status == 0 ) then
        set CURRENT_SYSCONS_ASYNC = `sysctl -n kern.syscons_async 2>/dev/null`
        if ( "${CURRENT_SYSCONS_ASYNC}" != "1" ) then
            sysctl kern.syscons_async=1 >/dev/null 2>&1
            if ( $status == 0 ) then
                log_msg OK phase3 runtime-sysctl "set kern.syscons_async=1"
            else
                log_msg WARN phase3 runtime-sysctl "failed to set kern.syscons_async=1 at runtime"
            endif
        else
            log_msg SKIP phase3 runtime-sysctl "kern.syscons_async already set to 1"
        endif
        set SYSCTL_LINES = ( ${SYSCTL_LINES} "kern.syscons_async=1" )
    else
        log_msg SKIP phase3 runtime-sysctl "kern.syscons_async not present on this system"
    endif

    set CURRENT_DEFAULT_AUDIO = `sysctl -n hw.snd.default_unit 2>/dev/null`
    if ( "${SELECTED_AUDIO_UNIT}" != "" && ${AUDIO_COUNT} > 1 ) then
        sysctl hw.snd.default_unit="${SELECTED_AUDIO_UNIT}" >/dev/null 2>&1
        if ( $status == 0 ) then
            log_msg OK phase3 runtime-audio "set hw.snd.default_unit=${SELECTED_AUDIO_UNIT} based on detected desktop output"
        else
            log_msg WARN phase3 runtime-audio "failed to set hw.snd.default_unit=${SELECTED_AUDIO_UNIT} at runtime"
        endif
        set SYSCTL_LINES = ( ${SYSCTL_LINES} "hw.snd.default_unit=${SELECTED_AUDIO_UNIT}" )
    else if ( "${CURRENT_DEFAULT_AUDIO}" != "" ) then
        if ( "${SELECTED_AUDIO_UNIT}" != "" ) then
            set SYSCTL_LINES = ( ${SYSCTL_LINES} "hw.snd.default_unit=${CURRENT_DEFAULT_AUDIO}" )
            log_msg INFO phase3 runtime-audio "retaining existing default audio unit ${CURRENT_DEFAULT_AUDIO}"
        else
            log_msg SKIP phase3 runtime-audio "no detected audio device to persist"
        endif
    else
        log_msg SKIP phase3 runtime-audio "default audio selection unchanged"
    endif

    set SYSCTL_CONTENT = `mktemp "${STATE_DIR}/sysctl-block.XXXXXX"`
    /bin/echo "${MANAGED_BEGIN}" >! "${SYSCTL_CONTENT}"
    /bin/echo "# managed by ${SCRIPT_NAME} run ${RUN_ID}" >>! "${SYSCTL_CONTENT}"
    foreach SYSCTL_LINE ( ${SYSCTL_LINES} )
        /bin/echo "${SYSCTL_LINE}" >>! "${SYSCTL_CONTENT}"
        log_msg INFO phase3 persistent-sysctl "planned persistent sysctl ${SYSCTL_LINE}"
    end
    /bin/echo "${MANAGED_END}" >>! "${SYSCTL_CONTENT}"

    if ( ! -e /etc/sysctl.conf ) /usr/bin/touch /etc/sysctl.conf
    set SYSCTL_TMP = `mktemp "/etc/sysctl.conf.tvb.XXXXXX"`
    setenv TVB_BEGIN "${MANAGED_BEGIN}"
    setenv TVB_END "${MANAGED_END}"
    setenv TVB_CONTENT_FILE "${SYSCTL_CONTENT}"
    awk -f "${MERGE_AWK}" /etc/sysctl.conf >! "${SYSCTL_TMP}"
    unsetenv TVB_BEGIN
    unsetenv TVB_END
    unsetenv TVB_CONTENT_FILE

    cmp -s /etc/sysctl.conf "${SYSCTL_TMP}"
    if ( $status == 0 ) then
        /bin/rm -f "${SYSCTL_TMP}"
        log_msg SKIP phase3 persistent-sysctl "/etc/sysctl.conf already converged"
    else
        set SAFE_PATH = `echo "/etc/sysctl.conf" | sed 's#^/##; s#[/[:space:]]#_#g'`
        set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
        /bin/cp -p /etc/sysctl.conf "${BACKUP_FILE}"
        if ( $status != 0 ) then
            /bin/rm -f "${SYSCTL_TMP}"
            log_msg ERROR phase3 persistent-sysctl "failed to back up /etc/sysctl.conf"
            set EXIT_CODE = ${EXIT_CODE_CONFIG}
            goto CLEAN_EXIT
        endif
        /bin/echo "/etc/sysctl.conf|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
        log_msg INFO phase3 persistent-sysctl "backup created at ${BACKUP_FILE}"
        /bin/mv -f "${SYSCTL_TMP}" /etc/sysctl.conf
        if ( $status != 0 ) then
            /bin/cp -p "${BACKUP_FILE}" /etc/sysctl.conf >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase3 persistent-sysctl "atomic replace failed; backup restored"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        /bin/echo "${RUN_ID}|/etc/sysctl.conf|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase3 persistent-sysctl "/etc/sysctl.conf updated atomically"
    endif

    /bin/rm -f "${SYSCTL_CONTENT}" "${AUDIO_PLAN_TMP}"

    mark_checkpoint phase3
    log_msg OK phase3 end "conservative tuning completed"
endif

#
# phase 4: package manager readiness
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase4" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase4 resume "checkpoint already completed"
else
    log_msg INFO phase4 start "ensuring pkg bootstrap and repository readiness"

    "${PKG_BIN}" -N >/dev/null 2>&1
    if ( $status != 0 ) then
        setenv ASSUME_ALWAYS_YES yes
        "${PKG_BIN}" bootstrap -yf >>& "${LOG_FILE}"
        if ( $status != 0 ) then
            log_msg ERROR phase4 bootstrap "pkg bootstrap failed"
            set EXIT_CODE = ${EXIT_CODE_PACKAGE}
            goto CLEAN_EXIT
        endif
        rehash
        set PKG_BIN = `which pkg 2>/dev/null`
        log_msg OK phase4 bootstrap "pkg bootstrapped successfully"
    else
        log_msg SKIP phase4 bootstrap "pkg already initialized"
    endif

    "${PKG_BIN}" update >>& "${LOG_FILE}"
    if ( $status != 0 ) then
        log_msg ERROR phase4 update "pkg repository metadata update failed"
        set EXIT_CODE = ${EXIT_CODE_PACKAGE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase4 update "pkg repository metadata updated"

    if ( ${SKIP_UPGRADE} == 0 ) then
        "${PKG_BIN}" upgrade -y >>& "${LOG_FILE}"
        if ( $status == 0 ) then
            log_msg OK phase4 upgrade "pkg upgrade completed"
        else
            log_msg WARN phase4 upgrade "pkg upgrade reported non-zero status; continuing"
        endif
    else
        log_msg SKIP phase4 upgrade "package upgrade skipped by flag"
    endif

    set PKG_ABI = `("${PKG_BIN}" -vv 2>/dev/null | awk -F'"' '/ABI/ {print $2; exit}')`
    if ( "${PKG_ABI}" == "" ) set PKG_ABI = "unknown"
    log_msg INFO phase4 context "repository ABI ${PKG_ABI}"

    mark_checkpoint phase4
    log_msg OK phase4 end "package manager readiness completed"
endif

#
# phase 5: hardware-aware planning
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase5" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase5 resume "checkpoint already completed"
else
    log_msg INFO phase5 start "building hardware-aware plan"

    set GPU_PLAN = "unknown-generic"
    if ( egrep -iq '(intel|i915|iris|uhd|hd graphics)' "${HARDWARE_SNAPSHOT}" ) then
        set GPU_PLAN = "intel-kms"
    else if ( egrep -iq '(navi|vega|polaris|rembrandt|rdna|amdgpu)' "${HARDWARE_SNAPSHOT}" ) then
        set GPU_PLAN = "amd-amdgpu"
    else if ( egrep -iq '(radeon|firepro|tahiti|pitcairn|bonaire|oland|cape verde|caicos|cedar|turks)' "${HARDWARE_SNAPSHOT}" ) then
        set GPU_PLAN = "amd-radeon"
    endif
    log_msg INFO phase5 gpu-plan "classified GPU plan as ${GPU_PLAN}"

    set AUDIO_PLAN_TMP = `mktemp "${STATE_DIR}/audio-plan.XXXXXX"`
    if ( -r /dev/sndstat ) then
        awk '
            BEGIN {
                best = -1
                bestunit = ""
                bestline = ""
                count = 0
                analog = 0
                usb = 0
                hdmi = 0
            }
            /^pcm[0-9]+:/ {
                line = $0
                unit = line
                sub(/^pcm/, "", unit)
                sub(/:.*/, "", unit)
                lower = tolower(line)
                score = 100
                if (lower ~ /(speaker|headphone|headset|analog|line[ -]?out|front|rear)/) {
                    score = 400
                    analog = 1
                } else if (lower ~ /(usb|uaudio|dac)/) {
                    score = 300
                    usb = 1
                } else if (lower ~ /(hdmi|displayport|display port|dp[ -]?audio)/) {
                    score = 200
                    hdmi = 1
                }
                count++
                if (score > best) {
                    best = score
                    bestunit = unit
                    bestline = line
                }
            }
            END {
                class = "no-detected-audio"
                if (count == 1 && analog == 1) class = "single-device-analog"
                else if (count > 1 && analog == 1 && hdmi == 1) class = "multi-device-analog+HDMI"
                else if (usb == 1) class = "USB-audio-present"
                else if (count > 0) class = "single-device-analog"
                print "COUNT=" count
                print "CLASS=" class
                print "SELECTED=" bestunit
                print "REASON=" bestline
            }
        ' /dev/sndstat >! "${AUDIO_PLAN_TMP}"
    else
        cat >! "${AUDIO_PLAN_TMP}" <<EOF
COUNT=0
CLASS=no-detected-audio
SELECTED=
REASON=/dev/sndstat not present
EOF
    endif

    set AUDIO_COUNT = `awk -F= '/^COUNT=/{print $2}' "${AUDIO_PLAN_TMP}"`
    set AUDIO_PLAN_CLASS = `awk -F= '/^CLASS=/{print $2}' "${AUDIO_PLAN_TMP}"`
    set SELECTED_AUDIO_UNIT = `awk -F= '/^SELECTED=/{print $2}' "${AUDIO_PLAN_TMP}"`
    set AUDIO_PLAN_REASON = `awk -F= '/^REASON=/{print $2}' "${AUDIO_PLAN_TMP}"`
    log_msg INFO phase5 audio-plan "classified audio plan as ${AUDIO_PLAN_CLASS}; selected unit ${SELECTED_AUDIO_UNIT}"

    sysctl -n hw.backlight_max >/dev/null 2>&1
    if ( $status == 0 ) then
        sysctl -n hw.backlight_level >/dev/null 2>&1
        if ( $status == 0 ) then
            set BACKLIGHT_MANAGEABLE = 1
            log_msg INFO phase5 backlight-plan "backlight sysctls detected"
        endif
    endif
    if ( ${BACKLIGHT_MANAGEABLE} == 0 ) log_msg SKIP phase5 backlight-plan "backlight sysctls not present"

    set KEYBOARD_VALID = 0
    set XKB_RULES_FILE = ""
    foreach RULEFILE ( /usr/local/share/X11/xkb/rules/base.lst /usr/local/share/X11/xkb/rules/evdev.lst )
        if ( -r "${RULEFILE}" ) set XKB_RULES_FILE = "${RULEFILE}"
    end
    if ( "${XKB_RULES_FILE}" != "" ) then
        awk -v want="${KEYBOARD_LAYOUT}" '
            BEGIN { in_layout = 0; ok = 0 }
            /^! layout/ { in_layout = 1; next }
            /^!/ { if (in_layout) exit }
            in_layout && $1 == want { ok = 1; exit }
            END { exit(ok ? 0 : 1) }
        ' "${XKB_RULES_FILE}" >/dev/null 2>&1
        if ( $status == 0 ) set KEYBOARD_VALID = 1
    endif
    if ( ${KEYBOARD_VALID} == 1 ) then
        log_msg OK phase5 keyboard-plan "xkb layout ${KEYBOARD_LAYOUT} validated against installed rules"
    else
        log_msg WARN phase5 keyboard-plan "authoritative xkb validation deferred until XKB data is available"
    endif

    cat >! "${PLAN_FILE}" <<EOF
run_id=${RUN_ID}
gpu_plan=${GPU_PLAN}
audio_count=${AUDIO_COUNT}
audio_plan=${AUDIO_PLAN_CLASS}
selected_audio_unit=${SELECTED_AUDIO_UNIT}
audio_reason=${AUDIO_PLAN_REASON}
backlight_manageable=${BACKLIGHT_MANAGEABLE}
keyboard_layout=${KEYBOARD_LAYOUT}
EOF

    /bin/rm -f "${AUDIO_PLAN_TMP}"

    mark_checkpoint phase5
    log_msg OK phase5 end "hardware-aware planning completed"
endif

#
# phase 6: package resolution
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase6" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase6 resume "checkpoint already completed"
else
    log_msg INFO phase6 start "resolving package capabilities"

    set SLOT_FILE = `mktemp "${STATE_DIR}/pkg-slots.XXXXXX"`
    cat >! "${SLOT_FILE}" <<EOF
REQUIRED|x_server_meta|xorg
REQUIRED|input_libinput|xf86-input-libinput
REQUIRED|input_evdev|xf86-input-evdev
REQUIRED|display_manager|xdm
REQUIRED|gnustep_core|gnustep
REQUIRED|gnustep_back|gnustep-back
REQUIRED|window_manager|windowmaker
REQUIRED|terminal|xterm,rxvt-unicode,mlterm
REQUIRED|editor|vim,nano
REQUIRED|browser|firefox,firefox-esr,chromium
REQUIRED|curl|curl
REQUIRED|wget|wget
REQUIRED|rsync|rsync
REQUIRED|git|git
OPTIONAL|office_suite|libreoffice
OPTIONAL|pdf_viewer|evince,xpdf,zathura
OPTIONAL|file_manager|thunar,pcmanfm,xfe
OPTIONAL|system_monitor|htop,btop
OPTIONAL|zip|zip
OPTIONAL|unzip|unzip
OPTIONAL|p7zip|p7zip
OPTIONAL|clipboard_helper|xclip,xsel
OPTIONAL|core_fonts|dejavu,liberation-fonts-ttf,noto-basic
OPTIONAL|video_player|mpv,vlc
OPTIONAL|audio_player|mpg123,audacious
OPTIONAL|transcoder|ffmpeg
OPTIONAL|audio_utility|sox
OPTIONAL|image_editor|gimp
OPTIONAL|screenshot_tool|scrot,maim,ImageMagick7
EOF

    /bin/rm -f "${CHOSEN_PACKAGES_FILE}"
    /usr/bin/touch "${CHOSEN_PACKAGES_FILE}"

    set SLOT_TOTAL = `wc -l < "${SLOT_FILE}"`
    @ SLOT_INDEX = 1
    while ( ${SLOT_INDEX} <= ${SLOT_TOTAL} )
        set SLOT_LINE = "`sed -n "${SLOT_INDEX}p" "${SLOT_FILE}"`"
        set SLOT_CLASS = `echo "${SLOT_LINE}" | awk -F'|' '{print $1}'`
        set SLOT_NAME = `echo "${SLOT_LINE}" | awk -F'|' '{print $2}'`
        set SLOT_CANDIDATES = `echo "${SLOT_LINE}" | awk -F'|' '{print $3}'`
        set SLOT_RESOLVED = 0

        log_msg INFO phase6 "resolve-${SLOT_NAME}" "resolving ${SLOT_CLASS} package slot ${SLOT_NAME}"

        foreach CANDIDATE ( `echo "${SLOT_CANDIDATES}" | tr ',' ' '` )
            "${PKG_BIN}" search -q -e "${CANDIDATE}" >/dev/null 2>&1
            if ( $status != 0 ) then
                log_msg SKIP phase6 "resolve-${SLOT_NAME}" "candidate ${CANDIDATE} not available"
                continue
            endif

            "${PKG_BIN}" info -e "${CANDIDATE}" >/dev/null 2>&1
            if ( $status == 0 ) then
                /bin/echo "${SLOT_NAME}=${CANDIDATE}" >>! "${CHOSEN_PACKAGES_FILE}"
                log_msg OK phase6 "install-${SLOT_NAME}" "package ${CANDIDATE} already installed"
                set SLOT_RESOLVED = 1
                break
            endif

            log_msg INFO phase6 "install-${SLOT_NAME}" "installing ${CANDIDATE}"
            "${PKG_BIN}" install -y "${CANDIDATE}" >>& "${LOG_FILE}"
            if ( $status == 0 ) then
                /bin/echo "${SLOT_NAME}=${CANDIDATE}" >>! "${CHOSEN_PACKAGES_FILE}"
                log_msg OK phase6 "install-${SLOT_NAME}" "installed ${CANDIDATE}"
                set SLOT_RESOLVED = 1
                break
            else
                log_msg WARN phase6 "install-${SLOT_NAME}" "install failed for ${CANDIDATE}; trying next candidate"
            endif
        end

        if ( ${SLOT_RESOLVED} == 0 ) then
            if ( "${SLOT_CLASS}" == "REQUIRED" ) then
                log_msg ERROR phase6 "resolve-${SLOT_NAME}" "required slot ${SLOT_NAME} could not be resolved"
                set EXIT_CODE = ${EXIT_CODE_PACKAGE}
                /bin/rm -f "${SLOT_FILE}"
                goto CLEAN_EXIT
            else
                log_msg WARN phase6 "resolve-${SLOT_NAME}" "optional slot ${SLOT_NAME} unresolved"
            endif
        endif

        @ SLOT_INDEX++
    end

    "${PKG_BIN}" info >! "${PACKAGE_SNAPSHOT}"

    set XORG_BIN = `which Xorg 2>/dev/null`
    if ( "${XORG_BIN}" == "" && -x /usr/local/bin/Xorg ) set XORG_BIN = "/usr/local/bin/Xorg"
    set XDM_BIN = `which xdm 2>/dev/null`
    if ( "${XDM_BIN}" == "" && -x /usr/local/bin/xdm ) set XDM_BIN = "/usr/local/bin/xdm"

    /bin/rm -f "${SLOT_FILE}"

    mark_checkpoint phase6
    log_msg OK phase6 end "package resolution completed"
endif

#
# phase 7: system configuration
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase7" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase7 resume "checkpoint already completed"
else
    log_msg INFO phase7 start "writing rc.conf, loader.conf, sysctl.conf, and /etc/ttys"

    #
    # /etc/rc.conf
    #
    if ( ! -e /etc/rc.conf ) /usr/bin/touch /etc/rc.conf
    set RC_CONTENT = `mktemp "${STATE_DIR}/rcconf-block.XXXXXX"`
    /bin/echo "${MANAGED_BEGIN}" >! "${RC_CONTENT}"
    /bin/echo "# managed by ${SCRIPT_NAME} run ${RUN_ID}" >>! "${RC_CONTENT}"
    /bin/echo "# desktop support block intentionally minimal and conservative" >>! "${RC_CONTENT}"
    /bin/echo "${MANAGED_END}" >>! "${RC_CONTENT}"

    set RC_TMP = `mktemp "/etc/rc.conf.tvb.XXXXXX"`
    setenv TVB_BEGIN "${MANAGED_BEGIN}"
    setenv TVB_END "${MANAGED_END}"
    setenv TVB_CONTENT_FILE "${RC_CONTENT}"
    awk -f "${MERGE_AWK}" /etc/rc.conf >! "${RC_TMP}"
    unsetenv TVB_BEGIN
    unsetenv TVB_END
    unsetenv TVB_CONTENT_FILE

    cmp -s /etc/rc.conf "${RC_TMP}"
    if ( $status == 0 ) then
        /bin/rm -f "${RC_TMP}"
        log_msg SKIP phase7 rc-conf "/etc/rc.conf already converged"
    else
        set SAFE_PATH = `echo "/etc/rc.conf" | sed 's#^/##; s#[/[:space:]]#_#g'`
        set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
        /bin/cp -p /etc/rc.conf "${BACKUP_FILE}"
        if ( $status != 0 ) then
            /bin/rm -f "${RC_TMP}"
            log_msg ERROR phase7 rc-conf "failed to back up /etc/rc.conf"
            set EXIT_CODE = ${EXIT_CODE_CONFIG}
            goto CLEAN_EXIT
        endif
        /bin/echo "/etc/rc.conf|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
        log_msg INFO phase7 rc-conf "backup created at ${BACKUP_FILE}"
        /bin/mv -f "${RC_TMP}" /etc/rc.conf
        if ( $status != 0 ) then
            /bin/cp -p "${BACKUP_FILE}" /etc/rc.conf >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase7 rc-conf "atomic replace failed; backup restored"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        /bin/echo "${RUN_ID}|/etc/rc.conf|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase7 rc-conf "/etc/rc.conf updated atomically"
    endif
    /bin/rm -f "${RC_CONTENT}"

    #
    # /boot/loader.conf
    #
    if ( ! -e /boot/loader.conf ) /usr/bin/touch /boot/loader.conf
    set LOADER_CONTENT = `mktemp "${STATE_DIR}/loader-block.XXXXXX"`
    /bin/echo "${MANAGED_BEGIN}" >! "${LOADER_CONTENT}"
    /bin/echo "# managed by ${SCRIPT_NAME} run ${RUN_ID}" >>! "${LOADER_CONTENT}"
    /bin/echo "# no documented hardware-justified loader tunables required for current plan" >>! "${LOADER_CONTENT}"
    /bin/echo "${MANAGED_END}" >>! "${LOADER_CONTENT}"

    set LOADER_TMP = `mktemp "/boot/loader.conf.tvb.XXXXXX"`
    setenv TVB_BEGIN "${MANAGED_BEGIN}"
    setenv TVB_END "${MANAGED_END}"
    setenv TVB_CONTENT_FILE "${LOADER_CONTENT}"
    awk -f "${MERGE_AWK}" /boot/loader.conf >! "${LOADER_TMP}"
    unsetenv TVB_BEGIN
    unsetenv TVB_END
    unsetenv TVB_CONTENT_FILE

    cmp -s /boot/loader.conf "${LOADER_TMP}"
    if ( $status == 0 ) then
        /bin/rm -f "${LOADER_TMP}"
        log_msg SKIP phase7 loader-conf "/boot/loader.conf already converged"
    else
        set SAFE_PATH = `echo "/boot/loader.conf" | sed 's#^/##; s#[/[:space:]]#_#g'`
        set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
        /bin/cp -p /boot/loader.conf "${BACKUP_FILE}"
        if ( $status != 0 ) then
            /bin/rm -f "${LOADER_TMP}"
            log_msg ERROR phase7 loader-conf "failed to back up /boot/loader.conf"
            set EXIT_CODE = ${EXIT_CODE_CONFIG}
            goto CLEAN_EXIT
        endif
        /bin/echo "/boot/loader.conf|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
        log_msg INFO phase7 loader-conf "backup created at ${BACKUP_FILE}"
        /bin/mv -f "${LOADER_TMP}" /boot/loader.conf
        if ( $status != 0 ) then
            /bin/cp -p "${BACKUP_FILE}" /boot/loader.conf >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase7 loader-conf "atomic replace failed; backup restored"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        /bin/echo "${RUN_ID}|/boot/loader.conf|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase7 loader-conf "/boot/loader.conf updated atomically"
    endif
    /bin/rm -f "${LOADER_CONTENT}"

    #
    # /etc/sysctl.conf (refresh with final selected unit)
    #
    if ( ! -e /etc/sysctl.conf ) /usr/bin/touch /etc/sysctl.conf
    set SYSCTL_LINES = ()
    sysctl -n kern.syscons_async >/dev/null 2>&1
    if ( $status == 0 ) set SYSCTL_LINES = ( ${SYSCTL_LINES} "kern.syscons_async=1" )
    if ( "${SELECTED_AUDIO_UNIT}" != "" && ${AUDIO_COUNT} > 0 ) set SYSCTL_LINES = ( ${SYSCTL_LINES} "hw.snd.default_unit=${SELECTED_AUDIO_UNIT}" )

    set SYSCTL_CONTENT = `mktemp "${STATE_DIR}/sysctl-block.XXXXXX"`
    /bin/echo "${MANAGED_BEGIN}" >! "${SYSCTL_CONTENT}"
    /bin/echo "# managed by ${SCRIPT_NAME} run ${RUN_ID}" >>! "${SYSCTL_CONTENT}"
    foreach SYSCTL_LINE ( ${SYSCTL_LINES} )
        /bin/echo "${SYSCTL_LINE}" >>! "${SYSCTL_CONTENT}"
    end
    /bin/echo "${MANAGED_END}" >>! "${SYSCTL_CONTENT}"

    set SYSCTL_TMP = `mktemp "/etc/sysctl.conf.tvb.XXXXXX"`
    setenv TVB_BEGIN "${MANAGED_BEGIN}"
    setenv TVB_END "${MANAGED_END}"
    setenv TVB_CONTENT_FILE "${SYSCTL_CONTENT}"
    awk -f "${MERGE_AWK}" /etc/sysctl.conf >! "${SYSCTL_TMP}"
    unsetenv TVB_BEGIN
    unsetenv TVB_END
    unsetenv TVB_CONTENT_FILE

    cmp -s /etc/sysctl.conf "${SYSCTL_TMP}"
    if ( $status == 0 ) then
        /bin/rm -f "${SYSCTL_TMP}"
        log_msg SKIP phase7 sysctl-conf "/etc/sysctl.conf already converged"
    else
        set SAFE_PATH = `echo "/etc/sysctl.conf" | sed 's#^/##; s#[/[:space:]]#_#g'`
        set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
        /bin/cp -p /etc/sysctl.conf "${BACKUP_FILE}"
        if ( $status != 0 ) then
            /bin/rm -f "${SYSCTL_TMP}"
            log_msg ERROR phase7 sysctl-conf "failed to back up /etc/sysctl.conf"
            set EXIT_CODE = ${EXIT_CODE_CONFIG}
            goto CLEAN_EXIT
        endif
        /bin/echo "/etc/sysctl.conf|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
        log_msg INFO phase7 sysctl-conf "backup created at ${BACKUP_FILE}"
        /bin/mv -f "${SYSCTL_TMP}" /etc/sysctl.conf
        if ( $status != 0 ) then
            /bin/cp -p "${BACKUP_FILE}" /etc/sysctl.conf >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase7 sysctl-conf "atomic replace failed; backup restored"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        /bin/echo "${RUN_ID}|/etc/sysctl.conf|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase7 sysctl-conf "/etc/sysctl.conf updated atomically"
    endif
    /bin/rm -f "${SYSCTL_CONTENT}"

    #
    # /etc/ttys
    #
    if ( ! -e /etc/ttys ) then
        log_msg ERROR phase7 ttys "/etc/ttys not found"
        set EXIT_CODE = ${EXIT_CODE_CONFIG}
        goto CLEAN_EXIT
    endif

    set XDM_BIN = `which xdm 2>/dev/null`
    if ( "${XDM_BIN}" == "" && -x /usr/local/bin/xdm ) set XDM_BIN = "/usr/local/bin/xdm"
    if ( "${XDM_BIN}" == "" ) set XDM_BIN = "/usr/local/bin/xdm"

    set TTYS_TMP = `mktemp "/etc/ttys.tvb.XXXXXX"`
    awk -v xdm_bin="${XDM_BIN}" '
        BEGIN { done = 0 }
        {
            if ($0 ~ /^[[:space:]]*ttyv8[[:space:]]+/) {
                done = 1
                if (match($0, /^[[:space:]]*ttyv8[[:space:]]+("[^"]+"|[^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)/, a)) {
                    cmd = a[1]
                    term = a[2]
                    sec = a[4]
                    if (cmd !~ /xdm/) cmd = "\"" xdm_bin " -nodaemon\""
                    if (term == "") term = "xterm"
                    if (sec == "") sec = "secure"
                    printf("ttyv8\t%s\t%s\ton\t%s\n", cmd, term, sec)
                } else {
                    printf("ttyv8\t\"%s -nodaemon\"\txterm\ton\tsecure\n", xdm_bin)
                }
                next
            }
            print
        }
        END {
            if (!done) {
                printf("ttyv8\t\"%s -nodaemon\"\txterm\ton\tsecure\n", xdm_bin)
            }
        }
    ' /etc/ttys >! "${TTYS_TMP}"

    grep -Eq '^[[:space:]]*ttyv8[[:space:]]+' "${TTYS_TMP}" >/dev/null 2>&1
    if ( $status != 0 ) then
        /bin/rm -f "${TTYS_TMP}"
        log_msg ERROR phase7 ttys "generated /etc/ttys does not contain ttyv8 entry"
        set EXIT_CODE = ${EXIT_CODE_CONFIG}
        goto CLEAN_EXIT
    endif

    cmp -s /etc/ttys "${TTYS_TMP}"
    if ( $status == 0 ) then
        /bin/rm -f "${TTYS_TMP}"
        log_msg SKIP phase7 ttys "/etc/ttys already converged for ttyv8 xdm enablement"
    else
        set SAFE_PATH = `echo "/etc/ttys" | sed 's#^/##; s#[/[:space:]]#_#g'`
        set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
        /bin/cp -p /etc/ttys "${BACKUP_FILE}"
        if ( $status != 0 ) then
            /bin/rm -f "${TTYS_TMP}"
            log_msg ERROR phase7 ttys "failed to back up /etc/ttys"
            set EXIT_CODE = ${EXIT_CODE_CONFIG}
            goto CLEAN_EXIT
        endif
        /bin/echo "/etc/ttys|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
        log_msg INFO phase7 ttys "backup created at ${BACKUP_FILE}"
        /bin/mv -f "${TTYS_TMP}" /etc/ttys
        if ( $status != 0 ) then
            /bin/cp -p "${BACKUP_FILE}" /etc/ttys >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase7 ttys "atomic replace failed; backup restored"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        set TTYS_CHANGED = 1
        NEED_REBOOT = 1
        /bin/echo "${RUN_ID}|/etc/ttys|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase7 ttys "/etc/ttys updated atomically"
    endif

    mark_checkpoint phase7
    log_msg OK phase7 end "system configuration completed"
endif

#
# phase 8: X11 configuration
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase8" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase8 resume "checkpoint already completed"
else
    log_msg INFO phase8 start "generating minimal X11 configuration"

    /bin/mkdir -p /etc/X11/xorg.conf.d
    if ( $status != 0 ) then
        log_msg ERROR phase8 xorg-dir "failed to create /etc/X11/xorg.conf.d"
        set EXIT_CODE = ${EXIT_CODE_CONFIG}
        goto CLEAN_EXIT
    endif

    set XKB_RULES_FILE = ""
    foreach RULEFILE ( /usr/local/share/X11/xkb/rules/base.lst /usr/local/share/X11/xkb/rules/evdev.lst )
        if ( -r "${RULEFILE}" ) set XKB_RULES_FILE = "${RULEFILE}"
    end
    if ( "${XKB_RULES_FILE}" == "" ) then
        log_msg ERROR phase8 validate-keyboard "XKB rules file not found after package installation"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif

    awk -v want="${KEYBOARD_LAYOUT}" '
        BEGIN { in_layout = 0; ok = 0 }
        /^! layout/ { in_layout = 1; next }
        /^!/ { if (in_layout) exit }
        in_layout && $1 == want { ok = 1; exit }
        END { exit(ok ? 0 : 1) }
    ' "${XKB_RULES_FILE}" >/dev/null 2>&1
    if ( $status != 0 ) then
        log_msg ERROR phase8 validate-keyboard "keyboard layout ${KEYBOARD_LAYOUT} not found in installed XKB data"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase8 validate-keyboard "authoritative XKB validation passed"

    set KB_FILE = "/etc/X11/xorg.conf.d/00-keyboard.conf"
    set KB_TMP = `mktemp "${KB_FILE}.XXXXXX"`
    cat >! "${KB_TMP}" <<EOF
# ${PROJECT_NAME}
${MANAGED_BEGIN}
Section "InputClass"
    Identifier "turkishvan-bsd keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${KEYBOARD_LAYOUT}"
EndSection
${MANAGED_END}
EOF

    if ( -e "${KB_FILE}" ) then
        cmp -s "${KB_FILE}" "${KB_TMP}"
    else
        false
    endif
    if ( $status == 0 ) then
        /bin/rm -f "${KB_TMP}"
        log_msg SKIP phase8 keyboard-file "${KB_FILE} already converged"
    else
        if ( -e "${KB_FILE}" ) then
            set SAFE_PATH = `echo "${KB_FILE}" | sed 's#^/##; s#[/[:space:]]#_#g'`
            set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
            /bin/cp -p "${KB_FILE}" "${BACKUP_FILE}"
            if ( $status != 0 ) then
                /bin/rm -f "${KB_TMP}"
                log_msg ERROR phase8 keyboard-file "failed to back up ${KB_FILE}"
                set EXIT_CODE = ${EXIT_CODE_CONFIG}
                goto CLEAN_EXIT
            endif
            /bin/echo "${KB_FILE}|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
            log_msg INFO phase8 keyboard-file "backup created at ${BACKUP_FILE}"
        endif
        /bin/mv -f "${KB_TMP}" "${KB_FILE}"
        if ( $status != 0 ) then
            if ( $?BACKUP_FILE ) /bin/cp -p "${BACKUP_FILE}" "${KB_FILE}" >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase8 keyboard-file "atomic replace failed for ${KB_FILE}"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        /bin/echo "${RUN_ID}|${KB_FILE}|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase8 keyboard-file "${KB_FILE} written"
    endif

    set NEED_LIBINPUT = 1
    foreach LIBINPUT_HINT ( /etc/X11/xorg.conf.d/*libinput* /usr/local/etc/X11/xorg.conf.d/*libinput* )
        if ( -e "${LIBINPUT_HINT}" ) set NEED_LIBINPUT = 0
    end

    if ( ${NEED_LIBINPUT} == 1 ) then
        set LI_FILE = "/etc/X11/xorg.conf.d/10-libinput.conf"
        set LI_TMP = `mktemp "${LI_FILE}.XXXXXX"`
        cat >! "${LI_TMP}" <<EOF
# ${PROJECT_NAME}
${MANAGED_BEGIN}
Section "InputClass"
    Identifier "turkishvan-bsd libinput pointer"
    MatchIsPointer "on"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "turkishvan-bsd libinput touchpad"
    MatchIsTouchpad "on"
    Driver "libinput"
EndSection
${MANAGED_END}
EOF
        if ( -e "${LI_FILE}" ) then
            cmp -s "${LI_FILE}" "${LI_TMP}"
        else
            false
        endif
        if ( $status == 0 ) then
            /bin/rm -f "${LI_TMP}"
            log_msg SKIP phase8 libinput-file "${LI_FILE} already converged"
        else
            if ( -e "${LI_FILE}" ) then
                set SAFE_PATH = `echo "${LI_FILE}" | sed 's#^/##; s#[/[:space:]]#_#g'`
                set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
                /bin/cp -p "${LI_FILE}" "${BACKUP_FILE}"
                if ( $status != 0 ) then
                    /bin/rm -f "${LI_TMP}"
                    log_msg ERROR phase8 libinput-file "failed to back up ${LI_FILE}"
                    set EXIT_CODE = ${EXIT_CODE_CONFIG}
                    goto CLEAN_EXIT
                endif
                /bin/echo "${LI_FILE}|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
                log_msg INFO phase8 libinput-file "backup created at ${BACKUP_FILE}"
            endif
            /bin/mv -f "${LI_TMP}" "${LI_FILE}"
            if ( $status != 0 ) then
                if ( $?BACKUP_FILE ) /bin/cp -p "${BACKUP_FILE}" "${LI_FILE}" >& /dev/null
                set ROLLBACK_OCCURRED = 1
                log_msg ERROR phase8 libinput-file "atomic replace failed for ${LI_FILE}"
                set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
                goto CLEAN_EXIT
            endif
            /bin/echo "${RUN_ID}|${LI_FILE}|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
            log_msg OK phase8 libinput-file "${LI_FILE} written"
        endif
    else
        log_msg SKIP phase8 libinput-file "existing libinput configuration already present"
    endif

    log_msg SKIP phase8 video-permissions "explicit DRI stanza not required; relying on autodetection and video group"

    mark_checkpoint phase8
    log_msg OK phase8 end "X11 configuration completed"
endif

#
# phase 9: user provisioning
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase9" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase9 resume "checkpoint already completed"
else
    log_msg INFO phase9 start "provisioning user session files and group membership"

    pw groupshow video >/dev/null 2>&1
    if ( $status != 0 ) then
        pw groupadd video >/dev/null 2>&1
        if ( $status != 0 ) then
            log_msg ERROR phase9 video-group "failed to create video group"
            set EXIT_CODE = ${EXIT_CODE_CONFIG}
            goto CLEAN_EXIT
        endif
        log_msg OK phase9 video-group "created missing video group"
    endif

    id -Gn "${TARGET_USER}" | tr ' ' '\n' | grep -qx "video" >/dev/null 2>&1
    if ( $status != 0 ) then
        pw groupmod video -m "${TARGET_USER}" >/dev/null 2>&1
        if ( $status != 0 ) then
            log_msg ERROR phase9 video-group "failed to add ${TARGET_USER} to video group"
            set EXIT_CODE = ${EXIT_CODE_CONFIG}
            goto CLEAN_EXIT
        endif
        NEED_RELOGIN = 1
        log_msg OK phase9 video-group "added ${TARGET_USER} to video group"
    else
        log_msg SKIP phase9 video-group "${TARGET_USER} already in video group"
    endif

    /bin/mkdir -p "${TARGET_HOME}/.config/turkishvan-bsd"
    if ( $status != 0 ) then
        log_msg ERROR phase9 user-dir "failed to create ${TARGET_HOME}/.config/turkishvan-bsd"
        set EXIT_CODE = ${EXIT_CODE_CONFIG}
        goto CLEAN_EXIT
    endif
    chown -R "${TARGET_USER}:${TARGET_GROUP}" "${TARGET_HOME}/.config"
    chmod 0755 "${TARGET_HOME}/.config" "${TARGET_HOME}/.config/turkishvan-bsd" >& /dev/null

    foreach GNUSTEP_CAND ( /usr/local/share/GNUstep/Makefiles/GNUstep.csh /usr/local/lib/GNUstep/System/Library/Makefiles/GNUstep.csh /usr/local/GNUstep/System/Library/Makefiles/GNUstep.csh )
        if ( -r "${GNUSTEP_CAND}" ) set GNUSTEP_ENV = "${GNUSTEP_CAND}"
    end
    if ( "${GNUSTEP_ENV}" == "" ) then
        set GNUSTEP_ENV = `find /usr/local -type f \( -name 'GNUstep.csh' -o -name 'GNUstep-login.csh' -o -name 'GNUstep.conf.csh' \) 2>/dev/null | head -n 1`
    endif
    if ( "${GNUSTEP_ENV}" == "" ) then
        set GNUSTEP_ENV = `("${PKG_BIN}" info -l gnustep 2>/dev/null; "${PKG_BIN}" info -l gnustep-back 2>/dev/null; "${PKG_BIN}" info -l gnustep-make 2>/dev/null) | awk '$1 ~ /^\/.*\.csh$/ && tolower($1) ~ /gnustep/ {print $1; exit}'`
    endif
    if ( "${GNUSTEP_ENV}" == "" || ! -r "${GNUSTEP_ENV}" ) then
        log_msg ERROR phase9 gnustep-env "GNUstep appears installed but no readable csh-compatible environment script was found"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase9 gnustep-env "using GNUstep environment script ${GNUSTEP_ENV}"

    set XSESSION_FILE = "${TARGET_HOME}/.xsession"
    set XSESSION_TMP = `mktemp "${STATE_DIR}/xsession.XXXXXX"`
    cat >! "${XSESSION_TMP}" <<EOF
#!/bin/csh -f
# ${PROJECT_NAME}
# ${STATUS_TEXT}
${MANAGED_BEGIN}
set path = ( /usr/local/sbin /usr/local/bin /sbin /bin /usr/sbin /usr/bin )

if ( -r "${GNUSTEP_ENV}" ) then
    source "${GNUSTEP_ENV}"
else
    /bin/echo "turkishvan-bsd: missing GNUstep environment script ${GNUSTEP_ENV}" >>! "\$HOME/.xsession-errors"
endif

setenv XDG_CURRENT_DESKTOP GNUstep
setenv DESKTOP_SESSION GNUstep
setenv WINDOW_MANAGER WindowMaker
setenv GNUSTEP_IS_FLATTENED YES

if ( -x /usr/local/bin/wmaker ) then
    /usr/local/bin/wmaker
    set _wm_status = \$status
    /bin/echo "turkishvan-bsd: Window Maker exited with status \${_wm_status}; falling back to xterm" >>! "\$HOME/.xsession-errors"
endif

if ( -x /usr/local/bin/xterm ) then
    exec /usr/local/bin/xterm -T "turkishvan-bsd recovery shell"
else if ( -x /usr/bin/xterm ) then
    exec /usr/bin/xterm -T "turkishvan-bsd recovery shell"
else
    exec /bin/csh -f
endif
${MANAGED_END}
EOF

    if ( -e "${XSESSION_FILE}" ) then
        cmp -s "${XSESSION_FILE}" "${XSESSION_TMP}"
    else
        false
    endif
    if ( $status == 0 ) then
        /bin/rm -f "${XSESSION_TMP}"
        log_msg SKIP phase9 xsession "${XSESSION_FILE} already converged"
    else
        if ( -e "${XSESSION_FILE}" ) then
            set SAFE_PATH = `echo "${XSESSION_FILE}" | sed 's#^/##; s#[/[:space:]]#_#g'`
            set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
            /bin/cp -p "${XSESSION_FILE}" "${BACKUP_FILE}"
            if ( $status != 0 ) then
                /bin/rm -f "${XSESSION_TMP}"
                log_msg ERROR phase9 xsession "failed to back up ${XSESSION_FILE}"
                set EXIT_CODE = ${EXIT_CODE_CONFIG}
                goto CLEAN_EXIT
            endif
            /bin/echo "${XSESSION_FILE}|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
            log_msg WARN phase9 xsession "replacing existing user file after backup ${BACKUP_FILE}"
        endif
        /bin/mv -f "${XSESSION_TMP}" "${XSESSION_FILE}"
        if ( $status != 0 ) then
            if ( $?BACKUP_FILE ) /bin/cp -p "${BACKUP_FILE}" "${XSESSION_FILE}" >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase9 xsession "atomic replace failed for ${XSESSION_FILE}"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        chown "${TARGET_USER}:${TARGET_GROUP}" "${XSESSION_FILE}"
        chmod 0755 "${XSESSION_FILE}"
        /bin/echo "${RUN_ID}|${XSESSION_FILE}|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase9 xsession "${XSESSION_FILE} written"
    endif

    set XINITRC_FILE = "${TARGET_HOME}/.xinitrc"
    set XINITRC_TMP = `mktemp "${STATE_DIR}/xinitrc.XXXXXX"`
    cat >! "${XINITRC_TMP}" <<'EOF'
#!/bin/csh -f
# turkishvan-bsd
# BEGIN turkishvan-bsd managed block
if ( -x "$HOME/.xsession" ) then
    exec "$HOME/.xsession"
else
    exec /bin/csh -f
endif
# END turkishvan-bsd managed block
EOF

    if ( -e "${XINITRC_FILE}" ) then
        cmp -s "${XINITRC_FILE}" "${XINITRC_TMP}"
    else
        false
    endif
    if ( $status == 0 ) then
        /bin/rm -f "${XINITRC_TMP}"
        log_msg SKIP phase9 xinitrc "${XINITRC_FILE} already converged"
    else
        if ( -e "${XINITRC_FILE}" ) then
            set SAFE_PATH = `echo "${XINITRC_FILE}" | sed 's#^/##; s#[/[:space:]]#_#g'`
            set BACKUP_FILE = "${BACKUP_DIR}/${SAFE_PATH}.${RUN_ID}.bak"
            /bin/cp -p "${XINITRC_FILE}" "${BACKUP_FILE}"
            if ( $status != 0 ) then
                /bin/rm -f "${XINITRC_TMP}"
                log_msg ERROR phase9 xinitrc "failed to back up ${XINITRC_FILE}"
                set EXIT_CODE = ${EXIT_CODE_CONFIG}
                goto CLEAN_EXIT
            endif
            /bin/echo "${XINITRC_FILE}|${BACKUP_FILE}" >>! "${ROLLBACK_MANIFEST}"
            log_msg WARN phase9 xinitrc "replacing existing user file after backup ${BACKUP_FILE}"
        endif
        /bin/mv -f "${XINITRC_TMP}" "${XINITRC_FILE}"
        if ( $status != 0 ) then
            if ( $?BACKUP_FILE ) /bin/cp -p "${BACKUP_FILE}" "${XINITRC_FILE}" >& /dev/null
            set ROLLBACK_OCCURRED = 1
            log_msg ERROR phase9 xinitrc "atomic replace failed for ${XINITRC_FILE}"
            set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
            goto CLEAN_EXIT
        endif
        chown "${TARGET_USER}:${TARGET_GROUP}" "${XINITRC_FILE}"
        chmod 0755 "${XINITRC_FILE}"
        /bin/echo "${RUN_ID}|${XINITRC_FILE}|${BACKUP_FILE}" >>! "${CHANGE_MANIFEST}"
        log_msg OK phase9 xinitrc "${XINITRC_FILE} written"
    endif

    if ( ${BACKLIGHT_MANAGEABLE} == 1 ) then
        set BRIGHTNESS_HELPER = "${TARGET_HOME}/.config/turkishvan-bsd/brightness.csh"
        set BRIGHTNESS_TMP = `mktemp "${STATE_DIR}/brightness.XXXXXX"`
        cat >! "${BRIGHTNESS_TMP}" <<'EOF'
#!/bin/csh -f
set path = ( /usr/local/sbin /usr/local/bin /sbin /bin /usr/sbin /usr/bin )

if ( $#argv < 1 ) then
    /bin/echo "usage: $0 up|down|set <value>"
    exit 20
endif

set max = `sysctl -n hw.backlight_max 2>/dev/null`
set cur = `sysctl -n hw.backlight_level 2>/dev/null`
if ( "$max" == "" || "$cur" == "" ) then
    /bin/echo "backlight sysctls are unavailable on this machine"
    exit 60
endif

switch ( "$1" )
    case "up":
        @ new = $cur + 10
        breaksw
    case "down":
        @ new = $cur - 10
        breaksw
    case "set":
        if ( $#argv < 2 ) then
            /bin/echo "usage: $0 set <value>"
            exit 20
        endif
        set new = "$2"
        breaksw
    default:
        /bin/echo "usage: $0 up|down|set <value>"
        exit 20
endsw

if ( $new < 0 ) set new = 0
if ( $new > $max ) set new = $max

if ( `id -u` != 0 ) then
    /bin/echo "root privileges are required to change hw.backlight_level"
    /bin/echo "try: su root -c 'sysctl hw.backlight_level=$new'"
    exit 10
endif

sysctl hw.backlight_level=$new
EOF
        if ( -e "${BRIGHTNESS_HELPER}" ) then
            cmp -s "${BRIGHTNESS_HELPER}" "${BRIGHTNESS_TMP}"
        else
            false
        endif
        if ( $status == 0 ) then
            /bin/rm -f "${BRIGHTNESS_TMP}"
            log_msg SKIP phase9 brightness-helper "${BRIGHTNESS_HELPER} already converged"
        else
            /bin/mv -f "${BRIGHTNESS_TMP}" "${BRIGHTNESS_HELPER}"
            if ( $status != 0 ) then
                set ROLLBACK_OCCURRED = 1
                log_msg ERROR phase9 brightness-helper "failed to write ${BRIGHTNESS_HELPER}"
                set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
                goto CLEAN_EXIT
            endif
            chown "${TARGET_USER}:${TARGET_GROUP}" "${BRIGHTNESS_HELPER}"
            chmod 0755 "${BRIGHTNESS_HELPER}"
            log_msg OK phase9 brightness-helper "generated ${BRIGHTNESS_HELPER}"
        endif
    else
        log_msg SKIP phase9 brightness-helper "backlight helper not required on this hardware"
    endif

    mark_checkpoint phase9
    log_msg OK phase9 end "user provisioning completed"
endif

#
# phase 10: audio configuration
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase10" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase10 resume "checkpoint already completed"
else
    log_msg INFO phase10 start "converging audio defaults and validation"

    if ( -r /dev/sndstat ) then
        if ( ${AUDIO_COUNT} > 0 ) then
            if ( "${SELECTED_AUDIO_UNIT}" != "" ) then
                sysctl hw.snd.default_unit="${SELECTED_AUDIO_UNIT}" >/dev/null 2>&1
                if ( $status == 0 ) then
                    log_msg OK phase10 select-default "runtime default audio set to unit ${SELECTED_AUDIO_UNIT}"
                else
                    log_msg WARN phase10 select-default "runtime default audio set failed for unit ${SELECTED_AUDIO_UNIT}"
                endif
            endif

            grep -Eq "^pcm${SELECTED_AUDIO_UNIT}:" /dev/sndstat >/dev/null 2>&1
            if ( "${SELECTED_AUDIO_UNIT}" != "" && $status == 0 ) then
                log_msg OK phase10 validate-device "selected default device pcm${SELECTED_AUDIO_UNIT} exists"
            else if ( "${SELECTED_AUDIO_UNIT}" == "" ) then
                log_msg WARN phase10 validate-device "no selected audio unit despite detected devices"
            else
                log_msg ERROR phase10 validate-device "selected audio device pcm${SELECTED_AUDIO_UNIT} is not present"
                set EXIT_CODE = ${EXIT_CODE_VALIDATE}
                goto CLEAN_EXIT
            endif
        else
            log_msg WARN phase10 detect-audio "no PCM devices detected"
        endif
    else
        log_msg WARN phase10 detect-audio "/dev/sndstat is not available"
    endif

    log_msg INFO phase10 rationale "audio plan ${AUDIO_PLAN_CLASS}; rationale ${AUDIO_PLAN_REASON}"

    mark_checkpoint phase10
    log_msg OK phase10 end "audio configuration completed"
endif

#
# phase 11: video and display configuration
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase11" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase11 resume "checkpoint already completed"
else
    log_msg INFO phase11 start "validating DRM/Xorg display path"

    if ( "${XORG_BIN}" == "" ) set XORG_BIN = `which Xorg 2>/dev/null`
    if ( "${XORG_BIN}" == "" && -x /usr/local/bin/Xorg ) set XORG_BIN = "/usr/local/bin/Xorg"
    if ( "${XORG_BIN}" == "" ) then
        log_msg ERROR phase11 validate-xorg "Xorg binary not found"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase11 validate-xorg "Xorg binary found at ${XORG_BIN}"

    if ( "${XDM_BIN}" == "" ) set XDM_BIN = `which xdm 2>/dev/null`
    if ( "${XDM_BIN}" == "" && -x /usr/local/bin/xdm ) set XDM_BIN = "/usr/local/bin/xdm"
    if ( "${XDM_BIN}" == "" ) then
        log_msg ERROR phase11 validate-xdm "xdm binary not found"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase11 validate-xdm "xdm binary found at ${XDM_BIN}"

    if ( ! -f /etc/X11/xorg.conf.d/00-keyboard.conf ) then
        log_msg ERROR phase11 validate-keyboard "/etc/X11/xorg.conf.d/00-keyboard.conf is missing"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase11 validate-keyboard "keyboard drop-in present"

    id -Gn "${TARGET_USER}" | tr ' ' '\n' | grep -qx "video" >/dev/null 2>&1
    if ( $status != 0 ) then
        log_msg ERROR phase11 validate-video-group "${TARGET_USER} is not in video group"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK phase11 validate-video-group "${TARGET_USER} has video group membership"

    log_msg INFO phase11 gpu-plan "using conservative DRM/Xorg plan ${GPU_PLAN} with Xorg autodetection"

    mark_checkpoint phase11
    log_msg OK phase11 end "video and display validation completed"
endif

#
# phase 12: XDM enablement
#

set SKIP_PHASE = 0
if ( -e "${CHECKPOINT_FILE}" && ${FORCE} == 0 ) then
    grep -qx "phase12" "${CHECKPOINT_FILE}" >/dev/null 2>&1
    if ( $status == 0 ) set SKIP_PHASE = 1
endif

if ( ${SKIP_PHASE} == 1 ) then
    log_msg SKIP phase12 resume "checkpoint already completed"
else
    log_msg INFO phase12 start "handling XDM activation mode"

    if ( ${ACTIVATE_NOW} == 1 ) then
        kill -HUP 1 >& /dev/null
        if ( $status == 0 ) then
            set XDM_ACTIVATION_MODE = "SUCCESS_ACTIVE"
            log_msg OK phase12 activate-now "init reload requested; XDM activation attempted"
            set NEED_REBOOT = 0
        else
            set XDM_ACTIVATION_MODE = "SUCCESS_PENDING_REBOOT"
            set NEED_REBOOT = 1
            log_msg WARN phase12 activate-now "init reload failed; reboot or manual init reload required"
        endif
    else
        pgrep -f xdm >/dev/null 2>&1
        if ( $status == 0 ) then
            set XDM_ACTIVATION_MODE = "SUCCESS_ACTIVE"
            log_msg OK phase12 activate "xdm process already active"
        else
            set XDM_ACTIVATION_MODE = "SUCCESS_PENDING_REBOOT"
            set NEED_REBOOT = 1
            log_msg WARN phase12 activate "xdm configured but left pending reboot or init reload by conservative policy"
        endif
    endif

    mark_checkpoint phase12
    log_msg OK phase12 end "XDM enablement handling completed"
endif

#
# final validation checklist
#

log_msg INFO final start "running final validation checklist"

id "${TARGET_USER}" >/dev/null 2>&1
if ( $status != 0 || ! -d "${TARGET_HOME}" ) then
    log_msg ERROR final validate-user "target user or home directory validation failed"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif
log_msg OK final validate-user "target user and home directory verified"

id -Gn "${TARGET_USER}" | tr ' ' '\n' | grep -qx "video" >/dev/null 2>&1
if ( $status != 0 ) then
    log_msg ERROR final validate-video "target user is not in video group"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif
log_msg OK final validate-video "target user is in video group"

foreach REQUIRED_PKG ( xorg xdm gnustep gnustep-back windowmaker )
    "${PKG_BIN}" info -e "${REQUIRED_PKG}" >/dev/null 2>&1
    if ( $status != 0 ) then
        log_msg ERROR final validate-pkg "required package ${REQUIRED_PKG} is not installed"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
end
log_msg OK final validate-pkg "required core package set installed"

grep -Eq '^[[:space:]]*ttyv8[[:space:]]+.*[[:space:]]on[[:space:]]' /etc/ttys >/dev/null 2>&1
if ( $status != 0 ) then
    log_msg ERROR final validate-ttys "/etc/ttys does not enable ttyv8 for xdm"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif
log_msg OK final validate-ttys "ttyv8 xdm enablement present"

if ( ! -f /etc/X11/xorg.conf.d/00-keyboard.conf ) then
    log_msg ERROR final validate-keyboard "keyboard config file missing"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif
log_msg OK final validate-keyboard "keyboard config file exists"

if ( ! -f "${TARGET_HOME}/.xsession" ) then
    log_msg ERROR final validate-session "user session file ${TARGET_HOME}/.xsession missing"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif
log_msg OK final validate-session "user session file exists"

grep -Fqx "${MANAGED_BEGIN}" /etc/sysctl.conf >/dev/null 2>&1
if ( $status != 0 ) then
    log_msg ERROR final validate-sysctl "managed sysctl block missing"
    set EXIT_CODE = ${EXIT_CODE_VALIDATE}
    goto CLEAN_EXIT
endif
log_msg OK final validate-sysctl "managed sysctl block exists"

if ( -r /dev/sndstat && ${AUDIO_COUNT} > 0 ) then
    grep -Eq "^pcm${SELECTED_AUDIO_UNIT}:" /dev/sndstat >/dev/null 2>&1
    if ( $status != 0 ) then
        log_msg ERROR final validate-audio "selected default audio device pcm${SELECTED_AUDIO_UNIT} is missing"
        set EXIT_CODE = ${EXIT_CODE_VALIDATE}
        goto CLEAN_EXIT
    endif
    log_msg OK final validate-audio "selected default audio device exists"
else
    log_msg WARN final validate-audio "audio device validation skipped because no PCM devices were detected"
endif

log_msg OK final validate-log "final summary will be written to log"
log_msg INFO final summary "gpu_plan=${GPU_PLAN} audio_plan=${AUDIO_PLAN_CLASS} selected_audio_unit=${SELECTED_AUDIO_UNIT} xdm_mode=${XDM_ACTIVATION_MODE}"

goto CLEAN_EXIT

HANDLE_INTERRUPT:
log_msg ERROR signal interrupt "received interrupt signal"
if ( ${ROLLBACK_OCCURRED} == 1 ) then
    set EXIT_CODE = ${EXIT_CODE_ROLLBACK}
else if ( ${EXIT_CODE} == 0 ) then
    set EXIT_CODE = ${EXIT_CODE_INTERNAL}
endif
goto CLEAN_EXIT

CLEAN_EXIT:
if ( ${EXIT_CODE} == 0 ) then
    if ( ${NEED_REBOOT} == 1 || ${NEED_RELOGIN} == 1 ) then
        set EXIT_CODE = ${EXIT_CODE_REBOOT}
    else
        set EXIT_CODE = ${EXIT_CODE_SUCCESS}
    endif
endif

cat >! "${LAST_RUN_FILE}" <<EOF
run_id=${RUN_ID}
timestamp=${RUN_TS}
hostname=${HOSTNAME_SHORT}
username=${TARGET_USER}
keyboard=${KEYBOARD_LAYOUT}
gpu_plan=${GPU_PLAN}
audio_plan=${AUDIO_PLAN_CLASS}
selected_audio_unit=${SELECTED_AUDIO_UNIT}
need_reboot=${NEED_REBOOT}
need_relogin=${NEED_RELOGIN}
xdm_activation_mode=${XDM_ACTIVATION_MODE}
rollback_occurred=${ROLLBACK_OCCURRED}
exit_code=${EXIT_CODE}
log_file=${LOG_FILE}
EOF

if ( ${EXIT_CODE} == ${EXIT_CODE_SUCCESS} ) then
    log_msg OK final exit "success; fully converged with no reboot required"
else if ( ${EXIT_CODE} == ${EXIT_CODE_REBOOT} ) then
    log_msg WARN final exit "success with reboot or relogin required"
else
    log_msg ERROR final exit "run failed with exit code ${EXIT_CODE}"
endif

if ( -e "${LOCK_FILE}" ) /bin/rm -f "${LOCK_FILE}"
exit ${EXIT_CODE}
