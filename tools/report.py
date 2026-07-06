#!/usr/bin/env python3
"""Telemetry report tool.

Reads session JSONL files and prints a human-readable summary useful for
prompt tuning and tracking a child's language-learning progress.

Usage:
    python tools/report.py                      # all profiles, last 30 days
    python tools/report.py --profile lily       # one child only
    python tools/report.py --days 7             # last 7 days
    python tools/report.py --log-dir /custom/path
    python tools/report.py --raw                # dump raw session_end events
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def _load_sessions(log_dir: Path, profile: str | None, since: date) -> list[dict]:
    """Return session_end events from JSONL files matching the filters."""
    sessions = []
    if not log_dir.exists():
        return sessions

    for path in sorted(log_dir.glob("*.jsonl")):
        # filename: 2026-07-06_lily_143052.jsonl
        parts = path.stem.split("_")
        if len(parts) < 2:
            continue
        try:
            file_date = date.fromisoformat(parts[0])
        except ValueError:
            continue
        if file_date < since:
            continue
        file_slug = parts[1] if len(parts) >= 2 else ""
        if profile and file_slug != profile:
            continue

        end_event = None
        turns = []
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    ev = json.loads(line)
                    if ev.get("event") == "session_end":
                        end_event = ev
                    elif ev.get("event") == "turn":
                        turns.append(ev)
                except json.JSONDecodeError:
                    continue

        if end_event:
            end_event["_turns"] = turns
            end_event["_file"] = str(path)
            end_event["_date"] = file_date
            sessions.append(end_event)

    return sorted(sessions, key=lambda s: s.get("ts", ""))


def _load_all_turns(log_dir: Path, profile: str | None, since: date) -> list[dict]:
    turns = []
    for s in _load_sessions(log_dir, profile, since):
        turns.extend(s.get("_turns", []))
    return turns


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def _ms(val) -> str:
    if val is None:
        return "  —  "
    return f"{val/1000:.1f}s"


def _pct(ratio) -> str:
    if ratio is None:
        return "  —  "
    return f"{ratio*100:.0f}%"


def _bar(value: float, max_val: float, width: int = 20) -> str:
    filled = int(round(value / max_val * width)) if max_val else 0
    return "█" * filled + "░" * (width - filled)


def _col(text: str, width: int, align: str = "<") -> str:
    return format(str(text)[:width], f"{align}{width}")


# ---------------------------------------------------------------------------
# Report sections
# ---------------------------------------------------------------------------

def print_sessions_table(sessions: list[dict]) -> None:
    if not sessions:
        print("  (no sessions found)")
        return
    header = (
        f"  {'Date':<12} {'Profile':<10} {'Lvl':<5} {'Turns':>5} "
        f"{'Avg wds':>8} {'Engaged':>8} {'STT fail':>9} {'Avg lat':>8}  Topics"
    )
    print(header)
    print("  " + "─" * (len(header) - 2))
    for s in sessions:
        topics = ", ".join((s.get("topics") or [])[:3])
        if len(s.get("topics") or []) > 3:
            topics += "…"
        print(
            f"  {str(s.get('_date','')):<12} "
            f"{str(s.get('profile','')):<10} "
            f"{str(s.get('level','?')):<5} "
            f"{s.get('turns', 0):>5} "
            f"{str(s.get('avg_word_count') or '—'):>8} "
            f"{_pct(s.get('engaged_ratio')):>8} "
            f"{s.get('didnt_catch_count', 0):>9} "
            f"{_ms(s.get('avg_total_ms')):>8}  "
            f"{topics}"
        )


def print_grammar_patterns(sessions: list[dict]) -> None:
    counter: Counter = Counter()
    for s in sessions:
        for p in (s.get("problems") or []):
            counter[p] += 1
    if not counter:
        print("  (no grammar patterns recorded yet)")
        return
    total_sessions = len(sessions)
    print(f"  {'Pattern':<40} {'Sessions':>8}  {'Frequency':>12}")
    print("  " + "─" * 65)
    for problem, count in counter.most_common(15):
        bar = _bar(count, max(counter.values()), 12)
        print(f"  {problem:<40} {count:>8}  {bar}")


def print_engagement_trend(sessions: list[dict]) -> None:
    if len(sessions) < 2:
        print("  (need at least 2 sessions for a trend)")
        return
    print(f"  {'Date':<12} {'Avg words':>10}  {'Trend':<20}  {'Avg latency':>12}")
    print("  " + "─" * 60)
    word_counts = [s.get("avg_word_count") for s in sessions if s.get("avg_word_count")]
    max_wc = max(word_counts) if word_counts else 10
    for i, s in enumerate(sessions):
        wc = s.get("avg_word_count")
        lat = s.get("avg_total_ms")
        if wc is None:
            continue
        arrow = ""
        if i > 0:
            prev_wc = next(
                (sessions[j].get("avg_word_count") for j in range(i-1, -1, -1)
                 if sessions[j].get("avg_word_count")), None
            )
            if prev_wc:
                arrow = "▲" if wc > prev_wc else ("▼" if wc < prev_wc else "═")
        bar = _bar(wc, max_wc or 10)
        print(
            f"  {str(s.get('_date','')):<12} {wc:>10.1f}  "
            f"{bar} {arrow:<3} {_ms(lat):>12}"
        )


def print_latency_breakdown(sessions: list[dict]) -> None:
    rows = [(s.get("avg_stt_ms"), s.get("avg_llm_ttft_ms"), s.get("avg_total_ms"))
            for s in sessions
            if s.get("avg_stt_ms") is not None]
    if not rows:
        print("  (no latency data)")
        return
    avg_stt   = sum(r[0] for r in rows) / len(rows)
    avg_ttft  = sum(r[1] for r in rows if r[1]) / max(1, sum(1 for r in rows if r[1]))
    avg_total = sum(r[2] for r in rows if r[2]) / max(1, sum(1 for r in rows if r[2]))
    print(f"  STT transcription avg   : {avg_stt/1000:.2f}s")
    print(f"  LLM time-to-first-token : {avg_ttft/1000:.2f}s")
    print(f"  Total turn latency avg  : {avg_total/1000:.2f}s  (target ≤ 1.5 s)")
    target_ok = sum(1 for r in rows if r[2] and r[2] <= 1500)
    print(f"  Turns within 1.5 s      : {target_ok}/{len(rows)} "
          f"({100*target_ok//len(rows) if rows else 0}%)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Nova telemetry report",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.strip(),
    )
    parser.add_argument("--profile", help="Filter to one child profile slug")
    parser.add_argument("--days", type=int, default=30,
                        help="Look back this many days (default 30)")
    parser.add_argument("--log-dir", default="~/.ai-avatar/logs/",
                        help="Path to the telemetry log directory")
    parser.add_argument("--raw", action="store_true",
                        help="Dump raw session_end JSON events and exit")
    args = parser.parse_args()

    log_dir = Path(args.log_dir).expanduser()
    since = date.today() - timedelta(days=args.days)
    sessions = _load_sessions(log_dir, args.profile, since)

    if not sessions:
        target = f"profile={args.profile}" if args.profile else "all profiles"
        print(f"No telemetry found in {log_dir} for {target} (last {args.days} days).")
        print("Sessions are written automatically when running the app.")
        sys.exit(0)

    if args.raw:
        for s in sessions:
            s.pop("_turns", None)
            s.pop("_file", None)
            s.pop("_date", None)
            print(json.dumps(s))
        sys.exit(0)

    profile_label = args.profile or "all profiles"
    total_sessions = len(sessions)
    total_turns = sum(s.get("turns", 0) for s in sessions)

    print()
    print(f"  Nova Telemetry Report — {profile_label} — last {args.days} days")
    print(f"  {total_sessions} session(s), {total_turns} turn(s) total")
    print()

    print("─── Sessions ─────────────────────────────────────────────────────────")
    print_sessions_table(sessions)
    print()

    print("─── Grammar patterns (most frequent) ─────────────────────────────────")
    print_grammar_patterns(sessions)
    print()

    print("─── Engagement trend (avg words per turn) ─────────────────────────────")
    print_engagement_trend(sessions)
    print()

    print("─── Latency breakdown (across all sessions) ──────────────────────────")
    print_latency_breakdown(sessions)
    print()


if __name__ == "__main__":
    main()
