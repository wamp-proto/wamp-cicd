# The SCM Exchange Model

How work is staged between a maintainer's control node, a private staging
instance, AI assistants, and — where they are used — autonomous agents.

This is the model the branch workflow in [`workflow.just`](workflow.just) runs
through. `workflow.just` implements; this document decides.

It has been in production use for over a year across both public and private
repositories. Until it was written down it survived in the shape of one Ansible
role, one hand-maintained untracked file, and habit. Three near-misses in two
days were all caused by it being tacit rather than stated, and none of them was
a thinking failure — all three were clerical.

## This document is a pattern, not an inventory

Everything below is parameterised. A deployment fills the parameters in; **which
repositories, hosts and people fill them is not recorded here** and belongs in
whatever private register that deployment keeps. A rule and the evidence that a
given estate follows it are different documents, and a document that mixes them
can be neither published nor trusted.

The worked examples throughout use one fictional deployment:

| parameter | worked example |
|---|---|
| `<owner>` | `alice` |
| `<collaborator>` | `claude`, `gemini` |
| `<area>` | `wamp` |
| `<repo>` | `wamp-proto` |
| `<instance>` | `nimbus`, and `stratus` where two are needed |
| `<exchange-host>` | `scm1` |
| `<scm_repos_path>` | `/scm/repos` |

---

## 1. Vocabulary

| term | meaning |
|---|---|
| **instance** | one deployment — its hosts, humans, agents and policies. Written `<instance>`. |
| **exchange** | the set of bare Git repositories inside an instance; the common point of exchange between the maintainer, AI assistants and autonomous agents. |
| **exchange host** | the host serving the exchange. Written `<exchange-host>`. An implementation detail *of the instance*. |
| **area of work** | a coherent body of work spanning several repositories. Written `<area>`. |
| **owner** | the human whose namespace a repository lives in. Written `<owner>`. |
| **control node** | the maintainer's machine. Outside the instance; sole holder of forge credentials and signing keys. |
| **forge** | the Git hosting service — GitHub today. |

An instance may serve several areas; an area may be staged through several
instances. Neither contains the other.

---

## 2. The exchange

Every repository in an area exists inside an instance as a **bare** repository:

```
<scm_repos_path>/<owner>/<area>/<repo>.git
/scm/repos/alice/wamp/wamp-proto.git
```

Collaborators — other humans, and AI agents — get their own bare repositories in
their own namespace, named for the owner they forked from:

```
<scm_repos_path>/<collaborator>/<area>/<repo>-<owner>.git
/scm/repos/claude/wamp/wamp-proto-alice.git
```

and working copies inside the instance live at:

```
/home/<user>/work/<area>/<repo>
/home/alice/work/wamp/wamp-proto
```

The exchange is bare on purpose. It has no working tree, so nothing can be
edited there and no state can accumulate that isn't a commit. It is the only
place the control node and the instance both reach, and it is the reason the
control node never has to grant an AI assistant anything: **the assistant pushes
to the exchange, the human pulls from it, reviews, and decides.**

---

## 3. Remote naming

### 3.1 Inside an instance

A working copy's `origin` **is** the exchange. It never has a forge remote at
all — the trust boundary is enforced by the machine's configuration, not by any
recipe knowing where it is running.

```console
$ git -C ~/work/wamp/wamp-proto remote -v
claude-alice  /scm/repos/claude/wamp/wamp-proto-alice.git
gemini-alice  /scm/repos/gemini/wamp/wamp-proto-alice.git
origin        /scm/repos/alice/wamp/wamp-proto.git
```

Collaborator remotes are named `<collaborator>-<owner>`; another owner's primary
repository is named `<owner>` alone.

### 3.2 On the control node

A working copy carries **one remote per instance it stages through, named for
the instance — not for the host**:

```
<instance>  ssh://<owner>@<exchange-host>/<scm_repos_path>/<owner>/<area>/<repo>.git
```

so a control node working with two instances holds two such remotes:

```
nimbus   ssh://alice@scm1/scm/repos/alice/wamp/wamp-proto.git
stratus  ssh://alice@scm2/scm/repos/alice/wamp/wamp-proto.git
```

Everything but `<exchange-host>` is fixed by the model, so a remote URL is fully
derivable from `(instance, owner, area, repo)`. That is the property worth
having: it makes the naming mechanically checkable rather than something an
operator has to remember.

Alongside the instance remotes sit the forge remotes, which keep their ordinary
Git meanings (§3.4). A complete control-node working copy under the fork
topology therefore looks like this:

```console
$ git remote -v
nimbus    ssh://alice@scm1/scm/repos/alice/wamp/wamp-proto.git
origin    git@github.com:alice/wamp-proto.git
upstream  git@github.com:wamp-proto/wamp-proto.git
```

Three remotes, three distinct roles, none of which can be inferred from another:
the instance you collaborate through, the fork you publish branches to, and the
canonical repository work lands in.

Branch tracking follows the roles: the integration branch tracks `upstream`,
because that is where "has this landed" is decided; a dev branch tracks `origin`,
because that is where it is published for review.

### 3.3 Why the instance, not the host

The control node reaches into *an instance*, not into a box. A host name still
works while lying if the exchange ever moves to another host — the worst failure
mode a name can have, because nothing breaks. Instance names also compose:
`git push nimbus fix_31` and `git push stratus fix_31` each say exactly where the
work is going, and a second instance needs no rename of the first.

Names considered and rejected: `bare` (a Git implementation detail — every
remote is bare, so it distinguishes nothing), `exchange` (names the function
correctly but not *which* one, so it breaks with a second instance), and
`<exchange-host>` itself (above).

### 3.4 What this model does **not** redefine

`origin` and `upstream` keep their ordinary Git meanings on the control node.
`origin` is where the working copy was cloned from, and that is legitimately
different on the two machines because they were cloned from different places.

Both of these are correct, and which one applies depends on whether the
maintainer has write access to the canonical repository — not on anything this
model decides:

| topology | `origin` | `upstream` | when |
|---|---|---|---|
| fork | personal fork | canonical | outside contributors work by fork |
| shared repository | canonical | *(absent)* | the maintainer can push branches to the canonical repository |

Which topology a given repository uses can change, and does. Ask the repository:

```console
git remote -v
```

Tooling must not assume either one. In particular, **the owner segment of a
remote URL answers "which repository is this?", never "who am I?"** — the two
coincide only under the fork topology.

---

## 4. Three layers

| layer | scope | holds |
|---|---|---|
| the class | the reusable system as such | roles, policies, this document |
| an instance | one deployment | hosts, humans, agents, addresses, hardware inventory, the project index the exchange is provisioned from |
| an area | one area of work | project index, standards, working memory |

**The area layer is scoped to the area, not to `(area, instance)`.**

The content of an area — which projects it comprises, how their documentation is
structured, what is licensed how, what is planned next — is a property of the
*work*. None of it changes if the same work is staged through a different
instance. Exactly one class of fact is instance-specific: the binding, which
already has a home in the instance repository.

Scoping the area layer per instance would produce near-identical copies that
drift. That is not hypothetical: one area's layer has existed as untracked files
in two places, and the copies had already diverged when it was noticed.

Area workspace repositories are created **when an area has something to put in
one**, not eight at once.

---

## 5. The binding rule

> Where area content needs instance facts, it takes a **named pointer resolved
> at run time — never a copy**.

Worked example, from production: an MCU testbed.

- Board MAC addresses, IP addresses and probe serial numbers are physical facts
  about hardware that exists in exactly one instance. They live in that
  instance's repository, in its hardware inventory.
- Firmware, the testbed registry and the bench tooling are area content. They
  live in the area's repositories.
- The firmware build reads the inventory through an environment variable at
  provisioning time.

The reason this was chosen is the reason it generalises: the MAC address is a
*flash-time*, not a *build-time*, input — **so CI never needs the private
instance repository**. An area whose hardware physically lives inside one
instance still stays instance-independent, provided the binding is a pointer.

A copy would have worked on the first day and been wrong on some later one, with
no signal. **A pointer cannot silently disagree with what it points at.**

The pointer must also **never silently fall back**: an unset or unresolvable
binding variable is an error, not a reason to use a built-in default. A binding
that quietly degrades to a guess is a copy again, made at run time.

---

## 6. An area is more than its declared repositories

The project index declares **what the exchange provisions**. It is not a
description of what an area consists of, and the two must not be confused.

For most areas the two lists coincide, which hides the difference. For a
firmware area they do not: its root may be a
[West](https://docs.zephyrproject.org/latest/develop/west/index.html) workspace,
and West clones several more repositories into it that the project index
declares nowhere:

```console
$ cat ~/work/<area>/.west/config
[manifest]
path = <repo>
file = west.yml

$ ls ~/work/<area>/
bootloader  build  <repo>  modules  zephyr

$ git -C ~/work/<area>/zephyr remote -v
zephyrproject-rtos  https://github.com/zephyrproject-rtos/zephyr
```

So one area can hold three remote topologies at once — exchange-staged,
upstream-direct, and third-party-tool-managed — and its root directory may be
laid out by another tool entirely.

Two consequences:

1. Anything that enumerates an area (an index, a checker, a report) must say
   which of the three it is enumerating, or it will be wrong the first time it
   meets an area like this one.
2. A workspace repository is a **guest** in the area root, never the landlord. It
   lives alongside whatever else owns that directory's layout.

---

## 7. Merging and signing

How a branch *lands* is not a style question — it is what decides whether
"has this landed?" can be answered mechanically, and who the resulting history
is attributable to. See
[MERGE-AND-SIGNING-POLICY.md](MERGE-AND-SIGNING-POLICY.md), which this model
requires and `workflow.just` implements.

Two properties from that document are load-bearing here, and are stated in both
places because the model is unsound without them:

- **Merge commits, never squash or rebase.** `land` decides containment with
  `git merge-base --is-ancestor`. Only a merge commit keeps a branch's commits
  as ancestors of the integration branch.
- **The maintainer creates the merge, not the forge.** The forge hosts review
  and decides readiness; the merge commit that enters protected history is made
  and signed on the control node — which is, per §1, the sole holder of the
  signing keys.

---

## 8. What this model does not decide

Deliberately out of scope, so that it does not have to be revisited when these
change:

- **Fork versus shared-repository** on the forge. Both are correct (§3.4).
- **Integration branch naming.** `master` and `main` both occur in practice.
- **Branch naming.** Issue branches, release branches and campaign branches are
  different species and a workflow that only recognises one will be routed
  around.
- **Whether a given physical fact is area or instance content** when it could
  plausibly be either. The rule in §5 decides the *binding*; it does not decide
  every classification. Where a bench's cabling is described, for instance, the
  cabling of one specific bench is instance content while a reproducible bench
  *design* is area content — a distinction worth making explicitly rather than
  by default.
- **Which repositories, hosts and people fill the parameters.** That is an
  inventory, it is deployment-specific, and it does not belong in a module that
  is reused across estates.

---

## 9. Checking it

Every structural claim here is re-checkable against any deployment that adopts
the model. Prefer running these to trusting the prose.

```console
# §3.1 - inside an instance, origin is the exchange and there is no forge remote
git -C ~/work/<area>/<repo> remote -v

# §3.2 - on the control node, one remote per instance
git -C ~/work/<area>/<repo> remote -v

# §6 - an area may hold repositories the exchange does not provision
cat ~/work/<area>/.west/config
git -C ~/work/<area>/zephyr remote -v

# §7 - the integration branch carries merge commits, not squashes
git log --first-parent --no-merges --format='%h %cn|%s' main | awk -F'|' '$1 ~ / GitHub$/'
```

### Known deviations

A deployment's *own* deviations from this model — remotes that carry a redundant
`origin`, push URLs that exist only because no credential is present to use them,
area layers that are not versioned — are real, and they are **instance content**.
They belong in that deployment's private register, next to the evidence that the
rest of the model is followed, not in this file. A list of one estate's
deviations published here would be neither checkable by a reader nor safe for
the estate.

What belongs here instead is the *shape* such a deviation takes, so that a
reader recognises one:

- **A boundary enforced by absence rather than by configuration** reads as a
  capability. A remote with a working push URL that fails only because the host
  holds no credentials is configured to push and prevented by circumstance. That
  is a deviation even when nothing has gone wrong yet.
- **A layer nothing versions cannot notice its own divergence** (§4).
