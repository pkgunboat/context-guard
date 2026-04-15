#!/usr/bin/env bash
#
# context_guard_hook.sh — PreToolUse hook
#
# 每次工具调用前检查上下文用量。
# 超限时阻止工具调用，指示 Claude 总结并保存带 session_id 的 prompt 文件。
# 保存完成后由 Stop hook 写入 next_prompt 标记，供 cg wrapper 自动重启。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THRESHOLD="${CONTEXT_GUARD_THRESHOLD:-128000}"
STATE_DIR="${CONTEXT_GUARD_STATE_DIR:-$HOME/.claude/context-guard}"
FLAG_FILE="$STATE_DIR/summarizing"
NEXT_PROMPT_MARKER="$STATE_DIR/next_prompt"

mkdir -p "$STATE_DIR"

# 读取 hook 输入
INPUT=$(cat)

# ── 提取 session_id ──
SESSION_ID=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('session_id', ''))" 2>/dev/null || true)

# 截取 session_id 前 8 位用于文件名（太长不好看）
SHORT_ID="${SESSION_ID:0:8}"
if [ -z "$SHORT_ID" ]; then
    SHORT_ID="unknown"
fi

PROMPT_FILE="$STATE_DIR/continuation_${SHORT_ID}.md"

# ── 获取 transcript 路径 ──
# Claude hook 输入会携带当前会话的 transcript_path；优先用它，避免多会话时
# fallback 到 ~/.claude/projects 下“最新文件”而读到别的会话或过期会话。
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('transcript_path', ''))" 2>/dev/null || true)

if [ -z "$TRANSCRIPT_PATH" ]; then
    TRANSCRIPT_PATH="${CLAUDE_TRANSCRIPT_PATH:-}"
fi

if [ -z "$TRANSCRIPT_PATH" ]; then
    TRANSCRIPT_PATH=$(python3 -c "
import glob, os
d = os.path.expanduser('~/.claude/projects')
fs = glob.glob(os.path.join(d, '**', '*.jsonl'), recursive=True)
if fs:
    fs.sort(key=os.path.getmtime, reverse=True)
    print(fs[0])
" 2>/dev/null || true)
fi

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    exit 0
fi

# ── 总结模式：只放行写操作 ──
if [ -f "$FLAG_FILE" ]; then
    EXPECTED_PROMPT_FILE=$(head -n 1 "$FLAG_FILE" 2>/dev/null || true)
    if [ -z "$EXPECTED_PROMPT_FILE" ]; then
        EXPECTED_PROMPT_FILE="$PROMPT_FILE"
    fi

    TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('tool_name', ''))" 2>/dev/null || true)

    case "$TOOL_NAME" in
        Write|Edit|MultiEdit|Read|Glob|Grep)
            exit 0
            ;;
        Bash)
            COMMAND=$(echo "$INPUT" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))" 2>/dev/null || true)
            case "$COMMAND" in
                cat*|echo*|tee*|mkdir*|cp*|mv*|printf*)
                    exit 0
                    ;;
            esac
            ;;
    esac

    cat >&2 <<'BLOCK'
⚠️ 上下文保护：你当前处于"总结并交接"模式。
请不要执行新任务。你只需要：
1. 将总结内容写入指定的 continuation prompt 文件
2. 完成后停止；Stop hook 会自动通知 wrapper 重启
BLOCK
    echo "指定文件: ${EXPECTED_PROMPT_FILE}" >&2
    exit 2
fi

# ── 检查上下文用量 ──
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

# ── 超限：进入总结模式 ──
printf '%s\n' "$PROMPT_FILE" > "$FLAG_FILE"

CONTEXT_LEN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('context_length', 0))" 2>/dev/null || true)
PCT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('percentage', 0))" 2>/dev/null || true)

cat >&2 <<SUMMARIZE_MSG
🛑 上下文保护触发！当前用量: ${CONTEXT_LEN} tokens (${PCT}%)，已超过阈值 ${THRESHOLD} tokens。
Session ID: ${SESSION_ID}

你必须立即停止当前工作，执行以下步骤：

1. **总结当前工作**：概述已完成的工作、正在进行的任务、遇到的问题
2. **记录关键状态**：列出已修改的文件、待处理的事项、重要的设计决策
3. **生成 continuation prompt**：写一段详细的 prompt，让新会话能无缝继续
4. **将所有内容保存到文件**: ${PROMPT_FILE}
5. **保存完毕后停止回复**。Stop hook 会自动写入重启标记并通知 wrapper 开新会话。

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
[这里写一段完整的指令，新会话的 Claude 读到后就能直接开始工作。
 要包含足够的上下文（项目路径、技术栈、当前分支等），
 不要假设新会话知道任何之前的内容。]
\`\`\`

⚠️ 只需要保存 ${PROMPT_FILE}，不要执行新任务。保存后停止回复即可。
SUMMARIZE_MSG
exit 2
