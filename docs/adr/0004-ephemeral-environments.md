# ADR-0004: Per-PR ephemeral environments with synthetic data

**Status:** Accepted

## Context
A shared staging environment is a bottleneck: changes queue behind each other, state drifts, and it tempts people to copy production data "just to test". In a HIPAA environment, that last point is unacceptable.

## Decision
Adding the `preview` label to a PR creates a full stack in its own Terraform workspace (`pr-N`): its own Aurora Serverless v2 cluster (scales to zero), DynamoDB table, and intake-api service. The shared dev VPC, ECS cluster, and AMP workspace are reused. The stack is seeded with **generated** data and tagged `data:classification=synthetic` and `expires-at`.

Teardown happens on PR close, with a nightly reaper as a backstop for anything past its TTL.

## Consequences
- Reviewers can click through a real deployment, including migrations, before merging.
- Cost is bounded by scale-to-zero, small task sizes, and a 72-hour TTL.
- Checkov skips the ephemeral composition (no deletion protection by design), but the modules it uses are scanned through `envs/prod`.
- No path exists for production data to reach preview environments: they live in the dev account, which has no network route or IAM trust to prod.
