#!/bin/csh -f

umask 022
set path = ( /sbin /bin /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin $path )
rehash

set SCRIPT_NAME = "turkishvan-bsd"
set VERSION = "draft-v1"
set UTC_NOW = `date -u +"%Y%m%dT%H%M%SZ"`
set RUN_ID = "${UTC_NOW}-$$"
set HOSTNAME = `hostname -s 2>/dev/null`
if ( "$HOSTNAME" == "" ) set HOSTNAME = `hostname`
set BASE_LOG_DIR = "/var/log/${SCRIPT_NAME}"
set BASE_STATE_DIR = "/var/db/${SCRIPT_NAME}"
set BASE_BACKUP_DIR = "/var/backups/${SCRIPT_NAME}"
set LOCKFILE = "${BASE_STATE_DIR}/run.lock"
set LOGFILE = "${BASE_LOG_DIR}/${RUN_ID}.log"
set CHECKPOINT_FILE = "${BASE_STATE_DIR}/checkpoint.state"
set LASTRUN_FILE = "${BASE_STATE_DIR}/last-run.state"
set PACKAGE_SNAPSHOT = "${BASE_STATE_DIR}/package.snapshot"
set HARDWARE_SNAPSHOT = "${BASE_STATE_DIR}/hardware.snapshot"
set CHANGE_MANIFEST = "${BASE_STATE_DIR}/change.manifest"
set ROLLBACK_MANIFEST = "${BASE_STATE_DIR}/rollback.manifest"
set REBOOT_REQUIRED_FILE = "${BASE_STATE_DIR}/reboot.required"
set SUMMARY_FILE = "${BASE_STATE_DIR}/final.summary"
set INVOCATION_FILE = "${BASE_STATE_DIR}/invocation.state"
set BEGIN_MARK = "# BEGIN turkishvan-bsd managed block"
set END_MARK = "# END turkishvan-bsd managed block"
set CURRENT_PHASE = "bootstrap"
set LOG_LEVEL = "INFO"
set LOG_STEP = "start"
set LOG_MSG = "initializing"
set EXIT_CODE = 0
set NEED_REBOOT = 0
set NEED_RELOGIN = 0
set XDM_MODE = "SUCCESS_PENDING_REBOOT"
set RESUME_MODE = 1
set FORCE_MODE = 0
set VERBOSE = 0
set SKIP_UPGRADE = 0
set IMMEDIATE_XDM = 0
set TARGET_USER = ""
set KEYBOARD_LAYOUT = ""
set TARGET_HOME = ""
set GROUP_CHANGED = 0
set AUDIO_SELECTED_UNIT = ""
set AUDIO_DEVICE_COUNT = 0
set AUDIO_DEFAULT_REASON = ""
set AUDIO_PROFILE = "no-detected-audio"
set GPU_PLAN = "unknown-generic"
set BACKLIGHT_MANAGEABLE = 0
set GNUSTEP_CSH_INIT = ""
set GNUSTEP_ENV_MODE = ""
set PKG_XORG = ""
set PKG_INPUT_LIBINPUT = ""
set PKG_INPUT_EVDEV = ""
set PKG_XDM = ""
set PKG_GNUSTEP = ""
set PKG_GNUSTEP_BACK = ""
set PKG_WINDOWMAKER = ""
set PKG_TERMINAL = ""
set TERMINAL_BIN = "xterm"
set PKG_EDITOR = ""
set PKG_BROWSER = ""
set PKG_CURL = "curl"
set PKG_WGET = "wget"
set PKG_RSYNC = "rsync"
set PKG_GIT = "git"
set PKG_OFFICE = ""
set PKG_PDFVIEW = ""
set PKG_FILEMGR = ""
set PKG_SYSMON = ""
set PKG_ZIP = "zip"
set PKG_UNZIP = "unzip"
set PKG_P7ZIP = "p7zip"
set PKG_CLIP = ""
set PKG_FONTS = ""
set PKG_VIDEO = ""
set PKG_AUDIO = ""
set PKG_TRANSCODER = ""
set PKG_AUDIO_UTIL = ""
set PKG_IMAGE = ""
set PKG_SCREENSHOT = ""
set LAST_COMPLETED_PHASE = 0
set KEYBOARD_VALIDATED = 0
set KEYBOARD_VALIDATION_SOURCE = "none"
set DEFERRED_KEYBOARD_VALIDATE = 0
set PHASE_SHOULD_RUN = 1
set FATAL_MESSAGE = ""
set FATAL_STEP = ""

/bin/mkdir -p "$BASE_LOG_DIR" "$BASE_STATE_DIR" "$BASE_BACKUP_DIR"
if ( ! -e "$LOGFILE" ) /usr/bin/touch "$LOGFILE"

alias logline 'set __ts=`date -u +"%Y-%m-%dT%H:%M:%SZ"`; /bin/echo "${__ts} ${LOG_LEVEL} ${CURRENT_PHASE} ${LOG_STEP} ${LOG_MSG}"; /bin/echo "${__ts} ${LOG_LEVEL} ${CURRENT_PHASE} ${LOG_STEP} ${LOG_MSG}" >>! "$LOGFILE"'

onintr handle_interrupt

if ( $#argv < 4 ) then
    /bin/echo "usage: ${SCRIPT_NAME}.csh --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose] [--skip-upgrade] [--immediate-xdm]"
    exit 20
endif

@ argi = 1
while ( $argi <= $#argv )
    switch ( "$argv[$argi]" )
        case --username:
            @ argi++
            if ( $argi > $#argv ) then
                /bin/echo "usage: ${SCRIPT_NAME}.csh --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose] [--skip-upgrade] [--immediate-xdm]"
                exit 20
            endif
            set TARGET_USER = "$argv[$argi]"
            breaksw
        case --keyboard:
            @ argi++
            if ( $argi > $#argv ) then
                /bin/echo "usage: ${SCRIPT_NAME}.csh --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose] [--skip-upgrade] [--immediate-xdm]"
                exit 20
            endif
            set KEYBOARD_LAYOUT = "$argv[$argi]"
            breaksw
        case --resume:
            set RESUME_MODE = 1
            breaksw
        case --force:
            set FORCE_MODE = 1
            breaksw
        case --verbose:
            set VERBOSE = 1
            breaksw
        case --skip-upgrade:
            set SKIP_UPGRADE = 1
            breaksw
        case --immediate-xdm:
            set IMMEDIATE_XDM = 1
            breaksw
        default:
            /bin/echo "usage: ${SCRIPT_NAME}.csh --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose] [--skip-upgrade] [--immediate-xdm]"
            exit 20
            breaksw
    endsw
    @ argi++
end

if ( "$TARGET_USER" == "" || "$KEYBOARD_LAYOUT" == "" ) then
    /bin/echo "usage: ${SCRIPT_NAME}.csh --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose] [--skip-upgrade] [--immediate-xdm]"
    exit 20
endif

set CURRENT_PHASE = "phase0"
set LOG_LEVEL = "INFO"
set LOG_STEP = "bootstrap-logging"
set LOG_MSG = "state directories ready; starting run ${RUN_ID}"
logline

if ( -e "$LOCKFILE" ) then
    set STALE_LOCK = 1
    set LOCK_PID = `awk -F= '/^pid=/{print $2}' "$LOCKFILE" 2>/dev/null`
    set LOCK_HOST = `awk -F= '/^hostname=/{print $2}' "$LOCKFILE" 2>/dev/null`
    if ( "$LOCK_PID" != "" && "$LOCK_HOST" == "$HOSTNAME" ) then
        /bin/kill -0 "$LOCK_PID" >/dev/null 2>&1
        if ( $status == 0 ) then
            set STALE_LOCK = 0
        endif
    endif
    if ( $STALE_LOCK == 1 ) then
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "lock"
        set LOG_MSG = "stale lock detected at ${LOCKFILE}; removing"
        logline
        /bin/rm -f "$LOCKFILE"
    else
        set LOG_LEVEL = "ERROR"
        set LOG_STEP = "lock"
        set LOG_MSG = "active lock held by pid ${LOCK_PID} on ${LOCK_HOST}; refusing concurrent execution"
        logline
        exit 70
    endif
endif

set LOCKTMP = "${BASE_STATE_DIR}/.run.lock.${RUN_ID}.tmp"
/bin/rm -f "$LOCKTMP"
/bin/echo "pid=$$" >! "$LOCKTMP"
/bin/echo "timestamp=${UTC_NOW}" >> "$LOCKTMP"
/bin/echo "hostname=${HOSTNAME}" >> "$LOCKTMP"
/bin/echo "run_id=${RUN_ID}" >> "$LOCKTMP"
/bin/mv -f "$LOCKTMP" "$LOCKFILE"
if ( $status != 0 ) then
    set LOG_LEVEL = "ERROR"
    set LOG_STEP = "lock"
    set LOG_MSG = "failed to create lock ${LOCKFILE}"
    logline
    exit 70
endif

set LOG_LEVEL = "OK"
set LOG_STEP = "lock"
set LOG_MSG = "lock acquired at ${LOCKFILE}"
logline

/bin/rm -f "$CHANGE_MANIFEST" "$ROLLBACK_MANIFEST" "$REBOOT_REQUIRED_FILE"
/usr/bin/touch "$CHANGE_MANIFEST" "$ROLLBACK_MANIFEST"

set INVTMP = "${BASE_STATE_DIR}/.invocation.${RUN_ID}.tmp"
/bin/rm -f "$INVTMP"
/bin/echo "set RUN_ID = \"${RUN_ID}\"" >! "$INVTMP"
/bin/echo "set RUN_UTC = \"${UTC_NOW}\"" >> "$INVTMP"
/bin/echo "set TARGET_USER = \"${TARGET_USER}\"" >> "$INVTMP"
/bin/echo "set KEYBOARD_LAYOUT = \"${KEYBOARD_LAYOUT}\"" >> "$INVTMP"
/bin/echo "set RESUME_MODE = \"${RESUME_MODE}\"" >> "$INVTMP"
/bin/echo "set FORCE_MODE = \"${FORCE_MODE}\"" >> "$INVTMP"
/bin/echo "set VERBOSE = \"${VERBOSE}\"" >> "$INVTMP"
/bin/echo "set SKIP_UPGRADE = \"${SKIP_UPGRADE}\"" >> "$INVTMP"
/bin/echo "set IMMEDIATE_XDM = \"${IMMEDIATE_XDM}\"" >> "$INVTMP"
/bin/mv -f "$INVTMP" "$INVOCATION_FILE"

if ( -e "$CHECKPOINT_FILE" ) then
    set LAST_COMPLETED_PHASE = `awk -F= '/^phase=/{print $2}' "$CHECKPOINT_FILE" 2>/dev/null`
    if ( "$LAST_COMPLETED_PHASE" == "" ) set LAST_COMPLETED_PHASE = 0
else
    set LAST_COMPLETED_PHASE = 0
endif

set LOG_LEVEL = "INFO"
set LOG_STEP = "checkpoint"
set LOG_MSG = "last completed phase is ${LAST_COMPLETED_PHASE}"
logline

###############################################################################
# Phase 1: preflight validation
###############################################################################
set CURRENT_PHASE = "phase1"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 1 ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "preflight validation begins"
    logline

    set OS_NAME = `uname -s`
    if ( "$OS_NAME" != "DragonFly" ) then
        set FATAL_STEP = "detect-os"
        set FATAL_MESSAGE = "uname -s returned ${OS_NAME}; DragonFlyBSD required"
        set EXIT_CODE = 30
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "detect-os"
    set LOG_MSG = "DragonFlyBSD confirmed"
    logline

    if ( "$shell" !~ */csh && "$shell" !~ */tcsh ) then
        set FATAL_STEP = "detect-shell"
        set FATAL_MESSAGE = "executing shell is ${shell}; csh-compatible execution is required"
        set EXIT_CODE = 30
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "detect-shell"
    set LOG_MSG = "csh-compatible shell confirmed: ${shell}"
    logline

    if ( "$USER" != "root" && `id -u` != 0 ) then
        set FATAL_STEP = "detect-root"
        set FATAL_MESSAGE = "script must run as root"
        set EXIT_CODE = 30
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "detect-root"
    set LOG_MSG = "root privileges confirmed"
    logline

    id "$TARGET_USER" >/dev/null 2>&1
    if ( $status != 0 ) then
        set FATAL_STEP = "validate-user"
        set FATAL_MESSAGE = "target user ${TARGET_USER} does not exist"
        set EXIT_CODE = 30
        goto fatal_exit
    endif
    if ( "$TARGET_USER" == "root" ) then
        set FATAL_STEP = "validate-user"
        set FATAL_MESSAGE = "target user must not be root"
        set EXIT_CODE = 30
        goto fatal_exit
    endif
    set TARGET_HOME = `eval echo ~${TARGET_USER}`
    if ( "$TARGET_HOME" == "~${TARGET_USER}" || ! -d "$TARGET_HOME" ) then
        set FATAL_STEP = "validate-home"
        set FATAL_MESSAGE = "target home for ${TARGET_USER} is invalid: ${TARGET_HOME}"
        set EXIT_CODE = 30
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "validate-user"
    set LOG_MSG = "target user ${TARGET_USER} with home ${TARGET_HOME} confirmed"
    logline

    pkg -N >/dev/null 2>&1
    if ( $status != 0 ) then
        which pkg >/dev/null 2>&1
        if ( $status != 0 ) then
            set FATAL_STEP = "validate-pkg"
            set FATAL_MESSAGE = "pkg is not available in PATH and cannot be validated"
            set EXIT_CODE = 30
            goto fatal_exit
        endif
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "validate-pkg"
        set LOG_MSG = "pkg present but not initialized; bootstrap will be attempted later"
        logline
    else
        set LOG_LEVEL = "OK"
        set LOG_STEP = "validate-pkg"
        set LOG_MSG = "pkg is available"
        logline
    endif

    foreach cmd ( uname id awk sed grep cut sort tr tee mkdir mv cp rm stat find pciconf kldstat sysctl hostname date touch pkg pw )
        which "$cmd" >/dev/null 2>&1
        if ( $status != 0 ) then
            set FATAL_STEP = "validate-command"
            set FATAL_MESSAGE = "required command ${cmd} is missing"
            set EXIT_CODE = 30
            goto fatal_exit
        endif
    end
    set LOG_LEVEL = "OK"
    set LOG_STEP = "validate-commands"
    set LOG_MSG = "essential commands are present"
    logline

    set XKB_RULES_FILE = ""
    foreach candidate ( /usr/local/share/X11/xkb/rules/base.lst /usr/local/share/X11/xkb/rules/evdev.lst /usr/X11R6/share/X11/xkb/rules/base.lst /usr/X11R6/share/X11/xkb/rules/evdev.lst )
        if ( -r "$candidate" ) then
            set XKB_RULES_FILE = "$candidate"
            break
        endif
    end
    if ( "$XKB_RULES_FILE" != "" ) then
        awk -v target="$KEYBOARD_LAYOUT" '
            BEGIN { in_layout = 0; found = 0 }
            /^! layout/ { in_layout = 1; next }
            /^!/ && $2 != "layout" { if (in_layout == 1) exit }
            in_layout == 1 {
                if ($1 == target) found = 1
            }
            END { exit(found ? 0 : 1) }
        ' "$XKB_RULES_FILE" >/dev/null 2>&1
        if ( $status == 0 ) then
            set KEYBOARD_VALIDATED = 1
            set KEYBOARD_VALIDATION_SOURCE = "$XKB_RULES_FILE"
        endif
    endif
    if ( $KEYBOARD_VALIDATED == 0 ) then
        foreach symroot ( /usr/local/share/X11/xkb/symbols /usr/X11R6/share/X11/xkb/symbols )
            if ( -r "$symroot/$KEYBOARD_LAYOUT" ) then
                set KEYBOARD_VALIDATED = 1
                set KEYBOARD_VALIDATION_SOURCE = "$symroot/$KEYBOARD_LAYOUT"
                break
            endif
        end
    endif
    if ( $KEYBOARD_VALIDATED == 0 ) then
        switch ( "$KEYBOARD_LAYOUT" )
            case us:
            case uk:
            case gb:
            case br:
            case de:
            case fr:
            case es:
            case it:
            case pt:
            case pl:
            case tr:
            case se:
            case no:
            case dk:
            case fi:
            case nl:
            case be:
            case ch:
            case at:
            case cz:
            case sk:
            case hu:
            case ro:
            case bg:
            case hr:
            case rs:
            case si:
            case ua:
            case ru:
            case jp:
            case kr:
            case latam:
            case ca:
            case il:
            case gr:
                set KEYBOARD_VALIDATED = 1
                set KEYBOARD_VALIDATION_SOURCE = "builtin-common-layouts"
                set DEFERRED_KEYBOARD_VALIDATE = 1
                breaksw
            default:
                breaksw
        endsw
    endif
    if ( $KEYBOARD_VALIDATED == 0 ) then
        set FATAL_STEP = "validate-keyboard"
        set FATAL_MESSAGE = "keyboard layout ${KEYBOARD_LAYOUT} could not be validated against local XKB data"
        set EXIT_CODE = 30
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "validate-keyboard"
    set LOG_MSG = "keyboard layout ${KEYBOARD_LAYOUT} validated via ${KEYBOARD_VALIDATION_SOURCE}"
    logline
    if ( $DEFERRED_KEYBOARD_VALIDATE == 1 ) then
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "validate-keyboard"
        set LOG_MSG = "keyboard layout ${KEYBOARD_LAYOUT} accepted by fallback list; strict XKB revalidation will occur after X packages install"
        logline
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=1" >! "$CPTMP"
    /bin/echo "name=preflight-validation" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 1
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "preflight validation complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 1 already completed; skipping by checkpoint"
    logline
    id "$TARGET_USER" >/dev/null 2>&1
    if ( $status == 0 ) set TARGET_HOME = `eval echo ~${TARGET_USER}`
endif

###############################################################################
# Phase 2: discovery snapshot
###############################################################################
set CURRENT_PHASE = "phase2"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 2 && -r "$HARDWARE_SNAPSHOT" ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "discovery snapshot begins"
    logline

    set DISCOVER_DIR = "${BASE_STATE_DIR}/discovery"
    /bin/mkdir -p "$DISCOVER_DIR"

    uname -a >! "${DISCOVER_DIR}/uname-a.txt"
    pkg -N >! "${DISCOVER_DIR}/pkg-N.txt"
    pkg info >! "${DISCOVER_DIR}/pkg-info.txt"
    pciconf -lv >! "${DISCOVER_DIR}/pciconf-lv.txt"
    kldstat >! "${DISCOVER_DIR}/kldstat.txt"
    if ( -r /dev/sndstat ) then
        cat /dev/sndstat >! "${DISCOVER_DIR}/sndstat.txt"
    else
        /bin/echo "sndstat-unavailable" >! "${DISCOVER_DIR}/sndstat.txt"
    endif
    foreach sctl ( kern.syscons_async hw.snd.default_unit hw.snd.default_auto hw.backlight_max hw.backlight_level )
        sysctl "$sctl" >>! "${DISCOVER_DIR}/sysctl-snapshot.txt" 2>/dev/null
    end
    id "$TARGET_USER" >! "${DISCOVER_DIR}/id-${TARGET_USER}.txt"
    id -Gn "$TARGET_USER" >! "${DISCOVER_DIR}/groups-${TARGET_USER}.txt"
    foreach managed ( /etc/rc.conf /boot/loader.conf /etc/sysctl.conf /etc/ttys )
        if ( -e "$managed" ) then
            set enc = `echo "$managed" | sed 's#/#_#g; s#^_##'`
            /bin/cp -p "$managed" "${DISCOVER_DIR}/${enc}.snapshot"
        endif
    end
    if ( -d /etc/X11 ) then
        find /etc/X11 -maxdepth 3 -type f | sort >! "${DISCOVER_DIR}/x11-filelist.txt"
    else
        /bin/echo "x11-absent" >! "${DISCOVER_DIR}/x11-filelist.txt"
    endif
    foreach ufile ( "$TARGET_HOME/.xsession" "$TARGET_HOME/.xinitrc" )
        if ( -e "$ufile" ) then
            set enc = `echo "$ufile" | sed 's#/#_#g; s#^_##'`
            /bin/cp -p "$ufile" "${DISCOVER_DIR}/${enc}.snapshot"
        endif
    end

    set HWTMP = "${BASE_STATE_DIR}/.hardware.${RUN_ID}.tmp"
    /bin/rm -f "$HWTMP"
    /bin/echo "set SNAPSHOT_DIR = \"${DISCOVER_DIR}\"" >! "$HWTMP"
    /bin/echo "set DISCOVERY_UTC = \"`date -u +%Y-%m-%dT%H:%M:%SZ`\"" >> "$HWTMP"
    /bin/echo "set TARGET_USER = \"${TARGET_USER}\"" >> "$HWTMP"
    /bin/echo "set TARGET_HOME = \"${TARGET_HOME}\"" >> "$HWTMP"
    /bin/mv -f "$HWTMP" "$HARDWARE_SNAPSHOT"

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=2" >! "$CPTMP"
    /bin/echo "name=discovery-snapshot" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 2
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "discovery snapshot complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 2 already completed; skipping by checkpoint"
    logline
endif

###############################################################################
# Phase 3: conservative desktop tuning first
###############################################################################
set CURRENT_PHASE = "phase3"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 3 && -e /etc/sysctl.conf ) then
    grep -F "$BEGIN_MARK" /etc/sysctl.conf >/dev/null 2>&1
    if ( $status == 0 ) set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "conservative desktop tuning begins"
    logline

    set SYSCTL_LINES = ()
    sysctl -n kern.syscons_async >/dev/null 2>&1
    if ( $status == 0 ) then
        set CUR_ASYNC = `sysctl -n kern.syscons_async`
        if ( "$CUR_ASYNC" != "1" ) then
            sysctl kern.syscons_async=1 >/dev/null 2>&1
            if ( $status == 0 ) then
                set LOG_LEVEL = "OK"
                set LOG_STEP = "runtime-sysctl"
                set LOG_MSG = "set kern.syscons_async=1 at runtime"
                logline
            else
                set LOG_LEVEL = "WARN"
                set LOG_STEP = "runtime-sysctl"
                set LOG_MSG = "unable to set kern.syscons_async=1 at runtime; persistence only"
                logline
            endif
        else
            set LOG_LEVEL = "SKIP"
            set LOG_STEP = "runtime-sysctl"
            set LOG_MSG = "kern.syscons_async already set to 1"
            logline
        endif
        set SYSCTL_LINES = ( $SYSCTL_LINES 'kern.syscons_async=1' )
    else
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "runtime-sysctl"
        set LOG_MSG = "kern.syscons_async not present on this host; skipping"
        logline
    endif

    if ( -r /dev/sndstat ) then
        set AUDIO_DEVICE_COUNT = `awk '/^pcm[0-9]+:/ {c++} END { if (c == "") c = 0; print c }' /dev/sndstat`
    else
        set AUDIO_DEVICE_COUNT = 0
    endif
    if ( "$AUDIO_DEVICE_COUNT" == "" ) set AUDIO_DEVICE_COUNT = 0

    if ( $AUDIO_DEVICE_COUNT > 1 ) then
        cat /dev/sndstat | awk '
            /^pcm[0-9]+:/ {
                unit = $1
                sub(/^pcm/, "", unit)
                sub(/:.*/, "", unit)
                line = tolower($0)
                score = 100
                reason = "first-detected-device"
                if (line ~ /(analog|speaker|headphone|front|line out)/) { score = 400; reason = "analog-output" }
                else if (line ~ /(usb|dac|headset)/) { score = 300; reason = "usb-audio" }
                else if (line ~ /(hdmi|displayport|display port|dp)/) { score = 200; reason = "hdmi-or-displayport" }
                print score "|" unit "|" reason "|" $0
            }
        ' | sort -t'|' -k1,1nr -k2,2n >! "${BASE_STATE_DIR}/.audio-score.${RUN_ID}.txt"
        set FIRST_AUDIO = "`head -n 1 ${BASE_STATE_DIR}/.audio-score.${RUN_ID}.txt`"
        if ( "$FIRST_AUDIO" != "" ) then
            set AUDIO_SELECTED_UNIT = `echo "$FIRST_AUDIO" | awk -F'|' '{print $2}'`
            set AUDIO_DEFAULT_REASON = `echo "$FIRST_AUDIO" | awk -F'|' '{print $3}'`
            sysctl hw.snd.default_unit="$AUDIO_SELECTED_UNIT" >/dev/null 2>&1
            if ( $status == 0 ) then
                set LOG_LEVEL = "OK"
                set LOG_STEP = "runtime-sysctl"
                set LOG_MSG = "set hw.snd.default_unit=${AUDIO_SELECTED_UNIT} based on ${AUDIO_DEFAULT_REASON}"
                logline
            else
                set LOG_LEVEL = "WARN"
                set LOG_STEP = "runtime-sysctl"
                set LOG_MSG = "unable to set hw.snd.default_unit=${AUDIO_SELECTED_UNIT} at runtime; persistence only"
                logline
            endif
            set SYSCTL_LINES = ( $SYSCTL_LINES "hw.snd.default_unit=${AUDIO_SELECTED_UNIT}" )
        endif
    else if ( $AUDIO_DEVICE_COUNT == 1 ) then
        set LOG_LEVEL = "SKIP"
        set LOG_STEP = "runtime-sysctl"
        set LOG_MSG = "single sound device detected; no persistent hw.snd.default_unit override needed"
        logline
    else
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "runtime-sysctl"
        set LOG_MSG = "no sound devices detected during tuning phase"
        logline
    endif

    set SYSCTLTMP = "/etc/.sysctl.conf.${RUN_ID}.tmp"
    set SYSCTLBLOCK = "/etc/.sysctl.block.${RUN_ID}.tmp"
    set SYSCTLMERGED = "/etc/.sysctl.merged.${RUN_ID}.tmp"
    /bin/rm -f "$SYSCTLTMP" "$SYSCTLBLOCK" "$SYSCTLMERGED"
    /bin/echo "$BEGIN_MARK" >! "$SYSCTLBLOCK"
    /bin/echo "# generated by ${SCRIPT_NAME} on `date -u +%Y-%m-%dT%H:%M:%SZ`" >> "$SYSCTLBLOCK"
    foreach line ( $SYSCTL_LINES )
        /bin/echo "$line" >> "$SYSCTLBLOCK"
    end
    /bin/echo "$END_MARK" >> "$SYSCTLBLOCK"

    set SYSCTL_BACKUP = "${BASE_BACKUP_DIR}/etc_sysctl.conf.${UTC_NOW}.${RUN_ID}.bak"
    if ( -e /etc/sysctl.conf ) then
        /bin/cp -p /etc/sysctl.conf "$SYSCTL_BACKUP"
        if ( $status != 0 ) then
            set FATAL_STEP = "backup-sysctl"
            set FATAL_MESSAGE = "failed to back up /etc/sysctl.conf to ${SYSCTL_BACKUP}"
            set EXIT_CODE = 50
            goto fatal_exit
        endif
        /bin/echo "/etc/sysctl.conf|${SYSCTL_BACKUP}" >>! "$ROLLBACK_MANIFEST"
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "backup-sysctl"
        set LOG_MSG = "backup created at ${SYSCTL_BACKUP}"
        logline
        awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v repl="$SYSCTLBLOCK" '
            BEGIN {
                while ((getline l < repl) > 0) new = new l ORS
                inblock = 0
                replaced = 0
            }
            $0 == begin {
                if (!replaced) {
                    printf "%s", new
                    replaced = 1
                }
                inblock = 1
                next
            }
            $0 == end {
                inblock = 0
                next
            }
            !inblock { print }
            END {
                if (!replaced) {
                    if (NR > 0) print ""
                    printf "%s", new
                }
            }
        ' /etc/sysctl.conf >! "$SYSCTLMERGED"
    else
        /bin/cp -p "$SYSCTLBLOCK" "$SYSCTLMERGED"
    endif
    if ( $status != 0 ) then
        if ( -e "$SYSCTL_BACKUP" ) /bin/cp -p "$SYSCTL_BACKUP" /etc/sysctl.conf
        set FATAL_STEP = "merge-sysctl"
        set FATAL_MESSAGE = "failed to generate merged /etc/sysctl.conf"
        set EXIT_CODE = 80
        goto fatal_exit
    endif
    /bin/mv -f "$SYSCTLMERGED" /etc/sysctl.conf
    if ( $status != 0 ) then
        if ( -e "$SYSCTL_BACKUP" ) /bin/cp -p "$SYSCTL_BACKUP" /etc/sysctl.conf
        set FATAL_STEP = "write-sysctl"
        set FATAL_MESSAGE = "failed atomic replace of /etc/sysctl.conf"
        set EXIT_CODE = 80
        goto fatal_exit
    endif
    /bin/echo "/etc/sysctl.conf|managed-block" >>! "$CHANGE_MANIFEST"
    set LOG_LEVEL = "OK"
    set LOG_STEP = "write-sysctl"
    set LOG_MSG = "managed /etc/sysctl.conf updated atomically"
    logline

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=3" >! "$CPTMP"
    /bin/echo "name=conservative-desktop-tuning" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 3
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "conservative desktop tuning complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 3 already completed and managed sysctl block detected; skipping"
    logline
endif

###############################################################################
# Phase 4: package manager readiness
###############################################################################
set CURRENT_PHASE = "phase4"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 4 ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "package manager readiness begins"
    logline

    pkg -N >/dev/null 2>&1
    if ( $status != 0 ) then
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "pkg-bootstrap"
        set LOG_MSG = "bootstrapping pkg"
        logline
        env ASSUME_ALWAYS_YES=yes pkg bootstrap -yf >/dev/null 2>&1
        if ( $status != 0 ) then
            set FATAL_STEP = "pkg-bootstrap"
            set FATAL_MESSAGE = "pkg bootstrap failed"
            set EXIT_CODE = 40
            goto fatal_exit
        endif
        rehash
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "pkg-bootstrap"
    set LOG_MSG = "pkg is initialized"
    logline

    pkg update >/dev/null 2>&1
    if ( $status != 0 ) then
        set FATAL_STEP = "pkg-update"
        set FATAL_MESSAGE = "pkg update failed"
        set EXIT_CODE = 40
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "pkg-update"
    set LOG_MSG = "repository metadata updated"
    logline

    set PKG_ABI = `pkg config ABI 2>/dev/null`
    set PKG_REPOS = `pkg repo -l 2>/dev/null | awk 'NR==1{print $1}'`
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "pkg-context"
    set LOG_MSG = "pkg ABI ${PKG_ABI}; repository context ${PKG_REPOS}"
    logline

    if ( $SKIP_UPGRADE == 0 ) then
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "pkg-upgrade"
        set LOG_MSG = "upgrading installed packages conservatively"
        logline
        env ASSUME_ALWAYS_YES=yes pkg upgrade -y >/dev/null 2>&1
        if ( $status == 0 ) then
            set LOG_LEVEL = "OK"
            set LOG_STEP = "pkg-upgrade"
            set LOG_MSG = "package upgrade completed"
            logline
        else
            set LOG_LEVEL = "WARN"
            set LOG_STEP = "pkg-upgrade"
            set LOG_MSG = "package upgrade failed; continuing with package resolution"
            logline
        endif
    else
        set LOG_LEVEL = "SKIP"
        set LOG_STEP = "pkg-upgrade"
        set LOG_MSG = "package upgrade skipped by flag"
        logline
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=4" >! "$CPTMP"
    /bin/echo "name=package-manager-readiness" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 4
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "package manager readiness complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 4 already completed; skipping by checkpoint"
    logline
endif

###############################################################################
# Phase 5: hardware-aware planning
###############################################################################
set CURRENT_PHASE = "phase5"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 5 && -r "$HARDWARE_SNAPSHOT" ) then
    grep -F 'set GPU_PLAN' "$HARDWARE_SNAPSHOT" >/dev/null 2>&1
    if ( $status == 0 ) set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "hardware-aware planning begins"
    logline

    set PCITEXT = "${BASE_STATE_DIR}/discovery/pciconf-lv.txt"
    set KLDTEXT = "${BASE_STATE_DIR}/discovery/kldstat.txt"
    if ( ! -r "$PCITEXT" ) then
        pciconf -lv >! "$PCITEXT"
    endif
    if ( ! -r "$KLDTEXT" ) then
        kldstat >! "$KLDTEXT"
    endif

    grep -Ei 'amdgpu' "$KLDTEXT" >/dev/null 2>&1
    if ( $status == 0 ) then
        set GPU_PLAN = "amd-amdgpu"
    else
        grep -Ei 'radeon' "$KLDTEXT" >/dev/null 2>&1
        if ( $status == 0 ) then
            set GPU_PLAN = "amd-radeon"
        else
            grep -Ei 'i915|intel' "$KLDTEXT" >/dev/null 2>&1
            if ( $status == 0 ) then
                set GPU_PLAN = "intel-kms"
            else
                awk 'BEGIN{RS=""; found=0}
                    {
                        low = tolower($0)
                    }
                    low ~ /(vg|display|graphics)/ {
                        if (low ~ /intel/) { print "intel-kms"; found=1; exit }
                        if (low ~ /(amd|ati|advanced micro devices)/) {
                            if (low ~ /(vega|navi|polaris|ellesmere|baffin|gfx|rdna|rembrandt|phoenix|raven|renoir|cezanne|rx[ -]4|rx[ -]5|rx[ -]6|rx[ -]7)/) print "amd-amdgpu";
                            else print "amd-radeon";
                            found=1;
                            exit
                        }
                    }
                    END { if (!found) print "unknown-generic" }
                ' "$PCITEXT" >! "${BASE_STATE_DIR}/.gpu-plan.${RUN_ID}.txt"
                set GPU_PLAN = `head -n 1 ${BASE_STATE_DIR}/.gpu-plan.${RUN_ID}.txt`
            endif
        endif
    endif
    if ( "$GPU_PLAN" == "" ) set GPU_PLAN = "unknown-generic"
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "gpu-plan"
    set LOG_MSG = "GPU classified as ${GPU_PLAN}"
    logline

    if ( -r /dev/sndstat ) then
        cat /dev/sndstat | awk '
            /^pcm[0-9]+:/ {
                line = tolower($0)
                c++
                if (line ~ /(hdmi|displayport|display port|dp)/) hdmi = 1
                if (line ~ /(usb|dac|headset)/) usb = 1
                if (line ~ /(analog|speaker|headphone|front|line out)/) analog = 1
                unit = $1
                sub(/^pcm/, "", unit)
                sub(/:.*/, "", unit)
                score = 100
                reason = "fallback-first-detected-device"
                if (line ~ /(analog|speaker|headphone|front|line out)/) { score = 400; reason = "analog-headphone-speaker-output" }
                else if (line ~ /(usb|dac|headset)/) { score = 300; reason = "usb-headset-or-dac" }
                else if (line ~ /(hdmi|displayport|display port|dp)/) { score = 200; reason = "hdmi-displayport-audio" }
                print score "|" unit "|" reason "|" $0
            }
            END {
                if (c == 0) profile = "no-detected-audio"
                else if (usb == 1) profile = "USB audio present"
                else if (c > 1 && analog == 1 && hdmi == 1) profile = "multi-device analog + HDMI"
                else if (c == 1 && analog == 1) profile = "single-device analog"
                else if (c == 1) profile = "single-device analog"
                else profile = "multi-device analog + HDMI"
                print "PROFILE|" profile > "/dev/stderr"
            }
        ' >! "${BASE_STATE_DIR}/.audio-plan.${RUN_ID}.txt" 2>! "${BASE_STATE_DIR}/.audio-plan.profile.${RUN_ID}.txt"
        set AUDIO_DEVICE_COUNT = `awk 'END{print NR}' "${BASE_STATE_DIR}/.audio-plan.${RUN_ID}.txt"`
        set AUDIO_PROFILE = "`awk -F'|' '/^PROFILE\|/ {print $2}' ${BASE_STATE_DIR}/.audio-plan.profile.${RUN_ID}.txt`"
        set FIRST_AUDIO = "`head -n 1 ${BASE_STATE_DIR}/.audio-plan.${RUN_ID}.txt`"
        if ( "$FIRST_AUDIO" != "" ) then
            set AUDIO_SELECTED_UNIT = `echo "$FIRST_AUDIO" | awk -F'|' '{print $2}'`
            set AUDIO_DEFAULT_REASON = `echo "$FIRST_AUDIO" | awk -F'|' '{print $3}'`
        endif
    else
        set AUDIO_DEVICE_COUNT = 0
        set AUDIO_PROFILE = "no-detected-audio"
        set AUDIO_SELECTED_UNIT = ""
        set AUDIO_DEFAULT_REASON = ""
    endif
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "audio-plan"
    set LOG_MSG = "audio classified as ${AUDIO_PROFILE}; selected unit ${AUDIO_SELECTED_UNIT} reason ${AUDIO_DEFAULT_REASON}"
    logline

    sysctl -n hw.backlight_max >/dev/null 2>&1
    if ( $status == 0 ) then
        sysctl -n hw.backlight_level >/dev/null 2>&1
        if ( $status == 0 ) then
            set BACKLIGHT_MANAGEABLE = 1
        endif
    endif
    if ( $BACKLIGHT_MANAGEABLE == 1 ) then
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "backlight-plan"
        set LOG_MSG = "backlight sysctls present; machine is backlight-manageable"
        logline
    else
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "backlight-plan"
        set LOG_MSG = "backlight sysctls not present; skipping backlight helper"
        logline
    endif

    if ( $DEFERRED_KEYBOARD_VALIDATE == 1 ) then
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "keyboard-plan"
        set LOG_MSG = "keyboard layout ${KEYBOARD_LAYOUT} will be strictly revalidated after XKB data is installed"
        logline
    else
        set LOG_LEVEL = "OK"
        set LOG_STEP = "keyboard-plan"
        set LOG_MSG = "keyboard layout ${KEYBOARD_LAYOUT} ready for minimal Xorg drop-in"
        logline
    endif

    set HWTMP = "${BASE_STATE_DIR}/.hardware.${RUN_ID}.tmp"
    /bin/rm -f "$HWTMP"
    /bin/echo "set GPU_PLAN = \"${GPU_PLAN}\"" >! "$HWTMP"
    /bin/echo "set AUDIO_PROFILE = \"${AUDIO_PROFILE}\"" >> "$HWTMP"
    /bin/echo "set AUDIO_DEVICE_COUNT = \"${AUDIO_DEVICE_COUNT}\"" >> "$HWTMP"
    /bin/echo "set AUDIO_SELECTED_UNIT = \"${AUDIO_SELECTED_UNIT}\"" >> "$HWTMP"
    /bin/echo "set AUDIO_DEFAULT_REASON = \"${AUDIO_DEFAULT_REASON}\"" >> "$HWTMP"
    /bin/echo "set BACKLIGHT_MANAGEABLE = \"${BACKLIGHT_MANAGEABLE}\"" >> "$HWTMP"
    /bin/echo "set KEYBOARD_LAYOUT = \"${KEYBOARD_LAYOUT}\"" >> "$HWTMP"
    /bin/mv -f "$HWTMP" "$HARDWARE_SNAPSHOT"

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=5" >! "$CPTMP"
    /bin/echo "name=hardware-aware-planning" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 5
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "hardware-aware planning complete"
    logline
else
    if ( -r "$HARDWARE_SNAPSHOT" ) source "$HARDWARE_SNAPSHOT"
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 5 already completed; using saved hardware plan"
    logline
endif

###############################################################################
# Phase 6: package resolution
###############################################################################
set CURRENT_PHASE = "phase6"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 6 && -r "$PACKAGE_SNAPSHOT" ) then
    source "$PACKAGE_SNAPSHOT"
    if ( "$PKG_XORG" != "" && "$PKG_WINDOWMAKER" != "" ) set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "package resolution begins"
    logline

    set PKG_XORG = ""
    foreach cand ( xorg )
        pkg search -e "$cand" >/dev/null 2>&1
        if ( $status == 0 ) set PKG_XORG = "$cand"
    end
    if ( "$PKG_XORG" == "" ) then
        set FATAL_STEP = "resolve-xorg"
        set FATAL_MESSAGE = "required package slot xorg could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_INPUT_LIBINPUT = ""
    foreach cand ( xf86-input-libinput )
        pkg search -e "$cand" >/dev/null 2>&1
        if ( $status == 0 ) set PKG_INPUT_LIBINPUT = "$cand"
    end
    if ( "$PKG_INPUT_LIBINPUT" == "" ) then
        set FATAL_STEP = "resolve-input"
        set FATAL_MESSAGE = "required package xf86-input-libinput could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_INPUT_EVDEV = ""
    foreach cand ( xf86-input-evdev )
        pkg search -e "$cand" >/dev/null 2>&1
        if ( $status == 0 ) set PKG_INPUT_EVDEV = "$cand"
    end
    if ( "$PKG_INPUT_EVDEV" == "" ) then
        set FATAL_STEP = "resolve-input"
        set FATAL_MESSAGE = "required package xf86-input-evdev could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_XDM = ""
    foreach cand ( xdm )
        pkg search -e "$cand" >/dev/null 2>&1
        if ( $status == 0 ) set PKG_XDM = "$cand"
    end
    if ( "$PKG_XDM" == "" ) then
        set FATAL_STEP = "resolve-xdm"
        set FATAL_MESSAGE = "required package xdm could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_GNUSTEP = ""
    foreach cand ( gnustep )
        pkg search -e "$cand" >/dev/null 2>&1
        if ( $status == 0 ) set PKG_GNUSTEP = "$cand"
    end
    if ( "$PKG_GNUSTEP" == "" ) then
        set FATAL_STEP = "resolve-gnustep"
        set FATAL_MESSAGE = "required package gnustep could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_GNUSTEP_BACK = ""
    foreach cand ( gnustep-back )
        pkg search -e "$cand" >/dev/null 2>&1
        if ( $status == 0 ) set PKG_GNUSTEP_BACK = "$cand"
    end
    if ( "$PKG_GNUSTEP_BACK" == "" ) then
        set FATAL_STEP = "resolve-gnustep-back"
        set FATAL_MESSAGE = "required package gnustep-back could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_WINDOWMAKER = ""
    foreach cand ( windowmaker )
        pkg search -e "$cand" >/dev/null 2>&1
        if ( $status == 0 ) set PKG_WINDOWMAKER = "$cand"
    end
    if ( "$PKG_WINDOWMAKER" == "" ) then
        set FATAL_STEP = "resolve-windowmaker"
        set FATAL_MESSAGE = "required package windowmaker could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_TERMINAL = ""
    foreach cand ( xterm rxvt-unicode mlterm )
        if ( "$PKG_TERMINAL" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_TERMINAL = "$cand"
        endif
    end
    if ( "$PKG_TERMINAL" == "" ) then
        set FATAL_STEP = "resolve-terminal"
        set FATAL_MESSAGE = "required terminal capability could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_EDITOR = ""
    foreach cand ( vim nano )
        if ( "$PKG_EDITOR" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_EDITOR = "$cand"
        endif
    end
    if ( "$PKG_EDITOR" == "" ) then
        set FATAL_STEP = "resolve-editor"
        set FATAL_MESSAGE = "required editor capability could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    set PKG_BROWSER = ""
    foreach cand ( firefox firefox-esr chromium )
        if ( "$PKG_BROWSER" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_BROWSER = "$cand"
        endif
    end
    if ( "$PKG_BROWSER" == "" ) then
        set FATAL_STEP = "resolve-browser"
        set FATAL_MESSAGE = "required browser capability could not be resolved"
        set EXIT_CODE = 40
        goto fatal_exit
    endif

    switch ( "$PKG_TERMINAL" )
        case xterm:
            set TERMINAL_BIN = "xterm"
            breaksw
        case rxvt-unicode:
            set TERMINAL_BIN = "urxvt"
            breaksw
        case mlterm:
            set TERMINAL_BIN = "mlterm"
            breaksw
        default:
            set TERMINAL_BIN = "xterm"
            breaksw
    endsw

    foreach reqpkg ( "$PKG_CURL" "$PKG_WGET" "$PKG_RSYNC" "$PKG_GIT" )
        pkg search -e "$reqpkg" >/dev/null 2>&1
        if ( $status != 0 ) then
            set FATAL_STEP = "resolve-core-utility"
            set FATAL_MESSAGE = "required package ${reqpkg} could not be resolved"
            set EXIT_CODE = 40
            goto fatal_exit
        endif
    end

    set PKG_OFFICE = ""
    foreach cand ( libreoffice )
        if ( "$PKG_OFFICE" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_OFFICE = "$cand"
        endif
    end
    set PKG_PDFVIEW = ""
    foreach cand ( evince xpdf zathura )
        if ( "$PKG_PDFVIEW" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_PDFVIEW = "$cand"
        endif
    end
    set PKG_FILEMGR = ""
    foreach cand ( thunar pcmanfm xfe )
        if ( "$PKG_FILEMGR" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_FILEMGR = "$cand"
        endif
    end
    set PKG_SYSMON = ""
    foreach cand ( htop btop )
        if ( "$PKG_SYSMON" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_SYSMON = "$cand"
        endif
    end
    set PKG_CLIP = ""
    foreach cand ( xclip xsel )
        if ( "$PKG_CLIP" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_CLIP = "$cand"
        endif
    end
    set PKG_FONTS = ""
    foreach cand ( dejavu liberation-fonts-ttf noto-basic-ttf )
        if ( "$PKG_FONTS" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_FONTS = "$cand"
        endif
    end
    set PKG_VIDEO = ""
    foreach cand ( mpv vlc )
        if ( "$PKG_VIDEO" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_VIDEO = "$cand"
        endif
    end
    set PKG_AUDIO = ""
    foreach cand ( mpg123 audacious )
        if ( "$PKG_AUDIO" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_AUDIO = "$cand"
        endif
    end
    set PKG_TRANSCODER = ""
    foreach cand ( ffmpeg )
        if ( "$PKG_TRANSCODER" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_TRANSCODER = "$cand"
        endif
    end
    set PKG_AUDIO_UTIL = ""
    foreach cand ( sox )
        if ( "$PKG_AUDIO_UTIL" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_AUDIO_UTIL = "$cand"
        endif
    end
    set PKG_IMAGE = ""
    foreach cand ( gimp )
        if ( "$PKG_IMAGE" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_IMAGE = "$cand"
        endif
    end
    set PKG_SCREENSHOT = ""
    foreach cand ( scrot maim ImageMagick7 ImageMagick )
        if ( "$PKG_SCREENSHOT" == "" ) then
            pkg search -e "$cand" >/dev/null 2>&1
            if ( $status == 0 ) set PKG_SCREENSHOT = "$cand"
        endif
    end

    foreach pair ( \
        "xorg:${PKG_XORG}" \
        "xf86-input-libinput:${PKG_INPUT_LIBINPUT}" \
        "xf86-input-evdev:${PKG_INPUT_EVDEV}" \
        "xdm:${PKG_XDM}" \
        "gnustep:${PKG_GNUSTEP}" \
        "gnustep-back:${PKG_GNUSTEP_BACK}" \
        "windowmaker:${PKG_WINDOWMAKER}" \
        "terminal:${PKG_TERMINAL}" \
        "editor:${PKG_EDITOR}" \
        "browser:${PKG_BROWSER}" \
        "curl:${PKG_CURL}" \
        "wget:${PKG_WGET}" \
        "rsync:${PKG_RSYNC}" \
        "git:${PKG_GIT}" )
        set slot = `echo "$pair" | awk -F: '{print $1}'`
        set pkgname = `echo "$pair" | awk -F: '{print $2}'`
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "resolve-required"
        set LOG_MSG = "resolved ${slot} to ${pkgname}"
        logline
    end

    set PKGTMP = "${BASE_STATE_DIR}/.packages.${RUN_ID}.tmp"
    /bin/rm -f "$PKGTMP"
    foreach line ( \
        "set PKG_XORG = \"${PKG_XORG}\"" \
        "set PKG_INPUT_LIBINPUT = \"${PKG_INPUT_LIBINPUT}\"" \
        "set PKG_INPUT_EVDEV = \"${PKG_INPUT_EVDEV}\"" \
        "set PKG_XDM = \"${PKG_XDM}\"" \
        "set PKG_GNUSTEP = \"${PKG_GNUSTEP}\"" \
        "set PKG_GNUSTEP_BACK = \"${PKG_GNUSTEP_BACK}\"" \
        "set PKG_WINDOWMAKER = \"${PKG_WINDOWMAKER}\"" \
        "set PKG_TERMINAL = \"${PKG_TERMINAL}\"" \
        "set TERMINAL_BIN = \"${TERMINAL_BIN}\"" \
        "set PKG_EDITOR = \"${PKG_EDITOR}\"" \
        "set PKG_BROWSER = \"${PKG_BROWSER}\"" \
        "set PKG_CURL = \"${PKG_CURL}\"" \
        "set PKG_WGET = \"${PKG_WGET}\"" \
        "set PKG_RSYNC = \"${PKG_RSYNC}\"" \
        "set PKG_GIT = \"${PKG_GIT}\"" \
        "set PKG_OFFICE = \"${PKG_OFFICE}\"" \
        "set PKG_PDFVIEW = \"${PKG_PDFVIEW}\"" \
        "set PKG_FILEMGR = \"${PKG_FILEMGR}\"" \
        "set PKG_SYSMON = \"${PKG_SYSMON}\"" \
        "set PKG_ZIP = \"${PKG_ZIP}\"" \
        "set PKG_UNZIP = \"${PKG_UNZIP}\"" \
        "set PKG_P7ZIP = \"${PKG_P7ZIP}\"" \
        "set PKG_CLIP = \"${PKG_CLIP}\"" \
        "set PKG_FONTS = \"${PKG_FONTS}\"" \
        "set PKG_VIDEO = \"${PKG_VIDEO}\"" \
        "set PKG_AUDIO = \"${PKG_AUDIO}\"" \
        "set PKG_TRANSCODER = \"${PKG_TRANSCODER}\"" \
        "set PKG_AUDIO_UTIL = \"${PKG_AUDIO_UTIL}\"" \
        "set PKG_IMAGE = \"${PKG_IMAGE}\"" \
        "set PKG_SCREENSHOT = \"${PKG_SCREENSHOT}\"" )
        /bin/echo "$line" >>! "$PKGTMP"
    end
    /bin/mv -f "$PKGTMP" "$PACKAGE_SNAPSHOT"

    foreach reqpkg ( "$PKG_XORG" "$PKG_INPUT_LIBINPUT" "$PKG_INPUT_EVDEV" "$PKG_XDM" "$PKG_GNUSTEP" "$PKG_GNUSTEP_BACK" "$PKG_WINDOWMAKER" "$PKG_TERMINAL" "$PKG_EDITOR" "$PKG_BROWSER" "$PKG_CURL" "$PKG_WGET" "$PKG_RSYNC" "$PKG_GIT" )
        pkg info -e "$reqpkg" >/dev/null 2>&1
        if ( $status == 0 ) then
            set LOG_LEVEL = "SKIP"
            set LOG_STEP = "pkg-install"
            set LOG_MSG = "required package ${reqpkg} already installed"
            logline
        else
            set LOG_LEVEL = "INFO"
            set LOG_STEP = "pkg-install"
            set LOG_MSG = "installing required package ${reqpkg}"
            logline
            env ASSUME_ALWAYS_YES=yes pkg install -y "$reqpkg" >/dev/null 2>&1
            if ( $status != 0 ) then
                set FATAL_STEP = "pkg-install"
                set FATAL_MESSAGE = "required package install failed for ${reqpkg}"
                set EXIT_CODE = 40
                goto fatal_exit
            endif
            set LOG_LEVEL = "OK"
            set LOG_STEP = "pkg-install"
            set LOG_MSG = "installed required package ${reqpkg}"
            logline
        endif
    end

    foreach optpkg ( "$PKG_OFFICE" "$PKG_PDFVIEW" "$PKG_FILEMGR" "$PKG_SYSMON" "$PKG_ZIP" "$PKG_UNZIP" "$PKG_P7ZIP" "$PKG_CLIP" "$PKG_FONTS" "$PKG_VIDEO" "$PKG_AUDIO" "$PKG_TRANSCODER" "$PKG_AUDIO_UTIL" "$PKG_IMAGE" "$PKG_SCREENSHOT" )
        if ( "$optpkg" == "" ) then
            set LOG_LEVEL = "WARN"
            set LOG_STEP = "pkg-install"
            set LOG_MSG = "optional package slot unresolved; continuing"
            logline
        else
            pkg info -e "$optpkg" >/dev/null 2>&1
            if ( $status == 0 ) then
                set LOG_LEVEL = "SKIP"
                set LOG_STEP = "pkg-install"
                set LOG_MSG = "optional package ${optpkg} already installed"
                logline
            else
                set LOG_LEVEL = "INFO"
                set LOG_STEP = "pkg-install"
                set LOG_MSG = "installing optional package ${optpkg}"
                logline
                env ASSUME_ALWAYS_YES=yes pkg install -y "$optpkg" >/dev/null 2>&1
                if ( $status != 0 ) then
                    set LOG_LEVEL = "WARN"
                    set LOG_STEP = "pkg-install"
                    set LOG_MSG = "optional package install failed for ${optpkg}; continuing"
                    logline
                else
                    set LOG_LEVEL = "OK"
                    set LOG_STEP = "pkg-install"
                    set LOG_MSG = "installed optional package ${optpkg}"
                    logline
                endif
            endif
        endif
    end

    if ( $DEFERRED_KEYBOARD_VALIDATE == 1 ) then
        set STRICT_XKB = ""
        foreach candidate ( /usr/local/share/X11/xkb/rules/base.lst /usr/local/share/X11/xkb/rules/evdev.lst /usr/X11R6/share/X11/xkb/rules/base.lst /usr/X11R6/share/X11/xkb/rules/evdev.lst )
            if ( -r "$candidate" ) then
                set STRICT_XKB = "$candidate"
                break
            endif
        end
        if ( "$STRICT_XKB" != "" ) then
            awk -v target="$KEYBOARD_LAYOUT" '
                BEGIN { in_layout = 0; found = 0 }
                /^! layout/ { in_layout = 1; next }
                /^!/ && $2 != "layout" { if (in_layout == 1) exit }
                in_layout == 1 { if ($1 == target) found = 1 }
                END { exit(found ? 0 : 1) }
            ' "$STRICT_XKB" >/dev/null 2>&1
            if ( $status != 0 ) then
                set FATAL_STEP = "validate-keyboard-strict"
                set FATAL_MESSAGE = "keyboard layout ${KEYBOARD_LAYOUT} failed strict XKB validation after package install"
                set EXIT_CODE = 60
                goto fatal_exit
            endif
            set DEFERRED_KEYBOARD_VALIDATE = 0
            set KEYBOARD_VALIDATION_SOURCE = "$STRICT_XKB"
            set LOG_LEVEL = "OK"
            set LOG_STEP = "validate-keyboard-strict"
            set LOG_MSG = "keyboard layout ${KEYBOARD_LAYOUT} strictly revalidated via ${STRICT_XKB}"
            logline
        else
            set FATAL_STEP = "validate-keyboard-strict"
            set FATAL_MESSAGE = "strict XKB data still unavailable after package install"
            set EXIT_CODE = 60
            goto fatal_exit
        endif
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=6" >! "$CPTMP"
    /bin/echo "name=package-resolution" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 6
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "package resolution complete"
    logline
else
    source "$PACKAGE_SNAPSHOT"
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 6 already completed; using saved package resolution"
    logline
endif

###############################################################################
# Phase 7: system configuration
###############################################################################
set CURRENT_PHASE = "phase7"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 7 ) then
    grep -F "$BEGIN_MARK" /etc/rc.conf >/dev/null 2>&1
    if ( $status == 0 ) set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "system configuration begins"
    logline

    foreach target ( /etc/rc.conf /boot/loader.conf )
        set base = `basename "$target"`
        set target_dir = `dirname "$target"`
        set tmpblock = "${target_dir}/.${base}.block.${RUN_ID}.tmp"
        set tmpmerge = "${target_dir}/.${base}.merged.${RUN_ID}.tmp"
        /bin/rm -f "$tmpblock" "$tmpmerge"
        /bin/echo "$BEGIN_MARK" >! "$tmpblock"
        /bin/echo "# generated by ${SCRIPT_NAME} on `date -u +%Y-%m-%dT%H:%M:%SZ`" >> "$tmpblock"
        if ( "$target" == "/etc/rc.conf" ) then
            /bin/echo "# intentionally conservative: no desktop daemons forced in v1" >> "$tmpblock"
        else
            /bin/echo "# intentionally conservative: no loader tunables forced in v1 without diagnosed need" >> "$tmpblock"
        endif
        /bin/echo "$END_MARK" >> "$tmpblock"
        set enc = `echo "$target" | sed 's#/#_#g; s#^_##'`
        set backup = "${BASE_BACKUP_DIR}/${enc}.${UTC_NOW}.${RUN_ID}.bak"
        if ( -e "$target" ) then
            /bin/cp -p "$target" "$backup"
            if ( $status != 0 ) then
                set FATAL_STEP = "backup-system-file"
                set FATAL_MESSAGE = "failed to back up ${target} to ${backup}"
                set EXIT_CODE = 50
                goto fatal_exit
            endif
            /bin/echo "${target}|${backup}" >>! "$ROLLBACK_MANIFEST"
            awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v repl="$tmpblock" '
                BEGIN {
                    while ((getline l < repl) > 0) new = new l ORS
                    inblock = 0
                    replaced = 0
                }
                $0 == begin {
                    if (!replaced) {
                        printf "%s", new
                        replaced = 1
                    }
                    inblock = 1
                    next
                }
                $0 == end { inblock = 0; next }
                !inblock { print }
                END {
                    if (!replaced) {
                        if (NR > 0) print ""
                        printf "%s", new
                    }
                }
            ' "$target" >! "$tmpmerge"
        else
            /bin/cp -p "$tmpblock" "$tmpmerge"
        endif
        if ( $status != 0 ) then
            if ( -e "$backup" ) /bin/cp -p "$backup" "$target"
            set FATAL_STEP = "merge-system-file"
            set FATAL_MESSAGE = "failed to generate merged ${target}"
            set EXIT_CODE = 80
            goto fatal_exit
        endif
        /bin/mv -f "$tmpmerge" "$target"
        if ( $status != 0 ) then
            if ( -e "$backup" ) /bin/cp -p "$backup" "$target"
            set FATAL_STEP = "write-system-file"
            set FATAL_MESSAGE = "failed atomic replace of ${target}"
            set EXIT_CODE = 80
            goto fatal_exit
        endif
        set LOG_LEVEL = "OK"
        set LOG_STEP = "write-system-file"
        set LOG_MSG = "managed block updated in ${target}"
        logline
        /bin/echo "${target}|managed-block" >>! "$CHANGE_MANIFEST"
    end

    set TTYS_BACKUP = "${BASE_BACKUP_DIR}/etc_ttys.${UTC_NOW}.${RUN_ID}.bak"
    /bin/cp -p /etc/ttys "$TTYS_BACKUP"
    if ( $status != 0 ) then
        set FATAL_STEP = "backup-ttys"
        set FATAL_MESSAGE = "failed to back up /etc/ttys"
        set EXIT_CODE = 50
        goto fatal_exit
    endif
    /bin/echo "/etc/ttys|${TTYS_BACKUP}" >>! "$ROLLBACK_MANIFEST"
    awk '
        BEGIN { changed = 0 }
        /^ttyv8[ \t]/ {
            line = $0
            if (line ~ /\"\/usr\/local\/bin\/xdm -nodaemon\"/) {
                sub(/[ \t]+off([ \t]+secure)?$/, " on secure", line)
            } else {
                line = "ttyv8\t\"/usr/local/bin/xdm -nodaemon\"\txterm\ton\tsecure"
            }
            print line
            changed = 1
            next
        }
        { print }
        END {
            if (!changed) print "ttyv8\t\"/usr/local/bin/xdm -nodaemon\"\txterm\ton\tsecure"
        }
    ' /etc/ttys >! /etc/.ttys.${RUN_ID}.tmp
    if ( $status != 0 ) then
        /bin/cp -p "$TTYS_BACKUP" /etc/ttys
        set FATAL_STEP = "merge-ttys"
        set FATAL_MESSAGE = "failed to generate updated /etc/ttys"
        set EXIT_CODE = 80
        goto fatal_exit
    endif
    grep '^ttyv8[[:space:]]\+"/usr/local/bin/xdm -nodaemon"[[:space:]]\+xterm[[:space:]]\+on' /etc/.ttys.${RUN_ID}.tmp >/dev/null 2>&1
    if ( $status != 0 ) then
        /bin/cp -p "$TTYS_BACKUP" /etc/ttys
        set FATAL_STEP = "validate-ttys"
        set FATAL_MESSAGE = "generated /etc/ttys does not contain enabled XDM ttyv8 entry"
        set EXIT_CODE = 60
        goto fatal_exit
    endif
    /bin/mv -f /etc/.ttys.${RUN_ID}.tmp /etc/ttys
    if ( $status != 0 ) then
        /bin/cp -p "$TTYS_BACKUP" /etc/ttys
        set FATAL_STEP = "write-ttys"
        set FATAL_MESSAGE = "failed atomic replace of /etc/ttys"
        set EXIT_CODE = 80
        goto fatal_exit
    endif
    /bin/echo "/etc/ttys|ttyv8-xdm-enabled" >>! "$CHANGE_MANIFEST"
    set LOG_LEVEL = "OK"
    set LOG_STEP = "write-ttys"
    set LOG_MSG = "/etc/ttys updated for XDM on ttyv8"
    logline

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=7" >! "$CPTMP"
    /bin/echo "name=system-configuration" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 7
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "system configuration complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 7 already completed and managed block detected; skipping"
    logline
endif

###############################################################################
# Phase 8: X11 configuration
###############################################################################
set CURRENT_PHASE = "phase8"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 8 && -r /etc/X11/xorg.conf.d/00-keyboard.conf ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "X11 configuration begins"
    logline

    /bin/mkdir -p /etc/X11/xorg.conf.d
    if ( $status != 0 ) then
        set FATAL_STEP = "mkdir-xorg-conf-d"
        set FATAL_MESSAGE = "failed to create /etc/X11/xorg.conf.d"
        set EXIT_CODE = 50
        goto fatal_exit
    endif

    set KBDTMP = "/etc/X11/xorg.conf.d/.00-keyboard.conf.${RUN_ID}.tmp"
    /bin/rm -f "$KBDTMP"
    cat >! "$KBDTMP" <<EOF_KBD
Section "InputClass"
    Identifier "turkishvan-bsd keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${KEYBOARD_LAYOUT}"
EndSection
EOF_KBD
    /bin/mv -f "$KBDTMP" /etc/X11/xorg.conf.d/00-keyboard.conf
    if ( $status != 0 ) then
        set FATAL_STEP = "write-keyboard-conf"
        set FATAL_MESSAGE = "failed atomic replace of /etc/X11/xorg.conf.d/00-keyboard.conf"
        set EXIT_CODE = 50
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "write-keyboard-conf"
    set LOG_MSG = "minimal keyboard drop-in written"
    logline
    /bin/echo "/etc/X11/xorg.conf.d/00-keyboard.conf|created" >>! "$CHANGE_MANIFEST"

    if ( -f /etc/X11/xorg.conf ) then
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "xorg-policy"
        set LOG_MSG = "monolithic /etc/X11/xorg.conf exists; leaving it untouched and preferring drop-ins"
        logline
    else
        set LOG_LEVEL = "OK"
        set LOG_STEP = "xorg-policy"
        set LOG_MSG = "no monolithic xorg.conf forced; autodetection remains primary"
        logline
    endif

    if ( -e /etc/X11/xorg.conf.d/10-libinput.conf ) then
        set LOG_LEVEL = "SKIP"
        set LOG_STEP = "libinput-conf"
        set LOG_MSG = "existing 10-libinput.conf preserved"
        logline
    else
        set LOG_LEVEL = "SKIP"
        set LOG_STEP = "libinput-conf"
        set LOG_MSG = "libinput explicit drop-in not needed in v1"
        logline
    endif

    if ( -e /etc/X11/xorg.conf.d/20-local-video-permissions.conf ) then
        set LOG_LEVEL = "SKIP"
        set LOG_STEP = "video-perm-conf"
        set LOG_MSG = "existing 20-local-video-permissions.conf preserved"
        logline
    else
        set LOG_LEVEL = "SKIP"
        set LOG_STEP = "video-perm-conf"
        set LOG_MSG = "explicit DRI permission stanza not needed; video group model used"
        logline
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=8" >! "$CPTMP"
    /bin/echo "name=x11-configuration" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 8
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "X11 configuration complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 8 already completed; keyboard drop-in present"
    logline
endif

###############################################################################
# Phase 9: user provisioning
###############################################################################
set CURRENT_PHASE = "phase9"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 9 && -r "$TARGET_HOME/.xsession" && -r "$TARGET_HOME/.xinitrc" ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "user provisioning begins"
    logline

    pw groupshow video >/dev/null 2>&1
    if ( $status != 0 ) then
        pw groupadd video >/dev/null 2>&1
        if ( $status != 0 ) then
            set FATAL_STEP = "ensure-video-group"
            set FATAL_MESSAGE = "failed to ensure video group exists"
            set EXIT_CODE = 50
            goto fatal_exit
        endif
        set LOG_LEVEL = "OK"
        set LOG_STEP = "ensure-video-group"
        set LOG_MSG = "created missing video group"
        logline
    endif
    id -Gn "$TARGET_USER" | tr ' ' '\n' | grep -x video >/dev/null 2>&1
    if ( $status != 0 ) then
        pw groupmod video -m "$TARGET_USER" >/dev/null 2>&1
        if ( $status != 0 ) then
            set FATAL_STEP = "group-membership"
            set FATAL_MESSAGE = "failed to add ${TARGET_USER} to video group"
            set EXIT_CODE = 50
            goto fatal_exit
        endif
        set GROUP_CHANGED = 1
        set NEED_RELOGIN = 1
        set LOG_LEVEL = "OK"
        set LOG_STEP = "group-membership"
        set LOG_MSG = "added ${TARGET_USER} to video group"
        logline
    else
        set LOG_LEVEL = "SKIP"
        set LOG_STEP = "group-membership"
        set LOG_MSG = "${TARGET_USER} already in video group"
        logline
    endif

    set GNUSTEP_CSH_INIT = ""
    foreach candidate ( /usr/local/share/GNUstep/Makefiles/GNUstep.csh /usr/local/share/GNUstep/Makefiles/GNUstep-reset.csh /usr/local/share/GNUstep/Makefiles/GNUstep-local.csh /usr/local/GNUstep/System/Library/Makefiles/GNUstep.csh )
        if ( -r "$candidate" ) then
            set GNUSTEP_CSH_INIT = "$candidate"
            break
        endif
    end
    if ( "$GNUSTEP_CSH_INIT" == "" ) then
        set GNUSTEP_PKG_LIST = `pkg info | awk '/^gnustep/ {print $1}'`
        foreach gpkg ( $GNUSTEP_PKG_LIST )
            pkg info -l "$gpkg" 2>/dev/null | awk '/GNUstep.*\.csh$/ {print $1}' >! "${BASE_STATE_DIR}/.gnustep-csh.${RUN_ID}.txt"
            set CANDIDATE_FILE = `head -n 1 ${BASE_STATE_DIR}/.gnustep-csh.${RUN_ID}.txt`
            if ( "$CANDIDATE_FILE" != "" && -r "$CANDIDATE_FILE" ) then
                set GNUSTEP_CSH_INIT = "$CANDIDATE_FILE"
                break
            endif
        end
    endif
    if ( "$GNUSTEP_CSH_INIT" == "" ) then
        foreach candidate ( `find /usr/local -type f \( -name 'GNUstep*.csh' -o -name 'GNUstep.csh' \) 2>/dev/null | sort` )
            if ( -r "$candidate" ) then
                set GNUSTEP_CSH_INIT = "$candidate"
                break
            endif
        end
    endif
    if ( "$GNUSTEP_CSH_INIT" == "" ) then
        set FATAL_STEP = "discover-gnustep-env"
        set FATAL_MESSAGE = "GNUstep is installed but no csh-compatible GNUstep init script was found"
        set EXIT_CODE = 60
        goto fatal_exit
    endif
    set LOG_LEVEL = "OK"
    set LOG_STEP = "discover-gnustep-env"
    set LOG_MSG = "GNUstep csh init discovered at ${GNUSTEP_CSH_INIT}"
    logline

    /bin/mkdir -p "$TARGET_HOME/.config/${SCRIPT_NAME}"
    /usr/sbin/chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/${SCRIPT_NAME}"
    /bin/chmod 0755 "$TARGET_HOME/.config/${SCRIPT_NAME}"

    set XSESSION_ENC = `echo "$TARGET_HOME/.xsession" | sed 's#/#_#g'`
    set XSESSION_BACKUP = "${BASE_BACKUP_DIR}/${XSESSION_ENC}.${UTC_NOW}.${RUN_ID}.bak"
    if ( -e "$TARGET_HOME/.xsession" ) then
        /bin/cp -p "$TARGET_HOME/.xsession" "$XSESSION_BACKUP"
        /bin/echo "$TARGET_HOME/.xsession|${XSESSION_BACKUP}" >>! "$ROLLBACK_MANIFEST"
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "backup-user-file"
        set LOG_MSG = "backup created for ${TARGET_HOME}/.xsession at ${XSESSION_BACKUP}"
        logline
    endif
    set XSESSIONTMP = "$TARGET_HOME/.xsession.${RUN_ID}.tmp"
    cat >! "$XSESSIONTMP" <<EOF_XSESSION
#!/bin/csh -f
setenv XDG_CONFIG_HOME "${TARGET_HOME}/.config"
setenv DESKTOP_SESSION "WindowMaker"
setenv XDG_CURRENT_DESKTOP "GNUstep:WindowMaker"
setenv WINDOW_MANAGER "WindowMaker"
setenv XKB_DEFAULT_LAYOUT "${KEYBOARD_LAYOUT}"
if ( -r "${GNUSTEP_CSH_INIT}" ) then
    source "${GNUSTEP_CSH_INIT}"
endif
if ( -x /usr/local/bin/wmaker ) then
    exec /usr/local/bin/wmaker
endif
if ( -x /usr/local/bin/WindowMaker ) then
    exec /usr/local/bin/WindowMaker
endif
if ( -x /usr/X11R6/bin/${TERMINAL_BIN} ) then
    exec /usr/X11R6/bin/${TERMINAL_BIN}
endif
if ( -x /usr/local/bin/${TERMINAL_BIN} ) then
    exec /usr/local/bin/${TERMINAL_BIN}
endif
if ( -x /usr/X11R6/bin/xterm ) then
    exec /usr/X11R6/bin/xterm
endif
exec /usr/local/bin/xterm
EOF_XSESSION
    /bin/mv -f "$XSESSIONTMP" "$TARGET_HOME/.xsession"
    if ( $status != 0 ) then
        if ( -e "$XSESSION_BACKUP" ) /bin/cp -p "$XSESSION_BACKUP" "$TARGET_HOME/.xsession"
        set FATAL_STEP = "write-xsession"
        set FATAL_MESSAGE = "failed atomic replace of ${TARGET_HOME}/.xsession"
        set EXIT_CODE = 80
        goto fatal_exit
    endif
    /usr/sbin/chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.xsession"
    /bin/chmod 0755 "$TARGET_HOME/.xsession"
    set LOG_LEVEL = "OK"
    set LOG_STEP = "write-xsession"
    set LOG_MSG = "managed ${TARGET_HOME}/.xsession installed"
    logline
    /bin/echo "$TARGET_HOME/.xsession|managed" >>! "$CHANGE_MANIFEST"

    set XINITRC_ENC = `echo "$TARGET_HOME/.xinitrc" | sed 's#/#_#g'`
    set XINITRC_BACKUP = "${BASE_BACKUP_DIR}/${XINITRC_ENC}.${UTC_NOW}.${RUN_ID}.bak"
    if ( -e "$TARGET_HOME/.xinitrc" ) then
        /bin/cp -p "$TARGET_HOME/.xinitrc" "$XINITRC_BACKUP"
        /bin/echo "$TARGET_HOME/.xinitrc|${XINITRC_BACKUP}" >>! "$ROLLBACK_MANIFEST"
        set LOG_LEVEL = "INFO"
        set LOG_STEP = "backup-user-file"
        set LOG_MSG = "backup created for ${TARGET_HOME}/.xinitrc at ${XINITRC_BACKUP}"
        logline
    endif
    set XINITTMP = "$TARGET_HOME/.xinitrc.${RUN_ID}.tmp"
    cat >! "$XINITTMP" <<EOF_XINIT
#!/bin/csh -f
exec "${TARGET_HOME}/.xsession"
EOF_XINIT
    /bin/mv -f "$XINITTMP" "$TARGET_HOME/.xinitrc"
    if ( $status != 0 ) then
        if ( -e "$XINITRC_BACKUP" ) /bin/cp -p "$XINITRC_BACKUP" "$TARGET_HOME/.xinitrc"
        set FATAL_STEP = "write-xinitrc"
        set FATAL_MESSAGE = "failed atomic replace of ${TARGET_HOME}/.xinitrc"
        set EXIT_CODE = 80
        goto fatal_exit
    endif
    /usr/sbin/chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.xinitrc"
    /bin/chmod 0755 "$TARGET_HOME/.xinitrc"
    set LOG_LEVEL = "OK"
    set LOG_STEP = "write-xinitrc"
    set LOG_MSG = "managed ${TARGET_HOME}/.xinitrc installed"
    logline
    /bin/echo "$TARGET_HOME/.xinitrc|managed" >>! "$CHANGE_MANIFEST"

    if ( $BACKLIGHT_MANAGEABLE == 1 ) then
        set BRIGHTTMP = "$TARGET_HOME/.config/${SCRIPT_NAME}/brightness.csh.${RUN_ID}.tmp"
        cat >! "$BRIGHTTMP" <<EOF_BRIGHT
#!/bin/csh -f
if ( $#argv != 1 ) then
    /bin/echo "usage: brightness.csh up|down"
    exit 64
endif
set max = `sysctl -n hw.backlight_max`
set cur = `sysctl -n hw.backlight_level`
@ step = $max / 10
if ( $step < 1 ) set step = 1
switch ( "$argv[1]" )
    case up:
        @ new = $cur + $step
        if ( $new > $max ) set new = $max
        breaksw
    case down:
        @ new = $cur - $step
        if ( $new < 0 ) set new = 0
        breaksw
    default:
        /bin/echo "usage: brightness.csh up|down"
        exit 64
        breaksw
endsw
sysctl hw.backlight_level=$new
EOF_BRIGHT
        /bin/mv -f "$BRIGHTTMP" "$TARGET_HOME/.config/${SCRIPT_NAME}/brightness.csh"
        /usr/sbin/chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config/${SCRIPT_NAME}/brightness.csh"
        /bin/chmod 0755 "$TARGET_HOME/.config/${SCRIPT_NAME}/brightness.csh"
        set LOG_LEVEL = "OK"
        set LOG_STEP = "backlight-helper"
        set LOG_MSG = "installed user backlight helper at ${TARGET_HOME}/.config/${SCRIPT_NAME}/brightness.csh"
        logline
        /bin/echo "$TARGET_HOME/.config/${SCRIPT_NAME}/brightness.csh|created" >>! "$CHANGE_MANIFEST"
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=9" >! "$CPTMP"
    /bin/echo "name=user-provisioning" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 9
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "user provisioning complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 9 already completed; user session files present"
    logline
endif

###############################################################################
# Phase 10: audio configuration
###############################################################################
set CURRENT_PHASE = "phase10"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 10 ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "audio configuration begins"
    logline

    if ( -r /dev/sndstat ) then
        set AUDIO_DEVICE_COUNT = `awk '/^pcm[0-9]+:/ {c++} END { if (c == "") c = 0; print c }' /dev/sndstat`
        if ( "$AUDIO_DEVICE_COUNT" == "" ) set AUDIO_DEVICE_COUNT = 0
    else
        set AUDIO_DEVICE_COUNT = 0
    endif

    if ( $AUDIO_DEVICE_COUNT > 0 ) then
        if ( "$AUDIO_SELECTED_UNIT" == "" ) then
            set AUDIO_SELECTED_UNIT = `awk '/^pcm[0-9]+:/ {u=$1; sub(/^pcm/, "", u); sub(/:.*/, "", u); print u; exit}' /dev/sndstat`
            set AUDIO_DEFAULT_REASON = "fallback-first-detected-device"
        endif
        sysctl hw.snd.default_unit="$AUDIO_SELECTED_UNIT" >/dev/null 2>&1
        if ( $status == 0 ) then
            set LOG_LEVEL = "OK"
            set LOG_STEP = "select-default-audio"
            set LOG_MSG = "runtime default audio unit set to ${AUDIO_SELECTED_UNIT} (${AUDIO_DEFAULT_REASON})"
            logline
        else
            set LOG_LEVEL = "WARN"
            set LOG_STEP = "select-default-audio"
            set LOG_MSG = "runtime default audio unit ${AUDIO_SELECTED_UNIT} could not be applied"
            logline
        endif
        cat /dev/sndstat | grep -E "^pcm${AUDIO_SELECTED_UNIT}:" >/dev/null 2>&1
        if ( $status != 0 ) then
            set FATAL_STEP = "validate-audio"
            set FATAL_MESSAGE = "selected default audio device ${AUDIO_SELECTED_UNIT} not found in /dev/sndstat"
            set EXIT_CODE = 60
            goto fatal_exit
        endif
        mixer >/dev/null 2>&1
        if ( $status == 0 ) then
            set LOG_LEVEL = "OK"
            set LOG_STEP = "validate-audio"
            set LOG_MSG = "mixer access available for audio validation"
            logline
        else
            set LOG_LEVEL = "WARN"
            set LOG_STEP = "validate-audio"
            set LOG_MSG = "mixer utility unavailable or inactive; sndstat validation used"
            logline
        endif
    else
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "select-default-audio"
        set LOG_MSG = "no PCM devices detected; audio configuration limited to discovery logs"
        logline
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=10" >! "$CPTMP"
    /bin/echo "name=audio-configuration" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 10
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "audio configuration complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 10 already completed; skipping by checkpoint"
    logline
endif

###############################################################################
# Phase 11: video and display configuration
###############################################################################
set CURRENT_PHASE = "phase11"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 11 ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "video and display configuration begins"
    logline

    if ( "$GPU_PLAN" == "unknown-generic" ) then
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "drm-path"
        set LOG_MSG = "GPU plan remains unknown-generic; keeping Xorg autodetection and no forced DRM modules"
        logline
    else
        set LOG_LEVEL = "OK"
        set LOG_STEP = "drm-path"
        set LOG_MSG = "GPU plan ${GPU_PLAN}; using Xorg autodetection with video group permissions"
        logline
    endif

    if ( -x /usr/local/bin/Xorg ) then
        set LOG_LEVEL = "OK"
        set LOG_STEP = "validate-display"
        set LOG_MSG = "Xorg binary present at /usr/local/bin/Xorg"
        logline
    else if ( -x /usr/X11R6/bin/Xorg ) then
        set LOG_LEVEL = "OK"
        set LOG_STEP = "validate-display"
        set LOG_MSG = "Xorg binary present at /usr/X11R6/bin/Xorg"
        logline
    else
        set FATAL_STEP = "validate-display"
        set FATAL_MESSAGE = "Xorg binary not found after package installation"
        set EXIT_CODE = 60
        goto fatal_exit
    endif

    if ( -x /usr/local/bin/xdm ) then
        set LOG_LEVEL = "OK"
        set LOG_STEP = "validate-display"
        set LOG_MSG = "XDM binary present at /usr/local/bin/xdm"
        logline
    else
        set FATAL_STEP = "validate-display"
        set FATAL_MESSAGE = "XDM binary not found after package installation"
        set EXIT_CODE = 60
        goto fatal_exit
    endif

    if ( ! -r "$TARGET_HOME/.xsession" ) then
        set FATAL_STEP = "validate-display"
        set FATAL_MESSAGE = "user session launcher ${TARGET_HOME}/.xsession is missing"
        set EXIT_CODE = 60
        goto fatal_exit
    endif

    id -Gn "$TARGET_USER" | tr ' ' '\n' | grep -x video >/dev/null 2>&1
    if ( $status != 0 ) then
        set FATAL_STEP = "validate-display"
        set FATAL_MESSAGE = "target user ${TARGET_USER} is not in video group"
        set EXIT_CODE = 60
        goto fatal_exit
    endif

    if ( ! -r /etc/X11/xorg.conf.d/00-keyboard.conf ) then
        set FATAL_STEP = "validate-display"
        set FATAL_MESSAGE = "keyboard config file /etc/X11/xorg.conf.d/00-keyboard.conf is missing"
        set EXIT_CODE = 60
        goto fatal_exit
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=11" >! "$CPTMP"
    /bin/echo "name=video-display-configuration" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 11
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "video and display configuration complete"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 11 already completed; skipping by checkpoint"
    logline
endif

###############################################################################
# Phase 12: XDM enablement
###############################################################################
set CURRENT_PHASE = "phase12"
set PHASE_SHOULD_RUN = 1
if ( $RESUME_MODE == 1 && $LAST_COMPLETED_PHASE >= 12 ) then
    set PHASE_SHOULD_RUN = 0
endif
if ( $PHASE_SHOULD_RUN == 1 ) then
    set LOG_LEVEL = "INFO"
    set LOG_STEP = "start"
    set LOG_MSG = "XDM enablement begins"
    logline

    pkg info -e "$PKG_XDM" >/dev/null 2>&1
    if ( $status != 0 ) then
        set FATAL_STEP = "xdm-install"
        set FATAL_MESSAGE = "XDM package ${PKG_XDM} is not installed"
        set EXIT_CODE = 60
        goto fatal_exit
    endif
    grep '^ttyv8[[:space:]]\+"/usr/local/bin/xdm -nodaemon"[[:space:]]\+xterm[[:space:]]\+on' /etc/ttys >/dev/null 2>&1
    if ( $status != 0 ) then
        set FATAL_STEP = "xdm-enable"
        set FATAL_MESSAGE = "/etc/ttys is not configured for XDM on ttyv8"
        set EXIT_CODE = 60
        goto fatal_exit
    endif

    if ( $IMMEDIATE_XDM == 1 ) then
        /bin/kill -HUP 1 >/dev/null 2>&1
        if ( $status == 0 ) then
            set XDM_MODE = "SUCCESS_ACTIVE"
            set LOG_LEVEL = "OK"
            set LOG_STEP = "xdm-activate"
            set LOG_MSG = "init reloaded; XDM activation requested immediately"
            logline
        else
            set XDM_MODE = "SUCCESS_PENDING_REBOOT"
            set NEED_REBOOT = 1
            set LOG_LEVEL = "WARN"
            set LOG_STEP = "xdm-activate"
            set LOG_MSG = "immediate init reload failed; XDM remains pending reboot or manual init restart"
            logline
        endif
    else
        set XDM_MODE = "SUCCESS_PENDING_REBOOT"
        set NEED_REBOOT = 1
        set LOG_LEVEL = "WARN"
        set LOG_STEP = "xdm-activate"
        set LOG_MSG = "conservative mode retained; XDM configured but pending reboot or manual init reload"
        logline
    endif

    if ( $NEED_REBOOT == 1 || $NEED_RELOGIN == 1 ) then
        /bin/echo "pending=1" >! "$REBOOT_REQUIRED_FILE"
        /bin/echo "reason=desktop-refresh-needed" >> "$REBOOT_REQUIRED_FILE"
    else
        /bin/rm -f "$REBOOT_REQUIRED_FILE"
    endif

    set CPTMP = "${BASE_STATE_DIR}/.checkpoint.${RUN_ID}.tmp"
    /bin/echo "phase=12" >! "$CPTMP"
    /bin/echo "name=xdm-enablement" >> "$CPTMP"
    /bin/echo "run_id=${RUN_ID}" >> "$CPTMP"
    /bin/mv -f "$CPTMP" "$CHECKPOINT_FILE"
    set LAST_COMPLETED_PHASE = 12
    set LOG_LEVEL = "OK"
    set LOG_STEP = "end"
    set LOG_MSG = "XDM enablement complete (${XDM_MODE})"
    logline
else
    set LOG_LEVEL = "SKIP"
    set LOG_STEP = "resume"
    set LOG_MSG = "phase 12 already completed; skipping by checkpoint"
    logline
endif

###############################################################################
# Final validation and summary
###############################################################################
set CURRENT_PHASE = "final"
set LOG_LEVEL = "INFO"
set LOG_STEP = "validation"
set LOG_MSG = "final validation begins"
logline

id "$TARGET_USER" >/dev/null 2>&1
if ( $status != 0 ) then
    set FATAL_STEP = "final-validation"
    set FATAL_MESSAGE = "target user ${TARGET_USER} no longer exists"
    set EXIT_CODE = 60
    goto fatal_exit
endif
if ( ! -d "$TARGET_HOME" ) then
    set FATAL_STEP = "final-validation"
    set FATAL_MESSAGE = "target home ${TARGET_HOME} no longer exists"
    set EXIT_CODE = 60
    goto fatal_exit
endif
id -Gn "$TARGET_USER" | tr ' ' '\n' | grep -x video >/dev/null 2>&1
if ( $status != 0 ) then
    set FATAL_STEP = "final-validation"
    set FATAL_MESSAGE = "target user ${TARGET_USER} is not in video group"
    set EXIT_CODE = 60
    goto fatal_exit
endif
foreach reqpkg ( "$PKG_XORG" "$PKG_XDM" "$PKG_GNUSTEP" "$PKG_GNUSTEP_BACK" "$PKG_WINDOWMAKER" )
    pkg info -e "$reqpkg" >/dev/null 2>&1
    if ( $status != 0 ) then
        set FATAL_STEP = "final-validation"
        set FATAL_MESSAGE = "required package ${reqpkg} is missing at final validation"
        set EXIT_CODE = 60
        goto fatal_exit
    endif
end
grep '^ttyv8[[:space:]]\+"/usr/local/bin/xdm -nodaemon"[[:space:]]\+xterm[[:space:]]\+on' /etc/ttys >/dev/null 2>&1
if ( $status != 0 ) then
    set FATAL_STEP = "final-validation"
    set FATAL_MESSAGE = "/etc/ttys does not contain enabled XDM ttyv8 entry"
    set EXIT_CODE = 60
    goto fatal_exit
endif
if ( ! -r /etc/X11/xorg.conf.d/00-keyboard.conf ) then
    set FATAL_STEP = "final-validation"
    set FATAL_MESSAGE = "keyboard config file missing"
    set EXIT_CODE = 60
    goto fatal_exit
endif
if ( ! -r "$TARGET_HOME/.xsession" ) then
    set FATAL_STEP = "final-validation"
    set FATAL_MESSAGE = "user session file ${TARGET_HOME}/.xsession missing"
    set EXIT_CODE = 60
    goto fatal_exit
endif
grep -F "$BEGIN_MARK" /etc/sysctl.conf >/dev/null 2>&1
if ( $status != 0 ) then
    set FATAL_STEP = "final-validation"
    set FATAL_MESSAGE = "managed sysctl block missing"
    set EXIT_CODE = 60
    goto fatal_exit
endif
if ( -r /dev/sndstat && $AUDIO_DEVICE_COUNT > 0 ) then
    cat /dev/sndstat | grep -E "^pcm${AUDIO_SELECTED_UNIT}:" >/dev/null 2>&1
    if ( $status != 0 ) then
        set FATAL_STEP = "final-validation"
        set FATAL_MESSAGE = "selected default audio device ${AUDIO_SELECTED_UNIT} missing at final validation"
        set EXIT_CODE = 60
        goto fatal_exit
    endif
endif

set SUMMARYTMP = "${BASE_STATE_DIR}/.summary.${RUN_ID}.tmp"
/bin/rm -f "$SUMMARYTMP"
/bin/echo "run_id=${RUN_ID}" >! "$SUMMARYTMP"
/bin/echo "timestamp=`date -u +%Y-%m-%dT%H:%M:%SZ`" >> "$SUMMARYTMP"
/bin/echo "target_user=${TARGET_USER}" >> "$SUMMARYTMP"
/bin/echo "target_home=${TARGET_HOME}" >> "$SUMMARYTMP"
/bin/echo "keyboard_layout=${KEYBOARD_LAYOUT}" >> "$SUMMARYTMP"
/bin/echo "gpu_plan=${GPU_PLAN}" >> "$SUMMARYTMP"
/bin/echo "audio_profile=${AUDIO_PROFILE}" >> "$SUMMARYTMP"
/bin/echo "audio_selected_unit=${AUDIO_SELECTED_UNIT}" >> "$SUMMARYTMP"
/bin/echo "backlight_manageable=${BACKLIGHT_MANAGEABLE}" >> "$SUMMARYTMP"
/bin/echo "gnustep_csh_init=${GNUSTEP_CSH_INIT}" >> "$SUMMARYTMP"
/bin/echo "xdm_mode=${XDM_MODE}" >> "$SUMMARYTMP"
/bin/echo "group_changed=${GROUP_CHANGED}" >> "$SUMMARYTMP"
/bin/echo "need_relogin=${NEED_RELOGIN}" >> "$SUMMARYTMP"
/bin/echo "need_reboot=${NEED_REBOOT}" >> "$SUMMARYTMP"
/bin/echo "logfile=${LOGFILE}" >> "$SUMMARYTMP"
/bin/mv -f "$SUMMARYTMP" "$SUMMARY_FILE"
/bin/cp -p "$SUMMARY_FILE" "$LASTRUN_FILE"

set LOG_LEVEL = "OK"
set LOG_STEP = "validation"
set LOG_MSG = "final validation complete; summary written to ${SUMMARY_FILE}"
logline

if ( $GROUP_CHANGED == 1 || $NEED_RELOGIN == 1 || $NEED_REBOOT == 1 || "$XDM_MODE" == "SUCCESS_PENDING_REBOOT" ) then
    set EXIT_CODE = 10
else
    set EXIT_CODE = 0
endif

set LOG_LEVEL = "INFO"
set LOG_STEP = "summary"
set LOG_MSG = "run completed with exit code ${EXIT_CODE}; logfile ${LOGFILE}; xdm ${XDM_MODE}; relogin ${NEED_RELOGIN}; reboot ${NEED_REBOOT}"
logline

/bin/rm -f "$LOCKFILE"
exit $EXIT_CODE

handle_interrupt:
set CURRENT_PHASE = "interrupt"
set LOG_LEVEL = "ERROR"
set LOG_STEP = "signal"
set LOG_MSG = "execution interrupted; lock will be released"
logline
/bin/rm -f "$LOCKFILE"
exit 90

fatal_exit:
set CURRENT_PHASE = "fatal"
set LOG_LEVEL = "ERROR"
set LOG_STEP = "$FATAL_STEP"
set LOG_MSG = "$FATAL_MESSAGE"
logline
if ( -e "$LOCKFILE" ) /bin/rm -f "$LOCKFILE"
if ( $EXIT_CODE == 0 ) set EXIT_CODE = 90
exit $EXIT_CODE
