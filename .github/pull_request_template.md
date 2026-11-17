## What & why

<!-- One paragraph. Link the issue / ADR. -->

## How it was validated

- [ ] Tests added/updated and passing (`make test`)
- [ ] Preview environment exercised (add the `preview` label)
- [ ] Terraform plan reviewed (bot comment below), no unexpected replacements/destroys

## Risk checklist

- [ ] **PHI**: does this change what PHI is stored, logged, exported, or who can decrypt it? If yes, security review requested.
- [ ] **Migrations**: expand-only? Previous app version still works against the new schema? Downgrade tested?
- [ ] **Observability**: new endpoints/jobs have metrics + alerts (rules + promtool tests) and a runbook link
- [ ] **Rollback**: how do we undo this? (`make rollback`, feature flag, revert)

## AI assistance

<!-- If Claude Code (or similar) drafted part of this change, say which parts and how you verified them.
     See CLAUDE.md "Validation & oversight". -->
