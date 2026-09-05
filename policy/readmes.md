# readmes

Type: **judgment**

## The rule

Every repository in this organisation has a README with exactly two headings
and nothing else:

```
# <repo-name>

<description>

<screenshot, optional>

# Capabilities

<lead sentence, then bullets>
```

**The name.** The repository's own name, lowercase, as it appears in the URL.
For a mirror this is its published name rather than the directory it was split
from: `# controlplane`, never `# systemd`.

**The description.** The same string as the repository's GitHub About field,
character for character, not a paraphrase of it. It follows the pattern already
in use across the organisation: `<name>` is a `<thing>` for `<purpose>`. A
repository with no About field gets one written before its README.

**The screenshot.** Optional and hand-made. Insert one where there is something
worth seeing, and skip it where there is not. Nothing generates it.

**Capabilities.** One sentence framing what the thing is, then a flat bullet
list of what it can technically do. Each bullet states a capability and, where
the reason is not obvious, why it works that way.

## Constraints

Headings are `#` only. No `##`, no `###`, anywhere in the file. Two headings is
the whole document, and forbidding depth closes the route by which a third
section arrives: not by decision, but by a subheading that later grows.

The restriction is on heading depth alone. Bullet lists, tables, code blocks and
images are all permitted inside a section.

Prose does not address the reader. No second person.

Prose does not use em dashes.

Capabilities stay conceptual. Naming a count ages the document badly, because
the count changes and the sentence does not.

## Why

Six repositories were left to write their own READMEs and grew six different
shapes, between one and three hundred lines each. Most of that material also
lived in CLAUDE.md, which is where it is maintained. A second copy of the truth
is free to drift from the first, and drift is what second copies do. A README
holding four things stays correct. A README holding an architecture stops being
correct and gives no sign that it has.

The audience settles the rest. These repositories are published for reading
rather than installation. Nobody integrates with them, so the inputs, outputs
and dependency lists that a component datasheet exists to answer are questions
nobody is asking. What a stranger wants is what this is and whether it is
interesting.

## What this gives up, deliberately

**The mirror provenance note.** Mirror READMEs used to open with a blockquote
saying the repository was force-synced and that pull requests belonged on the
parent. Issues are disabled on the mirrors instead, and that is as far as the
setting goes: GitHub permits disabling forks only on private repositories, so a
fork-based pull request against a public mirror cannot be prevented.

Nothing unwanted can land that way. Its author has no write access and so cannot
merge it, and a force-push does not close or delete an open pull request either.
What such a request cannot do is succeed: merging one into a mirror would be
undone by the very next sync, so the work has to be re-created against the parent
repository by hand. Until somebody does that it sits unanswered, on a repository
with Issues switched off that nobody watches. The cost is wasted effort by a
contributor, not anything reaching this codebase.

That is accepted rather than solved, and the blockquote did not solve it either,
since somebody who opens a pull request has generally not read the README first.
No such request has ever been opened against any of these repositories. An action
that closes one automatically and points at the parent is the thing to build if
one ever arrives.

**The traps.** Each README carried a section of hard-won warnings. Those stay in
CLAUDE.md and in the code, where the person who needs them is already looking.

**The architecture.** Cut, not relocated. It remains in the parent repository's
git history and is recoverable from there.

## Scope

Every repository in the organisation, with no exemptions. That includes
catallenya, which a stranger is most likely to land on first, and this rule
set, which is a directory inside catallenya rather than a repository of its own,
and whose ground rules become its own Capabilities bullets.

A repository with no commits is not yet in scope. The policy attaches when the
repository has content.

## Enforcement

None. This is `judgment` and deliberately not a `lock`: no script checks these
rules, so the policy holds only for as long as it is applied by hand.

The check worth writing first would compare each README's description line
against its GitHub About field, since that is the one rule here a machine can
settle outright. Structure is checkable too: two H1 headings, nothing deeper,
the second reading Capabilities. Whether the prose is any good is not checkable,
and that is most of what makes a README worth reading.

If such a script is ever written, this policy becomes a `lock` and names it.
