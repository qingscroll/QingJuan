"""Cooperative task control. Checks run only around durable work units."""

from collections.abc import Callable, Iterator
from contextlib import contextmanager
from contextvars import ContextVar

_stop: ContextVar[Callable[[], bool] | None] = ContextVar("task_stop", default=None)
_complete: ContextVar[Callable[[int], None] | None] = ContextVar("task_complete", default=None)


class TaskInterrupted(Exception):
    """The current work unit is durable and execution may leave the queue worker."""


def stop_requested() -> bool:
    callback = _stop.get()
    return callback is not None and callback()


def checkpoint() -> None:
    if stop_requested():
        raise TaskInterrupted()


def chapter_completed(chapter_index: int) -> None:
    callback = _complete.get()
    if callback is not None:
        callback(chapter_index)


@contextmanager
def task_boundaries(stop: Callable[[], bool], complete: Callable[[int], None]) -> Iterator[None]:
    stop_token = _stop.set(stop)
    complete_token = _complete.set(complete)
    try:
        yield
    finally:
        _stop.reset(stop_token)
        _complete.reset(complete_token)
