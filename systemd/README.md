# controlplane

controlplane is a governance framework for enforcing system job policy.

# Capabilities

controlplane declares the policy every background job on the host inherits,
refuses to install any job that breaks it, and verifies daily that each job
actually ran.

- Policy is declared once in layered drop-ins and inherited by every job. No job
  declares its own timeout, user or failure handler.
- A job states only what it is and what it touches. Everything else follows from
  that, so there is no map to keep in step with the jobs it describes.
- The installer validates every job against its contract and creates no links at
  all if a single one fails, so a host is never left half configured.
- Validation runs without root and without the container daemon, which makes it
  usable as a check before committing rather than only at install time.
- Jobs are discovered from the repository rather than read from a list, so a
  committed but unregistered job is a refusal instead of an invisible gap.
- A daily watchdog reads each job's own declaration and asks whether it ran
  inside its declared window, whether its output is fresh, and whether the thing
  that feeds it still exists.
- Jobs record their own completion, because the init system's runtime timestamps
  reset at boot and cannot answer that question.
- Findings are reported, never reconciled. A drifted job produces a notification,
  not a restart.
- Failed units are swept separately, because having run recently and having run
  successfully are different questions.
