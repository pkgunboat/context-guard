#!/usr/bin/env python3
"""
check_context.py — 计算 Claude Code 当前上下文 token 用量。

原理：读取 JSONL transcript 中最近一条主链 assistant 消息的 usage 字段，
上下文长度 = input_tokens + cache_read_input_tokens + cache_creation_input_tokens + output_tokens
（API 调用完成后，output 也成为下一轮对话上下文的一部分）

用法:
  python3 check_context.py [transcript_path] [--threshold N] [--json]
"""

import json, sys, os, glob, argparse
from datetime import datetime


def find_latest_transcript():
    claude_dir = os.path.expanduser("~/.claude/projects")
    if not os.path.exists(claude_dir):
        return None
    files = glob.glob(os.path.join(claude_dir, "**", "*.jsonl"), recursive=True)
    if not files:
        return None
    files.sort(key=os.path.getmtime, reverse=True)
    return files[0]


def get_context_length(transcript_path):
    if not os.path.exists(transcript_path):
        return 0, {}

    best_entry = None
    best_time = None

    with open(transcript_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue

            if data.get("isSidechain") or data.get("isApiErrorMessage"):
                continue

            msg = data.get("message") or {}
            # 跳过 streaming chunk（stop_reason=None 的条目 usage 全为 0）
            if msg.get("stop_reason") is None:
                continue

            usage = msg.get("usage")
            ts = data.get("timestamp")
            if not usage or not ts:
                continue

            inp = usage.get("input_tokens", 0) or 0
            out = usage.get("output_tokens", 0) or 0
            cr = usage.get("cache_read_input_tokens", 0) or 0
            cc = usage.get("cache_creation_input_tokens", 0) or 0
            if inp + out + cr + cc <= 0:
                continue

            try:
                t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            except (ValueError, TypeError):
                continue

            if best_time is None or t > best_time:
                best_time = t
                best_entry = data

    if not best_entry:
        return 0, {}

    u = best_entry["message"]["usage"]
    inp = u.get("input_tokens", 0)
    out = u.get("output_tokens", 0)
    cr = u.get("cache_read_input_tokens", 0)
    cc = u.get("cache_creation_input_tokens", 0)
    ctx = inp + cr + cc + out

    return ctx, {
        "input_tokens": inp,
        "output_tokens": out,
        "cache_read_input_tokens": cr,
        "cache_creation_input_tokens": cc,
        "context_length": ctx,
        "timestamp": best_entry.get("timestamp", ""),
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("transcript", nargs="?", default=None)
    p.add_argument("--threshold", type=int, default=200000)
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    path = args.transcript or os.environ.get("CLAUDE_TRANSCRIPT_PATH") or find_latest_transcript()
    if not path:
        print("找不到 transcript 文件", file=sys.stderr)
        sys.exit(1)

    ctx, details = get_context_length(path)
    exceeded = ctx > args.threshold
    pct = round((ctx / args.threshold) * 100, 1) if args.threshold > 0 else 0

    if args.json:
        print(json.dumps({
            "context_length": ctx, "threshold": args.threshold,
            "exceeded": exceeded, "percentage": pct,
            "transcript_path": path, **details,
        }, indent=2))
    else:
        tag = "🔴 超限" if exceeded else ("🟡 接近" if pct > 70 else "🟢 正常")
        print(f"{tag} 上下文: {ctx:,} / {args.threshold:,} tokens ({pct}%)")
        if details:
            print(f"  input={details.get('input_tokens',0):,}  "
                  f"cache_read={details.get('cache_read_input_tokens',0):,}  "
                  f"cache_create={details.get('cache_creation_input_tokens',0):,}")

    sys.exit(1 if exceeded else 0)


if __name__ == "__main__":
    main()
