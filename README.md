# 🛡️ Context Guard

Claude Code 上下文自动保护。超限时自动总结、保存、重启新会话，全程同一终端窗口，无需手动操作。

## 工作原理

```
┌──────────────────────────────────────────────────────────┐
│  cg (wrapper)  —  在循环中运行 claude                      │
│                                                          │
│   ┌─────────────────────────────────────────────┐        │
│   │  Claude Code 会话 #1                         │        │
│   │                                             │        │
│   │  正常工作...                                  │        │
│   │  ↓                                          │        │
│   │  PreToolUse hook 检测到上下文超限              │        │
│   │  ↓                                          │        │
│   │  Claude 总结工作 → 保存 continuation prompt   │        │
│   │  ↓                           (带 session ID) │        │
│   │  写入 next_prompt 标记                        │        │
│   │  ↓                                          │        │
│   │  wrapper 检测到标记 → 自动终止当前会话         │        │
│   └─────────────────────────────────────────────┘        │
│                         ↓ 自动重启                        │
│   ┌─────────────────────────────────────────────┐        │
│   │  Claude Code 会话 #2                         │        │
│   │  (以 continuation prompt 作为第一条消息)       │        │
│   │  无缝继续工作...                              │        │
│   └─────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────┘
```

## 快速开始

```bash
# 1. 克隆/下载
git clone <repo> ~/context-guard
cd ~/context-guard

# 2. 安装（默认阈值 128k tokens）
./install.sh
# 或自定义阈值
./install.sh 100000

# 3. 确保 ~/.local/bin 在 PATH 中
export PATH="$HOME/.local/bin:$PATH"

# 4. 用 cg 替代 claude（所有 claude 参数都支持）
cg                                            # 交互式
cg "帮我重构 auth 模块"                         # 带初始 prompt
cg --dangerously-skip-permissions              # 跳过权限确认
cg --model opus --effort high "开始工作"         # flag + prompt
cg --dangerously-skip-permissions --model opus  # 多个 flag
```

## 文件结构

```
context-guard/
├── cg                        # wrapper 脚本（替代 claude 命令）
├── context_guard_hook.sh     # PreToolUse hook（核心：检测超限 → 触发总结）
├── stop_hook.sh              # Stop hook（检查纯文本回复后超限 + 兜底写 next_prompt）
├── session_start_hook.sh     # SessionStart hook（清理旧状态）
├── check_context.py          # 上下文用量计算（可独立使用）
├── install.sh                # 安装/卸载
└── README.md
```

运行时生成的文件：

```
~/.claude/context-guard/
├── continuation_<session_id>.md   # 带 session ID 的 prompt 文件
├── next_prompt                    # 标记文件（wrapper 用来检测重启信号）
├── summarizing                    # 标志文件（表示正在总结模式）
└── archive/                       # 历史 prompt 归档
    ├── continuation_a1b2c3d4.md
    └── continuation_e5f6g7h8.md
```

## 自动化流程详解

### 为什么需要 `cg` wrapper？

Claude Code 的 hooks 无法直接：
- 关闭当前会话
- 启动新会话
- 执行 `/clear` 等斜杠命令

所以我们用一个 wrapper 脚本在外层运行 `claude`。当 guard 触发时：

1. **PreToolUse hook** → 阻止工具调用，指示 Claude 总结
2. **Claude 保存 prompt** → `~/.claude/context-guard/continuation_<session_id>.md`
3. **Claude 写标记** → `echo "路径" > ~/.claude/context-guard/next_prompt`
4. **Stop hook** → 纯文本回复后也检查超限；如果 Claude 忘记写标记，Stop hook 补上
5. **cg wrapper 后台监控** → 检测到标记文件出现 → 发送 SIGINT 终止 claude
6. **cg wrapper 循环** → 读取 prompt 文件 → 重新启动 `claude "prompt内容"`

整个过程在同一个终端窗口完成，用户看到的效果类似于"自动刷新"。

### Session ID 追溯

每个 prompt 文件以 session ID 前 8 位命名，例如 `continuation_a1b2c3d4.md`。
文件内部包含完整的 session ID，方便追溯到原始 transcript：

```
~/.claude/projects/<project>/<full_session_id>.jsonl
```

历史 prompt 自动归档到 `~/.claude/context-guard/archive/`。

## CLI 参数支持

`cg` 完全透传所有 claude CLI 参数，并在重启时**保留 flags**，只替换 prompt：

```bash
# 启动时
cg --dangerously-skip-permissions --model opus "实现用户登录功能"
#   ↑ flags (重启时保留)                        ↑ prompt (重启时替换)

# 重启后等同于
claude --dangerously-skip-permissions --model opus "continuation prompt 内容..."
```

支持的 flag 来自 [Claude Code 官方 CLI 文档](https://code.claude.com/docs/en/cli-reference)，包括：

| 常用 flag | 说明 |
|-----------|------|
| `--dangerously-skip-permissions` | 跳过所有权限提示 |
| `--model <name>` / `-m` | 指定模型 |
| `--effort <level>` | 设置 effort (low/medium/high/max) |
| `--allowedTools <tools>` | 预授权的工具列表 |
| `--max-turns <n>` | 限制 agentic 轮数 |
| `--add-dir <path>` | 添加额外工作目录 |
| `--continue` / `-c` | 继续上次对话 |
| `--verbose` | 详细输出 |
| `--plan` | 以 plan 模式启动 |

## 配置

### 调整阈值

```bash
# 方法一：重新安装
./install.sh 100000

# 方法二：直接改 settings.json 中的 CONTEXT_GUARD_THRESHOLD=xxx
```

### 阈值建议

| 场景 | 阈值 | 说明 |
|------|------|------|
| 保守 | 100,000 | 留足余量，适合长 CLAUDE.md |
| 推荐 | 128,000 | 平衡效率和安全 |
| 激进 | 160,000 | 最大化单次会话工作量 |

> Claude Code 默认上下文窗口 200k tokens，其中约 40-45k 被保留为 auto-compact buffer。

### 手动检查上下文

```bash
python3 check_context.py                    # 自动查找最新 session
python3 check_context.py --threshold 100000 # 自定义阈值
python3 check_context.py --json             # JSON 输出
```

## 技术细节

### 上下文计算

Claude Code 将消息记录到 `~/.claude/projects/<project>/<session>.jsonl`。
取最近一条主链（非 sidechain）消息的 `usage` 字段：

```
上下文长度 = input_tokens + cache_read_input_tokens + cache_creation_input_tokens + output_tokens
```

其中 `output_tokens` 会成为下一轮请求的上下文，所以也需要计入。脚本会跳过
`stop_reason = null` 的 streaming chunk，以及 usage 全为 0 的 synthetic 消息。
Hook 运行时优先使用 Claude 传入的当前 `transcript_path`，只有缺失时才回退到
`~/.claude/projects` 下最新的 jsonl 文件。

### 局限性

- **计算是近似值**：基于 transcript 中最近的 usage 数据，可能有几千 tokens 的误差
- **检查有延迟**：基于最近一次写入 transcript 的 usage；Stop hook 会覆盖纯文本回复后的检查，PreToolUse 会覆盖工具调用前的检查
- **exit 2 行为**：某些版本中 Claude 收到 exit 2 后可能等待用户输入。如果发生，手动输入"请继续总结"即可
- **SIGINT 退出**：wrapper 通过 SIGINT 终止 claude，等同于 Ctrl+C，是安全的优雅退出

## 卸载

```bash
./install.sh --uninstall
```

## License

MIT
