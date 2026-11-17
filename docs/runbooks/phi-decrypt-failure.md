# Runbook: PHI decrypt failures

**Alert:** `PhiDecryptFailures` (critical, pages **security** + platform). Any non-zero count is abnormal.

AES-GCM decryption fails only when the ciphertext, nonce, or associated data doesn't match, or when the data key can't be unwrapped. Treat this as a **potential integrity incident** until proven otherwise.

## Steps

1. **Scope:** which service and environment? How many records? Check log entries `"msg": "decrypt failure"` for `patient_id` values. Ids aren't PHI, but don't paste them into public channels.
2. **Key access:** CloudTrail → `kms:Decrypt` events for the PHI key, filtered by `errorCode`.
   - `AccessDeniedException` → a key policy or IAM change. Find the change (Terraform PR / CloudTrail `PutKeyPolicy`) and revert it.
   - No errors → the key unwrapped fine and the ciphertext itself failed authentication. Continue below.
3. **Data integrity:** for the affected ids, check `phi_access_log` and pgaudit `UPDATE` statements on `patients`. Were the `*_enc` columns modified outside the API? Was a row copied (AAD mismatch)?
4. **Recent code:** did a deploy change `aad_for()`, the token format, or column mapping? If so, roll back.
5. **Restore** affected records from PITR into a side cluster and compare (see disaster-recovery §A).
6. If modification outside the application is confirmed, follow the security incident and HIPAA breach-assessment process. Preserve evidence and don't "fix" rows in place.
