from dataclasses import fields
from datetime import UTC, date, datetime

import pytest

from pipeline_worker.deidentify import (
    DeidentifiedEncounter,
    SourceEncounter,
    SourcePatient,
    age_bucket,
    deidentify,
    generalize_zip3,
    pseudonym,
)

SECRET = b"s" * 32


def _enc(pid="p1", eid="e1", when=datetime(2026, 5, 17, 14, 30, tzinfo=UTC), typ="office_visit"):
    return SourceEncounter(id=eid, patient_id=pid, encounter_type=typ, occurred_at=when)


@pytest.mark.parametrize("zip3,expected", [("021", "021"), ("036", "000"), ("893", "000"), (None, "000"), ("2a1", "000")])
def test_zip3_generalization(zip3, expected):
    assert generalize_zip3(zip3) == expected


def test_age_over_89_aggregated_and_birth_year_suppressed():
    assert age_bucket(1930, date(2026, 1, 1)) == ("90+", None)
    assert age_bucket(1937, date(2026, 1, 1)) == ("89", 1937)


def test_unknown_or_impossible_ages():
    assert age_bucket(None, date(2026, 1, 1)) == ("unknown", None)
    assert age_bucket(2030, date(2026, 1, 1)) == ("unknown", None)


def test_only_year_survives_from_dates():
    row = deidentify(SourcePatient("p1", "021", 1984), _enc(), SECRET).as_row()
    assert row["ENCOUNTER_YEAR"] == 2026
    serialized = str(row)
    assert "05-17" not in serialized and "14:30" not in serialized


def test_pseudonyms_stable_unlinkable_and_not_raw_ids():
    a = deidentify(SourcePatient("p1", "021", 1984), _enc(), SECRET)
    b = deidentify(SourcePatient("p1", "021", 1984), _enc(eid="e2"), SECRET)
    assert a.patient_key == b.patient_key  # longitudinal linkage works
    assert a.encounter_key != b.encounter_key
    assert "p1" not in a.patient_key
    assert pseudonym(b"other" * 7, "patient", "p1") != a.patient_key  # key-dependent


def test_output_schema_is_an_allow_list():
    # Guardrail: adding a field to the output requires changing this test,
    # which puts a privacy review in front of every schema change.
    assert {f.name for f in fields(DeidentifiedEncounter)} == {
        "patient_key", "encounter_key", "encounter_type", "encounter_year", "zip3", "birth_year", "age_at_encounter",
    }


def test_unknown_encounter_types_collapsed():
    row = deidentify(SourcePatient("p1", "021", 1984), _enc(typ="Dr. Smith follow-up"), SECRET)
    assert row.encounter_type == "other"


def test_mismatched_patient_rejected():
    with pytest.raises(ValueError):
        deidentify(SourcePatient("p1", "021", 1984), _enc(pid="p2"), SECRET)
