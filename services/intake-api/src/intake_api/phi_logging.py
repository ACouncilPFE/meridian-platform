"""Structured JSON logging with PHI redaction.

Logs leave the HIPAA boundary more easily than any other data (they get
shipped, indexed, pasted into tickets). So redaction is enforced at the
handler level for every record, not left to developer discipline.
"""

from __future__ import annotations

import json
import logging
import re
import sys
from datetime import UTC, datetime

_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "[REDACTED-SSN]"),
    (re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "[REDACTED-EMAIL]"),
    (re.compile(r"\b(?:\+?1[-. ]?)?\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}\b"), "[REDACTED-PHONE]"),
    (re.compile(r"\b(19|20)\d{2}-\d{2}-\d{2}\b"), "[REDACTED-DATE]"),
    (re.compile(r"\bMRN[-:\s]?\d{6,}\b", re.IGNORECASE), "[REDACTED-MRN]"),
]

# Keys whose values are always dropped regardless of content.
_SENSITIVE_KEYS = {"name", "first_name", "last_name", "dob", "date_of_birth", "email", "phone", "ssn", "address", "mrn"}


def redact(text: str) -> str:
    for pattern, replacement in _PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def _scrub(value):
    if isinstance(value, dict):
        return {k: ("[REDACTED]" if k.lower() in _SENSITIVE_KEYS else _scrub(v)) for k, v in value.items()}
    if isinstance(value, list | tuple):
        return [_scrub(v) for v in value]
    if isinstance(value, str):
        return redact(value)
    return value


class JsonFormatter(logging.Formatter):
    RESERVED = set(vars(logging.makeLogRecord({}))) | {"message", "asctime"}

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": redact(record.getMessage()),
        }
        extras = {k: v for k, v in vars(record).items() if k not in self.RESERVED}
        payload.update(_scrub(extras))
        if record.exc_info:
            payload["exc"] = redact(self.formatException(record.exc_info))
        return json.dumps(payload, default=str)


def configure_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
