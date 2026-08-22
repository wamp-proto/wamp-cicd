# Merge and Signing Policy

How an approved branch becomes protected history, and who that history is
cryptographically attributable to.

[SCM-EXCHANGE-MODEL.md](SCM-EXCHANGE-MODEL.md) decides how work is *staged*;
this decides how it *lands*. [`workflow.just`](workflow.just) implements both.

---

## The policy

> Pull requests are reviewed and approved on the forge, but are **not** merged
> using the forge's web interface. An approved pull request is merged locally
> using a regular non-fast-forward merge commit, signed with the maintainer's
> Sigstore identity, and the signed history is then pushed. **Squash and rebase
> merging are not used.** Forge-generated signatures are not equivalent to the
> required Sigstore identity and must not appear on a protected-branch merge
> commit.

Stated as the property rather than the procedure, because the procedure will
change and the property must not:

**The forge determines that a pull request is ready to merge. The maintainer
creates the cryptographically authenticated merge commit that becomes part of
the project's trusted history.**

The forge is the platform. It is not the signing authority for the project's
history.

---

## 1. Why no squash, and no rebase

This is not a preference about history aesthetics. `just land` decides "has this
landed?" by SHA containment:

```
git merge-base --is-ancestor <branch> <authority>/<integration-branch>
```

Only a merge commit keeps a branch's commits as ancestors of the integration
branch. Squash and rebase both mint new SHAs, so `land` refuses — correctly, by
its own rule — on work that really did land, and `git branch -d` refuses forever
afterwards. The branch is in the integration branch by content and **provably so
by nothing**.

That state is unrecoverable rather than merely inconvenient: the branch commits
were never ancestors of anything, so retiring such a branch needs `git branch
-D` — force, on work that did land.

**And the failure is silent by construction.** A squash merge made through the
forge is committed by the forge and carries the forge's signature, so in
`git log` it is indistinguishable from a legitimately merged pull request.
Nothing about it announces itself; it is found later, by a recipe refusing.

Disable the buttons rather than documenting the trap:

| forge setting | value |
|---|---|
| Allow merge commits | **ON** |
| Allow squash merging | **off** |
| Allow rebase merging | **off** |

---

## 2. Why not the web-UI merge button

Commits made through a forge's web interface are signed with **the forge's own
signing key**. A web-created merge commit is therefore associated with the
forge's identity rather than the maintainer's:

```
forge "Merge" button
    └── forge creates the merge commit
        ├── forge's own signature (OpenPGP)
        ├── no Fulcio certificate
        └── no Sigstore transparency-log entry
```

Under a verification policy that names an expected identity and issuer, that
object **fails verification** — and that failure is the policy working, not the
verifier misbehaving.

The consequence worth stating plainly: without this policy, the merge commit —
the single artefact that carries the human review decision — is the *least*
verifiable commit in the repository. Every commit around it can be attributed to
a person; the one that admits work into protected history cannot.

---

## 3. The landing procedure

After a pull request has been reviewed and approved:

```console
git fetch --all --prune
git checkout <integration-branch>
git pull --ff-only <authority> <integration-branch>

git merge --no-ff <remote>/<branch>          # signed - see below

gitsign verify \
  --certificate-identity=<maintainer-identity> \
  --certificate-oidc-issuer=<expected-oidc-issuer> HEAD

git push <authority> <integration-branch>
# then every other remote that carries the integration branch
```

`--no-ff` is required, not stylistic: without it Git fast-forwards where it can
and no merge commit exists to sign or to prove containment with.

The exact command sequence is not the point — **the resulting object is**:

```
merge commit
   ├── Git commit
   ├── gitsign signature
   ├── Fulcio certificate
   └── transparency-log record
```

**Verify before pushing, not after.** A merge that was made but not signed must
not reach the protected branch, and the check costs one command.

This belongs in a recipe rather than in a runbook. It is six commands, one of
which must be signed, three of which are pushes to different remotes, and one of
which is destructive. Every clerical guard in `workflow.just` replaced a step
that had been forgotten at least once.

---

## 4. Verification

The policy is not *"this commit has some valid signature"*. It is:

> This commit has a valid Sigstore signature whose certificate identifies the
> expected maintainer through the expected OIDC issuer.

```console
gitsign verify \
  --certificate-identity=<maintainer-identity> \
  --certificate-oidc-issuer=<expected-oidc-issuer> <commit>
```

Deliberately stricter than a presence check — because a forge-signed merge
commit **has** a valid signature and is exactly the object this policy exists to
keep out. A check for mere presence would pass the one case it was written for.

The expected identity is deployment-specific and belongs in repository
configuration, never as a literal in a shared module: this file is reused across
repositories whose maintainers differ.

---

## 5. What this does and does not guarantee

The recommended authentication model is keyless signing with the forge as OIDC
identity provider, and the maintainer's forge account protected by a FIDO2
hardware authenticator with user presence.

The chain is:

```
FIDO2 authenticator (touch)
    └── forge account authentication
        └── OIDC identity token
            └── Fulcio short-lived certificate
                └── ephemeral signing key
                    └── merge commit signature
                        └── transparency log
```

**The hardware key protects the authentication, not the artefact signature.**
One authentication can cover many subsequent signatures. This is deliberate —
the signing key is meant to be disposable, which is the whole reason the keyless
model avoids long-lived key management — but it must not be overstated. The
accurate description is:

> hardware-protected identity → ephemeral signing authority → transparent
> signing record

and **not** "the merge is signed by the hardware key". A policy that requires an
explicit hardware approval per signature is a different architecture with
different operating costs.

Two consequences that follow directly and are easy to leave unplanned:

- **The forge account is now part of the provenance chain.** It is no longer
  merely a hosting account.
- **A single physical authenticator must not be the only path to the signing
  identity.** A backup authenticator and offline recovery codes are part of this
  policy, not an optional extra. Losing the authenticator without them loses the
  identity, not just a signature.

---

## 6. Consequences to plan for

Three, each of which will otherwise be discovered at the first merge — and a
policy whose costs are discovered at the moment of use is a policy that gets
skipped.

1. **Branch protection must permit the maintainer to push a merge.** A rule
   requiring a pull request before merging refuses a direct push to the
   integration branch. The maintainer needs an explicit bypass. A forge setting
   that must be *relaxed* to satisfy a provenance policy is worth deciding
   deliberately and writing down.
2. **`land` changes shape.** It was built for a world in which the forge had
   already created the merge and the maintainer only fast-forwarded afterwards.
   Under this policy the maintainer *creates* the merge, so the load-bearing
   step of the cycle needs a recipe.
3. **Automation cannot sign, and must not try.** Keyless signing binds an OIDC
   identity; an automated assistant producing one would be impersonating a
   person. Every merge is a human act at the control node.

Point 3 also fixes the scope of this policy, and the fixing matters: **unsigned
commits on dev branches are correct and expected.** The requirement is about what
reaches a *protected* branch. A guard that refused unsigned commits generally
would be red on every assistant push, on work that is entirely correct — and a
check that refuses correct work is the check that gets disabled.

---

## 7. Configuration

`gitsign` is configured **per repository**, not globally:

```console
git config gpg.format x509
git config gpg.x509.program gitsign
git config commit.gpgsign true
```

A repository without this silently falls through to the OpenPGP backend, where
`git commit -S` fails with *"No secret key"* — which reads like a broken key and
is not.

**Do not read `git log --format=%G?` to answer "is this signed".** A clone
without `gpg.x509.program` prints `N`, which means *"cannot verify"*, not
*"unsigned"*. Read the object:

```console
git cat-file commit <sha> | grep -q '^gpgsig'          # is there a signature at all
git cat-file commit <sha> | sed -n '/^gpgsig/,/END/p'  # BEGIN SIGNED MESSAGE -> x509 / gitsign
                                                       # BEGIN PGP SIGNATURE  -> OpenPGP / forge web-flow
```
