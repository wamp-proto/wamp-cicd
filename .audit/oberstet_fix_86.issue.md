Issue:    wamp-proto/wamp-cicd#86
Title:    land: retry the merge-signature check while Rekor has not yet indexed the new entry
URL:      https://github.com/wamp-proto/wamp-cicd/issues/86
State:    OPEN at freeze
Author:   @oberstet
Updated:  2026-10-14T19:30:11Z
Comments: 0
Frozen:   2026-10-16T09:28:58Z by `just new-branch`
SHA-256:  cebab2ff08322673cd77728ec474efcd2b3333384b609f8cd6bda6a8ef35f1de (of everything below the line)

---


## Why

`_workflow-merge-signed` verifies the signed merge with `gitsign verify` immediately after creating it, and undoes the merge if verification fails. That is right: an unverified merge must not be pushed.

With gitsign's online Rekor mode (gitsign v0.17.1's default here: `RekorMode: online`, `EnableSigstoreGo: true`), verification looks the entry up in Rekor. Right after signing, that lookup can fail although the entry exists. Measured on 2026-10-14, three `just land` attempts in a row:

```
tlog entry created with index: 3253761989
...
--> Verifying the merge signature
Error: no signer could be verified online: signer 0: looking up rekor entry: could not find matching tlog entry
REFUSING: the merge commit does not verify as <identity> via https://github.com/login/oauth. The merge has been undone; nothing was pushed.
```

A few minutes later, the undone merge commit (still in the reflog) verified fine, with the same tlog index:

```
tlog index: 3253761989
gitsign: Good signature from [<identity>](https://github.com/login/oauth)
Validated Git signature: true
Validated Rekor entry: true
Validated Certificate claims: true
```

So the refusal was not about the signature. Rekor had not yet indexed the new entry when the check ran, within a second of signing. Each retry signs a new merge and goes through the browser OIDC flow again.

## Proposal

1. In `_workflow-merge-signed` step 3, when `gitsign verify` fails **and** its output contains `could not find matching tlog entry`, wait and retry: for example 5 attempts with 5, 10, 15 and 20 s between them, about 50 s in all. Print one line per retry: `--> Rekor has not indexed the entry yet; retrying in N s (attempt k/5)`.
2. Any other verification failure (wrong identity, wrong issuer, no signature, a bad certificate) refuses at once, as today. Only the "not indexed yet" case is retried.
3. If every retry fails, refuse as today, and add one line saying that the merge commit is still in the reflog, and the command that verifies it later (`gitsign verify ... <sha>`).

## Tests

Each provoked to fail without the change:
- a stub `gitsign` that fails twice with `could not find matching tlog entry`, then succeeds: the land goes ahead, and two retry lines are printed;
- a stub that always fails with that message: refused after the last attempt, merge undone, the reflog hint printed;
- a stub that fails with any other message (e.g. a wrong identity): refused at once, with no retry.

Note: This issue was drafted with AI assistance (Claude Code).

---

## Comments at freeze (0)

