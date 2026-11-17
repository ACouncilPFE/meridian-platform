-- Local only. Mirrors the role layout used in Aurora (where these roles
-- authenticate with IAM tokens via GRANT rds_iam instead of passwords).
CREATE ROLE intake_api LOGIN PASSWORD 'local-only';
CREATE ROLE pipeline_reader LOGIN PASSWORD 'local-only';
CREATE ROLE dr_verifier LOGIN PASSWORD 'local-only';

-- In Aurora, pipeline_reader receives column-level grants on Safe Harbor
-- columns only (patients.id, zip3, birth_year; encounters.*  minus notes_enc),
-- so the export worker physically cannot SELECT ciphertext columns.
