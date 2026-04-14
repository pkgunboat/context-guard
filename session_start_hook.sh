#!/usr/bin/env bash
#
# session_start_hook.sh — 新会话启动时清理旧的 guard 状态
#

STATE_DIR="${CONTEXT_GUARD_STATE_DIR:-$HOME/.claude/context-guard}"

# 清理上一次的 summarizing 标志（新会话不应继承）
rm -f "$STATE_DIR/summarizing"

exit 0
