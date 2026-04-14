#!/usr/bin/env bash
#
# stop_hook.sh — Stop hook (fallback)
#
# 当 Claude 结束回复时触发。如果处于总结模式但 Claude 忘记写 next_prompt 标记，
# 这个 hook 会自动补上，确保 cg wrapper 能检测到并重启。
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THRESHOLD="${CONTEXT_GUARD_THRESHOLD:-128000}"
STATE_DIR="${CONTEXT_GUARD_STATE_DIR:-$HOME/.claude/context-guard}"
FLAG_FILE="$STATE_DIR/summarizing"
NEXT_PROMPT_MARKER="$STATE_DIR/next_prompt"

mkdir -p "$STATE_DIR"

INPUT=$(cat)

# 不在总结模式，什么都不做
if [ ! -f "$FLAG_FILE" ]; then
    SESSION_ID=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('session_id', ''))" 2>/dev/null || true)

    SHORT_ID="${SESSION_ID:0:8}"
    if [ -z "$SHORT_ID" ]; then
        SHORT_ID="unknown"
    fi

    TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('transcript_path', ''))" 2>/dev/null || true)

    if [ -z "$TRANSCRIPT_PATH" ]; then
        TRANSCRIPT_PATH="${CLAUDE_TRANSCRIPT_PATH:-}"
    fi

    if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
        exit 0
    fi

    RESULT=$(python3 "$SCRIPT_DIR/check_context.py" "$TRANSCRIPT_PATH" --threshold "$THRESHOLD" --json 2>/dev/null || true)
    if [ -z "$RESULT" ]; then
        exit 0
    fi

    EXCEEDED=$(echo "$RESULT" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('exceeded', False))" 2>/dev/null || true)

    if [ "$EXCEEDED" != "True" ]; then
        exit 0
    fi

    touch "$FLAG_FILE"

    PROMPT_FILE="$STATE_DIR/continuation_${SHORT_ID}.md"
    CONTEXT_LEN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('context_length', 0))" 2>/dev/null || true)
    PCT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('percentage', 0))" 2>/dev/null || true)

    cat >&2 <<SUMMARIZE_MSG
🛑 上下文保护触发！当前用量: ${CONTEXT_LEN} tokens (${PCT}%)，已超过阈值 ${THRESHOLD} tokens。
Session ID: ${SESSION_ID}

你必须立即停止当前工作，执行以下步骤：

1. 总结当前工作：概述已完成的工作、正在进行的任务、遇到的问题
2. 记录关键状态：列出已修改的文件、待处理事项、重要设计决策
3. 生成 continuation prompt：写一段详细 prompt，让新会话能无缝继续
4. 将所有内容保存到文件: ${PROMPT_FILE}
5. 保存完毕后，立即运行以下命令来通知 wrapper 自动重启新会话：
   echo "${PROMPT_FILE}" > ${NEXT_PROMPT_MARKER}

文件格式：
\`\`\`markdown
# Continuation Prompt
Previous session: ${SESSION_ID}
Generated: $(date '+%Y-%m-%d %H:%M:%S')

## 项目概述
[简要描述正在做什么]

## 已完成的工作
- ...

## 当前进度（在哪里被中断的）
- ...

## 待处理事项
- ...

## 关键文件和修改
- ...

## 继续执行的指令
[这里写一段完整的指令，新会话的 Claude 读到后就能直接开始工作。]
\`\`\`

⚠️ 保存文件后，一定要运行:
echo "${PROMPT_FILE}" > ${NEXT_PROMPT_MARKER}
SUMMARIZE_MSG
    exit 2
fi

# 已经有标记了，不需要干预
if [ -f "$NEXT_PROMPT_MARKER" ]; then
    exit 0
fi

# 查找最近生成的 continuation prompt 文件
LATEST_PROMPT=$(find "$STATE_DIR" -name "continuation_*.md" -newer "$FLAG_FILE" 2>/dev/null | head -1 || true)

if [ -n "$LATEST_PROMPT" ] && [ -f "$LATEST_PROMPT" ]; then
    # Claude 保存了 prompt 但忘记写标记 → 补上
    echo "$LATEST_PROMPT" > "$NEXT_PROMPT_MARKER"
    exit 0
fi

# prompt 文件还没出现 → 让 Claude 继续工作（exit 2 = 强制继续）
echo "你还没有完成总结。请立即将 continuation prompt 保存到 $STATE_DIR/continuation_*.md 文件中。" >&2
exit 2
