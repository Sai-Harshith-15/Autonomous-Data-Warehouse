#!/usr/bin/env python3
"""
worker_verification.py — Verification worker for the AI Software Factory
scheduler.

Extracts the verification-command execution logic from the legacy
``dispatch_task()`` into a proper worker.  Runs each verification command
via subprocess, captures stdout/stderr, and returns a TaskResult.

Unlike the original ``dispatch_task``, this worker **does not** auto-succeed
when the verification command list is empty — it returns a structured failure
so the scheduler can make an explicit decision.
"""

from __future__ import annotations

import json
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any

from runtime.worker_base import BaseWorker, TaskResult


# ─── Worker ─────────────────────────────────────────────────────────────────


class VerificationWorker(BaseWorker):
    """Runs verification / gate commands via subprocess.

    This is the default worker: it handles any task whose ``worker_type``
    is not explicitly claimed by a more specific worker (implementation,
    coding, testing, etc.).
    """

    worker_label: str = "verification"

    def can_handle(self, task: dict[str, Any]) -> bool:
        """Default handler — accepts any task that isn't explicitly
        routed to a specialist worker."""
        wtype = task.get("worker_type", "")
        # If worker_type is unset, empty, or "verification" we handle it.
        # Specialist types (implementation, coding, testing) are claimed
        # by OmniRouteCodingWorker.
        specialist_types = frozenset({"implementation", "coding", "testing"})
        return wtype not in specialist_types

    def execute(
        self,
        task: dict[str, Any],
        run_id: str,  # noqa: ARG002
        task_dir: Path,
    ) -> TaskResult:
        """Run each verification command, capture evidence, return result."""
        goal = task.get("goal", "")
        verification_cmds: list[str] = []
        raw_v = task.get("verification", "[]")
        if isinstance(raw_v, str):
            try:
                verification_cmds = json.loads(raw_v) if raw_v else []
            except (json.JSONDecodeError, TypeError):
                verification_cmds = []
        elif isinstance(raw_v, list):
            verification_cmds = raw_v

        # ── Guard: empty verification list → failure ──────────────────
        if not verification_cmds:
            return TaskResult(
                success=False,
                summary=f"No verification commands specified for task: {goal[:80]}",
                evidence={
                    "stdout": "",
                    "stderr": "No verification commands in task definition.",
                    "exit_code": -1,
                    "diff": "",
                    "changed_files": [],
                },
                failure_class="NO_VERIFICATION",
            )

        # ── Resolve working directory for git diff ─────────────────────
        repo_root = Path(__file__).resolve().parent.parent
        work_dir = self._resolve_work_dir(task, repo_root)

        # ── Run commands ──────────────────────────────────────────────
        start_ts = time.time()
        all_passed = True
        failure_class: str | None = None
        cmd_output = ""
        cmd_errors = ""
        exit_code = 0

        for idx, cmd in enumerate(verification_cmds):
            cmd_tag = cmd[:80]

            # Log to stdout accumulator
            header = f"\n{'='*60}\n[CMD {idx+1}/{len(verification_cmds)}] {cmd_tag}\n{'='*60}\n"
            cmd_output += header

            try:
                # Safe execution — no shell=True
                cmd_parts = shlex.split(cmd) if isinstance(cmd, str) else list(cmd)
                result = subprocess.run(
                    cmd_parts,
                    shell=False,
                    capture_output=True,
                    text=True,
                    timeout=task.get("timeout_seconds", 900),
                )
                cmd_output += result.stdout
                if result.stderr:
                    cmd_errors += result.stderr

                if result.returncode == 0:
                    cmd_output += "\n→ exit 0 (PASS)\n"
                else:
                    all_passed = False
                    failure_class = "TEST_FAILURE"
                    exit_code = result.returncode
                    cmd_output += f"\n→ exit {result.returncode} (FAIL)\n"

            except subprocess.TimeoutExpired:
                all_passed = False
                failure_class = "TRANSIENT"
                exit_code = -1
                msg = f"\n[TIMEOUT] exceeded {task.get('timeout_seconds', 900)}s\n"
                cmd_output += msg
                cmd_errors += msg

            except Exception as exc:  # noqa: BLE001
                all_passed = False
                failure_class = "ENVIRONMENT"
                exit_code = -2
                msg = f"\n[ERROR] {exc}\n"
                cmd_output += msg
                cmd_errors += msg

        elapsed_ms = int((time.time() - start_ts) * 1000)

        # ── Write stdout / stderr logs ────────────────────────────────
        stdout_path = task_dir / "stdout.log"
        stderr_path = task_dir / "stderr.log"
        stdout_path.write_text(cmd_output, encoding="utf-8")
        if cmd_errors:
            stderr_path.write_text(cmd_errors, encoding="utf-8")
        else:
            stderr_path.write_text("", encoding="utf-8")

        # ── Git diff evidence ─────────────────────────────────────────
        diff_evidence = self._capture_diff(work_dir)

        # ── Result ────────────────────────────────────────────────────
        summary = (
            f"{'✓' if all_passed else '✗'} {goal[:80]} "
            f"({len(verification_cmds)} cmd(s), {elapsed_ms}ms)"
        )

        return TaskResult(
            success=all_passed,
            summary=summary,
            evidence={
                "stdout": cmd_output,
                "stderr": cmd_errors,
                "exit_code": exit_code,
                "diff": diff_evidence.get("diff", ""),
                "changed_files": diff_evidence.get("changed_files", []),
                "elapsed_ms": elapsed_ms,
                "command_count": len(verification_cmds),
            },
            failure_class=failure_class,
        )

    # ── Internal helpers ───────────────────────────────────────────────

    @staticmethod
    def _resolve_work_dir(task: dict[str, Any], repo_root: Path) -> Path:
        """Resolve working directory for git-diff operations.

        Checks task metadata for a ``worktree`` or ``work_dir`` override;
        falls back to the repo root (``Agent-os/``).
        """
        metadata = task.get("metadata", {})
        if isinstance(metadata, str):
            try:
                metadata = json.loads(metadata)
            except (json.JSONDecodeError, TypeError):
                metadata = {}

        worktree = metadata.get("worktree", "") or metadata.get("work_dir", "")
        if worktree:
            return Path(worktree)
        return repo_root
