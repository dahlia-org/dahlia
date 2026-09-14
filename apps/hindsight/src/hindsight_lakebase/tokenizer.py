"""One tokenizer for indexed documents and queries; never modifies canonical text."""

import importlib
import os
from functools import lru_cache

ENV = "HINDSIGHT_API_LAKEBASE_TEXT_TOKENIZER"
DEFAULT = "hindsight_lakebase.tokenizer:sudachi"


@lru_cache(maxsize=1)
def _dictionary():
    from sudachipy import dictionary

    return dictionary.Dictionary(dict="core")


def sudachi(text: str) -> list[str]:
    from sudachipy import tokenizer

    # A tokenizer instance is not shared across worker threads.
    return [
        token.normalized_form()
        for token in _dictionary().create().tokenize(text, tokenizer.Tokenizer.SplitMode.B)
        if token.part_of_speech()[0] not in {"空白", "補助記号", "記号"}
    ]


def identity(text: str) -> list[str]:
    """Control for comparing Japanese retrieval with and without segmentation."""
    return [text] if text else []


@lru_cache(maxsize=8)
def _load(path: str):
    module, sep, name = path.partition(":")
    if not sep or not module or not name:
        raise ValueError(f"{ENV} must be module:function")
    function = getattr(importlib.import_module(module), name)
    if not callable(function):
        raise ValueError(f"{ENV} must name a callable")
    return function


def tokenize(text: str) -> list[str]:
    tokens = _load(os.environ.get(ENV, DEFAULT))(text)
    if not isinstance(tokens, list) or any(not isinstance(token, str) or "\x00" in token for token in tokens):
        raise ValueError("Lakebase tokenizer must return list[str] without NUL characters")
    return [token for token in tokens if token.strip()]


def search_text(text: str, max_terms: int | None = None) -> str:
    tokens = tokenize(text)
    if max_terms is not None and max_terms > 0:
        tokens = tokens[:max_terms]
    return " ".join(tokens)
