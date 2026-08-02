#!/usr/bin/env python3
"""
worker_base.py — TaskResult dataclass and BaseWorker abstract class for the
AI Software Factory scheduler.

All worker implementations inherit from BaseWorker and return TaskResult.
"""

from __future__ import annotations

import subprocess
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ─── TaskResult ─────────────────────────────────────────────────────────────


@dataclass
class TaskResult:
    """Standard result returned by every worker execute() call.

    Attributes:
        success:       Whether the task completed successfully.
        summary:       Human-readable one-liner describing the outcome.
        evidence:      Structured evidence dict with stdout, stderr,
                       exit_code, diff, and changed_files.
        failure_class: Optional classification for failures (e.g.
                       "TEST_FAILURE", "TRANSIENT", "ENVIRONMENT").
    """

    success: bool
    summary: str
    evidence: dict[str, Any] = field(default_factory=dict)
    failure_class: str | None = None

    @classmethod
    def from_exit_code(
        cls,
        exit_code: int,
        summary: str = "",
        stdout: str = "",
        stderr: str = "",
        failure_class: str | None = None,
    ) -> "TaskResult":
        """Build a TaskResult from a subprocess exit code."""
        return cls(
            success=exit_code == 0,
            summary=summary or ("ok" if exit_code == 0 else f"exit {exit_code}"),
            evidence={
                "stdout": stdout,
                "stderr": stderr,
                "exit_code": exit_code,
                "diff": "",
                "changed_files": [],
            },
            failure_class=None if exit_code == 0 else (failure_class or "UNKNOWN"),
        )


# ─── BaseWorker ─────────────────────────────────────────────────────────────


class BaseWorker(ABC):
    """Abstract worker that executes a single task and returns a TaskResult.

    Subclasses must implement ``can_handle`` and ``execute``.
    """

    # Human-friendly label used in logs / events.
    worker_label: str = "base"

    @abstractmethod
    def can_handle(self, task: dict[str, Any]) -> bool:
        """Return True if this worker is capable of executing *task*.

        The decision is typically based on ``task.get("worker_type")`` or
        other metadata (skill, agent, etc.).
        """
        ...

    @abstractmethod
    def execute(
        self,
        task: dict[str, Any],
        run_id: str,
        task_dir: Path,
    ) -> TaskResult:
        """Execute *task* inside *task_dir* and return a TaskResult.

        Args:
            task:    The full task row dict from the database.
            run_id:  The owning run ID (e.g. ``R-2026-...``).
            task_dir: Scratch directory for logs, artifacts, and evidence.
        """
        ...

    # ── helpers ──────────────────────────────────────────────────────────

    def _capture_diff(self, work_dir: Path) -> dict[str, Any]:
        """Run *git diff* in *work_dir* and return structured evidence.

        Returns a dict with keys:
            diff:           Unified diff string (empty string if not a git repo
                            or nothing changed).
            changed_files:  List of file paths that were modified.
        """
        evidence: dict[str, Any] = {
            "diff": "",
            "changed_files": [],
        }

        git_dir = work_dir / ".git"
        if not git_dir.is_dir():
            return evidence

        try:
            result = subprocess.run(
                ["git", "diff", "--no-color"],
                capture_output=True,
                text=True,
                cwd=work_dir,
                timeout=30,
            )
            evidence["diff"] = result.stdout
        except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
            evidence["diff"] = f"# git-diff error: {exc}"

        try:
            result = subprocess.run(
                ["git", "diff", "--name-only", "--no-color"],
                capture_output=True,
                text=True,
                cwd=work_dir,
                timeout=30,
            )
            if result.stdout.strip():
                evidence["changed_files"] = [
                    f.strip() for f in result.stdout.splitlines() if f.strip()
                ]
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        return evidence
