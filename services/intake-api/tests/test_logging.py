import json
import logging

from intake_api.phi_logging import JsonFormatter, redact


def test_redacts_common_identifiers():
    s = redact("ssn 123-45-6789 email a.b@example.org phone (617) 555-1234 dob 1984-03-09 MRN:00123456")
    for leaked in ("123-45-6789", "a.b@example.org", "555-1234", "1984-03-09", "00123456"):
        assert leaked not in s


def test_formatter_scrubs_sensitive_extra_keys():
    record = logging.makeLogRecord(
        {
            "msg": "created for jane@example.com",
            "levelname": "INFO",
            "name": "t",
            "email": "jane@example.com",
            "patient_id": "abc",
            "nested": {"dob": "1990-01-01"},
        }
    )
    out = json.loads(JsonFormatter().format(record))
    assert out["email"] == "[REDACTED]"
    assert out["nested"]["dob"] == "[REDACTED]"
    assert out["patient_id"] == "abc"
    assert "jane@example.com" not in out["msg"]
