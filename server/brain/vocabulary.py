"""Names the speech-to-text should know. Whisper mishears unfamiliar names
(clients, towns, products); a short hint of real names from the
pipeline and a static list makes them come out right. Kept short on
purpose: a long list makes Whisper hallucinate names into silence."""

from __future__ import annotations

import json
import os
import subprocess
import time

from . import config

STATIC: list[str] = []   # set VOCABULARY in server/settings.json
CACHE = os.path.expanduser("~/.cache/desk-robot/vocabulary.json")


def pipeline_names(limit: int = 20) -> list[str]:
    """Customer names from the Studio, newest activity first; cached a day."""
    try:
        c = json.load(open(CACHE))
        if time.time() - c.get("at", 0) < 86400:
            return c.get("names", [])
    except (OSError, ValueError):
        pass
    names: list[str] = []
    tool = os.path.expanduser(config.CLAUDE_WORKSPACE + "/tools/jk")
    try:
        out = subprocess.run([tool, "pipeline"], capture_output=True, text=True, timeout=15).stdout
        for line in out.splitlines():
            if line.startswith("- "):
                name = line[2:].split(" — ")[0].strip()
                if name and name not in names:
                    names.append(name)
    except Exception as e:
        print(f"(vocabulary: could not read the pipeline: {e})")
    names = names[:limit]
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        json.dump({"at": time.time(), "names": names}, open(CACHE, "w"))
    except OSError:
        pass
    return names


def stt_prompt() -> str:
    names = list(config.VOCABULARY) + (pipeline_names() if "jk" in config.EXTRA_TOOLS else [])
    # Last names carry the weight; keep the whole hint under ~150 tokens.
    return f"Hey {config.ROBOT_NAME}. {config.ROBOT_NAME} is a robot. Names: " + ", ".join(names)[:600] + "."
