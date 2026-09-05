# policy

policy is the baseline rule set for every repository in the organisation.

# Capabilities

policy holds the rules that apply globally, to every repository in the
organisation and to all work on catallenya.

- Rules compose underneath everything else. A repository's own instructions may
  add detail for that repository; they may not contradict a policy, and a
  contradiction is raised with the owner rather than quietly resolved.
- One rule per file, with a stable filename, so any other document can reference
  a policy by name.
- Every rule states what it is, why it exists and its type. A rule that names its
  reason can be retired when the reason dies rather than when it becomes
  inconvenient.
- Rules are typed as judgment or lock. A judgment guides a decision and the prose
  is the mechanism. A lock must never be violated, and the file names the hook,
  deny rule or gate that enforces it.
- Policies are drafted from established precedent rather than invented, and
  ratified by the owner's commit.
- The repository reaches the assistant by being cloned onto the machine. A policy
  that is not on the box is not in force.
