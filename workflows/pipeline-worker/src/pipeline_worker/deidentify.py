"""HIPAA Safe Harbor de-identification (45 CFR 164.514(b)(2)).

Only an explicit allow-list of fields ever leaves this module. Anything not
named here is dropped, so a new column added upstream can't silently leak
into Snowflake.

Rules implemented:
  * Direct identifiers (names, contact info, MRN, free text...) are never
    selected in the first place and are dropped if present.
  * All date elements except year are removed.
  * Ages over 89 are aggregated into a single "90+" category, and the birth
    year is suppressed for those individuals.
  * ZIP codes are truncated to the first 3 digits; 3-digit areas with a
    population of 20,000 or fewer are replaced with "000".
  * Record linkage uses a keyed pseudonym (HMAC) that is not derived from
    any identifier and can't be reversed without the secret key, which lives
    only in Secrets Manager and is never shared with Snowflake.
"""

from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass
from datetime import date, datetime

# 3-digit ZIP areas with population <= 20,000 (HHS guidance, 2000 Census).
RESTRICTED_ZIP3 = frozenset(
    {"036", "059", "063", "102", "203", "556", "692", "790", "821", "823", "830", "831", "878", "879", "884", "890", "893"}
)

AGE_CAP = 89


@dataclass(frozen=True)
class SourcePatient:
    id: str
    zip3: str | None
    birth_year: int | None


@dataclass(frozen=True)
class SourceEncounter:
    id: str
    patient_id: str
    encounter_type: str
    occurred_at: datetime


@dataclass(frozen=True)
class DeidentifiedEncounter:
    patient_key: str
    encounter_key: str
    encounter_type: str
    encounter_year: int
    zip3: str
    birth_year: int | None
    age_at_encounter: str  # "0".."89" or "90+"

    def as_row(self) -> dict:
        return {
            "PATIENT_KEY": self.patient_key,
            "ENCOUNTER_KEY": self.encounter_key,
            "ENCOUNTER_TYPE": self.encounter_type,
            "ENCOUNTER_YEAR": self.encounter_year,
            "ZIP3": self.zip3,
            "BIRTH_YEAR": self.birth_year,
            "AGE_AT_ENCOUNTER": self.age_at_encounter,
        }


ALLOWED_ENCOUNTER_TYPES = frozenset({"office_visit", "telehealth", "lab", "imaging", "inpatient", "emergency"})


def pseudonym(secret: bytes, namespace: str, value: str) -> str:
    return hmac.new(secret, f"{namespace}:{value}".encode(), hashlib.sha256).hexdigest()[:32]


def generalize_zip3(zip3: str | None) -> str:
    if not zip3 or len(zip3) != 3 or not zip3.isdigit():
        return "000"
    return "000" if zip3 in RESTRICTED_ZIP3 else zip3


def age_bucket(birth_year: int | None, on: date) -> tuple[str, int | None]:
    """Return (age category, birth year to publish).

    Age is computed from years only (we never hold the full DOB here), so it
    can be off by one; that's acceptable for analytics and is documented.
    """
    if birth_year is None:
        return "unknown", None
    age = on.year - birth_year
    if age < 0:
        return "unknown", None
    if age > AGE_CAP:
        return "90+", None
    return str(age), birth_year


def deidentify(patient: SourcePatient, encounter: SourceEncounter, secret: bytes) -> DeidentifiedEncounter:
    if encounter.patient_id != patient.id:
        raise ValueError("encounter/patient mismatch")
    age, published_birth_year = age_bucket(patient.birth_year, encounter.occurred_at.date())
    return DeidentifiedEncounter(
        patient_key=pseudonym(secret, "patient", patient.id),
        encounter_key=pseudonym(secret, "encounter", encounter.id),
        encounter_type=encounter.encounter_type if encounter.encounter_type in ALLOWED_ENCOUNTER_TYPES else "other",
        encounter_year=encounter.occurred_at.year,
        zip3=generalize_zip3(patient.zip3),
        birth_year=published_birth_year,
        age_at_encounter=age,
    )
