"""A brain made of Claude Code.

Instead of calling a chat API with a key, this keeps one long-lived
`claude -p --input-format stream-json` process alive and feeds it each
question. Claude Code brings its own login, its own memory of the
conversation, and its tools (reading notes, searching the web, running
commands you allow), so the desk robot can be a real helper rather than a
character that only chats.

Same interface as thinking.RobotBrain: reply() yields sentences as they
are written, on_emotion() fires as soon as the "[happy] " tag is known,
abandon() drops a reply the human talked over. The streaming event shapes
follow Claude Code's stream-json protocol.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import threading
import time
from collections.abc import Callable, Iterator

from . import config, personality
from .thinking import Interrupted, RobotBrain, _SENTENCE_END


def _find_claude() -> str:
    for cand in (config.CLAUDE_BIN, shutil.which("claude"),
                 os.path.expanduser("~/.local/bin/claude"),
                 os.path.expanduser("~/.claude/local/claude")):
        if cand and os.path.exists(cand):
            return cand
    import glob
    hits = sorted(glob.glob(os.path.expanduser("~/.nvm/versions/node/*/bin/claude")))
    if hits:
        return hits[-1]
    raise FileNotFoundError("claude (Claude Code CLI) not found; set CLAUDE_BIN in config.py")


class _Proc:
    """One `claude -p` process with a reader thread feeding a queue of events."""

    def __init__(self) -> None:
        self.proc: subprocess.Popen | None = None
        self.events: queue.Queue[dict | None] = queue.Queue()
        self.turns = 0
        self.started = 0.0
        self.session_id: str | None = None
        self.in_flight = False
        self.model = config.CLAUDE_MODEL

    def set_model(self, model: str) -> None:
        """Switch the live process to another model for the next turn."""
        if model == self.model or not self.alive():
            return
        self.send({"type": "control_request", "request_id": f"model-{int(time.time() * 1000)}",
                   "request": {"subtype": "set_model", "model": model}})
        self.model = model
        print(f"  (answering with {model})")

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self) -> None:
        self.stop()
        args = [
            _find_claude(), "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", config.CLAUDE_MODEL,
            "--append-system-prompt", personality.SYSTEM_PROMPT,
            *config.CLAUDE_ARGS,
        ]
        env = dict(os.environ)
        env.pop("CLAUDECODE", None)  # allow starting from inside another Claude Code session
        # `claude` from nvm is a node script: when the Mac app launches this
        # server, PATH is bare, so make sure node (next to claude) is findable.
        env["PATH"] = os.path.dirname(args[0]) + ":" + env.get("PATH", "/usr/bin:/bin")
        cwd = os.path.expanduser(config.CLAUDE_WORKSPACE)
        os.makedirs(cwd, exist_ok=True)
        self.proc = subprocess.Popen(
            args, cwd=cwd, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        self.started = time.time()
        self.turns = 0
        self.session_id = None
        self.in_flight = False
        self.model = config.CLAUDE_MODEL
        self.events = queue.Queue()
        threading.Thread(target=self._read_stdout, args=(self.proc,), daemon=True).start()
        threading.Thread(target=self._read_stderr, args=(self.proc,), daemon=True).start()
        print(f"(claude code brain started: model {config.CLAUDE_MODEL}, workspace {cwd})")

    def stop(self) -> None:
        p, self.proc = self.proc, None
        if p is not None and p.poll() is None:
            try:
                p.stdin.close()
            except Exception:
                pass
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()

    def _read_stdout(self, proc: subprocess.Popen) -> None:
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.events.put(json.loads(line))
            except json.JSONDecodeError:
                continue
        self.events.put(None)  # EOF

    def _read_stderr(self, proc: subprocess.Popen) -> None:
        for line in proc.stderr:
            s = line.rstrip()
            if s and "[debug]" not in s.lower():
                print(f"(claude: {s[:300]})")

    def send(self, obj: dict) -> None:
        assert self.proc is not None and self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def interrupt(self) -> None:
        try:
            self.send({"type": "control_request", "request_id": f"int-{int(time.time() * 1000)}",
                       "request": {"subtype": "interrupt"}})
        except Exception as e:
            print(f"(interrupt not sent: {e})")

    def drain(self, timeout: float = 30.0) -> None:
        """Swallow the rest of an abandoned turn so the next one starts clean."""
        deadline = time.time() + timeout
        while self.in_flight and time.time() < deadline:
            try:
                ev = self.events.get(timeout=0.5)
            except queue.Empty:
                continue
            if ev is None or ev.get("type") == "result":
                self.in_flight = False
                return
        if self.in_flight:
            print("(abandoned turn never finished; restarting claude)")
            self.stop()
            self.in_flight = False


class ClaudeCodeBrain(RobotBrain):
    def __init__(self) -> None:
        # Not calling RobotBrain.__init__: no API client needed.
        self.history: list[dict] = []
        self.actions = {}
        self.emotion = "neutral"
        self._inflight = None
        self._proc = _Proc()
        self._lock = threading.Lock()  # one turn at a time
        self._smart_until = 0.0
        self._smart_turns = 0
        self._warm = threading.Thread(target=self._warm_up, daemon=True)
        self._warm.start()

    # ── lifecycle ────────────────────────────────────────────────────────────

    def _warm_up(self) -> None:
        """Start the process and absorb the session-start cost before the
        first real question, so the first spoken reply isn't slow."""
        with self._lock:
            try:
                self._ensure()
                self._proc.send(_user_msg("(warm-up: reply with the single word ready)"))
                self._proc.in_flight = True
                t0 = time.time()
                self._proc.drain(timeout=120)
                print(f"(claude code brain ready in {time.time() - t0:.1f}s)")
            except Exception as e:
                print(f"(claude code brain warm-up failed: {e})")

    def _ensure(self) -> None:
        p = self._proc
        stale = p.alive() and (p.turns >= config.CLAUDE_RECYCLE_TURNS
                               or time.time() - p.started > config.CLAUDE_RECYCLE_SECONDS)
        if stale:
            print("(recycling the claude code brain: fresh conversation)")
        if not p.alive() or stale:
            p.start()

    def abandon(self) -> None:
        """The human kept talking: interrupt and forget this reply."""
        super().abandon()
        if self._proc.in_flight and self._proc.alive():
            self._proc.interrupt()
            threading.Thread(target=self._drain_locked, daemon=True).start()

    def _drain_locked(self) -> None:
        with self._lock:
            self._proc.drain()

    # ── one turn ─────────────────────────────────────────────────────────────

    def _converse(self, on_emotion: Callable[[str], None] | None, cancelled: threading.Event) -> Iterator[str]:
        question = _last_user_text(self.history)
        with self._lock:
            try:
                self._ensure()
            except Exception as e:
                self.emotion = "sad"
                if on_emotion:
                    on_emotion(self.emotion)
                yield f"Brain cannot start. {e}"
                return
            p = self._proc
            p.drain(timeout=5)  # just in case a previous turn is still winding down
            smart_active = time.time() < self._smart_until and self._smart_turns > 0
            model = route_model(question, smart_active)
            if model != config.CLAUDE_MODEL:
                self._smart_until = time.time() + config.CLAUDE_SMART_STICKY_SECONDS
                self._smart_turns = config.CLAUDE_SMART_STICKY_TURNS
            elif smart_active:
                self._smart_turns -= 1
            p.set_model(model)
            self._question = question
            p.send(_user_msg(question))
            p.in_flight = True
            p.turns += 1
            yield from self._read_turn(p, on_emotion, cancelled)

    def _read_turn(self, p: _Proc, on_emotion, cancelled: threading.Event) -> Iterator[str]:
        limit = config.REPLY_MAX_SENTENCES
        buf = ""
        tag_decided = False
        spoken = 0
        streamed = ""      # text seen as deltas for the current assistant message
        full = ""          # everything spoken-worthy this turn
        thinking_shown = False
        deadline = time.time() + config.CLAUDE_TURN_TIMEOUT
        while True:
            if cancelled.is_set():
                raise Interrupted()
            if time.time() > deadline:
                print("(claude turn timed out; restarting the brain)")
                p.stop()
                p.in_flight = False
                self.emotion = "sad"
                if on_emotion:
                    on_emotion(self.emotion)
                yield "That took too long. Ask me again."
                return
            try:
                ev = p.events.get(timeout=0.05)
            except queue.Empty:
                continue
            if ev is None:
                p.in_flight = False
                p.proc = None
                self.emotion = "sad"
                if on_emotion:
                    on_emotion(self.emotion)
                yield "My brain process quit. Ask again and I will restart it."
                return
            t = ev.get("type")
            if t == "system" and ev.get("subtype") == "init":
                p.session_id = ev.get("session_id")
                continue
            text = ""
            if t == "stream_event":
                e = ev.get("event") or {}
                et = e.get("type")
                if et == "message_start":
                    streamed = ""
                elif et == "content_block_delta":
                    d = e.get("delta") or {}
                    if d.get("type") == "text_delta" and d.get("text"):
                        text = d["text"]
                        streamed += text
                elif et == "content_block_start":
                    cb = e.get("content_block") or {}
                    if cb.get("type") == "tool_use":
                        print(f"  [{cb.get('name')}]")
                        if not thinking_shown and on_emotion and not spoken:
                            thinking_shown = True
                            self.emotion = "thinking"
                            on_emotion("thinking")
            elif t == "assistant":
                for block in (ev.get("message") or {}).get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        inp = block.get("input") or {}
                        brief = inp.get("command") or inp.get("query") or inp.get("file_path") or inp.get("pattern") or ""
                        print(f"  [{block.get('name')} {str(brief)[:80]}]")
                if not streamed:
                    for block in (ev.get("message") or {}).get("content") or []:
                        if isinstance(block, dict) and block.get("type") == "text" and block.get("text"):
                            text += block["text"]
                streamed = ""
            elif t == "result":
                p.in_flight = False
                final = str(ev.get("result") or "")
                if ev.get("is_error") and not full:
                    print(f"(claude result error: {final[:300]})")
                    self.emotion = "sad"
                    if on_emotion:
                        on_emotion(self.emotion)
                    yield "Something went wrong in my brain. Ask again."
                    return
                if final and not full.strip():
                    text = final  # nothing streamed (rare): speak the final result
                elif final.strip().startswith(full.strip()) and len(final.strip()) > len(full.strip()):
                    text = final.strip()[len(full.strip()):]
                buf += text
                full += text
                if not tag_decided:
                    buf, _ = self._take_emotion_tag(buf, final=True)
                    if on_emotion:
                        on_emotion(self.emotion)
                tail = buf.strip()
                if tail and spoken < limit:
                    yield tail
                elif spoken >= limit and config.NOTE_LONG_REPLIES:
                    # He had more to say than the cap allows: keep the whole
                    # answer in a note instead of losing it.
                    unspoken = full.strip()
                    if len(unspoken) > 400:
                        title = write_fleeting_note(getattr(self, "_question", ""), unspoken)
                        if title:
                            print(f"  (full answer written to fleeting note: {title})")
                            yield "The full answer is in a fleeting note."
                elif not spoken and not tail:
                    self.emotion = "thinking"
                    if on_emotion:
                        on_emotion(self.emotion)
                    yield "Hmm. Words did not come. Ask again."
                return
            if not text:
                continue
            if spoken >= limit:
                full += text
                continue  # keep reading to the result, but say no more
            buf += text
            full += text
            if not tag_decided:
                buf, tag_decided = self._take_emotion_tag(buf, final=False)
                if not tag_decided:
                    continue
                if on_emotion:
                    on_emotion(self.emotion)
            parts = _SENTENCE_END.split(buf)
            while len(parts) > 1:
                s = parts.pop(0).strip()
                if s:
                    spoken += 1
                    yield s
                if spoken >= limit:
                    print(f"  (trimmed reply to {limit} sentences)")
                    parts = [""]
                    break
            buf = parts[-1] if parts else ""


# ── Model routing ────────────────────────
_WORK_WORDS = ("research", "write", "draft", "plan", "summar", "analy", "compare", "outline",
               "explain", "review", "code", "script", "proposal", "email", "letter", "my notes",
               "strategy", "budget", "think through", "pros and cons", "look into", "dig into")
_QUICK_WORDS = ("quick", "quickly", "just tell me", "short answer", "one word", "yes or no")
_HARD_WORDS = ("think hard", "use opus", "big model", "deep dive")
_SMART_WORDS = ("be thorough", "use sonnet", "think about this")


def route_model(text: str, smart_active: bool) -> str:
    """Which model should answer this turn. Haiku for chat; the smart model for
    work that benefits from it; opus only on request."""
    t = text.lower()
    words = len(t.split())
    if any(w in t for w in _QUICK_WORDS):
        return config.CLAUDE_MODEL
    if any(w in t for w in _HARD_WORDS):
        return "opus"
    hits = sum(1 for w in _WORK_WORDS if w in t)
    if any(w in t for w in _SMART_WORDS) or (hits and words >= 8) or hits >= 2 or words >= 45:
        return config.CLAUDE_SMART_MODEL
    return config.CLAUDE_SMART_MODEL if smart_active else config.CLAUDE_MODEL


def write_fleeting_note(question: str, text: str) -> str | None:
    """Put a long answer in the vault as a fleeting note. Returns the title."""
    import re
    vault = os.path.expanduser(config.NOTES_INBOX)
    os.makedirs(vault, exist_ok=True)
    stem = re.sub(r"[^A-Za-z0-9 ]+", "", question).strip()
    stem = " ".join(stem.split()[:7]) or "Rocky answer"
    stamp = time.strftime("%y%m%d")
    title = f"{stamp} - {stem}"
    path = os.path.join(vault, title + ".md")
    n = 2
    while os.path.exists(path):
        path = os.path.join(vault, f"{title} ({n}).md"); n += 1
    body = f"# {stem}\n\n*Rocky, {time.strftime('%Y-%m-%d %H:%M')}. Asked: {question.strip()}*\n\n{text.strip()}\n"
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
    except OSError as e:
        print(f"(could not write note: {e})")
        return None
    return os.path.basename(path)[:-3]


def _user_msg(text: str) -> dict:
    return {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}


def _last_user_text(history: list[dict]) -> str:
    for m in reversed(history):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                return c
            return " ".join(p.get("text", "") for p in c if p.get("type") == "text").strip()
    return ""
