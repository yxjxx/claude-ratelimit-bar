#!/bin/bash
# Claude Code Statusline with Rate Limit Display
# Dracula theme | Shows: model, context window, rate limits (5h + 7d), git status

JSON_INPUT=$(cat)

model=$(echo "$JSON_INPUT" | jq -r '.model.display_name // "Claude"' | sed 's/ ([^)]*)//' | sed 's/\([A-Za-z]\) \([0-9]\)/\1\2/g')
percent=$(echo "$JSON_INPUT" | jq -r '.context_window.used_percentage // 0')
ctx_size=$(echo "$JSON_INPUT" | jq -r '.context_window.context_window_size // 0')
ctx_used=$(echo "$JSON_INPUT" | jq -r '(.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0)')
cwd=$(echo "$JSON_INPUT" | jq -r '.cwd // (.workspace.current_dir // "")')

MODEL_COLOR="\033[38;5;141m"
RESET="\033[0m"
PROGRESS_BAR="\033[38;5;141m"
PROGRESS_LOW="\033[38;5;84m"
PROGRESS_MID="\033[38;5;229m"
PROGRESS_HIGH="\033[38;5;203m"
TOKEN_COLOR="\033[38;5;189m"
DIR_COLOR="\033[38;5;84m"
GIT_COLOR="\033[38;5;141m"
GIT_CLEAN="\033[38;5;84m"
GIT_DIRTY="\033[38;5;203m"

PROGRESS_FILLED="▓"
PROGRESS_EMPTY="░"

get_progress_bar() {
    local p=$1
    local filled=$((p / 20))
    local empty=$((5 - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="${PROGRESS_FILLED}"; done
    for ((i=0; i<empty; i++)); do bar+="${PROGRESS_EMPTY}"; done
    echo "$bar"
}

get_directory() {
    local dir="$1"
    local parent=$(basename "$(dirname "$dir")")
    local current=$(basename "$dir")
    if [[ "$parent" == "/" || -z "$parent" ]]; then
        echo "~/${current}"
    else
        echo "~/${parent}/${current}"
    fi
}

get_git_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }
get_git_status() {
    if git -C "$1" diff --quiet 2>/dev/null && git -C "$1" diff --cached --quiet 2>/dev/null; then
        echo "clean"
    else
        echo "dirty"
    fi
}

get_git_counts() {
    local dir="$1"
    local added=$(git -C "$dir" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    local modified=$(git -C "$dir" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    local untracked=$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    echo "$added $modified $untracked"
}

format_ctx_size() {
    local size=$1
    if (( size >= 1000 )); then
        printf "%dk" "$((size / 1000))"
    else
        echo "$size"
    fi
}

progress_bar=$(get_progress_bar "$percent")
directory=$(get_directory "$cwd")
ctx_used_fmt=$(format_ctx_size "$ctx_used")
ctx_size_fmt=$(format_ctx_size "$ctx_size")

# --- Rate limit from cache + auto-refresh if stale (>10 min) ---
RATE_CACHE="$HOME/.claude/rate-limit-cache.json"
RATE_PROBE="$HOME/.claude/rate-limit-probe.py"
RATE_MAX_AGE=600  # 10 minutes
rl_show=0
if [[ -f "$RATE_CACHE" ]]; then
    rl_session_pct=$(jq -r '.session_pct // 0' "$RATE_CACHE" 2>/dev/null)
    rl_week_pct=$(jq -r '.week_all_pct // 0' "$RATE_CACHE" 2>/dev/null)
    rl_session_reset=$(jq -r '.session_reset // ""' "$RATE_CACHE" 2>/dev/null)
    rl_week_reset=$(jq -r '.week_all_reset // ""' "$RATE_CACHE" 2>/dev/null)
    rl_ts=$(jq -r '.timestamp // 0' "$RATE_CACHE" 2>/dev/null)
    rl_age=$(( $(date +%s) - ${rl_ts%.*} ))
    rl_show=1

    # Auto-refresh in background if cache older than 10 min
    if (( rl_age > RATE_MAX_AGE )); then
        if [[ ! -f "${RATE_CACHE}.lock" ]]; then
            python3 "$RATE_PROBE" >/dev/null 2>&1 &
        fi
    fi
else
    # No cache yet, trigger first probe in background
    if [[ -f "$RATE_PROBE" && ! -f "${RATE_CACHE}.lock" ]]; then
        python3 "$RATE_PROBE" >/dev/null 2>&1 &
    fi
fi

# --- Line 1: model + context + rate limits ---
printf "${MODEL_COLOR}[${model}]${RESET} "
printf "${PROGRESS_BAR}${progress_bar}${ctx_used_fmt}/${ctx_size_fmt}${RESET}"

if (( rl_show )); then
    rl_color() {
        local p=$1
        if (( p >= 80 )); then echo -ne "$PROGRESS_HIGH"
        elif (( p > 50 )); then echo -ne "$PROGRESS_MID"
        else echo -ne "$PROGRESS_LOW"
        fi
    }

    printf " ${TOKEN_COLOR}|${RESET}"
    printf " $(rl_color $rl_session_pct)5h:%d%%${RESET}" "$rl_session_pct"
    [[ -n "$rl_session_reset" ]] && printf "${TOKEN_COLOR}↻%s${RESET}" "${rl_session_reset#today }"
    printf " $(rl_color $rl_week_pct)7d:%d%%${RESET}" "$rl_week_pct"
    [[ -n "$rl_week_reset" ]] && printf "${TOKEN_COLOR}↻%s${RESET}" "$rl_week_reset"
    # Show cache age if stale (>10 min)
    if (( rl_age > 600 )); then
        printf " ${TOKEN_COLOR}(%dm ago)${RESET}" "$((rl_age / 60))"
    fi
fi
printf "\n"

# --- Line 2: directory + git ---
printf "${DIR_COLOR}${directory}${RESET}"
if [[ -n "$cwd" ]]; then
    git_branch=$(get_git_branch "$cwd")
    if [[ -n "$git_branch" ]]; then
        git_status=$(get_git_status "$cwd")
        printf " ${GIT_COLOR}(${git_branch})${RESET}"
        if [[ "$git_status" == "clean" ]]; then
            printf "${GIT_CLEAN}✓${RESET}"
        else
            printf "${GIT_DIRTY}✗${RESET}"
            read added modified untracked <<< "$(get_git_counts "$cwd")"
            [[ "$added" -gt 0 ]] && printf "${GIT_CLEAN}+%s${RESET}" "$added"
            [[ "$modified" -gt 0 ]] && printf "${PROGRESS_MID}~%s${RESET}" "$modified"
            [[ "$untracked" -gt 0 ]] && printf "${TOKEN_COLOR}?%s${RESET}" "$untracked"
        fi
    fi
fi
