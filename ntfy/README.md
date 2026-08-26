# dispatch

dispatch is a notification composition layer for system messaging.

# Capabilities

dispatch is the single transport for every notification the system sends. A
caller supplies a title, a body and an optional set of action buttons, and
receives a message consistent with every other message on the system.

- Titles are built by constructors rather than written by hand, and checked
  against a declared vocabulary.
- Bodies are built by renderers that escape every line, so text arriving from a
  filename or a scanned document cannot inject a link or break formatting.
- Message kinds fix their own arguments. A receipt has nowhere to attach a
  button; a proposal cannot omit the identifier that makes it withdrawable.
- Priority and tags do not exist. Nothing shouts.
- Delivery is best effort. A caller that must fail on an undelivered alert
  asserts against the transport's output rather than its exit code.
- Any message published with a sequence identifier can be retracted, so a
  notification lives exactly as long as the decision it carries.
- A written contract records every title in the system and every deliberate
  exception to the grammar, so the whole scheme can be rebuilt from that one
  file.
- The test suite runs offline, with no network and no device.
