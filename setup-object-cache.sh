#!/bin/bash

LOG_FILE="/var/log/lscwp-setup.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-setup-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=30

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
# ====================================
DIRS=()
for dir in /home/*/public_html/*/; do
    if [ -f "${dir}wp-config.php" ]; then
        DIRS+=("$dir")
    fi
done

TOTAL=${#DIRS[@]}
log "พบ WordPress ทั้งหมด: $TOTAL เว็บ"
log "======================================"

# ====================================
# PHASE 1: Check
# ====================================
log " PHASE 1: กำลังตรวจสอบค่าปัจจุบัน..."
log "======================================"

check_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local SITE=$(echo "$dir" | awk -F'/' '{print $5"/"$7}')
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    if ! _wp plugin is-installed litespeed-cache; then
        _log "⏭  NO LITESPEED: $SITE"
        touch "${RESULT_DIR}/check/noplugin_${UNIQUE}"
        return
    fi

    if ! _wp plugin is-active litespeed-cache; then
        _log "⏭  INACTIVE: $SITE"
        touch "${RESULT_DIR}/check/inactive_${UNIQUE}"
        return
    fi

    local CUR_OBJ=$(_wp litespeed-option get object | tr -d '[:space:]')
    local CUR_KIND=$(_wp litespeed-option get object-kind | tr -d '[:space:]')
    local CUR_HOST=$(_wp litespeed-option get object-host | tr -d '[:space:]')
    local CUR_PORT=$(_wp litespeed-option get object-port | tr -d '[:space:]')

    if [ "$CUR_OBJ" = "1" ] && [ "$CUR_KIND" = "1" ] && \
       [ "$CUR_HOST" = "/var/run/redis/redis.sock" ] && [ "$CUR_PORT" = "0" ]; then
        _log "✅ CORRECT: $SITE"
        touch "${RESULT_DIR}/check/correct_${UNIQUE}"
    else
        _log "⚠️  NEEDS FIX: $SITE"
        _log "   object=$CUR_OBJ | kind=$CUR_KIND | host=$CUR_HOST | port=$CUR_PORT"
        ( flock 200; echo "$dir" >> "$RESULT_DIR/needs_fix.txt" ) 200>"$LOCK_FILE"
        touch "${RESULT_DIR}/check/needsfix_${UNIQUE}"
    fi
}

export -f check_site

declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    check_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

CORRECT=$(find "$RESULT_DIR/check" -name "correct_*" 2>/dev/null | wc -l)
NEEDSFIX=$(find "$RESULT_DIR/check" -name "needsfix_*" 2>/dev/null | wc -l)
NOPLUGIN=$(find "$RESULT_DIR/check" -name "noplugin_*" 2>/dev/null | wc -l)
INACTIVE=$(find "$RESULT_DIR/check" -name "inactive_*" 2>/dev/null | wc -l)
SKIPPED=$(( NOPLUGIN + INACTIVE ))

log "======================================"
log " สรุปผล PHASE 1"
log " รวมทั้งหมด         : $TOTAL เว็บ"
log " ✅ ถูกต้องแล้ว      : $CORRECT เว็บ"
log " ⚠️  ต้องแก้ไข       : $NEEDSFIX เว็บ"
log " ⏭  ข้าม (No Plugin) : $NOPLUGIN เว็บ"
log " ⏭  ข้าม (Inactive)  : $INACTIVE เว็บ"
log "======================================"

if [ "$NEEDSFIX" -eq 0 ]; then
    log "✅ ทุกเว็บถูกต้องแล้ว ไม่ต้องแก้ไขอะไร"
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    log " เวลาที่ใช้ : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
    log "======================================"
    exit 0
fi

# ====================================
# PHASE 2: Setup
# ====================================
log " PHASE 2: กำลังแก้ไข $NEEDSFIX เว็บ..."
log "======================================"

fix_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local SITE=$(echo "$dir" | awk -F'/' '{print $5"/"$7}')
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    local FAILED=0

    _wp litespeed-option set object 1 || FAILED=1
    _wp litespeed-option set object-kind 1 || FAILED=1
    _wp litespeed-option set object-host "/var/run/redis/redis.sock" || FAILED=1
    _wp litespeed-option set object-port "0" || FAILED=1
    _wp litespeed-option set object-user "" || \
    _wp litespeed-option set object-user " " || FAILED=1
    _wp litespeed-option set object-pswd "" || \
    _wp litespeed-option set object-pswd " " || FAILED=1

    if [ "$FAILED" -eq 1 ]; then
        _log "❌ FAILED (Set Error): $SITE"
        touch "${RESULT_DIR}/fix/failed_${UNIQUE}"
        return
    fi

    _log "✅ SET DONE: $SITE"
    touch "${RESULT_DIR}/fix/success_${UNIQUE}"
}

export -f fix_site

declare -a PIDS=()
while IFS= read -r dir; do
    fix_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done < "$RESULT_DIR/needs_fix.txt"
for pid in "${PIDS[@]}"; do wait "$pid"; done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

SUCCESS=$(find "$RESULT_DIR/fix" -name "success_*" 2>/dev/null | wc -l)
FAILED=$(find "$RESULT_DIR/fix" -name "failed_*" 2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " รวมทั้งหมด         : $TOTAL เว็บ"
log " ✅ ถูกต้องอยู่แล้ว  : $CORRECT เว็บ"
log " ✅ Set สำเร็จ       : $SUCCESS เว็บ"
log " ❌ Set ไม่สำเร็จ    : $FAILED เว็บ"
log " ⏭  ข้ามทั้งหมด      : $SKIPPED เว็บ"
log " เวลาที่ใช้          : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log " ✅ รัน verify ต่อด้วย: verify-object-cache.sh"
log "======================================"
