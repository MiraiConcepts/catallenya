# inference

inference is a shared reasoning platform for higher-order systems.

# Capabilities

inference is the single place in the system that talks to a language model,
shared by every pipeline that needs one.

- One library holds the model choice, the effort setting and the request shape,
  so moving to a different model is a single edit for every consumer.
- Requests carry no tool definitions. Containment is a property of the endpoint
  rather than something the caller arranges.
- Responses are classified into four verdicts: proceed, retry, pause and fail.
  Consumers need only three branches, because two of the verdicts are disposed of
  identically and differ only in the reason reported.
- An exhausted account is distinguished from an unreachable network, which the
  status code alone cannot do. A billing pause parks the work to be retried
  rather than discarding it as failed.
- Retries are bounded, and spend nothing on a failure that retrying cannot fix.
- The credential lives outside the repository in a root-owned file and is
  injected into the process, never stored beside the code.
- The test suite runs offline against a scripted endpoint, which is the only way
  to prove a retry loop both retries and stops. A real failure cannot be summoned
  on demand, and paying for one would defeat the point.
