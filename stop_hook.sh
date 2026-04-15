#!/usr/bin/env bash
#
# stop_hook.sh — Stop hook (fallback)
#
# 当 Claude 结束回复时触发。它会检查纯文本回复后的上下文是否超限；
# 如果处于总结模式，则只接受 summarizing 状态文件中记录的确定 prompt 路径，
# 并自动写 next_prompt 标记，确保 cg wrapper 能检测到并重启。
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

    PROMPT_FILE="$STATE_DIR/continuation_${SHORT_ID}.md"
    printf '%s\n' "$PROMPT_FILE" > "$FLAG_FILE"
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
5. 保存完毕后停止回复。Stop hook 会自动写入重启标记并通知 wrapper 开新会话。

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

⚠️ 只需要保存 ${PROMPT_FILE}，不要执行新任务。保存后停止回复即可。
SUMMARIZE_MSG
    exit 2
fi

# 已经有标记了，不需要干预
if [ -f "$NEXT_PROMPT_MARKER" ]; then
    exit 0
fi

EXPECTED_PROMPT=$(head -n 1 "$FLAG_FILE" 2>/dev/null || true)

if [ -n "$EXPECTED_PROMPT" ] && [ -f "$EXPECTED_PROMPT" ]; then
    echo "$EXPECTED_PROMPT" > "$NEXT_PROMPT_MARKER"
    exit 0
fi

# prompt 文件还没出现 → 让 Claude 继续工作（exit 2 = 强制继续）
if [ -n "$EXPECTED_PROMPT" ]; then
    echo "你还没有完成总结。请立即将 continuation prompt 保存到指定文件: $EXPECTED_PROMPT" >&2
else
    echo "你还没有完成总结，且状态文件缺少指定路径。请重新触发 Context Guard。" >&2
fi
exit 2
