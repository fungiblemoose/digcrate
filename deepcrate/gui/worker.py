"""Background worker utilities for Qt."""

from __future__ import annotations

import traceback
from inspect import Parameter, Signature, signature
from typing import Any, Callable

from PySide6.QtCore import QObject, QRunnable, Signal


class WorkerSignals(QObject):
    """Signals for worker task lifecycle."""

    finished = Signal(object)
    error = Signal(str)
    progress = Signal(object)


class Worker(QRunnable):
    """Run a callable in Qt's global thread pool."""

    def __init__(self, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> None:
        super().__init__()
        self.fn = fn
        self.args = args
        self.kwargs = kwargs
        self.signals = WorkerSignals()
        self._accepts_progress = _accepts_progress_cb(fn)

    def run(self) -> None:
        try:
            call_kwargs = dict(self.kwargs)
            if self._accepts_progress:
                call_kwargs["progress_cb"] = self.signals.progress.emit
            result = self.fn(*self.args, **call_kwargs)
        except Exception:
            self.signals.error.emit(traceback.format_exc())
            return

        self.signals.finished.emit(result)


def _accepts_progress_cb(fn: Callable[..., Any]) -> bool:
    """Return True when callable accepts a `progress_cb` kwarg."""
    try:
        sig: Signature = signature(fn)
    except Exception:
        return True

    if "progress_cb" in sig.parameters:
        return True

    return any(param.kind == Parameter.VAR_KEYWORD for param in sig.parameters.values())
