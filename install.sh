#!/usr/bin/env bash
#
# install.sh — 安装 Context Guard
#
# 用法:
#   ./install.sh [阈值]         # 安装 (默认阈值 128000)
#   ./install.sh --uninstall    # 卸载
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
BIN_DIR="$HOME/.local/bin"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

# ── 卸载 ──
if [ "${1:-}" = "--uninstall" ]; then
    echo -e "${YELLOW}正在卸载 Context Guard...${NC}"

    rm -f "$BIN_DIR/cg"
    rm -rf "$HOME/.claude/context-guard"

    if [ -f "$SETTINGS_FILE" ]; then
        python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    s = json.load(f)
h = s.get('hooks', {})
for ev in ['PreToolUse', 'SessionStart', 'Stop']:
    if ev in h:
        h[ev] = [r for r in h[ev]
                 if not any('context_guard' in x.get('command','') or 'stop_hook' in x.get('command','')
                            for x in r.get('hooks', []))]
        if not h[ev]: del h[ev]
if not h and 'hooks' in s: del s['hooks']
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
"
    fi

    echo -e "${GREEN}✅ 已卸载${NC}"
    exit 0
fi

# ── 安装 ──
THRESHOLD="${1:-128000}"

echo -e "${BLUE}🛡️  Context Guard 安装${NC}"
echo ""

# 检查依赖
command -v python3 &>/dev/null || { echo "需要 python3"; exit 1; }
command -v claude &>/dev/null  || echo -e "${YELLOW}⚠️  未检测到 claude 命令${NC}"

# 设置权限
chmod +x "$SCRIPT_DIR/cg"
chmod +x "$SCRIPT_DIR"/*.sh
chmod +x "$SCRIPT_DIR"/*.py

# 创建目录
mkdir -p "$HOME/.claude/context-guard" "$BIN_DIR"

# 安装 cg 到 PATH
ln -sf "$SCRIPT_DIR/cg" "$BIN_DIR/cg"

# 检查 PATH
if ! echo "$PATH" | grep -q "$BIN_DIR"; then
    echo -e "${YELLOW}⚠️  $BIN_DIR 不在 PATH 中，请添加到 shell 配置:${NC}"
    echo -e "   ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    echo ""
fi

# ── 写入 hooks 配置 ──
python3 <<PYEOF
import json, os

sf = "$SETTINGS_FILE"
sd = "$SCRIPT_DIR"
th = "$THRESHOLD"

s = {}
if os.path.exists(sf):
    with open(sf) as f:
        try: s = json.load(f)
        except: s = {}

h = s.setdefault("hooks", {})

def upsert_hook(event, marker, command):
    """移除旧的同类 hook，添加新的"""
    rules = h.setdefault(event, [])
    rules[:] = [r for r in rules
                if not any(marker in x.get("command", "") for x in r.get("hooks", []))]
    rules.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": command}]
    })

upsert_hook("PreToolUse", "context_guard_hook",
            f"CONTEXT_GUARD_THRESHOLD={th} bash {sd}/context_guard_hook.sh")

upsert_hook("Stop", "stop_hook",
            f"CONTEXT_GUARD_THRESHOLD={th} bash {sd}/stop_hook.sh")

upsert_hook("SessionStart", "session_start_hook",
            f"bash {sd}/session_start_hook.sh")

os.makedirs(os.path.dirname(sf), exist_ok=True)
with open(sf, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
PYEOF

echo -e "${GREEN}✅ 安装完成${NC}"
echo ""
echo -e "  ${BLUE}使用方法:${NC}"
echo -e "  用 ${YELLOW}cg${NC} 替代 ${DIM}claude${NC} 启动会话 (所有 claude 参数都支持):"
echo ""
echo -e "    ${YELLOW}cg${NC}                                          # 交互式"
echo -e "    ${YELLOW}cg${NC} \"帮我重构 auth 模块\"                       # 带初始 prompt"
echo -e "    ${YELLOW}cg${NC} --dangerously-skip-permissions             # 跳过权限确认"
echo -e "    ${YELLOW}cg${NC} --model opus --effort high \"开始工作\"       # flag + prompt"
echo ""
echo -e "  ${BLUE}工作原理:${NC}"
echo -e "  • 上下文超过 ${YELLOW}${THRESHOLD}${NC} tokens 时自动触发"
echo -e "  • Claude 总结工作 → 保存 prompt → 自动重启新会话"
echo -e "  • 全程同一个终端窗口，无需手动操作"
echo -e "  • Prompt 文件带 session ID: ${DIM}~/.claude/context-guard/continuation_<id>.md${NC}"
echo -e "  • 归档目录: ${DIM}~/.claude/context-guard/archive/${NC}"
echo ""
echo -e "  ${BLUE}其他:${NC}"
echo -e "  • ${YELLOW}python3 $SCRIPT_DIR/check_context.py${NC} — 手动检查上下文"
echo -e "  • ${YELLOW}./install.sh --uninstall${NC} — 卸载"
echo ""
echo -e "  ${YELLOW}💡 重启 Claude Code 以加载新 hooks 配置${NC}"
