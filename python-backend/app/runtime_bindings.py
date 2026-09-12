"""Live bindings to the composing module while legacy use cases are extracted."""

from collections.abc import Mapping
from typing import Any


class RuntimeBindings:
    def __init__(self, namespace: Mapping[str, Any]) -> None:
        self._namespace = namespace

    def __getattr__(self, name: str) -> Any:
        try:
            return self._namespace[name]
        except KeyError as error:
            raise AttributeError(name) from error
