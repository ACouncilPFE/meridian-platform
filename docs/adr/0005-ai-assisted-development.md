# ADR-0005: AI-assisted development with explicit oversight boundaries

**Status:** Accepted

## Context
Coding agents like Claude Code materially speed up infrastructure and service work: scaffolding modules, writing tests, reviewing diffs, triaging alerts. In a regulated environment, the risks are specific. An agent might weaken a security control while "fixing" a failing check, put realistic-looking PHI in fixtures, or run a destructive command.

## Decision
1. **Codify the working agreement** in [`CLAUDE.md`](../../CLAUDE.md): commands, definition of done, hard rules, and changes that always need a human.
2. **Make verification mechanical, not trust-based.** The guardrails that matter are tests that fail loudly:
   - the de-identification output allow-list test
   - crypto tamper and AAD-binding tests
   - migration round-trip and ORM-drift tests
   - promtool alert tests and dashboard drift checks
   - Checkov, Trivy, and gitleaks in CI
3. **Least privilege for agents.** Agents run locally against the docker-compose stack. They have no AWS, Snowflake, or Temporal Cloud credentials, and Terraform apply only happens from approval-gated CI.
4. **Independent review for sensitive paths.** CODEOWNERS requires security review on crypto, de-identification, KMS, IAM, and policy exceptions, regardless of who or what wrote the change. A second agent pass with fresh context is encouraged as a pre-review, never as a substitute.
5. **Disclosure.** The PR template asks which parts were AI-drafted and how each was verified.

## Consequences
- Faster iteration on boilerplate-heavy work (Terraform modules, tests, runbooks) without lowering the bar on controls.
- The quality of the test suite becomes a safety property, so investment in it is prioritized.
