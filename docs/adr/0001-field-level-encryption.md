# ADR-0001: Field-level envelope encryption for direct identifiers

**Status:** Accepted

## Context
Aurora storage encryption protects disks, snapshots, and replicas from physical or out-of-band access. It doesn't protect against the more likely incidents: a leaked DB credential, an over-broad grant to an analytics role, a `pg_dump` left in a bucket, or a SQL injection.

## Decision
Encrypt direct identifiers (name, DOB, email, free-text notes) in the application with AES-256-GCM, using data keys from KMS (envelope encryption).
- Associated data = `table:column:row_id`, so ciphertext can't be moved between rows or columns.
- Data keys are cached and rotated every 1,000 encryptions, which bounds KMS latency and cost.
- Equality search uses a **blind index** (HMAC-SHA256 with a separate key) instead of deterministic encryption.
- Only the intake-api task role has `kms:Decrypt` on the PHI key. CloudTrail records every decrypt.

## Consequences
- A database dump alone doesn't reveal identifiers. An attacker also needs to compromise the API's IAM role.
- Encrypted columns can't be queried with SQL range or LIKE. Generalized forms (`zip3`, `birth_year`) are stored in clear for analytics because they fall within Safe Harbor.
- Backfills of derived columns must run under the API role (see migration 0002).
- Key loss means data loss: KMS keys have a 30-day deletion window, and the CI apply role's permission boundary denies `kms:ScheduleKeyDeletion`.
