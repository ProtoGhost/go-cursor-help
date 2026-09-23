#!/bin/bash

# ========================================
# Cursor Hook Injection Script (macOS/Linux)
# ========================================
#
# 🎯 Feature: Injects cursor_hook.js into the top of Cursor's main.js file
# 
# 📦 Usage:
# chmod +x inject_hook_unix.sh
# ./inject_hook_unix.sh
#
# Arguments:
#   --rollback  Rollback to original version
#   --force     Force re-injection
#   --debug     Enable debug mode
#
# ========================================

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Argument parsing
ROLLBACK=false
FORCE=false
DEBUG=false

for arg in "$@"; do
    case $arg in
        --rollback) ROLLBACK=true ;;
        --force) FORCE=true ;;
        --debug) DEBUG=true ;;
    esac
done

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { if $DEBUG; then echo -e "${BLUE}[DEBUG]${NC} $1"; fi; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/cursor_hook.js"

# Get Cursor main.js path
get_cursor_path() {
    local paths=()
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        paths=(
            "/Applications/Cursor.app/Contents/Resources/app/out/main.js"
            "$HOME/Applications/Cursor.app/Contents/Resources/app/out/main.js"
        )
    else
        # Linux
        paths=(
            "/opt/Cursor/resources/app/out/main.js"
            "/usr/share/cursor/resources/app/out/main.js"
            "$HOME/.local/share/cursor/resources/app/out/main.js"
            "/snap/cursor/current/resources/app/out/main.js"
        )
    fi
    
    for path in "${paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Check if already injected
check_already_injected() {
    local main_js="$1"
    grep -q "__cursor_patched__" "$main_js" 2>/dev/null
}

# Backup original file
backup_main_js() {
    local main_js="$1"
    local backup_dir="$(dirname "$main_js")/backups"
    
    mkdir -p "$backup_dir"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$backup_dir/main.js.backup_$timestamp"
    local original_backup="$backup_dir/main.js.original"
    
    # Create original backup if not present
    if [[ ! -f "$original_backup" ]]; then
        cp "$main_js" "$original_backup"
        log_info "Created original backup: $original_backup"
    fi
    
    cp "$main_js" "$backup_path"
    log_info "Created timestamped backup: $backup_path"
    
    echo "$original_backup"
}

# Rollback to original version
restore_main_js() {
    local main_js="$1"
    local backup_dir="$(dirname "$main_js")/backups"
    local original_backup="$backup_dir/main.js.original"
    
    if [[ -f "$original_backup" ]]; then
        cp "$original_backup" "$main_js"
        log_info "Rolled back to original version successfully"
        return 0
    else
        log_error "Original backup file not found"
        return 1
    fi
}

# Stop Cursor processes
stop_cursor_process() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        pkill -x "Cursor" 2>/dev/null || true
        pkill -x "Cursor Helper" 2>/dev/null || true
    else
        # Linux
        pkill -f "cursor" 2>/dev/null || true
    fi
    
    sleep 2
    log_info "Cursor processes stopped"
}

# Inject Hook code
inject_hook() {
    local main_js="$1"
    local hook_script="$2"
    
    # Read Hook script content
    local hook_content=$(cat "$hook_script")
    
    # Create temporary file
    local temp_file=$(mktemp)
    
    # Read main.js and inject Hook after copyright header
    awk -v hook="$hook_content" '
    /^\*\// && !injected {
        print
        print ""
        print "// ========== Cursor Hook Injection Start =========="
        print hook
        print "// ========== Cursor Hook Injection End =========="
        print ""
        injected = 1
        next
    }
    { print }
    ' "$main_js" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$main_js"

    return 0
}

# Main function
main() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Cursor Hook Injection Tool (Unix)    ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # Get Cursor main.js path
    local main_js
    main_js=$(get_cursor_path) || {
        log_error "Cursor installation path not found"
        log_error "Please ensure Cursor is properly installed"
        exit 1
    }
    log_info "Found Cursor main.js: $main_js"

    # Rollback mode
    if $ROLLBACK; then
        log_info "Executing rollback operation..."
        stop_cursor_process
        if restore_main_js "$main_js"; then
            log_info "Rollback completed successfully!"
        else
            log_error "Rollback failed!"
            exit 1
        fi
        exit 0
    fi

    # Check if already injected
    if check_already_injected "$main_js" && ! $FORCE; then
        log_warn "Hook is already injected; no action needed"
        log_info "To force re-injection, use the --force argument"
        exit 0
    fi

    # Check if Hook script exists
    if [[ ! -f "$HOOK_SCRIPT" ]]; then
        log_error "cursor_hook.js file not found"
        log_error "Please ensure cursor_hook.js is in the same directory as this script"
        exit 1
    fi
    log_info "Found Hook script: $HOOK_SCRIPT"

    # Stop Cursor processes
    stop_cursor_process

    # Backup original file
    log_info "Backing up original file..."
    backup_main_js "$main_js"

    # Inject Hook code
    log_info "Injecting Hook code..."
    if inject_hook "$main_js" "$HOOK_SCRIPT"; then
        log_info "Hook injected successfully!"
    else
        log_error "Hook injection failed!"
        log_warn "Rolling back..."
        restore_main_js "$main_js"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   ✅ Hook Injection Complete!          ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    log_info "You can now launch Cursor"
    log_info "ID configuration file location: ~/.cursor_ids.json"
    echo ""
    echo -e "${YELLOW}Notes:${NC}"
    echo "  - To rollback: ./inject_hook_unix.sh --rollback"
    echo "  - To force re-inject: ./inject_hook_unix.sh --force"
    echo "  - To enable debug logging: ./inject_hook_unix.sh --debug"
    echo ""
}

# Run main function
main "$@"
