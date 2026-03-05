#!/bin/bash

LOG_FILE="/var/log/lscwp-setup.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-setup-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=30

# directories ที่ไม่ใช่ cPanel user
SKIP_DIRS="virtfs|cPanelInstall|almalinux|mig_data|lscache|error_log|lost\+found"

log() {
    local DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

cleanup() {
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR"
mkdir -p "$RESULT_DIR/check"
mkdir -p "$RESULT_DIR/fix"

START_TIME=$(date +%s)

# ====================================
# เช็ค WP-CLI
# ====================================
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI กรุณาติดตั้งก่อน"
    exit 1
fi

# ====================================
# เช็ค Redis
# ====================================
if [ ! -S "/var/run/redis/redis.sock" ]; then
    log "❌ ERROR: ไม่พบ Redis Socket ที่ /var/run/redis/redis.sock"
    exit 1
fi

REDIS_PING=$(redis-cli -s /var/run/redis/redis.sock ping 2>/dev/null)
if [ "$REDIS_PING" != "PONG" ]; then
    log "❌ ERROR: Redis ไม่ตอบสนอง (ping ได้ = ${REDIS_PING:-ไม่มีผล})"
    exit 1
fi

# ====================================
# ฟังก์ชัน: ดึงรายชื่อ cPanel accounts จริงๆ
# รองรับ 3 วิธี ตามความพร้อมของระบบ
# ====================================
get_cpanel_accounts() {
    local base_dir="$1"
    local accounts=()

    # วิธีที่ 1: /var/cpanel/users/ (แม่นที่สุด)
    if [ -d "/var/cpanel/users" ]; then
        while IFS= read -r user; do
            [ -d "${base_dir}/${user}" ] && accounts+=("$user")
        done < <(ls /var/cpanel/users/ 2>/dev/null | grep -vE "^(root|nobody)$")

    # วิธีที่ 2: /etc/trueuserdomains
    elif [ -f "/etc/trueuserdomains" ]; then
        while IFS= read -r user; do
            [ -d "${base_dir}/${user}" ] && accounts+=("$user")
        done < <(awk '{print $NF}' /etc/trueuserdomains 2>/dev/null | sort -u | grep -vE "^(root|nobody)$")

    # วิธีที่ 3: สแกน directory ตรงๆ กรองเฉพาะที่มี public_html
    else
        for d in "${base_dir}"/*/; do
            local user=$(basename "$d")
            echo "$user" | grep -qE "^(${SKIP_DIRS})$" && continue
            [ -d "${d}public_html" ] && accounts+=("$user")
        done
    fi

    echo "${accounts[@]}"
}

# ====================================
# PRE-SCAN: สแกน cPanel Accounts
# ====================================
log "======================================"

CPANEL_USERS_HOME1=()
CPANEL_USERS_HOME2=()
CPANEL_USERS_BOTH=()
CPANEL_USERS_ALL=()

# --- สแกน /home ---
if [ -d "/home" ]; then
    read -ra USERS_H1 <<< "$(get_cpanel_accounts /home)"
    for user in "${USERS_H1[@]}"; do
        IN_HOME2=false
        [ -d "/home2/${user}" ] && IN_HOME2=true

        if $IN_HOME2; then
            CPANEL_USERS_BOTH+=("$user")
        else
            CPANEL_USERS_HOME1+=("$user")
        fi
        CPANEL_USERS_ALL+=("$user")
    done
fi

# --- สแกน /home2 (เฉพาะที่ยังไม่ถูกนับ) ---
if [ -d "/home2" ]; then
    read -ra USERS_H2 <<< "$(get_cpanel_accounts /home2)"
    for user in "${USERS_H2[@]}"; do
        already=false
        for u in "${CPANEL_USERS_BOTH[@]}"; do
            [ "$u" = "$user" ] && already=true && break
        done
        if ! $already; then
            CPANEL_USERS_HOME2+=("$user")
            CPANEL_USERS_ALL+=("$user")
        fi
    done
fi

TOTAL_ACCOUNTS=${#CPANEL_USERS_ALL[@]}
COUNT_HOME1=${#CPANEL_USERS_HOME1[@]}
COUNT_HOME2=${#CPANEL_USERS_HOME2[@]}
COUNT_BOTH=${#CPANEL_USERS_BOTH[@]}

log " 👥 cPanel Accounts ทั้งหมด : $TOTAL_ACCOUNTS accounts"
log "======================================"

# ====================================
# คำนวณ MAX_JOBS อัตโนมัติ
# ====================================
CPU_CORES=$(nproc)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
MAX_JOBS_BY_RAM=$(( TOTAL_RAM_MB / RAM_PER_JOB_MB ))

if [ "$CPU_CORES" -lt "$MAX_JOBS_BY_RAM" ]; then
    MAX_JOBS=$CPU_CORES
else
    MAX_JOBS=$MAX_JOBS_BY_RAM
fi

[ "$MAX_JOBS" -lt 1 ] && MAX_JOBS=1
[ "$MAX_JOBS" -gt 20 ] && MAX_JOBS=20

log "======================================"
log " LITESPEED OBJECT CACHE SETUP"
log " เริ่มเวลา      : $(date '+%Y-%m-%d %H:%M:%S')"
log " CPU Cores     : $CPU_CORES Core"
log " Total RAM     : $TOTAL_RAM_MB MB"
log " Auto MAX_JOBS : $MAX_JOBS"
log " Redis Status  : ✅ PONG"
log " WP-CLI        : ✅ $(wp --version --allow-root 2>/dev/null)"
log "======================================"

# ====================================
# หา WordPress ทั้งหมด
# รองรับ: public_html โดยตรง (main domain) + subdirectory (addon domains)
# รองรับ: /home และ /home2
# ====================================
DIRS=()

# ====================================
# สแกนหา WordPress ทุกเว็บบนเซิร์ฟเวอร์
# ไม่สนใจ directory structure
# validate ด้วย wp-includes/version.php และ dedup ด้วย inode
# ====================================
declare -A SEEN_INODE

# EXCLUDE patterns
EXCLUDE_PATHS="wp-content|node_modules|\.git|/backup|softaculous_backups|wordpress-backups|/cache|/tmp|/logs|\.trash"

_is_real_wp() {
    [ -f "${1}wp-includes/version.php" ] && return 0
    return 1
}

_add_wp_dir() {
    local site_dir="$1"
    local inode
    inode=$(stat -c "%d:%i" "${site_dir}wp-config.php" 2>/dev/null) || return
    [ -n "${SEEN_INODE[$inode]+_}" ] && return
    SEEN_INODE[$inode]=1
    DIRS+=("$site_dir")
}

scan_all_wordpress() {
    local base="$1"
    [ ! -d "$base" ] && return

    for user_dir in "${base}"/*/; do
        [ ! -d "$user_dir" ] && continue
        local user
        user=$(basename "$user_dir")
        echo "$user" | grep -qE "^(${SKIP_DIRS})$" && continue

        while IFS= read -r wpconfig; do
            local site_dir
            site_dir="$(dirname "$wpconfig")/"

            # ข้าม path ที่อยู่ใน exclude list
            echo "$site_dir" | grep -qE "${EXCLUDE_PATHS}" && continue

            # validate: ต้องมี wp-includes/version.php
            _is_real_wp "$site_dir" || continue

            _add_wp_dir "$site_dir"

        done < <(find "$user_dir" -maxdepth 6 -name "wp-config.php" -type f 2>/dev/null)
    done
}

scan_all_wordpress "/home"
scan_all_wordpress "/home2"

# ตรวจสอบเบื้องต้นว่ามี WordPress อย่างน้อย 1 เว็บ
if [ "${#DIRS[@]}" -eq 0 ]; then
    log "⚠️  ไม่พบ WordPress เลย หยุดการทำงาน"
    exit 0
fi

# นับจำนวนเว็บทั้งหมดสำหรับแสดง progress
TOTAL_SITES=${#DIRS[@]}
COUNTER_FILE="$RESULT_DIR/counter"
echo 0 > "$COUNTER_FILE"

# ====================================
# process_site: Check + Fix ในรอบเดียว
# ====================================
log " จำนวน WordPress : $TOTAL_SITES เว็บ"
log "======================================"

# แปลงค่าจาก wp-cli ให้ clean: ตัด whitespace + single-quotes ที่ติดมา
_clean() { echo "$1" | tr -d "[:space:]'" ; }

process_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local TOTAL_SITES="$6"
    local COUNTER_FILE="$7"

    local base=$(echo "$dir" | cut -d'/' -f2)
    local user=$(echo "$dir" | cut -d'/' -f3)
    # ใช้ basename ของ dir เป็นชื่อเว็บ รองรับทุก structure
    local site_name
    site_name=$(basename "${dir%/}")
    # ถ้า basename คือ public_html ให้ขึ้นไปชั้นบน
    [ "$site_name" = "public_html" ] && site_name=$(basename "$(dirname "${dir%/}")")
    local SITE="[${base}/${user}] ${site_name}"
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    # get: ต้องการ stdout | set: suppress ทั้ง stdout และ stderr
    _wp_get() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }
    _wp_set() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root >/dev/null 2>&1
    }
    _wp() { _wp_get "$@"; }

    # atomic counter increment + read
    _next_count() {
        local n
        ( flock 201
          n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
          n=$(( n + 1 ))
          echo "$n" > "$COUNTER_FILE"
          echo "$n"
        ) 201>"${COUNTER_FILE}.lock"
    }

    # --- เช็ค plugin ---
    if ! _wp plugin is-installed litespeed-cache; then
        touch "${RESULT_DIR}/check/noplugin_${UNIQUE}"
        return
    fi
    if ! _wp plugin is-active litespeed-cache; then
        touch "${RESULT_DIR}/check/inactive_${UNIQUE}"
        return
    fi

    # --- อ่านค่าทั้งหมดใน 1 call (เร็วกว่า 6x) ---
    local RAW_OPTS
    RAW_OPTS=$(_wp_get litespeed-option list 2>/dev/null)

    _get_opt() {
        echo "$RAW_OPTS" | grep -m1 "^| $1 " | awk -F'|' '{print $3}' | tr -d '[:space:]\'"''"
    }

    local CUR_OBJ;  CUR_OBJ=$(_get_opt "object")
    local CUR_KIND; CUR_KIND=$(_get_opt "object-kind")
    local CUR_HOST; CUR_HOST=$(_get_opt "object-host")
    local CUR_PORT; CUR_PORT=$(_get_opt "object-port")
    local CUR_USER; CUR_USER=$(_get_opt "object-user")
    local CUR_PSWD; CUR_PSWD=$(_get_opt "object-pswd")

    # fallback: ถ้า list ไม่ work ให้ get ทีละตัว
    if [ -z "$CUR_OBJ" ] && [ -z "$CUR_HOST" ]; then
        CUR_OBJ=$(_clean "$(_wp_get litespeed-option get object)")
        CUR_KIND=$(_clean "$(_wp_get litespeed-option get object-kind)")
        CUR_HOST=$(_wp_get litespeed-option get object-host | tr -d '[:space:]')
        CUR_PORT=$(_clean "$(_wp_get litespeed-option get object-port)")
        CUR_USER=$(_clean "$(_wp_get litespeed-option get object-user)")
        CUR_PSWD=$(_clean "$(_wp_get litespeed-option get object-pswd)")
    fi

    # normalize empty values
    [ -z "$CUR_PORT" ] && CUR_PORT="0"
    [ -z "$CUR_OBJ"  ] && CUR_OBJ="0"
    [ -z "$CUR_KIND" ] && CUR_KIND="0"


    # --- เช็คทีละ field เฉพาะที่ผิดจริง ---
    local NEED_FIX=()

    # object cache ON/OFF — ถ้า ON (1) อยู่แล้วข้ามเงียบๆ
    [ "$CUR_OBJ"  != "1" ] && NEED_FIX+=("object")

    # method — ถ้า Redis (1) อยู่แล้วข้ามเงียบๆ
    [ "$CUR_KIND" != "1" ] && NEED_FIX+=("object-kind")

    # host — ถ้าตรงอยู่แล้วข้ามเงียบๆ
    [ "$CUR_HOST" != "/var/run/redis/redis.sock" ] && NEED_FIX+=("object-host")

    # port — '' และ '0' ถือว่าถูกต้องทั้งคู่ (normalize แล้วข้างบน)
    [ "$CUR_PORT" != "0" ] && NEED_FIX+=("object-port")

    # user/password — ถ้าว่างอยู่แล้วไม่ต้องแจ้ง ไม่ต้องทำอะไร
    [ -n "$CUR_USER" ] && NEED_FIX+=("object-user")
    [ -n "$CUR_PSWD" ] && NEED_FIX+=("object-pswd")

    # --- ถ้าครบทุก field ถูกต้องหมด: skip เงียบๆ ---
    if [ "${#NEED_FIX[@]}" -eq 0 ]; then
        local IDX; IDX=$(_next_count)
        _log "✔️  Object Cache Already Set : [${IDX}/${TOTAL_SITES}] $SITE"
        touch "${RESULT_DIR}/check/correct_${UNIQUE}"
        return
    fi

    # --- label helper ---
    _kind_label() {
        case "$1" in
            0) echo "Memcached" ;;
            1) echo "Redis" ;;
            *) echo "${1:-unknown}" ;;
        esac
    }

    # --- build change summary แบบ inline ---
    local CHANGES=""
    for field in "${NEED_FIX[@]}"; do
        case "$field" in
            object)
                local OBJ_OLD; [ "$CUR_OBJ" = "1" ] && OBJ_OLD="ON" || OBJ_OLD="OFF"
                CHANGES="${CHANGES} ⚙️ Object Cache: ${OBJ_OLD} ► ON  |"
                ;;
            object-kind)
                CHANGES="${CHANGES} ⚙️ Method: $(_kind_label "$CUR_KIND") ► Redis  |"
                ;;
            object-host)
                CHANGES="${CHANGES} ⚙️ Host: '${CUR_HOST:-empty}' ► /var/run/redis/redis.sock  |"
                ;;
            object-port)
                CHANGES="${CHANGES} ⚙️ Port: '${CUR_PORT:-0}' ► 0  |"
                ;;
            object-user)
                CHANGES="${CHANGES} ⚙️ User: '${CUR_USER}' ► (ว่าง)  |"
                ;;
            object-pswd)
                CHANGES="${CHANGES} ⚙️ Password: (มีค่า) ► (ว่าง)  |"
                ;;
        esac
    done
    CHANGES="${CHANGES%  |}"
    local IDX; IDX=$(_next_count)
    _log "🔧 Object Cache Fixed : [${IDX}/${TOTAL_SITES}] $SITE  ${CHANGES}"

    # --- แก้ไขเฉพาะ field ที่ผิด ---
    local FAILED=0
    for field in "${NEED_FIX[@]}"; do
        case "$field" in
            object)      _wp_set litespeed-option set object 1 || FAILED=1 ;;
            object-kind) _wp_set litespeed-option set object-kind 1 || FAILED=1 ;;
            object-host) _wp_set litespeed-option set object-host "/var/run/redis/redis.sock" || FAILED=1 ;;
            object-port) _wp_set litespeed-option set object-port "0" || FAILED=1 ;;
            object-user) _wp_set litespeed-option set object-user "" || _wp_set litespeed-option set object-user " " || FAILED=1 ;;
            object-pswd) _wp_set litespeed-option set object-pswd "" || _wp_set litespeed-option set object-pswd " " || FAILED=1 ;;
        esac
    done

    if [ "$FAILED" -eq 1 ]; then
        local IDX; IDX=$(_next_count)
        _log "❌ FAILED : [${IDX}/${TOTAL_SITES}] $SITE"
        touch "${RESULT_DIR}/check/failed_${UNIQUE}"
    else
        touch "${RESULT_DIR}/check/fixed_${UNIQUE}"
    fi
}

export -f process_site
export -f _clean

declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    process_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" "$TOTAL_SITES" "$COUNTER_FILE" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

CORRECT=$(find "$RESULT_DIR/check" -name "correct_*" 2>/dev/null | wc -l)
FIXED=$(find   "$RESULT_DIR/check" -name "fixed_*"   2>/dev/null | wc -l)
FAILED=$(find  "$RESULT_DIR/check" -name "failed_*"  2>/dev/null | wc -l)
NOPLUGIN=$(find "$RESULT_DIR/check" -name "noplugin_*" 2>/dev/null | wc -l)
INACTIVE=$(find "$RESULT_DIR/check" -name "inactive_*" 2>/dev/null | wc -l)
SKIPPED=$(( NOPLUGIN + INACTIVE ))

log "======================================"
log " สรุปผลรวม"
log " 👥 cPanel Accounts    : $TOTAL_ACCOUNTS accounts"
log "    /home  : $COUNT_HOME1 | /home2 : $COUNT_HOME2 | ทั้งคู่ : $COUNT_BOTH"
log "--------------------------------------"
log " รวม WordPress          : $(( CORRECT + FIXED + FAILED + SKIPPED )) เว็บ (นับจากผลจริง)"
log " ✔️  Object Cache Already Set : $CORRECT เว็บ (ตั้งค่าไว้ถูกต้องอยู่แล้วไม่ได้ปรับเปลี่ยน)"
log " 🔧 Object Cache Fixed        : $FIXED เว็บ (อัปเดตเรียบร้อย)"
log " ❌ แก้ไขไม่สำเร็จ            : $FAILED เว็บ"
log " ⏭  ข้ามทั้งหมด               : $SKIPPED เว็บ"
log " เวลาที่ใช้                   : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log "======================================"
