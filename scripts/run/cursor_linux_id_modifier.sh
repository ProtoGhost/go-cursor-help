#!/bin/bash

# 设置错误处理
set -e

# 定义日志文件路径
LOG_FILE="/tmp/cursor_linux_id_modifier.log"

# 初始化日志文件
initialize_log() {
    echo "========== Cursor ID 修改工具日志开始 $(date) ==========" > "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显式禁用时，关闭 TTY UI（resize/clear/Logo），避免部分环境乱码/花屏
if [ -n "${CURSOR_NO_TTY_UI:-}" ]; then
    CURSOR_NO_TTY_UI=1
fi

# UI/颜色开关：遵循 NO_COLOR 标准，并支持 CURSOR_NO_TTY_UI（禁用花哨 TTY UI）
if [ -n "${NO_COLOR:-}" ] || [ -n "${CURSOR_NO_COLOR:-}" ] || [ -n "${CURSOR_NO_TTY_UI:-}" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# 启动时尝试调整终端窗口大小为 120x40（列x行）；不支持/失败时静默忽略，避免影响脚本主流程
try_resize_terminal_window() {
    local target_cols=120
    local target_rows=40

    # 可通过 CURSOR_NO_TTY_UI 显式禁用所有终端控制输出（避免部分环境乱码/花屏）
    if [ -n "${CURSOR_NO_TTY_UI:-}" ]; then
        return 0
    fi

    # 仅在交互终端中尝试，避免输出被重定向时出现乱码
    if [ ! -t 1 ]; then
        return 0
    fi

    case "${TERM:-}" in
        ""|dumb)
            return 0
            ;;
    esac

    # 终端类型检测：仅对常见 xterm 体系终端尝试窗口调整（GNOME Terminal/Konsole/xterm/Terminator 等通常为 xterm*）
    case "${TERM:-}" in
        xterm*|screen*|tmux*|rxvt*|alacritty*|kitty*|foot*|wezterm*)
            ;;
        *)
            return 0
            ;;
    esac

    # 优先通过 xterm 窗口控制序列调整；在 tmux/screen 下需要 passthrough 包装
    if [ -n "${TMUX:-}" ]; then
        printf '\033Ptmux;\033\033[8;%d;%dt\033\\' "$target_rows" "$target_cols" 2>/dev/null || true
    elif [ -n "${STY:-}" ]; then
        printf '\033P\033[8;%d;%dt\033\\' "$target_rows" "$target_cols" 2>/dev/null || true
    else
        printf '\033[8;%d;%dt' "$target_rows" "$target_cols" 2>/dev/null || true
    fi

    return 0
}

# 日志函数 - 同时输出到终端和日志文件
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# 记录命令输出到日志文件
log_cmd_output() {
    local cmd="$1"
    local msg="$2"
    echo "[CMD] $(date '+%Y-%m-%d %H:%M:%S') 执行命令: $cmd" >> "$LOG_FILE"
    echo "[CMD] $msg:" >> "$LOG_FILE"
    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

# sed -i 兼容封装：优先原地编辑；不支持/失败时回退到临时文件替换，提升跨发行版兼容性
sed_inplace() {
    local expr="$1"
    local file="$2"

    # GNU sed / BusyBox sed：通常支持 sed -i
    if sed -i "$expr" "$file" 2>/dev/null; then
        return 0
    fi

    # BSD sed：需要提供 -i '' 形式（少数环境可能出现）
    if sed -i '' "$expr" "$file" 2>/dev/null; then
        return 0
    fi

    # 最后兜底：临时文件替换（避免不同 sed 的 -i 语义差异）
    local temp_file
    temp_file=$(mktemp) || return 1
    if sed "$expr" "$file" > "$temp_file"; then
        cat "$temp_file" > "$file"
        rm -f "$temp_file"
        return 0
    fi
    rm -f "$temp_file"
    return 1
}

# 路径解析兼容：优先 realpath；缺失时回退到 readlink -f / python3 / cd+pwd（避免命令缺失触发 set -e）
resolve_path() {
    local target="$1"

    if command -v realpath >/dev/null 2>&1; then
        realpath "$target" 2>/dev/null && return 0
    fi

    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$target" 2>/dev/null && return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null && return 0
    fi

    # 最后兜底：不解析符号链接，仅尽量返回绝对路径
    if [ -d "$target" ]; then
        (cd "$target" 2>/dev/null && pwd -P) && return 0
    fi
    local dir
    dir=$(dirname "$target")
    (cd "$dir" 2>/dev/null && printf "%s/%s\n" "$(pwd -P)" "$(basename "$target")") && return 0

    echo "$target"
    return 0
}

# 获取当前用户
get_current_user() {
    # sudo 场景：优先以 SUDO_USER 作为目标用户（Cursor 通常运行在该用户下）
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER"
        return 0
    fi

    # 普通/直跑 root 场景：使用当前有效用户
    if command -v id >/dev/null 2>&1; then
        id -un 2>/dev/null && return 0
    fi
    echo "${USER:-}"
}

# 获取指定用户的 Home 目录（兼容 sudo/root/容器等场景）
get_user_home_dir() {
    local user="$1"
    local home=""

    if command -v getent >/dev/null 2>&1; then
        home=$(getent passwd "$user" 2>/dev/null | awk -F: '{print $6}' | head -n 1)
    fi
    if [ -z "$home" ] && [ -f /etc/passwd ]; then
        home=$(awk -F: -v u="$user" '$1==u {print $6; exit}' /etc/passwd 2>/dev/null)
    fi
    if [ -z "$home" ]; then
        home=$(eval echo "~$user" 2>/dev/null)
    fi

    # 兜底：无法解析时使用当前环境 HOME
    if [ -z "$home" ] || [[ "$home" == "~"* ]]; then
        home="${HOME:-}"
    fi

    echo "$home"
}

# 获取指定用户的主组（chown 需要 user:group；不同发行版 id 参数/输出可能存在差异）
get_user_primary_group() {
    local user="$1"
    local group=""
    local gid=""

    # 优先：直接获取主组名（最简洁）
    if command -v id >/dev/null 2>&1; then
        group=$(id -gn "$user" 2>/dev/null | tr -d '\r\n') || true
        if [ -n "$group" ]; then
            echo "$group"
            return 0
        fi

        # 回退：先取 gid，再映射为组名（映射失败则直接返回 gid，chown 同样可用）
        gid=$(id -g "$user" 2>/dev/null | tr -d '\r\n') || true
    fi

    if [ -n "$gid" ]; then
        if command -v getent >/dev/null 2>&1; then
            group=$(getent group "$gid" 2>/dev/null | awk -F: '{print $1}' | head -n 1) || true
        fi
        if [ -z "$group" ] && [ -f /etc/group ]; then
            group=$(awk -F: -v g="$gid" '$3==g {print $1; exit}' /etc/group 2>/dev/null) || true
        fi

        if [ -n "$group" ]; then
            echo "$group"
            return 0
        fi

        echo "$gid"
        return 0
    fi

    # 最后兜底：返回用户本身（少数系统允许 user:user）
    echo "$user"
    return 0
}

CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "无法获取用户名"
    exit 1
fi

# 🎯 统一“目标用户/目标 Home”：后续所有 Cursor 用户数据路径均基于该 Home
TARGET_HOME=$(get_user_home_dir "$CURRENT_USER")
if [ -z "$TARGET_HOME" ]; then
    log_error "无法解析目标用户 Home 目录: $CURRENT_USER"
    exit 1
fi
log_info "目标用户: $CURRENT_USER"
log_info "目标用户 Home: $TARGET_HOME"

# 🎯 统一“目标用户主组”：chown 时不再依赖 id -g -n 的兼容性
CURRENT_GROUP=$(get_user_primary_group "$CURRENT_USER")
if [ -z "$CURRENT_GROUP" ]; then
    CURRENT_GROUP="$CURRENT_USER"
    log_warn "无法解析目标用户主组，已回退为: $CURRENT_GROUP（后续 chown 可能失败）"
else
    log_info "目标用户主组: $CURRENT_GROUP"
fi

# 定义Linux下的Cursor路径
CURSOR_CONFIG_DIR="$TARGET_HOME/.config/Cursor"
STORAGE_FILE="$CURSOR_CONFIG_DIR/User/globalStorage/storage.json"
BACKUP_DIR="$CURSOR_CONFIG_DIR/User/globalStorage/backups"

# 共享ID（用于配置与JS注入保持一致）
CURSOR_ID_MACHINE_ID=""
CURSOR_ID_MACHINE_GUID=""
CURSOR_ID_MAC_MACHINE_ID=""
CURSOR_ID_DEVICE_ID=""
CURSOR_ID_SQM_ID=""
CURSOR_ID_FIRST_SESSION_DATE=""
CURSOR_ID_SESSION_ID=""
CURSOR_ID_MAC_ADDRESS="00:11:22:33:44:55"

# --- 新增：安装相关变量 ---
APPIMAGE_SEARCH_DIR="/opt/CursorInstall" # AppImage 搜索目录，可按需修改
APPIMAGE_PATTERN="Cursor-*.AppImage"     # AppImage 文件名模式
INSTALL_DIR="/opt/Cursor"                # Cursor 最终安装目录
ICON_PATH="/usr/share/icons/cursor.png"
DESKTOP_FILE="/usr/share/applications/cursor-cursor.desktop"
# --- 结束：安装相关变量 ---

# 可能的Cursor二进制路径 - 添加了标准安装路径
CURSOR_BIN_PATHS=(
    "/usr/bin/cursor"
    "/usr/local/bin/cursor"
    "$INSTALL_DIR/cursor"               # 添加标准安装路径
    "$TARGET_HOME/.local/bin/cursor"
    "/snap/bin/cursor"
)

# 找到Cursor安装路径
find_cursor_path() {
    log_info "查找Cursor安装路径..."
    
    for path in "${CURSOR_BIN_PATHS[@]}"; do
        if [ -f "$path" ] && [ -x "$path" ]; then # 确保文件存在且可执行
            log_info "找到Cursor安装路径: $path"
            CURSOR_PATH="$path"
            return 0
        fi
    done

    # 尝试通过which命令定位
    if command -v cursor &> /dev/null; then
        # 兼容修复：部分发行版没有 which；command -v 已可直接返回路径
        CURSOR_PATH=$(command -v cursor)
        log_info "通过 command -v 找到 Cursor: $CURSOR_PATH"
        return 0
    fi
    
    # 尝试查找可能的安装路径 (限制搜索范围和类型)
    # 兼容修复：find 的 -executable 在 BusyBox 等环境可能不可用，且 find 报错返回非0会触发 set -e；这里统一兜底处理
    local cursor_paths=""

    # 优先：使用 -executable（若受支持）
    cursor_paths=$(find /usr /opt "$TARGET_HOME/.local" -type f -name "cursor" -executable 2>/dev/null || true)

    # 回退：不依赖 -executable，改用 shell 过滤可执行
    if [ -z "$cursor_paths" ]; then
        cursor_paths=$(find /usr /opt "$TARGET_HOME/.local" -type f -name "cursor" 2>/dev/null || true)
        cursor_paths=$(echo "$cursor_paths" | while IFS= read -r p; do [ -n "$p" ] && [ -x "$p" ] && echo "$p"; done)
    fi

    # 额外兜底：标准安装路径优先
    if [ -x "$INSTALL_DIR/cursor" ]; then
        cursor_paths="$INSTALL_DIR/cursor"$'\n'"$cursor_paths"
    fi
    if [ -n "$cursor_paths" ]; then
        # 优先选择标准安装路径
        local standard_path=$(echo "$cursor_paths" | grep "$INSTALL_DIR/cursor" | head -1)
        if [ -n "$standard_path" ]; then
            CURSOR_PATH="$standard_path"
        else
            CURSOR_PATH=$(echo "$cursor_paths" | head -1)
        fi
        log_info "通过查找找到Cursor: $CURSOR_PATH"
        return 0
    fi
    
    log_warn "未找到Cursor可执行文件"
    return 1
}

# 查找并定位Cursor资源文件目录
find_cursor_resources() {
    log_info "查找Cursor资源目录..."
    
    # 可能的资源目录路径 - 添加了标准安装目录
    local resource_paths=(
        "$INSTALL_DIR" # 添加标准安装路径
        "/usr/lib/cursor"
        "/usr/share/cursor"
        "$TARGET_HOME/.local/share/cursor"
    )
    
    for path in "${resource_paths[@]}"; do
        if [ -d "$path/resources" ]; then # 检查是否存在 resources 子目录
            log_info "找到Cursor资源目录: $path"
            CURSOR_RESOURCES="$path"
            return 0
        fi
         if [ -d "$path/app" ]; then # 有些版本可能直接是 app 目录
             log_info "找到Cursor资源目录 (app): $path"
             CURSOR_RESOURCES="$path"
             return 0
         fi
    done
    
    # 如果有CURSOR_PATH，尝试从它推断
    if [ -n "$CURSOR_PATH" ]; then
        local base_dir=$(dirname "$CURSOR_PATH")
        # 检查常见的相对路径
        if [ -d "$base_dir/resources" ]; then
            CURSOR_RESOURCES="$base_dir"
            log_info "通过二进制路径找到资源目录: $CURSOR_RESOURCES"
            return 0
        elif [ -d "$base_dir/../resources" ]; then # 例如在 bin 目录内
            CURSOR_RESOURCES=$(resolve_path "$base_dir/..")
            log_info "通过二进制路径找到资源目录: $CURSOR_RESOURCES"
            return 0
        elif [ -d "$base_dir/../lib/cursor/resources" ]; then # 另一种常见结构
            CURSOR_RESOURCES=$(resolve_path "$base_dir/../lib/cursor")
            log_info "通过二进制路径找到资源目录: $CURSOR_RESOURCES"
            return 0
        fi
    fi
    
    log_warn "未找到Cursor资源目录"
    return 1
}

# 检查权限
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 sudo 运行此脚本 (安装和修改系统文件需要权限)"
        echo "示例: sudo $0"
        exit 1
    fi
}

# --- 新增/重构：从本地 AppImage 安装 Cursor ---
install_cursor_appimage() {
    log_info "开始尝试从本地 AppImage 安装 Cursor..."
    local found_appimage_path=""

    # 确保搜索目录存在
    mkdir -p "$APPIMAGE_SEARCH_DIR"

    # 查找 AppImage 文件
    find_appimage() {
        # 兼容修复：find 参数在不同实现中可能有差异，且 find 非0 会触发 set -e；这里统一兜底为成功返回
        found_appimage_path=$(find "$APPIMAGE_SEARCH_DIR" -maxdepth 1 -name "$APPIMAGE_PATTERN" -print -quit 2>/dev/null || true)
        if [ -z "$found_appimage_path" ]; then
            return 1
        else
            return 0
        fi
    }

    if ! find_appimage; then
        log_warn "在 '$APPIMAGE_SEARCH_DIR' 目录下未找到 '$APPIMAGE_PATTERN' 文件。"
        # --- 新增：添加文件名格式提醒 ---
        log_info "请确保 AppImage 文件名格式类似: Cursor-版本号-架构.AppImage (例如: Cursor-1.0.6-aarch64.AppImage 或 Cursor-x.y.z-x86_64.AppImage)"
        # --- 结束：添加文件名格式提醒 ---
        # 等待用户放置文件
        read -p $"请将 Cursor AppImage 文件放入 '$APPIMAGE_SEARCH_DIR' 目录，然后按 Enter 键继续..."

        # 再次查找
        if ! find_appimage; then
            log_error "在 '$APPIMAGE_SEARCH_DIR' 中仍然找不到 '$APPIMAGE_PATTERN' 文件。安装中止。"
            return 1
        fi
    fi

    log_info "找到 AppImage 文件: $found_appimage_path"
    local appimage_filename=$(basename "$found_appimage_path")

    # 进入搜索目录操作，避免路径问题
    local current_dir=$(pwd)
    cd "$APPIMAGE_SEARCH_DIR" || { log_error "无法进入目录: $APPIMAGE_SEARCH_DIR"; return 1; }

    log_info "设置 '$appimage_filename' 可执行权限..."
    chmod +x "$appimage_filename" || {
        log_error "设置可执行权限失败: $appimage_filename"
        cd "$current_dir"
        return 1
    }

    log_info "解压 AppImage 文件 '$appimage_filename'..."
    # 创建临时解压目录
    local extract_dir="squashfs-root"
    rm -rf "$extract_dir" # 清理旧的解压目录（如果存在）
    
    # 执行解压，将输出重定向避免干扰
    if ./"$appimage_filename" --appimage-extract > /dev/null; then
        log_info "AppImage 解压成功到 '$extract_dir'"
    else
        log_error "解压 AppImage 失败: $appimage_filename"
        rm -rf "$extract_dir" # 清理失败的解压
        cd "$current_dir"
        return 1
    fi

    # 检查解压后的预期目录结构
    local cursor_source_dir=""
    if [ -d "$extract_dir/usr/share/cursor" ]; then
       cursor_source_dir="$extract_dir/usr/share/cursor"
    elif [ -d "$extract_dir" ]; then # 有些 AppImage 可能直接在根目录
       # 进一步检查是否存在关键文件/目录
       if [ -f "$extract_dir/cursor" ] && [ -d "$extract_dir/resources" ]; then
           cursor_source_dir="$extract_dir"
       fi
    fi

    if [ -z "$cursor_source_dir" ]; then
        log_error "解压后的目录 '$extract_dir' 中未找到预期的 Cursor 文件结构 (例如 'usr/share/cursor' 或直接包含 'cursor' 和 'resources')。"
        rm -rf "$extract_dir"
        cd "$current_dir"
        return 1
    fi
     log_info "找到 Cursor 源文件在: $cursor_source_dir"


    log_info "安装 Cursor 到 '$INSTALL_DIR'..."
    # 如果安装目录已存在，先删除 (确保全新安装)
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "发现已存在的安装目录 '$INSTALL_DIR'，将先移除..."
        rm -rf "$INSTALL_DIR" || { log_error "移除旧安装目录失败: $INSTALL_DIR"; cd "$current_dir"; return 1; }
    fi
    
    # 创建安装目录的父目录（如果需要）并设置权限
    mkdir -p "$(dirname "$INSTALL_DIR")"
    
    # 移动解压后的内容到安装目录
    if mv "$cursor_source_dir" "$INSTALL_DIR"; then
        log_info "成功将文件移动到 '$INSTALL_DIR'"
        # 确保安装目录及其内容归属当前用户（如果需要）
        chown -R "$CURRENT_USER":"$CURRENT_GROUP" "$INSTALL_DIR" || log_warn "设置 '$INSTALL_DIR' 文件所有权失败，可能需要手动调整"
        chmod -R u+rwX,go+rX,go-w "$INSTALL_DIR" || log_warn "设置 '$INSTALL_DIR' 文件权限失败，可能需要手动调整"
    else
        log_error "移动文件到安装目录 '$INSTALL_DIR' 失败"
        rm -rf "$extract_dir" # 确保清理
        rm -rf "$INSTALL_DIR" # 清理部分移动的文件
        cd "$current_dir"
        return 1
    fi

    # 处理图标和桌面快捷方式 (从脚本执行的原始目录查找)
    cd "$current_dir" # 返回原始目录查找图标等文件

    local icon_source="./cursor.png"
    local desktop_source="./cursor-cursor.desktop"

    if [ -f "$icon_source" ]; then
        log_info "安装图标..."
        mkdir -p "$(dirname "$ICON_PATH")"
        cp "$icon_source" "$ICON_PATH" || log_warn "无法复制图标文件 '$icon_source' 到 '$ICON_PATH'"
        chmod 644 "$ICON_PATH" || log_warn "设置图标文件权限失败: $ICON_PATH"
    else
        log_warn "图标文件 '$icon_source' 在脚本当前目录不存在，跳过图标安装。"
        log_warn "请将 'cursor.png' 文件放置在脚本目录 '$current_dir' 下并重新运行安装（如果需要图标）。"
    fi

    if [ -f "$desktop_source" ]; then
        log_info "安装桌面快捷方式..."
         mkdir -p "$(dirname "$DESKTOP_FILE")"
        cp "$desktop_source" "$DESKTOP_FILE" || log_warn "无法创建桌面快捷方式 '$desktop_source' 到 '$DESKTOP_FILE'"
        chmod 644 "$DESKTOP_FILE" || log_warn "设置桌面文件权限失败: $DESKTOP_FILE"

        # 更新桌面数据库
        log_info "更新桌面数据库..."
        update-desktop-database "$(dirname "$DESKTOP_FILE")" &> /dev/null || log_warn "无法更新桌面数据库，快捷方式可能不会立即显示"
    else
        log_warn "桌面文件 '$desktop_source' 在脚本当前目录不存在，跳过快捷方式安装。"
         log_warn "请将 'cursor-cursor.desktop' 文件放置在脚本目录 '$current_dir' 下并重新运行安装（如果需要快捷方式）。"
    fi

    # 创建符号链接到 /usr/local/bin
    log_info "创建命令行启动链接..."
    ln -sf "$INSTALL_DIR/cursor" /usr/local/bin/cursor || log_warn "无法创建命令行链接 '/usr/local/bin/cursor'"

    # 清理临时文件
    log_info "清理临时文件..."
    cd "$APPIMAGE_SEARCH_DIR" # 返回搜索目录清理
    rm -rf "$extract_dir"
    log_info "正在删除原始 AppImage 文件: $found_appimage_path"
    rm -f "$appimage_filename" # 删除 AppImage 文件

    cd "$current_dir" # 确保返回最终目录

    log_info "Cursor 安装成功！安装目录: $INSTALL_DIR"
    return 0
}
# --- 结束：安装函数 ---

# 检查并关闭 Cursor 进程

# 获取 Cursor 相关进程 PID（兼容 pgrep/ps 多种实现）
get_cursor_pids() {
    local self_pid="$$"
    local pids=""

    # 优先使用 pgrep（更稳定）：仅按进程名匹配，避免误匹配到脚本命令行（例如 sudo bash ...cursor_linux_id_modifier.sh）
    if command -v pgrep >/dev/null 2>&1; then
        pids=$(pgrep -i "cursor" 2>/dev/null || true)
        if [ -z "$pids" ]; then
            pids=$(pgrep "cursor" 2>/dev/null || true)
        fi
        if [ -z "$pids" ]; then
            pids=$(pgrep "Cursor" 2>/dev/null || true)
        fi

        if [ -n "$pids" ]; then
            echo "$pids" | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' | sort -u
            return 0
        fi
    fi

    # 回退：兼容不同 ps 实现（BusyBox 可能不支持 aux / -ef）
    if ps aux >/dev/null 2>&1; then
        ps aux 2>/dev/null \
            | grep -i '[c]ursor' \
            | grep -v "cursor_linux_id_modifier.sh" \
            | awk '{print $2}' \
            | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' \
            | sort -u
        return 0
    fi

    if ps -ef >/dev/null 2>&1; then
        ps -ef 2>/dev/null \
            | grep -i '[c]ursor' \
            | grep -v "cursor_linux_id_modifier.sh" \
            | awk '{print $2}' \
            | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' \
            | sort -u
        return 0
    fi

    ps 2>/dev/null \
        | grep -i '[c]ursor' \
        | grep -v "cursor_linux_id_modifier.sh" \
        | awk '{print $1}' \
        | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' \
        | sort -u
    return 0
}

# 打印 Cursor 相关进程详情（用于排障；不依赖固定列结构）
print_cursor_process_details() {
    log_debug "正在获取 Cursor 进程详细信息："

    if ps aux >/dev/null 2>&1; then
        ps aux 2>/dev/null | grep -i '[c]ursor' | grep -v "cursor_linux_id_modifier.sh" || true
        return 0
    fi

    if ps -ef >/dev/null 2>&1; then
        ps -ef 2>/dev/null | grep -i '[c]ursor' | grep -v "cursor_linux_id_modifier.sh" || true
        return 0
    fi

    ps 2>/dev/null | grep -i '[c]ursor' | grep -v "cursor_linux_id_modifier.sh" || true
    return 0
}

check_and_kill_cursor() {
    log_info "检查 Cursor 进程..."
    
    local attempt=1
    local max_attempts=5
    
    while [ $attempt -le $max_attempts ]; do
        # 跨发行版兼容：优先 pgrep，其次兼容 ps aux/ps -ef/ps 的 PID 列差异
        local cursor_pids_raw
        cursor_pids_raw=$(get_cursor_pids || true)
        # 将换行分隔的 PID 列表转换为空格分隔，便于传给 kill（避免依赖 xargs）
        CURSOR_PIDS=$(echo "$cursor_pids_raw" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' || true)
        
        if [ -z "$CURSOR_PIDS" ]; then
            log_info "未发现运行中的 Cursor 进程"
            return 0
        fi
        
        log_warn "发现 Cursor 进程正在运行: $CURSOR_PIDS"
        print_cursor_process_details
        
        log_warn "尝试关闭 Cursor 进程..."
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "尝试强制终止进程..."
            kill -9 $CURSOR_PIDS 2>/dev/null || true
        else
            kill $CURSOR_PIDS 2>/dev/null || true
        fi
        
        sleep 1
        
        # 再次检查进程是否还在运行
        if [ -z "$(get_cursor_pids | head -n 1)" ]; then
            log_info "Cursor 进程已成功关闭"
            return 0
        fi
        
        log_warn "等待进程关闭，尝试 $attempt/$max_attempts..."
        ((attempt++))
    done
    
    log_error "在 $max_attempts 次尝试后仍无法关闭 Cursor 进程"
    print_cursor_process_details
    log_error "请手动关闭进程后重试"
    exit 1
}

# 备份配置文件
backup_config() {
    if [ ! -f "$STORAGE_FILE" ]; then
        log_warn "配置文件 '$STORAGE_FILE' 不存在，跳过备份"
        return 0
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/storage.json.backup_$(date +%Y%m%d_%H%M%S)"
    
    if cp "$STORAGE_FILE" "$backup_file"; then
        chmod 644 "$backup_file"
        # 确保备份文件归属正确用户
        chown "$CURRENT_USER":"$CURRENT_GROUP" "$backup_file" || log_warn "设置备份文件所有权失败: $backup_file"
        log_info "配置已备份到: $backup_file"
    else
        log_error "备份失败: $STORAGE_FILE"
        exit 1
    fi
    return 0 # 明确返回成功
}

# 生成随机 ID
generate_hex_bytes() {
    local bytes="$1"

    # 优先使用 openssl
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
        return 0
    fi

    # 兜底：/dev/urandom + od（多数发行版可用）
    if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        # 使用更通用的 od 参数写法，兼容更多发行版实现
        od -An -N "$bytes" -t x1 /dev/urandom | tr -d ' \n'
        return 0
    fi

    # 最后兜底：如果 python3 可用
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os, sys; print(os.urandom(int(sys.argv[1])).hex())' "$bytes"
        return 0
    fi

    log_error "缺少 openssl/od/python3，无法生成随机数（bytes=$bytes）"
    return 1
}

generate_random_id() {
    # 生成32字节(64个十六进制字符)的随机数
    generate_hex_bytes 32
}

# 生成随机 UUID
generate_uuid() {
    # 在Linux上使用uuidgen生成UUID
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # 备选方案：使用/proc/sys/kernel/random/uuid
        if [ -f /proc/sys/kernel/random/uuid ]; then
            cat /proc/sys/kernel/random/uuid
        else
            # 最后备选方案：使用随机 16 bytes 并格式化（避免 sed 捕获组超 9 的兼容性问题）
            local hex
            hex=$(generate_hex_bytes 16) || return 1
            echo "${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
        fi
    fi
}

# 规范化 machineId（确保为十六进制字符串）
normalize_machine_id() {
    local raw="$1"
    local cleaned
    cleaned=$(echo "$raw" | tr -d '-' | tr '[:upper:]' '[:lower:]')
    if [[ "$cleaned" =~ ^[0-9a-f]{32,}$ ]]; then
        echo "$cleaned"
        return 0
    fi
    return 1
}

# 从现有配置读取ID（用于JS注入保持一致）
load_ids_from_storage() {
    if [ ! -f "$STORAGE_FILE" ]; then
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "未检测到 python3，无法从现有配置读取 ID"
        return 1
    fi

    local output
    output=$(python3 - "$STORAGE_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def pick(keys):
    for k in keys:
        v = data.get(k)
        if isinstance(v, str) and v:
            return v
    return ""

items = {
    "machineId": pick(["telemetry.machineId", "machineId"]),
    "macMachineId": pick(["telemetry.macMachineId"]),
    "devDeviceId": pick(["telemetry.devDeviceId", "deviceId"]),
    "sqmId": pick(["telemetry.sqmId"]),
    "firstSessionDate": pick(["telemetry.firstSessionDate"]),
}

for k, v in items.items():
    print(f"{k}={v}")
PY
)
    if [ $? -ne 0 ] || [ -z "$output" ]; then
        return 1
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            machineId) CURSOR_ID_MACHINE_ID="$value" ;;
            macMachineId) CURSOR_ID_MAC_MACHINE_ID="$value" ;;
            devDeviceId) CURSOR_ID_DEVICE_ID="$value" ;;
            sqmId) CURSOR_ID_SQM_ID="$value" ;;
            firstSessionDate) CURSOR_ID_FIRST_SESSION_DATE="$value" ;;
        esac
    done <<< "$output"

    if [ -n "$CURSOR_ID_MACHINE_ID" ]; then
        local normalized
        if normalized=$(normalize_machine_id "$CURSOR_ID_MACHINE_ID"); then
            if [ "$normalized" != "$CURSOR_ID_MACHINE_ID" ]; then
                log_warn "machineId 非标准格式，JS 注入将使用去除连字符后的值"
            fi
            CURSOR_ID_MACHINE_ID="$normalized"
        else
            log_warn "machineId 无法识别为十六进制，JS 注入将改用新值"
            CURSOR_ID_MACHINE_ID=""
        fi
    fi

    CURSOR_ID_SESSION_ID=$(generate_uuid)
    CURSOR_ID_MAC_ADDRESS="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"

    if [ -n "$CURSOR_ID_MACHINE_ID" ] && [ -n "$CURSOR_ID_MAC_MACHINE_ID" ] && [ -n "$CURSOR_ID_DEVICE_ID" ] && [ -n "$CURSOR_ID_SQM_ID" ]; then
        return 0
    fi
    return 1
}

# 仅用于JS注入的ID生成（不写配置）
generate_ids_for_js_only() {
    CURSOR_ID_MACHINE_ID=$(generate_random_id)
    CURSOR_ID_MACHINE_GUID=$(generate_uuid)
    CURSOR_ID_MAC_MACHINE_ID=$(generate_random_id)
    CURSOR_ID_DEVICE_ID=$(generate_uuid)
    CURSOR_ID_SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    CURSOR_ID_FIRST_SESSION_DATE=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    CURSOR_ID_SESSION_ID=$(generate_uuid)
    CURSOR_ID_MAC_ADDRESS="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"
}

# 修改现有文件
modify_or_add_config() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    if [ ! -f "$file" ]; then
        log_error "配置文件不存在: $file"
        return 1
    fi
    
    # 确保文件对当前执行用户（root）可写
    chmod u+w "$file" || {
        log_error "无法修改文件权限（写）: $file"
        return 1
    }
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 检查key是否存在
    if grep -q "\"$key\":[[:space:]]*\"[^\"]*\"" "$file"; then
        # key存在,执行替换 (更精确的匹配)
        sed "s/\\(\"$key\"\\):[[:space:]]*\"[^\"]*\"/\\1: \"$value\"/" "$file" > "$temp_file" || {
            log_error "修改配置失败 (替换): $key in $file"
            rm -f "$temp_file"
            chmod u-w "$file" # 恢复权限
            return 1
        }
         log_debug "已替换 key '$key' 在文件 '$file' 中"
    elif grep -q "}" "$file"; then
         # key不存在, 在最后一个 '}' 前添加新的key-value对
         # 注意：这种方式比较脆弱，如果 JSON 格式不标准或最后一行不是 '}' 会失败
         # 🔧 兼容修复：不依赖 GNU sed 的 \n 替换扩展；同时避免在 `}` 独占一行时生成无效 JSON
         if tail -n 1 "$file" | grep -Eq '^[[:space:]]*}[[:space:]]*$'; then
             # 多行 JSON：在最后一个 `}` 前插入新行，并为上一条属性补上逗号
             awk -v key="$key" -v value="$value" '
             { lines[NR] = $0 }
             END {
                 brace = 0
                 for (i = NR; i >= 1; i--) {
                     if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) { brace = i; break }
                 }
                 if (brace == 0) { exit 2 }

                 prev = 0
                 for (i = brace - 1; i >= 1; i--) {
                     if (lines[i] !~ /^[[:space:]]*$/) { prev = i; break }
                 }
                 if (prev > 0) {
                     line = lines[prev]
                     sub(/[[:space:]]*$/, "", line)
                     if (line !~ /{$/ && line !~ /,$/) {
                         lines[prev] = line ","
                     } else {
                         lines[prev] = line
                     }
                 }

                 insert_line = "    \"" key "\": \"" value "\""
                 for (i = 1; i <= NR; i++) {
                     if (i == brace) { print insert_line }
                     print lines[i]
                 }
             }
             ' "$file" > "$temp_file" || {
                 log_error "添加配置失败 (注入): $key to $file"
                 rm -f "$temp_file"
                 chmod u-w "$file" # 恢复权限
                 return 1
             }
         else
             # 单行 JSON：直接在末尾 `}` 前插入键值（避免依赖 sed 的 \\n 扩展）
             sed "s/}[[:space:]]*$/,\"$key\": \"$value\"}/" "$file" > "$temp_file" || {
                 log_error "添加配置失败 (注入): $key to $file"
                 rm -f "$temp_file"
                 chmod u-w "$file" # 恢复权限
                 return 1
             }
         fi
         log_debug "已添加 key '$key' 到文件 '$file' 中"
    else
         log_error "无法确定如何添加配置: $key to $file (文件结构可能不标准)"
         rm -f "$temp_file"
         chmod u-w "$file" # 恢复权限
         return 1
    fi

    # 检查临时文件是否有效
    if [ ! -s "$temp_file" ]; then
        log_error "修改或添加配置后生成的临时文件为空: $key in $file"
        rm -f "$temp_file"
        chmod u-w "$file" # 恢复权限
        return 1
    fi
    
    # 使用 cat 替换原文件内容
    cat "$temp_file" > "$file" || {
        log_error "无法写入更新后的配置到文件: $file"
        rm -f "$temp_file"
        # 尝试恢复权限（如果失败也无大碍）
        chmod u-w "$file" || true
        return 1
    }
    
    rm -f "$temp_file"
    
    # 设置所有者和基础权限（root执行时目标文件是用户家目录下的）
    chown "$CURRENT_USER":"$CURRENT_GROUP" "$file" || log_warn "设置文件所有权失败: $file"
    chmod 644 "$file" || log_warn "设置文件权限失败: $file" # 用户读写，组和其他读
    
    return 0
}

# 生成新的配置
generate_new_config() {
    echo
    log_warn "机器码重置选项"
    
    # 使用菜单选择函数询问用户是否重置机器码
    set +e
    # 默认选择“重置”，满足“默认应全部处理”的需求
    select_menu_option "是否需要重置机器码? (默认：重置并同步修改配置文件)：" "不重置 - 仅修改js文件即可|重置 - 同时修改配置文件和机器码" 1
    reset_choice=$?
    set -e
    
    # 记录日志以便调试
    echo "[INPUT_DEBUG] 机器码重置选项选择: $reset_choice" >> "$LOG_FILE"
    
    # 确保配置文件目录存在
    mkdir -p "$(dirname "$STORAGE_FILE")"
    chown "$CURRENT_USER":"$CURRENT_GROUP" "$(dirname "$STORAGE_FILE")" || log_warn "设置配置目录所有权失败: $(dirname "$STORAGE_FILE")"
    chmod 755 "$(dirname "$STORAGE_FILE")" || log_warn "设置配置目录权限失败: $(dirname "$STORAGE_FILE")"

    # 处理用户选择 - 索引0对应"不重置"选项，索引1对应"重置"选项
    if [ "$reset_choice" = "1" ]; then
        log_info "您选择了重置机器码"
        
        # 检查配置文件是否存在
        if [ -f "$STORAGE_FILE" ]; then
            log_info "发现已有配置文件: $STORAGE_FILE"
            
            # 备份现有配置
            if ! backup_config; then # 如果备份失败，不继续修改
                 log_error "配置文件备份失败，中止机器码重置。"
                 return 1 # 返回错误状态
            fi
            
            # 生成并设置新的设备ID
            local new_device_id=$(generate_uuid)
            local new_machine_id=$(generate_random_id)
            # 🔧 新增: serviceMachineId (用于 storage.serviceMachineId)
            local new_service_machine_id=$(generate_uuid)
            # 🔧 新增: firstSessionDate (重置首次会话日期)
            local new_first_session_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
            # 🔧 新增: macMachineId 和 sqmId
            local new_mac_machine_id=$(generate_random_id)
            local new_sqm_id="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"

            CURSOR_ID_MACHINE_ID="$new_machine_id"
            CURSOR_ID_MAC_MACHINE_ID="$new_mac_machine_id"
            CURSOR_ID_DEVICE_ID="$new_device_id"
            CURSOR_ID_SQM_ID="$new_sqm_id"
            CURSOR_ID_FIRST_SESSION_DATE="$new_first_session_date"
            CURSOR_ID_SESSION_ID=$(generate_uuid)
            CURSOR_ID_MAC_ADDRESS="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"

            log_info "正在设置新的设备和机器ID..."
            log_debug "新设备ID: $new_device_id"
            log_debug "新机器ID: $new_machine_id"
            log_debug "新serviceMachineId: $new_service_machine_id"
            log_debug "新firstSessionDate: $new_first_session_date"

            # 修改配置文件
            # 🔧 修复: 添加 storage.serviceMachineId, telemetry.firstSessionDate, telemetry.macMachineId, telemetry.sqmId
            local config_success=true
            modify_or_add_config "deviceId" "$new_device_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "machineId" "$new_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.machineId" "$new_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.macMachineId" "$new_mac_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.devDeviceId" "$new_device_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.sqmId" "$new_sqm_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "storage.serviceMachineId" "$new_service_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.firstSessionDate" "$new_first_session_date" "$STORAGE_FILE" || config_success=false

            if [ "$config_success" = true ]; then
                log_info "配置文件中的所有标识符修改成功"
                log_info "📋 [详情] 已更新以下标识符："
                echo "   🔹 deviceId: ${new_device_id:0:16}..."
                echo "   🔹 machineId: ${new_machine_id:0:16}..."
                echo "   🔹 macMachineId: ${new_mac_machine_id:0:16}..."
                echo "   🔹 sqmId: $new_sqm_id"
                echo "   🔹 serviceMachineId: $new_service_machine_id"
                echo "   🔹 firstSessionDate: $new_first_session_date"

                # 🔧 新增: 修改 machineid 文件
                log_info "🔧 [machineid] 正在修改 machineid 文件..."
                local machineid_file_path="$CURSOR_CONFIG_DIR/machineid"
                if [ -f "$machineid_file_path" ]; then
                    # 备份原始 machineid 文件
                    local machineid_backup="$BACKUP_DIR/machineid.backup_$(date +%Y%m%d_%H%M%S)"
                    cp "$machineid_file_path" "$machineid_backup" 2>/dev/null && \
                        log_info "💾 [备份] machineid 文件已备份: $machineid_backup"
                fi
                # 写入新的 serviceMachineId 到 machineid 文件
                if echo -n "$new_service_machine_id" > "$machineid_file_path" 2>/dev/null; then
                    log_info "✅ [machineid] machineid 文件修改成功: $new_service_machine_id"
                    # 设置 machineid 文件为只读
                    chmod 444 "$machineid_file_path" 2>/dev/null && \
                        log_info "🔒 [保护] machineid 文件已设置为只读"
                else
                    log_warn "⚠️  [machineid] machineid 文件修改失败"
                    log_info "💡 [提示] 可手动修改文件: $machineid_file_path"
                fi

                # 🔧 新增: 修改 .updaterId 文件（更新器设备标识符）
                log_info "🔧 [updaterId] 正在修改 .updaterId 文件..."
                local updater_id_file_path="$CURSOR_CONFIG_DIR/.updaterId"
                if [ -f "$updater_id_file_path" ]; then
                    # 备份原始 .updaterId 文件
                    local updater_id_backup="$BACKUP_DIR/.updaterId.backup_$(date +%Y%m%d_%H%M%S)"
                    cp "$updater_id_file_path" "$updater_id_backup" 2>/dev/null && \
                        log_info "💾 [备份] .updaterId 文件已备份: $updater_id_backup"
                fi
                # 生成新的 updaterId（UUID格式）
                local new_updater_id=$(generate_uuid)
                if echo -n "$new_updater_id" > "$updater_id_file_path" 2>/dev/null; then
                    log_info "✅ [updaterId] .updaterId 文件修改成功: $new_updater_id"
                    # 设置 .updaterId 文件为只读
                    chmod 444 "$updater_id_file_path" 2>/dev/null && \
                        log_info "🔒 [保护] .updaterId 文件已设置为只读"
                else
                    log_warn "⚠️  [updaterId] .updaterId 文件修改失败"
                    log_info "💡 [提示] 可手动修改文件: $updater_id_file_path"
                fi
            else
                log_error "配置文件中的部分标识符修改失败"
                # 注意：即使失败，备份仍在，但配置文件可能已部分修改
                return 1 # 返回错误状态
            fi
        else
            log_warn "未找到配置文件 '$STORAGE_FILE'，无法重置机器码。如果这是首次安装，这是正常的。"
            # 即使文件不存在，也认为此步骤（不执行）是"成功"的，允许继续
        fi
    else
        log_info "您选择了不重置机器码，将仅修改js文件"
        
        # 检查配置文件是否存在并备份（如果存在）
        if [ -f "$STORAGE_FILE" ]; then
            log_info "发现已有配置文件: $STORAGE_FILE"
            if ! backup_config; then
                 log_error "配置文件备份失败，中止操作。"
                 return 1 # 返回错误状态
            fi
            if load_ids_from_storage; then
                log_info "已从现有配置读取 ID，JS 注入将保持一致"
            else
                log_warn "无法从现有配置读取 ID，JS 注入将使用新生成的 ID（不会修改配置）"
                generate_ids_for_js_only
            fi
        else
            log_warn "未找到配置文件 '$STORAGE_FILE'，跳过备份。"
            log_warn "无法读取现有ID，JS 注入将使用新生成的 ID（不会修改配置）"
            generate_ids_for_js_only
        fi
    fi
    
    echo
    log_info "配置处理完成"
    return 0 # 明确返回成功
}

# 查找Cursor的JS文件
find_cursor_js_files() {
    log_info "查找Cursor的JS文件..."
    
    local js_files=()
    local found=false
    
    # 确保 CURSOR_RESOURCES 已设置
    if [ -z "$CURSOR_RESOURCES" ] || [ ! -d "$CURSOR_RESOURCES" ]; then
        log_error "Cursor 资源目录未找到或无效 ($CURSOR_RESOURCES)，无法查找 JS 文件。"
        return 1
    fi

    log_debug "在资源目录中搜索JS文件: $CURSOR_RESOURCES"
    
    # 在资源目录中递归搜索特定JS文件
    # 注意：这些模式可能需要根据 Cursor 版本更新
    local js_patterns=(
        "resources/app/out/vs/workbench/api/node/extensionHostProcess.js"
        "resources/app/out/main.js"
        "resources/app/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js"
        "resources/app/out/vs/code/node/cliProcessMain.js"
        # 添加其他可能的路径模式
        "app/out/vs/workbench/api/node/extensionHostProcess.js" # 如果资源目录是 app 的父目录
        "app/out/main.js"
        "app/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js"
        "app/out/vs/code/node/cliProcessMain.js"
    )
    
    for pattern in "${js_patterns[@]}"; do
        # 使用 find 在 CURSOR_RESOURCES 下查找完整路径
        # 兼容修复：find 遇到错误返回非0可能触发 set -e，这里统一兜底为成功返回
        local files=$(find "$CURSOR_RESOURCES" -path "*/$pattern" -type f 2>/dev/null || true)
        if [ -n "$files" ]; then
            while IFS= read -r file; do
                # 检查文件是否已添加
                if [[ ! " ${js_files[@]} " =~ " ${file} " ]]; then
                    log_info "找到JS文件: $file"
                    js_files+=("$file")
                    found=true
                fi
            done <<< "$files"
        fi
    done
    
    # 如果还没找到，尝试更通用的搜索（可能误报）
    if [ "$found" = false ]; then
        log_warn "在标准路径模式中未找到JS文件，尝试在资源目录 '$CURSOR_RESOURCES' 中进行更广泛的搜索..."
        # 查找包含特定关键字的 JS 文件
        local files=$(find "$CURSOR_RESOURCES" -name "*.js" -type f -exec grep -lE 'IOPlatformUUID|x-cursor-checksum|getMachineId' {} \; 2>/dev/null || true)
        if [ -n "$files" ]; then
            while IFS= read -r file; do
                 if [[ ! " ${js_files[@]} " =~ " ${file} " ]]; then
                     log_info "通过关键字找到可能的JS文件: $file"
                     js_files+=("$file")
                     found=true
                 fi
            done <<< "$files"
        else
             log_warn "在资源目录 '$CURSOR_RESOURCES' 中通过关键字也未能找到 JS 文件。"
        fi
    fi

    if [ "$found" = false ]; then
        log_error "在资源目录 '$CURSOR_RESOURCES' 中未找到任何可修改的JS文件。"
        log_error "请检查 Cursor 安装是否完整，或脚本中的 JS 路径模式是否需要更新。"
        return 1
    fi
    
    # 去重（理论上上面的检查已经处理，但以防万一）
    IFS=" " read -r -a CURSOR_JS_FILES <<< "$(echo "${js_files[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    
    log_info "找到 ${#CURSOR_JS_FILES[@]} 个唯一的JS文件需要处理。"
    return 0
}

# 修改Cursor的JS文件
# 🔧 修改Cursor内核JS文件实现设备识别绕过（增强版三重方案）
# 方案A: someValue占位符替换 - 稳定锚点，不依赖混淆后的函数名
# 方案B: b6 定点重写 - 机器码源函数直接返回固定值
# 方案C: Loader Stub + 外置 Hook - 主/共享进程仅加载外置 Hook 文件
modify_cursor_js_files() {
    log_info "🔧 [内核修改] 开始修改Cursor内核JS文件实现设备识别绕过..."
    log_info "💡 [方案] 使用增强版三重方案：占位符替换 + b6 定点重写 + Loader Stub + 外置 Hook"

    # 先查找需要修改的JS文件
    if ! find_cursor_js_files; then
        return 1
    fi

    if [ ${#CURSOR_JS_FILES[@]} -eq 0 ]; then
        log_error "JS 文件列表为空，无法继续修改。"
        return 1
    fi

    # 生成或复用设备标识符（优先使用配置中读取的值）
    local machine_id="${CURSOR_ID_MACHINE_ID:-}"
    local machine_guid="${CURSOR_ID_MACHINE_GUID:-}"
    local device_id="${CURSOR_ID_DEVICE_ID:-}"
    local mac_machine_id="${CURSOR_ID_MAC_MACHINE_ID:-}"
    local sqm_id="${CURSOR_ID_SQM_ID:-}"
    local session_id="${CURSOR_ID_SESSION_ID:-}"
    local first_session_date="${CURSOR_ID_FIRST_SESSION_DATE:-}"
    local mac_address="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"
    local ids_missing=false

    if [ -z "$machine_id" ]; then
        machine_id=$(generate_random_id)
        ids_missing=true
    fi
    if [ -z "$machine_guid" ]; then
        machine_guid=$(generate_uuid)
        ids_missing=true
    fi
    if [ -z "$device_id" ]; then
        device_id=$(generate_uuid)
        ids_missing=true
    fi
    if [ -z "$mac_machine_id" ]; then
        mac_machine_id=$(generate_random_id)
        ids_missing=true
    fi
    if [ -z "$sqm_id" ]; then
        sqm_id="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
        ids_missing=true
    fi
    if [ -z "$session_id" ]; then
        session_id=$(generate_uuid)
        ids_missing=true
    fi
    if [ -z "$first_session_date" ]; then
        first_session_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        ids_missing=true
    fi

    if [ "$ids_missing" = true ]; then
        log_warn "部分 ID 未从配置获取，已生成新值用于 JS 注入"
    else
        log_info "已使用配置中的设备标识符进行 JS 注入"
    fi

    CURSOR_ID_MACHINE_ID="$machine_id"
    CURSOR_ID_MACHINE_GUID="$machine_guid"
    CURSOR_ID_DEVICE_ID="$device_id"
    CURSOR_ID_MAC_MACHINE_ID="$mac_machine_id"
    CURSOR_ID_SQM_ID="$sqm_id"
    CURSOR_ID_SESSION_ID="$session_id"
    CURSOR_ID_FIRST_SESSION_DATE="$first_session_date"
    CURSOR_ID_MAC_ADDRESS="$mac_address"

    log_info "🔑 [准备] 设备标识符已就绪"
    log_info "   machineId: ${machine_id:0:16}..."
    log_info "   machineGuid: ${machine_guid:0:16}..."
    log_info "   deviceId: ${device_id:0:16}..."
    log_info "   macMachineId: ${mac_machine_id:0:16}..."
    log_info "   sqmId: $sqm_id"

    # 每次执行都删除旧配置并重新生成，确保获得新的设备标识符
    local ids_config_path="$TARGET_HOME/.cursor_ids.json"
    if [ -f "$ids_config_path" ]; then
        rm -f "$ids_config_path"
        log_info "🗑️  [清理] 已删除旧的 ID 配置文件"
    fi
    cat > "$ids_config_path" << EOF
{
  "machineId": "$machine_id",
  "machineGuid": "$machine_guid",
  "macMachineId": "$mac_machine_id",
  "devDeviceId": "$device_id",
  "sqmId": "$sqm_id",
  "macAddress": "$mac_address",
  "sessionId": "$session_id",
  "firstSessionDate": "$first_session_date",
  "createdAt": "$first_session_date"
}
EOF
    chown "$CURRENT_USER":"$CURRENT_GROUP" "$ids_config_path" 2>/dev/null || true
    log_info "💾 [保存] 新的 ID 配置已保存到: $ids_config_path"

    # 部署外置 Hook 文件（供 Loader Stub 加载，支持多域名备用下载）
    local hook_target_path="$TARGET_HOME/.cursor_hook.js"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local hook_source_path="$script_dir/../hook/cursor_hook.js"
    local hook_download_urls=(
        "https://wget.la/https://raw.githubusercontent.com/ProtoGhost/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://down.npee.cn/?https://raw.githubusercontent.com/ProtoGhost/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://xget.xi-xu.me/gh/ProtoGhost/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://gh-proxy.com/https://raw.githubusercontent.com/ProtoGhost/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://gh.chjina.com/https://raw.githubusercontent.com/ProtoGhost/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
    )
    # 支持通过环境变量覆盖下载节点（逗号分隔）
    if [ -n "$CURSOR_HOOK_DOWNLOAD_URLS" ]; then
        IFS=',' read -r -a hook_download_urls <<< "$CURSOR_HOOK_DOWNLOAD_URLS"
        log_info "ℹ️  [Hook] 检测到自定义下载节点列表，将优先使用"
    fi

    if [ -f "$hook_source_path" ]; then
        if cp "$hook_source_path" "$hook_target_path"; then
            chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
            log_info "✅ [Hook] 外置 Hook 已部署: $hook_target_path"
        else
            log_warn "⚠️  [Hook] 本地 Hook 复制失败，尝试在线下载..."
        fi
    fi

    if [ ! -f "$hook_target_path" ]; then
        log_info "ℹ️  [Hook] 正在下载外置 Hook，用于设备标识拦截..."
        local hook_downloaded=false
        local total_urls=${#hook_download_urls[@]}
        if [ "$total_urls" -eq 0 ]; then
            log_warn "⚠️  [Hook] 下载节点列表为空，跳过在线下载"
        elif command -v curl >/dev/null 2>&1; then
            local index=0
            for url in "${hook_download_urls[@]}"; do
                index=$((index + 1))
                log_info "⏳ [Hook] ($index/$total_urls) 当前下载节点: $url"

                # 兼容修复：部分 curl 版本可能不支持 --progress-bar，失败时回退为基础参数
                if curl -fL --progress-bar "$url" -o "$hook_target_path"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] 外置 Hook 已在线下载: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] curl 下载失败，尝试回退参数重试: $url"
                if curl -fL "$url" -o "$hook_target_path"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] 外置 Hook 已在线下载: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] 外置 Hook 下载失败: $url"
            done
        elif command -v wget >/dev/null 2>&1; then
            local index=0
            for url in "${hook_download_urls[@]}"; do
                index=$((index + 1))
                log_info "⏳ [Hook] ($index/$total_urls) 当前下载节点: $url"

                # 兼容修复：BusyBox/精简版 wget 可能不支持 --progress=bar:force，失败时回退为基础参数
                if wget --progress=bar:force -O "$hook_target_path" "$url"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] 外置 Hook 已在线下载: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] wget 下载失败，尝试回退参数重试: $url"
                if wget -O "$hook_target_path" "$url"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] 外置 Hook 已在线下载: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] 外置 Hook 下载失败: $url"
            done
        else
            log_warn "⚠️  [Hook] 未检测到 curl/wget，无法在线下载 Hook"
        fi
        if [ "$hook_downloaded" != true ] && [ ! -f "$hook_target_path" ]; then
            log_warn "⚠️  [Hook] 外置 Hook 全部下载失败"
        fi
    fi

    local modified_count=0
    local file_modification_status=()

    # 处理每个文件：创建原始备份或从原始备份恢复
    for file in "${CURSOR_JS_FILES[@]}"; do
        log_info "📝 [处理] 正在处理: $(basename "$file")"

        if [ ! -f "$file" ]; then
            log_error "文件不存在: $file，跳过处理。"
            file_modification_status+=("'$(basename "$file")': Not Found")
            continue
        fi

        # 创建备份目录
        local backup_dir="$(dirname "$file")/backups"
        mkdir -p "$backup_dir" 2>/dev/null || true

        local file_name=$(basename "$file")
        local original_backup="$backup_dir/$file_name.original"

        # 如果原始备份不存在，先创建
        if [ ! -f "$original_backup" ]; then
            # 检查当前文件是否已被修改过
            if grep -q "__cursor_patched__" "$file" 2>/dev/null; then
                log_warn "⚠️  [警告] 文件已被修改但无原始备份，将使用当前版本作为基础"
            fi
            cp "$file" "$original_backup"
            chown "$CURRENT_USER":"$CURRENT_GROUP" "$original_backup" 2>/dev/null || true
            chmod 444 "$original_backup" 2>/dev/null || true
            log_info "✅ [备份] 原始备份创建成功: $file_name"
        else
            # 从原始备份恢复，确保每次都是干净的注入
            log_info "🔄 [恢复] 从原始备份恢复: $file_name"
            cp "$original_backup" "$file"
        fi

        # 创建时间戳备份（记录每次修改前的状态）
        local backup_file="$backup_dir/$file_name.backup_$(date +%Y%m%d_%H%M%S)"
        if ! cp "$file" "$backup_file"; then
            log_error "无法创建文件备份: $file"
            file_modification_status+=("'$(basename "$file")': Backup Failed")
            continue
        fi
        chown "$CURRENT_USER":"$CURRENT_GROUP" "$backup_file" 2>/dev/null || true
        chmod 444 "$backup_file" 2>/dev/null || true

        chmod u+w "$file" || {
            log_error "无法修改文件权限（写）: $file"
            file_modification_status+=("'$(basename "$file")': Permission Error")
            continue
        }

        local replaced=false

        # ========== 方法A: someValue占位符替换（稳定锚点） ==========
        # 重要说明：
        # 当前 Cursor 的 main.js 中占位符通常是以字符串字面量形式出现，例如：
        #   this.machineId="someValue.machineId"
        # 如果直接把 someValue.machineId 替换成 "\"<真实值>\""，会形成 ""<真实值>"" 导致 JS 语法错误。
        # 因此这里优先替换完整的字符串字面量（包含外层引号），再兜底替换不带引号的占位符。
        if grep -q 'someValue\.machineId' "$file"; then
            sed_inplace "s/\"someValue\.machineId\"/\"${machine_id}\"/g" "$file"
            sed_inplace "s/'someValue\.machineId'/\"${machine_id}\"/g" "$file"
            sed_inplace "s/someValue\.machineId/\"${machine_id}\"/g" "$file"
            log_info "   ✓ [方案A] 替换 someValue.machineId"
            replaced=true
        fi

        if grep -q 'someValue\.macMachineId' "$file"; then
            sed_inplace "s/\"someValue\.macMachineId\"/\"${mac_machine_id}\"/g" "$file"
            sed_inplace "s/'someValue\.macMachineId'/\"${mac_machine_id}\"/g" "$file"
            sed_inplace "s/someValue\.macMachineId/\"${mac_machine_id}\"/g" "$file"
            log_info "   ✓ [方案A] 替换 someValue.macMachineId"
            replaced=true
        fi

        if grep -q 'someValue\.devDeviceId' "$file"; then
            sed_inplace "s/\"someValue\.devDeviceId\"/\"${device_id}\"/g" "$file"
            sed_inplace "s/'someValue\.devDeviceId'/\"${device_id}\"/g" "$file"
            sed_inplace "s/someValue\.devDeviceId/\"${device_id}\"/g" "$file"
            log_info "   ✓ [方案A] 替换 someValue.devDeviceId"
            replaced=true
        fi

        if grep -q 'someValue\.sqmId' "$file"; then
            sed_inplace "s/\"someValue\.sqmId\"/\"${sqm_id}\"/g" "$file"
            sed_inplace "s/'someValue\.sqmId'/\"${sqm_id}\"/g" "$file"
            sed_inplace "s/someValue\.sqmId/\"${sqm_id}\"/g" "$file"
            log_info "   ✓ [方案A] 替换 someValue.sqmId"
            replaced=true
        fi

        if grep -q 'someValue\.sessionId' "$file"; then
            sed_inplace "s/\"someValue\.sessionId\"/\"${session_id}\"/g" "$file"
            sed_inplace "s/'someValue\.sessionId'/\"${session_id}\"/g" "$file"
            sed_inplace "s/someValue\.sessionId/\"${session_id}\"/g" "$file"
            log_info "   ✓ [方案A] 替换 someValue.sessionId"
            replaced=true
        fi

        if grep -q 'someValue\.firstSessionDate' "$file"; then
            sed_inplace "s/\"someValue\.firstSessionDate\"/\"${first_session_date}\"/g" "$file"
            sed_inplace "s/'someValue\.firstSessionDate'/\"${first_session_date}\"/g" "$file"
            sed_inplace "s/someValue\.firstSessionDate/\"${first_session_date}\"/g" "$file"
            log_info "   ✓ [方案A] 替换 someValue.firstSessionDate"
            replaced=true
        fi

        # ========== 方法B: b6 定点重写（机器码源函数，仅 main.js） ==========
        local b6_patched=false
        if [ "$(basename "$file")" = "main.js" ]; then
            if command -v python3 >/dev/null 2>&1; then
                local b6_result
                b6_result=$(python3 - "$file" "$machine_guid" "$machine_id" <<'PY'
# 🔧 修复：使用标准 4 空格缩进，避免 IndentationError
import re, sys

def diag(msg):
    print(f"[方案B][诊断] {msg}", file=sys.stderr)

path, machine_guid, machine_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

# ✅ 1+3 融合：限定 out-build/vs/base/node/id.js 模块内做特征匹配 + 花括号配对定位函数边界
marker = "out-build/vs/base/node/id.js"
marker_index = data.find(marker)
if marker_index < 0:
    print("NOT_FOUND")
    diag(f"未找到模块标记: {marker}")
    raise SystemExit(0)

window_end = min(len(data), marker_index + 200000)
window = data[marker_index:window_end]

def find_matching_brace(text, open_index, max_scan=20000):
    limit = min(len(text), open_index + max_scan)
    depth = 1
    in_single = in_double = in_template = False
    in_line_comment = in_block_comment = False
    escape = False
    i = open_index + 1
    while i < limit:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < limit else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue

        if in_single:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_double = False
            i += 1
            continue
        if in_template:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "`":
                in_template = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue

        if ch == "'":
            in_single = True
            i += 1
            continue
        if ch == '"':
            in_double = True
            i += 1
            continue
        if ch == "`":
            in_template = True
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i

        i += 1
    return None

# 🔧 修复：避免 raw string + 单引号 + ['"] 字符组导致的语法错误；同时修正正则转义，提升 b6 特征匹配命中率
hash_re = re.compile(r"""createHash\(["']sha256["']\)""")
sig_re = re.compile(r'^async function (\w+)\((\w+)\)')

hash_matches = list(hash_re.finditer(window))
diag(f"marker_index={marker_index} window_len={len(window)} sha256_createHash={len(hash_matches)}")

for idx, hm in enumerate(hash_matches, start=1):
    hash_pos = hm.start()
    func_start = window.rfind("async function", 0, hash_pos)
    if func_start < 0:
        if idx <= 3:
            diag(f"候选#{idx}: 未找到 async function 起点")
        continue

    open_brace = window.find("{", func_start)
    if open_brace < 0:
        if idx <= 3:
            diag(f"候选#{idx}: 未找到函数起始花括号")
        continue

    end_brace = find_matching_brace(window, open_brace, max_scan=20000)
    if end_brace is None:
        if idx <= 3:
            diag(f"候选#{idx}: 花括号配对失败（扫描上限内未闭合）")
        continue

    func_text = window[func_start:end_brace + 1]
    if len(func_text) > 8000:
        if idx <= 3:
            diag(f"候选#{idx}: 函数体过长 len={len(func_text)}，已跳过")
        continue

    sm = sig_re.match(func_text)
    if not sm:
        if idx <= 3:
            diag(f"候选#{idx}: 未解析到函数签名（async function name(param)）")
        continue
    name, param = sm.group(1), sm.group(2)

    # 特征校验：sha256 + hex digest + return param ? raw : hash
    has_digest = re.search(r"""\.digest\(["']hex["']\)""", func_text) is not None
    has_return = re.search(r'return\s+' + re.escape(param) + r'\?\w+:\w+\}', func_text) is not None
    if idx <= 3:
        diag(f"候选#{idx}: {name}({param}) len={len(func_text)} digest={has_digest} return={has_return}")
    if not has_digest:
        continue
    if not has_return:
        continue

    replacement = f'async function {name}({param}){{return {param}?"{machine_guid}":"{machine_id}";}}'
    abs_start = marker_index + func_start
    abs_end = marker_index + end_brace
    new_data = data[:abs_start] + replacement + data[abs_end + 1:]
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_data)
    diag(f"命中并重写: {name}({param}) len={len(func_text)}")
    print("PATCHED")
    break
else:
    diag("未找到满足特征的候选函数")
    print("NOT_FOUND")
PY
                 )
                if [ "$b6_result" = "PATCHED" ]; then
                    log_info "   ✓ [方案B] 已重写 b6 特征函数"
                    b6_patched=true
                else
                    log_warn "⚠️  [方案B] 未定位到 b6 特征函数"
                fi
            else
                log_warn "⚠️  [方案B] 未检测到 python3，跳过 b6 定点重写"
            fi
        fi

        # ========== 方法C: Loader Stub 注入 ==========
        local inject_code='// ========== Cursor Hook Loader 开始 ==========
;(async function(){/*__cursor_patched__*/
"use strict";
if(globalThis.__cursor_hook_loaded__)return;
globalThis.__cursor_hook_loaded__=true;

try{
    // 兼容 ESM/CJS：避免使用 import.meta（仅 ESM 支持），统一用动态 import 加载 Hook
    var fsMod=await import("fs");
    var pathMod=await import("path");
    var osMod=await import("os");
    var urlMod=await import("url");

    var fs=fsMod&&(fsMod.default||fsMod);
    var path=pathMod&&(pathMod.default||pathMod);
    var os=osMod&&(osMod.default||osMod);
    var url=urlMod&&(urlMod.default||urlMod);

    if(fs&&path&&os&&url&&typeof url.pathToFileURL==="function"){
        var hookPath=path.join(os.homedir(), ".cursor_hook.js");
        if(typeof fs.existsSync==="function"&&fs.existsSync(hookPath)){
            await import(url.pathToFileURL(hookPath).href);
        }
    }
}catch(e){
    // 失败静默，避免影响启动
}
})();
// ========== Cursor Hook Loader 结束 ==========

'

        # 在版权声明后注入代码
        local temp_file=$(mktemp)
        if grep -q '\*/' "$file"; then
            awk -v inject="$inject_code" '
            /\*\// && !injected {
                print
                print ""
                print inject
                injected = 1
                next
            }
            { print }
            ' "$file" > "$temp_file"
            log_info "   ✓ [方案C] Loader Stub 已注入（版权声明后）"
        else
            echo "$inject_code" > "$temp_file"
            cat "$file" >> "$temp_file"
            log_info "   ✓ [方案C] Loader Stub 已注入（文件开头）"
        fi

        if mv "$temp_file" "$file"; then
            local summary="Hook加载器"
            if [ "$replaced" = true ]; then
                summary="someValue替换 + $summary"
            fi
            if [ "$b6_patched" = true ]; then
                summary="b6定点重写 + $summary"
            fi
            log_info "✅ [成功] 增强版方案修改成功（$summary）"
            ((modified_count++))
            file_modification_status+=("'$(basename "$file")': Success")

            chmod u-w,go-w "$file" 2>/dev/null || true
            chown "$CURRENT_USER":"$CURRENT_GROUP" "$file" 2>/dev/null || true
        else
            log_error "Hook注入失败 (无法移动临时文件)"
            rm -f "$temp_file"
            file_modification_status+=("'$(basename "$file")': Inject Failed")
            cp "$original_backup" "$file" 2>/dev/null || true
        fi

    done

    log_info "📊 [统计] JS 文件处理状态汇总:"
    for status in "${file_modification_status[@]}"; do
        log_info "   - $status"
    done

    if [ "$modified_count" -eq 0 ]; then
        log_error "❌ [失败] 未能成功修改任何JS文件。"
        return 1
    fi

    log_info "🎉 [完成] 成功修改 $modified_count 个JS文件"
    log_info "💡 [说明] 使用增强版三重方案："
    log_info "   • 方案A: someValue占位符替换（稳定锚点，跨版本兼容）"
    log_info "   • 方案B: b6 定点重写（机器码源函数）"
    log_info "   • 方案C: Loader Stub + 外置 Hook（cursor_hook.js）"
    log_info "📁 [配置] ID 配置文件: $ids_config_path"
    return 0
}

# 禁用自动更新
disable_auto_update() {
    log_info "正在尝试禁用 Cursor 自动更新..."
    
    # 查找可能的更新配置文件
    local update_configs=()
    # 用户配置目录下的
    if [ -d "$CURSOR_CONFIG_DIR" ]; then
        update_configs+=("$CURSOR_CONFIG_DIR/update-config.json")
        update_configs+=("$CURSOR_CONFIG_DIR/settings.json") # 有些设置可能在这里
    fi
    # 安装目录下的 (如果资源目录确定)
    if [ -n "$CURSOR_RESOURCES" ] && [ -d "$CURSOR_RESOURCES" ]; then
        update_configs+=("$CURSOR_RESOURCES/resources/app-update.yml")
         update_configs+=("$CURSOR_RESOURCES/app-update.yml") # 可能的位置
    fi
     # 标准安装目录下的
     if [ -d "$INSTALL_DIR" ]; then
          update_configs+=("$INSTALL_DIR/resources/app-update.yml")
          update_configs+=("$INSTALL_DIR/app-update.yml")
     fi
     # $TARGET_HOME/.local/share
     update_configs+=("$TARGET_HOME/.local/share/cursor/update-config.json")


    local disabled_count=0
    
    # 处理 JSON 配置文件
    local json_config_pattern='update-config.json|settings.json'
    for config in "${update_configs[@]}"; do
       if [[ "$config" =~ $json_config_pattern ]] && [ -f "$config" ]; then
           log_info "找到可能的更新配置文件: $config"
           
           # 备份
           cp "$config" "${config}.bak_$(date +%Y%m%d%H%M%S)" 2>/dev/null
           
            # 尝试修改 JSON (如果存在且是 settings.json)
            if [[ "$config" == *settings.json ]]; then
                # 🔧 兼容修复：复用 modify_or_add_config 统一处理替换/注入，避免 sed -i 与 \n 扩展差异
                if modify_or_add_config "update.mode" "none" "$config"; then
                    ((disabled_count++))
                    log_info "已尝试在 '$config' 中设置 'update.mode' 为 'none'"
                else
                    log_warn "修改 settings.json 中的 update.mode 失败: $config"
                fi
            elif [[ "$config" == *update-config.json ]]; then
                 # 直接覆盖 update-config.json
                 echo '{"autoCheck": false, "autoDownload": false}' > "$config"
                 chown "$CURRENT_USER":"$CURRENT_GROUP" "$config" || log_warn "设置所有权失败: $config"
                chmod 644 "$config" || log_warn "设置权限失败: $config"
                ((disabled_count++))
                log_info "已覆盖更新配置文件: $config"
            fi
       fi
    done

    # 处理 YAML 配置文件
     local yml_config_pattern='app-update.yml'
     for config in "${update_configs[@]}"; do
        if [[ "$config" =~ $yml_config_pattern ]] && [ -f "$config" ]; then
            log_info "找到可能的更新配置文件: $config"
            # 备份
            cp "$config" "${config}.bak_$(date +%Y%m%d%H%M%S)" 2>/dev/null
            # 清空或修改内容 (简单起见，直接清空或写入禁用标记)
             echo "# Automatic updates disabled by script $(date)" > "$config"
             # echo "provider: generic" > "$config" # 或者尝试修改 provider
             # echo "url: http://127.0.0.1" >> "$config"
             chmod 444 "$config" # 设置为只读
             ((disabled_count++))
             log_info "已修改/清空更新配置文件: $config"
        fi
     done

    # 尝试查找updater可执行文件并禁用（重命名或移除权限）
    local updater_paths=()
     if [ -n "$CURSOR_RESOURCES" ] && [ -d "$CURSOR_RESOURCES" ]; then
        # 兼容修复：不强依赖 find -executable，且兜底避免 find 非0 触发 set -e
        updater_paths+=($(find "$CURSOR_RESOURCES" -name "updater" -type f 2>/dev/null || true))
        updater_paths+=($(find "$CURSOR_RESOURCES" -name "CursorUpdater" -type f 2>/dev/null || true)) # macOS 风格？
     fi
       if [ -d "$INSTALL_DIR" ]; then
          updater_paths+=($(find "$INSTALL_DIR" -name "updater" -type f 2>/dev/null || true))
          updater_paths+=($(find "$INSTALL_DIR" -name "CursorUpdater" -type f 2>/dev/null || true))
       fi
       updater_paths+=("$CURSOR_CONFIG_DIR/updater") # 旧位置？

    for updater in "${updater_paths[@]}"; do
        if [ -f "$updater" ] && [ -x "$updater" ]; then
            log_info "找到更新程序: $updater"
            local bak_updater="${updater}.bak_$(date +%Y%m%d%H%M%S)"
            if mv "$updater" "$bak_updater"; then
                 log_info "已重命名更新程序为: $bak_updater"
                 ((disabled_count++))
            else
                 log_warn "重命名更新程序失败: $updater，尝试移除执行权限..."
                 if chmod a-x "$updater"; then
                      log_info "已移除更新程序执行权限: $updater"
                      ((disabled_count++))
                 else
                     log_error "无法禁用更新程序: $updater"
                 fi
            fi
        # elif [ -d "$updater" ]; then # 如果是目录，尝试禁用
        #     log_info "找到更新程序目录: $updater"
        #     touch "${updater}.disabled_by_script"
        #     log_info "已标记禁用更新程序目录: $updater"
        #     ((disabled_count++))
        fi
    done
    
    if [ "$disabled_count" -eq 0 ]; then
        log_warn "未能找到或禁用任何已知的自动更新机制。"
        log_warn "如果 Cursor 仍然自动更新，可能需要手动查找并禁用相关文件或设置。"
    else
        log_info "成功禁用或尝试禁用了 $disabled_count 个自动更新相关的文件/程序。"
    fi
     return 0 # 即使没找到，也认为函数执行成功
}

# 新增：通用菜单选择函数
select_menu_option() {
    local prompt="$1"
    IFS='|' read -ra options <<< "$2"
    local default_index=${3:-0}
    local selected_index=$default_index
    local key_input
    local cursor_up=$'\e[A' # 更标准的 ANSI 码
    local cursor_down=$'\e[B'
    local cursor_up_alt=$'\eOA' # 兼容应用光标模式
    local cursor_down_alt=$'\eOB'
    local enter_key=$'\n'
    # 兼容管道执行场景：stdin 非 TTY 时改用 /dev/tty 读取
    local input_fd=0
    local input_fd_opened=0

    if [ -t 0 ]; then
        input_fd=0
    elif [ -r /dev/tty ]; then
        exec 3</dev/tty
        input_fd=3
        input_fd_opened=1
    else
        # 无可用 TTY，直接使用默认选项返回
        echo -e "$prompt ${GREEN}${options[$selected_index]}${NC}"
        return $selected_index
    fi

    # 隐藏光标
    tput civis
    # 清除可能存在的旧菜单行 (假设菜单最多 N 行)
    local num_options=${#options[@]}
    for ((i=0; i<num_options+1; i++)); do echo -e "\033[K"; done # 清除行
     tput cuu $((num_options + 1)) # 光标移回顶部


    # 显示提示信息
    echo -e "$prompt"
    
    # 绘制菜单函数
    draw_menu() {
        # 光标移到菜单开始行下方一行
        tput cud 1 
        for i in "${!options[@]}"; do
             tput el # 清除当前行
            if [ $i -eq $selected_index ]; then
                echo -e " ${GREEN}►${NC} ${options[$i]}"
            else
                echo -e "   ${options[$i]}"
            fi
        done
         # 将光标移回提示行下方
        tput cuu "$num_options"
    }
    
    # 第一次显示菜单
    draw_menu

    # 循环处理键盘输入
    while true; do
        # 读取按键 (使用 -sn1 或 -sn3 取决于系统对箭头键的处理)
        # -N 1 读取单个字符，可能需要多次读取箭头键
        # -N 3 一次读取3个字符，通常用于箭头键
        read -rsn1 -u "$input_fd" key_press_1 # 读取第一个字符
         if [[ "$key_press_1" == $'\e' ]]; then # 如果是 ESC，读取后续字符
             read -rsn2 -u "$input_fd" key_press_2 # 读取 '[' 和 A/B
             key_input="$key_press_1$key_press_2"
         elif [[ "$key_press_1" == "" ]]; then # 如果是 Enter
             key_input=$enter_key
         else
             key_input="$key_press_1" # 其他按键
         fi

        # 检测按键
        case "$key_input" in
            # 上箭头键
            "$cursor_up"|"$cursor_up_alt")
                if [ $selected_index -gt 0 ]; then
                    ((selected_index--))
                    draw_menu
                fi
                ;;
            # 下箭头键
            "$cursor_down"|"$cursor_down_alt")
                if [ $selected_index -lt $((${#options[@]}-1)) ]; then
                    ((selected_index++))
                    draw_menu
                fi
                ;;
            # 数字键选择（1..N），避免方向键不可用
            [1-9])
                if [ "$key_input" -ge 1 ] && [ "$key_input" -le "$num_options" ]; then
                    selected_index=$((key_input - 1))
                    draw_menu
                fi
                ;;
            # Enter键
            "$enter_key")
                 # 清除菜单区域
                 tput cud 1 # 下移一行开始清除
                 for i in "${!options[@]}"; do tput el; tput cud 1; done
                 tput cuu $((num_options + 1)) # 移回提示行
                 tput el # 清除提示行本身
                 echo -e "$prompt ${GREEN}${options[$selected_index]}${NC}" # 显示最终选择

                 # 恢复光标
                 tput cnorm
                 # 关闭 /dev/tty 句柄，避免资源占用
                 if [ "$input_fd_opened" -eq 1 ]; then
                     exec 3<&-
                 fi
                 # 返回选择的索引
                 return $selected_index
                ;;
             *)
                 # 忽略其他按键
                 ;;
        esac
    done
}

# 新增 Cursor 初始化清理函数
cursor_initialize_cleanup() {
    log_info "正在执行 Cursor 初始化清理..."
    # CURSOR_CONFIG_DIR 在脚本全局已定义: $TARGET_HOME/.config/Cursor
    local USER_CONFIG_BASE_PATH="$CURSOR_CONFIG_DIR/User"

    log_debug "用户配置基础路径: $USER_CONFIG_BASE_PATH"

    local files_to_delete=(
        "$USER_CONFIG_BASE_PATH/globalStorage/state.vscdb"
        "$USER_CONFIG_BASE_PATH/globalStorage/state.vscdb.backup"
    )
    
    local folder_to_clean_contents="$USER_CONFIG_BASE_PATH/History"
    local folder_to_delete_completely="$USER_CONFIG_BASE_PATH/workspaceStorage"

    # 删除指定文件
    for file_path in "${files_to_delete[@]}"; do
        log_debug "检查文件: $file_path"
        if [ -f "$file_path" ]; then
            if rm -f "$file_path"; then
                log_info "已删除文件: $file_path"
            else
                log_error "删除文件 $file_path 失败"
            fi
        else
            log_warn "文件不存在，跳过删除: $file_path"
        fi
    done

    # 清空指定文件夹内容
    log_debug "检查待清空文件夹: $folder_to_clean_contents"
    if [ -d "$folder_to_clean_contents" ]; then
        if find "$folder_to_clean_contents" -mindepth 1 -delete; then
            log_info "已清空文件夹内容: $folder_to_clean_contents"
        else
            if [ -z "$(ls -A "$folder_to_clean_contents")" ]; then
                 log_info "文件夹 $folder_to_clean_contents 现在为空。"
            else
                 log_error "清空文件夹 $folder_to_clean_contents 内容失败 (部分或全部)。请检查权限或手动删除。"
            fi
        fi
    else
        log_warn "文件夹不存在，跳过清空: $folder_to_clean_contents"
    fi

    # 删除指定文件夹及其内容
    log_debug "检查待删除文件夹: $folder_to_delete_completely"
    if [ -d "$folder_to_delete_completely" ]; then
        if rm -rf "$folder_to_delete_completely"; then
            log_info "已删除文件夹: $folder_to_delete_completely"
        else
            log_error "删除文件夹 $folder_to_delete_completely 失败"
        fi
    else
        log_warn "文件夹不存在，跳过删除: $folder_to_delete_completely"
    fi

    log_info "Cursor 初始化清理完成。"
}

# 主函数
main() {
    # 在显示菜单/流程说明前调整终端窗口大小；不支持则静默忽略
    if [ -z "${CURSOR_NO_TTY_UI:-}" ]; then
        try_resize_terminal_window
    fi

    # 初始化日志文件
    initialize_log
    log_info "脚本启动..."
    log_info "运行用户: $CURRENT_USER (脚本以 EUID=$EUID 运行)"

    # 检查权限 (必须在脚本早期)
    check_permissions # 需要 root 权限进行安装和修改系统文件

    # 记录系统信息
    log_info "系统信息: $(uname -a)"
    log_cmd_output "lsb_release -a 2>/dev/null || cat /etc/*release 2>/dev/null || cat /etc/issue" "系统版本信息"
    
    if [ -z "${CURSOR_NO_TTY_UI:-}" ]; then
        clear
        # 显示 Logo
        echo -e "
        ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ 
       ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
       ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
       ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
       ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
        ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝
        "
        echo -e "${BLUE}=====================================================${NC}"
        echo -e "${GREEN}         Cursor Linux 启动与修改工具（免费）            ${NC}"
        echo -e "${YELLOW}        关注公众号【煎饼果子卷AI】     ${NC}"
        echo -e "${YELLOW}  一起交流更多Cursor技巧和AI知识(脚本免费、关注公众号加群有更多技巧和大佬)  ${NC}"
        echo -e "${BLUE}=====================================================${NC}"
        echo
        echo -e "${YELLOW}⚡  [小小广告] Cursor官网正规成品号：Unlimited ♾️ ¥1050 | 7天周卡 $100 ¥210 | 7天周卡 $500 ¥1050 | 7天周卡 $1000 ¥2450 | 全部7天质保 | ，WeChat：JavaRookie666  ${NC}"
        echo
        echo -e "${YELLOW}[提示]${NC} 本工具旨在修改 Cursor 以解决可能的启动问题或设备限制。"
        echo -e "${YELLOW}[提示]${NC} 它将优先修改 JS 文件，并可选择重置设备ID和禁用自动更新。"
        echo -e "${YELLOW}[提示]${NC} 如果未找到 Cursor，将尝试从 '$APPIMAGE_SEARCH_DIR' 目录安装。"
        echo
    fi

    # 查找 Cursor 路径
    if ! find_cursor_path; then
        log_warn "系统中未找到现有的 Cursor 安装。"
        set +e
        select_menu_option "是否尝试从 '$APPIMAGE_SEARCH_DIR' 目录中的 AppImage 文件安装 Cursor？" "是，安装 Cursor|否，退出脚本" 0
        install_choice=$?
        set -e
        
        if [ "$install_choice" -eq 0 ]; then
            if ! install_cursor_appimage; then
                log_error "Cursor 安装失败，请检查上面的日志。脚本将退出。"
                exit 1
            fi
            # 安装成功后，重新查找路径
            if ! find_cursor_path || ! find_cursor_resources; then
                 log_error "安装后仍然无法找到 Cursor 的可执行文件或资源目录。请检查 '$INSTALL_DIR' 和 '/usr/local/bin/cursor'。脚本退出。"
                 exit 1
            fi
            log_info "Cursor 安装成功，继续执行修改步骤..."
        else
            log_info "用户选择不安装 Cursor，脚本退出。"
            exit 0
        fi
    else
        # 如果找到了 Cursor，也要确保找到资源目录
        if ! find_cursor_resources; then
            log_error "找到了 Cursor 可执行文件 ($CURSOR_PATH)，但未能定位资源目录。"
            log_error "无法继续修改 JS 文件。请检查 Cursor 安装是否完整。脚本退出。"
            exit 1
        fi
        log_info "发现已安装的 Cursor ($CURSOR_PATH)，资源目录 ($CURSOR_RESOURCES)。"
    fi

    # 到这里，Cursor 应该已安装并且路径已知

    # 检查并关闭Cursor进程
    if ! check_and_kill_cursor; then
         # check_and_kill_cursor 内部会记录错误并退出，但以防万一
         exit 1
    fi
    
    # 执行 Cursor 初始化清理
    # cursor_initialize_cleanup

    # 备份并处理配置文件 (机器码重置选项)
    if ! generate_new_config; then
         log_error "处理配置文件时出错，脚本中止。"
         # 此处可能需要考虑是否回滚JS修改（如果已执行）？目前不回滚。
         exit 1
    fi
    
    # 修改JS文件
    log_info "正在修改 Cursor JS 文件..."
    if ! modify_cursor_js_files; then
        log_error "JS 文件修改过程中发生错误。"
        log_warn "配置文件可能已被修改，但 JS 文件修改失败。"
        log_warn "如果重启后 Cursor 行为异常或仍有问题，请检查日志并考虑手动恢复备份或重新运行脚本。"
        # 决定是否继续执行禁用更新？通常建议继续
        # exit 1 # 或者选择退出
    else
        log_info "JS 文件修改成功！"
    fi
    
    # 禁用自动更新
    if ! disable_auto_update; then
        # disable_auto_update 内部会记录警告，不视为致命错误
        log_warn "尝试禁用自动更新时遇到问题（详见日志），但脚本将继续。"
    fi
    
    log_info "所有修改步骤已完成！"
    log_info "请启动 Cursor 以应用更改。"
    
    # 显示最后的提示信息
    echo
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${YELLOW}  请关注公众号【煎饼果子卷AI】获取更多技巧和交流 ${NC}"
    echo -e "${YELLOW}⚡   [小小广告] Cursor官网正规成品号：Unlimited ♾️ ¥1050 | 7天周卡 $100 ¥210 | 7天周卡 $500 ¥1050 | 7天周卡 $1000 ¥2450 | 全部7天质保 | ，WeChat：JavaRookie666  ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo
    
    # 记录脚本完成信息
    log_info "脚本执行完成"
    echo "========== Cursor ID 修改工具日志结束 $(date) ==========" >> "$LOG_FILE"
    
    # 显示日志文件位置
    echo
    log_info "详细日志已保存到: $LOG_FILE"
    echo "如遇问题请将此日志文件提供给开发者以协助排查"
    echo
}

# 执行主函数
main

exit 0 # 确保最后返回成功状态码
