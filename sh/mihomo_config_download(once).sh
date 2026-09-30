#!/system/bin/sh
# ============================================
# 启动后立即下载一次文件（不循环）
# ============================================

# ---------- 配置区域 ----------
DOWNLOAD_URL=""   # ← 替换为实际下载网址
TARGET_DIR="/data/data/com.boxproxy.box/files/box/mihomo/"
TARGET_FILE="mihomo_warp_vg.yaml"                       # 目标文件名，按需修改
LOG_FILE="/data/local/tmp/mihomo_download.log"
# -----------------------------

log() {
    echo "$(date '+%F %T') | $1" >> "$LOG_FILE"
}

# 确保目标目录存在
if [ ! -d "$TARGET_DIR" ]; then
    mkdir -p "$TARGET_DIR"
    if [ $? -ne 0 ]; then
        log "错误：无法创建目录 $TARGET_DIR"
        exit 1
    fi
fi

# 下载函数：优先 curl，回退 wget / busybox wget
download_file() {
    local url="$1"
    local out="$2"

    if command -v curl > /dev/null 2>&1; then
        curl -sL --connect-timeout 30 --retry 3 -o "$out" "$url"
    elif command -v wget > /dev/null 2>&1; then
        wget -q --timeout=30 --tries=3 -O "$out" "$url"
    elif command -v busybox > /dev/null 2>&1; then
        busybox wget -q -O "$out" "$url"
    else
        log "错误：未找到可用的下载工具（curl/wget/busybox）"
        return 1
    fi
    return $?
}

# ---------- 执行下载 ----------
log "===== 开始下载 ====="

TMP_FILE="${TARGET_DIR}${TARGET_FILE}.tmp"

if download_file "$DOWNLOAD_URL" "$TMP_FILE"; then
    mv -f "$TMP_FILE" "${TARGET_DIR}${TARGET_FILE}"
    chmod 644 "${TARGET_DIR}${TARGET_FILE}"
    log "下载成功 → ${TARGET_DIR}${TARGET_FILE}"
else
    rm -f "$TMP_FILE"
    log "下载失败"
    exit 1
fi

exit 0
