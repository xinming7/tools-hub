#!/system/bin/sh
# ============================================
# 循环下载服务（6 小时一次）
# - 单实例锁（带 PID 身份校验，避免 PID 复用误判）
# - 启动自检（root / 目录 / 下载工具）
# - 等待网络就绪
# - 下载完整性校验 + 原子替换
# - 日志自动截断
# - 退出自动清理锁
# ============================================

# ---------- 配置 ----------
DOWNLOAD_URL=""
TARGET_DIR="/data/data/com.boxproxy.box/files/box/mihomo/"
TARGET_FILE="mihomo_warp_vg.yaml"
TARGET_UID=""                # 可选：设置文件属主，如 "10123"（app UID），留空不改
LOG_FILE="/data/local/tmp/mihomo_download.log"
LOG_MAX_LINES=2000
LOCK_DIR="/data/local/tmp/mihomo_download.lock"
INTERVAL=21600 #10800
HTTP_TIMEOUT=30
NET_WAIT_MAX=600
# -------------------------

# 统一时间格式，兼容旧 toybox
now() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(now) | $1" >> "$LOG_FILE"; }

# 日志截断，避免无限增长
trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null)
    [ -z "$lines" ] && return 0
    if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" \
            && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

# ========== 1. 单实例锁 ==========
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    ALIVE=0
    if [ -n "$OLD_PID" ] && [ -d "/proc/$OLD_PID" ]; then
        # 进一步校验 cmdline，排除 PID 复用
        if tr '\0' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null \
           | grep -q "mihomo_download"; then
            ALIVE=1
        fi
    fi

    if [ "$ALIVE" -eq 1 ]; then
        log "检测到已有实例运行 (PID=$OLD_PID)，本次启动放弃"
        exit 0
    fi

    log "发现残留锁 (旧 PID=$OLD_PID 已失效)，清理后继续"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "错误：无法创建锁目录，退出"
        exit 1
    fi
fi
echo $$ > "$LOCK_DIR/pid"

# ========== 2. 退出清理 ==========
cleanup() {
    rm -rf "$LOCK_DIR"
    log "===== 服务退出 (PID=$$) ====="
}
trap cleanup EXIT INT TERM HUP

# ========== 3. 启动自检 ==========
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    log "自检失败：需要 root 权限运行"
    exit 1
fi

if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
    log "自检失败：无法创建目录 $TARGET_DIR"
    exit 1
fi

DL_TOOL=""
if command -v curl >/dev/null 2>&1; then
    DL_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
    DL_TOOL="wget"
elif command -v busybox >/dev/null 2>&1; then
    DL_TOOL="busybox"
else
    log "自检失败：未找到 curl / wget / busybox"
    exit 1
fi

log "===== 服务启动 PID=$$ 下载工具=$DL_TOOL ====="

# ========== 4. 等待网络 ==========
wait_for_network() {
    waited=0
    while [ "$waited" -lt "$NET_WAIT_MAX" ]; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 \
           || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    return 1
}

# ========== 5. 下载 ==========
download_file() {
    url="$1"; out="$2"
    case "$DL_TOOL" in
        curl)
            curl -fsSL --connect-timeout "$HTTP_TIMEOUT" \
                 --retry 2 --retry-delay 3 -o "$out" "$url"
            ;;
        wget)
            wget -q --timeout="$HTTP_TIMEOUT" --tries=3 -O "$out" "$url"
            ;;
        busybox)
            busybox wget -q -T "$HTTP_TIMEOUT" -O "$out" "$url"
            ;;
    esac
    return $?
}

do_download() {
    TMP="${TARGET_DIR}${TARGET_FILE}.tmp"
    log "开始下载：$DOWNLOAD_URL"

    if ! download_file "$DOWNLOAD_URL" "$TMP"; then
        rm -f "$TMP"
        log "下载失败，下次重试"
        return 1
    fi

    # 完整性校验：文件存在且非空
    SIZE=$(wc -c < "$TMP" 2>/dev/null)
    if [ -z "$SIZE" ] || [ "$SIZE" -lt 1 ]; then
        rm -f "$TMP"
        log "下载内容为空，丢弃"
        return 1
    fi

    mv -f "$TMP" "${TARGET_DIR}${TARGET_FILE}"
    chmod 644 "${TARGET_DIR}${TARGET_FILE}"
    [ -n "$TARGET_UID" ] && \
        chown "$TARGET_UID:$TARGET_UID" "${TARGET_DIR}${TARGET_FILE}" 2>/dev/null

    log "下载成功 → ${TARGET_DIR}${TARGET_FILE} (${SIZE} 字节)"
    return 0
}

# ========== 6. 主循环 ==========
trim_log

if wait_for_network; then
    do_download
else
    log "首次等待网络超时，进入循环重试"
fi

while true; do
    log "等待 3 小时..."
    sleep "$INTERVAL"
    trim_log
    if wait_for_network; then
        do_download
    else
        log "网络仍未就绪，跳过本轮"
    fi
done
