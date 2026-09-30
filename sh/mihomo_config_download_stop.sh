#!/system/bin/sh
# ============================================
# 停止 mihomo 下载服务 (终极优化版)
# 适配路径: /data/user/0/com.boxproxy.box/files/box/scripts/
# 策略: SIGTERM -> 等待 -> SIGKILL
# ============================================

# ---------- 配置区域 ----------
TARGET_SCRIPT_NAME="mihomo_config_download.sh"
LOCK_DIR="/data/local/tmp/mihomo_download.lock"
LOG_FILE="/data/local/tmp/mihomo_download.log"
TARGET_TMP="/data/data/com.boxproxy.box/files/box/mihomo/config.yaml.tmp"
# -----------------------------

# 简单日志函数
now() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(now) | $1" | tee -a "$LOG_FILE"; }

log "===== 开始停止任务 ====="
log "当前 UID=$(id -u) (0=root)"

SELF_PID=$$

# 安全读取 cmdline（解决 No such file or directory 报错）
read_cmdline() {
    local f="/proc/$1/cmdline"
    [ -r "$f" ] || { echo ""; return; }
    tr '\0' ' ' < "$f" 2>/dev/null
}

# 优雅杀死进程：先 SIGTERM，超时后 SIGKILL
kill_pid_gracefully() {
    local p="$1"
    [ -z "$p" ] && return 1
    [ "$p" = "$SELF_PID" ] && return 1
    [ -d "/proc/$p" ] || return 1

    log "  → 发送 SIGTERM 到 PID=$p ($(read_cmdline "$p"))"
    kill -15 "$p" 2>/dev/null

    # 最多等待 3 秒，每秒检查一次进程是否退出
    for i in 1 2 3; do
        [ -d "/proc/$p" ] || return 0
        sleep 1
    done

    # 超时仍未退出，使用 SIGKILL 强制终止
    log "    SIGTERM 超时，发送 SIGKILL 到 PID=$p"
    kill -9 "$p" 2>/dev/null
    return 0
}

KILLED=0

# ========== 1. 从锁文件找 ==========
if [ -f "$LOCK_DIR/pid" ]; then
    LP=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    log "锁文件记录 PID=$LP"
    if [ -n "$LP" ] && [ -d "/proc/$LP" ]; then
        kill_pid_gracefully "$LP" && KILLED=$((KILLED+1))
    fi
fi

# ========== 2. 扫描 /proc (comm 快速过滤 + cmdline 精确匹配) ==========
for PD in /proc/[0-9]*; do
    p=${PD#/proc/}
    [ "$p" = "$SELF_PID" ] && continue
    [ -r "$PD/comm" ] || continue

    # 第一层：comm 快速过滤（进程名通常为 sh、dash、bash、busybox）
    COMM=$(cat "$PD/comm" 2>/dev/null)
    case "$COMM" in
        sh|dash|bash|busybox|ash) ;;
        *) continue ;;
    esac

    # 第二层：cmdline 精确匹配目标脚本名
    CMD=$(read_cmdline "$p")
    [ -z "$CMD" ] && continue

    case "$CMD" in
        *mihomo_config_download_stop*) continue ;; # 跳过停止脚本自身
        *"$TARGET_SCRIPT_NAME"*)
            # 第三层：UID 校验，只杀 root 进程
            TARGET_UID=$(awk '/^Uid:/{print $2}' "$PD/status" 2>/dev/null)
            if [ "$TARGET_UID" != "0" ]; then
                log "  发现匹配进程 PID=$p 但 UID=$TARGET_UID (非root)，跳过"
                continue
            fi
            log "匹配到目标进程 PID=$p"
            kill_pid_gracefully "$p" && KILLED=$((KILLED+1))
            ;;
    esac
done

# ========== 3. 结果与清理 ==========
if [ "$KILLED" -eq 0 ]; then
    log "未找到正在运行的目标下载进程。"
else
    log "共结束 $KILLED 个目标进程。"
fi

# 清理锁目录
if [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
    log "已清理锁目录：$LOCK_DIR"
fi

# 清理临时文件
[ -f "$TARGET_TMP" ] && rm -f "$TARGET_TMP" && log "已清理临时文件：$TARGET_TMP"

log "===== 停止任务完成 ====="
exit 0
