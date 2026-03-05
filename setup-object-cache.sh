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
log " PRE-SCAN: กำลังสแกน cPanel Accounts..."
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

log "--------------------------------------"
log " ผลสแกน cPanel Accounts"
log "--------------------------------------"
log " 👥 รวม cPanel Accounts ทั้งหมด : $TOTAL_ACCOUNTS accounts"
log " 📁 อยู่ใน /home เท่านั้น        : $COUNT_HOME1 accounts"
log " 📁 อยู่ใน /home2 เท่านั้น       : $COUNT_HOME2 accounts"
log " 📁 อยู่ทั้ง /home และ /home2    : $COUNT_BOTH accounts"
log "--------------------------------------"

if [ "$COUNT_HOME1" -gt 0 ]; then
    log " 📂 Accounts ใน /home:"
    for u in "${CPANEL_USERS_HOME1[@]}"; do
        log "    ✦ $u  →  /home/$u"
    done
fi

if [ "$COUNT_HOME2" -gt 0 ]; then
    log " 📂 Accounts ใน /home2:"
    for u in "${CPANEL_USERS_HOME2[@]}"; do
        log "    ✦ $u  →  /home2/$u"
    done
fi

if [ "$COUNT_BOTH" -gt 0 ]; then
    log " 📂 Accounts ที่อยู่ทั้ง /home และ /home2:"
    for u in "${CPANEL_USERS_BOTH[@]}"; do
        log "    ✦ $u  →  /home/$u  +  /home2/$u"
    done
fi

if [ "$TOTAL_ACCOUNTS" -eq 0 ]; then
    log "⚠️  WARNING: ไม่พบ cPanel accounts ใน /home หรือ /home2"
    log "   กรุณาตรวจสอบว่าเซิร์ฟเวอร์นี้ใช้ cPanel จริงหรือไม่"
fi

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

scan_wordpress_in() {
    local base="$1"   # /home หรือ /home2
    [ ! -d "$base" ] && return

    for user_dir in "${base}"/*/; do
        local user=$(basename "$user_dir")
        echo "$user" | grep -qE "^(${SKIP_DIRS})$" && continue
        [ ! -d "${user_dir}public_html" ] && continue

        local pub="${user_dir}public_html"

        # ใช้ find เพื่อหา wp-config.php ใน addon domains (subdirectory ของ public_html)
        # -mindepth 2 = ข้าม public_html/wp-config.php (main domain) ตามที่ต้องการ
        # -maxdepth 3 = รองรับ public_html/domain/ และ public_html/domain/subdir/
        while IFS= read -r wpconfig; do
            DIRS+=("$(dirname "$wpconfig")/")
        done < <(find "$pub" -mindepth 2 -maxdepth 3 -name "wp-config.php" 2>/dev/null)
    done
}

scan_wordpress_in "/home"
scan_wordpress_in "/home2"

TOTAL=${#DIRS[@]}
log "พบ WordPress ทั้งหมด: $TOTAL เว็บ (จาก $TOTAL_ACCOUNTS cPanel accounts)"
log "======================================"

if [ "$TOTAL" -eq 0 ]; then
    log "⚠️  ไม่พบ WordPress เลย หยุดการทำงาน"
    exit 0
fi

# ====================================
# process_site: Check + Fix ในรอบเดียว
# ====================================
log " กำลังตรวจสอบและแก้ไข (single-pass)..."
log "======================================"

# แปลงค่าจาก wp-cli ให้ clean: ตัด whitespace + single-quotes ที่ติดมา
_clean() { echo "$1" | tr -d "[:space:]'" ; }

process_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"

    local base=$(echo "$dir" | cut -d'/' -f2)
    local user=$(echo "$dir" | cut -d'/' -f3)
    local sub=$(echo "$dir" | cut -d'/' -f5)
    local SITE="[${base}/${user}] ${sub:-(main)}"
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

    # --- เช็ค plugin ---
    if ! _wp plugin is-installed litespeed-cache; then
        touch "${RESULT_DIR}/check/noplugin_${UNIQUE}"
        return
    fi
    if ! _wp plugin is-active litespeed-cache; then
        touch "${RESULT_DIR}/check/inactive_${UNIQUE}"
        return
    fi

    # --- อ่านค่าปัจจุบัน (clean quotes + whitespace ออก) ---
    local CUR_OBJ;  CUR_OBJ=$(_clean "$(_wp_get litespeed-option get object)")
    local CUR_KIND; CUR_KIND=$(_clean "$(_wp_get litespeed-option get object-kind)")
    local CUR_HOST; CUR_HOST=$(_wp_get litespeed-option get object-host | tr -d '[:space:]')
    local CUR_PORT; CUR_PORT=$(_clean "$(_wp_get litespeed-option get object-port)")
    local CUR_USER; CUR_USER=$(_clean "$(_wp_get litespeed-option get object-user)")
    local CUR_PSWD; CUR_PSWD=$(_clean "$(_wp_get litespeed-option get object-pswd)")

    # --- เช็คทีละ field เฉพาะที่ผิดจริง ---
    local NEED_FIX=()

    # object cache ON/OFF — ถ้า ON อยู่แล้วข้ามเงียบๆ
    [ "$CUR_OBJ" != "1" ] && NEED_FIX+=("object")

    # method — ถ้า Redis (1) อยู่แล้วข้ามเงียบๆ
    [ "$CUR_KIND" != "1" ] && NEED_FIX+=("object-kind")

    # host — ถ้าตรงอยู่แล้วข้ามเงียบๆ
    [ "$CUR_HOST" != "/var/run/redis/redis.sock" ] && NEED_FIX+=("object-host")

    # port — ถ้า 0 อยู่แล้วข้ามเงียบๆ
    [ "$CUR_PORT" != "0" ] && NEED_FIX+=("object-port")

    # user/password — ถ้าว่างอยู่แล้วไม่ต้องแจ้ง ไม่ต้องทำอะไร
    [ -n "$CUR_USER" ] && NEED_FIX+=("object-user")
    [ -n "$CUR_PSWD" ] && NEED_FIX+=("object-pswd")

    # --- ถ้าครบทุก field ถูกต้องหมด: skip เงียบๆ ---
    if [ "${#NEED_FIX[@]}" -eq 0 ]; then
        _log "✅ SKIP : $SITE"
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

    # --- แสดงเฉพาะ field ที่เปลี่ยน (จากอะไร → เป็นอะไร) ---
    _log "======================================"
    _log "🔧 FIX (${#NEED_FIX[@]} รายการ): $SITE"
    for field in "${NEED_FIX[@]}"; do
        case "$field" in
            object)
                local OBJ_OLD; [ "$CUR_OBJ" = "1" ] && OBJ_OLD="ON" || OBJ_OLD="OFF"
                _log "   ❌→✅ Object Cache : ${OBJ_OLD} → ON"
                ;;
            object-kind)
                _log "   ❌→✅ Method       : $(_kind_label "$CUR_KIND") → Redis"
                ;;
            object-host)
                _log "   ❌→✅ Host         : '${CUR_HOST:-empty}' → /var/run/redis/redis.sock"
                ;;
            object-port)
                _log "   ❌→✅ Port         : '${CUR_PORT:-empty}' → 0"
                ;;
            object-user)
                _log "   ❌→✅ User         : '${CUR_USER}' → (ว่างเปล่า)"
                ;;
            object-pswd)
                _log "   ❌→✅ Password     : (มีค่า) → (ว่างเปล่า)"
                ;;
        esac
    done

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
        _log "--------------------------------------"
        _log "   ❌ FAILED : แก้ไขไม่สำเร็จ"
        _log "   📁 Site   : $SITE"
        _log "======================================"
        touch "${RESULT_DIR}/check/failed_${UNIQUE}"
    else
        _log "   ✅ FIXED  : แก้ไขครบทุกรายการแล้ว"
        _log "======================================"
        touch "${RESULT_DIR}/check/fixed_${UNIQUE}"
    fi
}

export -f process_site
export -f _clean

declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    process_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
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
log " รวม WordPress          : $TOTAL เว็บ"
log " ✅ ถูกต้องอยู่แล้ว    : $CORRECT เว็บ"
log " ✅ แก้ไขสำเร็จ         : $FIXED เว็บ"
log " ❌ แก้ไขไม่สำเร็จ      : $FAILED เว็บ"
log " ⏭  ข้ามทั้งหมด         : $SKIPPED เว็บ"
log " เวลาที่ใช้             : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log " ✅ รัน verify ต่อด้วย  : verify-object-cache.sh"
log "======================================"
