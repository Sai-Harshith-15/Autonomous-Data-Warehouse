#!/usr/bin/env python3
"""
worker_omniroute.py — OmniRoute coding-agent worker for the AI Software
Factory scheduler.

Invokes the OmniRoute API (localhost:20128) with AntiGravity-backed models
to implement, code, or test features.  Returns a TaskResult with evidence
captured from the model response and git workspace.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from runtime.worker_base import BaseWorker, TaskResult
# ─── Constants ──────────────────────────────────────────────────────────────

OMNIROUTE_BASE = os.environ.get(
    "OMNIROUTE_BASE", "http://localhost:20128"
)
OMNIROUTE_CHAT_URL = f"{OMNIROUTE_BASE}/api/v1/chat/completions"
REQUEST_TIMEOUT = int(os.environ.get("OMNIROUTE_TIMEOUT", "300"))

# Model routing — primary models
MODEL_PLANNING = "opencode-go/glm-5.2"          # GLM 5.2: planning only
MODEL_CODING = "auto/coding:free"                # AntiGravity: implementation & coding
MODEL_TESTING = "auto/coding:free"               # AntiGravity: testing

# Fallback models (latest gen)
MODEL_GEMINI_FLASH = "opencode-go/gemini-3.6-flash"   # Gemini 3.6 Flash
MODEL_GEMINI_PRO = "opencode-go/gemini-3.1-pro"        # Gemini 3.1 Pro

# Worker-types this worker claims
HANDLED_TYPES = frozenset({"implementation", "coding", "testing"})


# ─── Worker ─────────────────────────────────────────────────────────────────


class OmniRouteCodingWorker(BaseWorker):
    """Invokes the OmniRoute API to complete implementation/coding/testing
    tasks using AntiGravity models."""

    worker_label: str = "omniroute"

    def can_handle(self, task: dict[str, Any]) -> bool:
        """Handle tasks whose ``worker_type`` is implementation, coding,
        or testing."""
        return task.get("worker_type", "") in HANDLED_TYPES

    def execute(
        self,
        task: dict[str, Any],
        run_id: str,  # noqa: ARG002
        task_dir: Path,
    ) -> TaskResult:
        worker_type = task.get("worker_type", "coding")
        goal = task.get("goal", "")
        inputs = task.get("inputs", {})
        if isinstance(inputs, str):
            try:
                inputs = json.loads(inputs)
            except (json.JSONDecodeError, TypeError):
                inputs = {"raw": inputs}
        owner_skill = task.get("owner_skill", "")

        # ── 1. Prepare workspace ───────────────────────────────────────
        work_dir = self._resolve_work_dir(task, task_dir)

        # ── 2. Build prompts ───────────────────────────────────────────
        system_prompt, user_prompt = self._build_prompts(
            goal, inputs, owner_skill, worker_type
        )

        # ── 3. Select model ────────────────────────────────────────────
        model_id = self._select_model(worker_type)

        # ── 4. Call OmniRoute ──────────────────────────────────────────
        start_ts = time.time()
        status_code = 0
        model_response = ""
        error_msg = ""

        try:
            status_code, model_response = self._call_omniroute(
                model_id, system_prompt, user_prompt
            )
        except Exception as exc:
            error_msg = str(exc)
            status_code = 1

        elapsed_ms = int((time.time() - start_ts) * 1000)

        # ── 5. Capture evidence ────────────────────────────────────────
        stdout_path = task_dir / "stdout.log"
        stderr_path = task_dir / "stderr.log"
        model_json_path = task_dir / "model.json"

        # Write stdout.log — model response
        stdout_path.write_text(model_response, encoding="utf-8")

        # Write model.json — full API metadata
        model_json_path.write_text(
            json.dumps(
                {
                    "model": model_id,
                    "worker_type": worker_type,
                    "goal": goal,
                    "response_preview": model_response[:2000],
                    "response_length": len(model_response),
                    "elapsed_ms": elapsed_ms,
                    "error": error_msg or None,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                },
                indent=2,
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )

        # Write stderr.log — errors only
        if error_msg:
            stderr_path.write_text(error_msg, encoding="utf-8")

        # ── 6. Git diff evidence ───────────────────────────────────────
        diff_evidence = self._capture_diff(work_dir)

        # ── 7. Build result ────────────────────────────────────────────
        success = status_code == 0 and bool(model_response)
        failure_class = None
        if not success:
            if error_msg:
                failure_class = "OMNIROUTE_ERROR"
            elif not model_response:
                failure_class = "EMPTY_RESPONSE"
            else:
                failure_class = "API_ERROR"

        return TaskResult(
            success=success,
            summary=self._build_summary(success, goal, worker_type, model_id, elapsed_ms),
            evidence={
                "stdout": model_response[:100_000],
                "stderr": error_msg,
                "exit_code": status_code,
                "diff": diff_evidence.get("diff", ""),
                "changed_files": diff_evidence.get("changed_files", []),
                "model": model_id,
                "elapsed_ms": elapsed_ms,
                "response_length": len(model_response),
            },
            failure_class=failure_class,
        )

    # ── Internal helpers ───────────────────────────────────────────────

    def _resolve_work_dir(self, task: dict[str, Any], task_dir: Path) -> Path:
        """Resolve the working directory for git operations.

        Uses a git worktree if a ``worktree`` is specified in the task's
        metadata; otherwise falls back to *task_dir*.
        """
        metadata = task.get("metadata", {})
        if isinstance(metadata, str):
            try:
                metadata = json.loads(metadata)
            except (json.JSONDecodeError, TypeError):
                metadata = {}

        worktree = metadata.get("worktree", "") or metadata.get("work_dir", "")
        if worktree:
            wd = Path(worktree)
            wd.mkdir(parents=True, exist_ok=True)
            return wd

        # Fall back to repo root (parent of scripts/)
        repo_root = Path(__file__).resolve().parent.parent
        return repo_root

    def _build_prompts(
        self,
        goal: str,
        inputs: dict[str, Any],
        owner_skill: str,
        worker_type: str,  # noqa: ARG002
    ) -> tuple[str, str]:
        """Build system and user prompts for the OmniRoute API."""
        # Serialise inputs for the prompt
        inputs_text = json.dumps(inputs, indent=2, ensure_ascii=False) if inputs else "(none)"

        system_prompt = (
            "You are an AI Software Factory coding agent. "
            "Your job is to implement, test, or modify code according to the task goal. "
            "Write clean, well-documented, production-quality code. "
            "Output ONLY the code and any brief explanations — no extra commentary.\n"
        )
        if owner_skill:
            system_prompt += (
                f"\nYou have access to the following skill/context:\n{owner_skill}\n"
            )

        user_prompt = (
            f"## Goal\n{goal}\n\n"
            f"## Inputs\n{inputs_text}\n\n"
            "Please implement the above. "
            "If applicable, run relevant tests and include test output in your response."
        )

        return system_prompt, user_prompt

    def _select_model(self, worker_type: str) -> str:
        """Route to the appropriate OmniRoute model based on worker type."""
        mapping = {
            # GLM 5.2 = planning ONLY
            "planning": MODEL_PLANNING,
            # AntiGravity = execution & testing
            "implementation": MODEL_CODING,
            "coding": MODEL_CODING,
            "testing": MODEL_TESTING,
        }
        return mapping.get(worker_type, MODEL_CODING)

    def _call_omniroute(
        self,
        model_id: str,
        system_prompt: str,
        user_prompt: str,
    ) -> tuple[int, str]:
        """POST to the OmniRoute chat completions endpoint.

        Returns (exit_code, response_text).
        """
        payload = json.dumps(
            {
                "model": model_id,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                "max_tokens": 4000,
                "temperature": 0,
            }
        ).encode("utf-8")

        req = urllib.request.Request(
            OMNIROUTE_CHAT_URL,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
                raw = resp.read().decode("utf-8")
                data = json.loads(raw)
                content = data["choices"][0]["message"]["content"]
                return 0, content
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            return exc.code, f"HTTP {exc.code}: {body[:2000]}"
        except urllib.error.URLError as exc:
            return 1, f"Connection failed: {exc.reason}"
        except (json.JSONDecodeError, KeyError, IndexError) as exc:
            return 1, f"Response parse error: {exc}"
        except subprocess.TimeoutExpired:
            return 1, "Request timed out"

    @staticmethod
    def _build_summary(
        success: bool,
        goal: str,
        worker_type: str,
        model_id: str,
        elapsed_ms: int,
    ) -> str:
        prefix = "✓" if success else "✗"
        goal_preview = (goal[:80] + "…") if len(goal) > 80 else goal
        return (
            f"{prefix} [{worker_type}] {goal_preview} "
            f"(model={model_id}, {elapsed_ms}ms)"
        )
