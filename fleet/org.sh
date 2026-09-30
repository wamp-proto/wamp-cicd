#!/usr/bin/env bash
# org.sh - consistent GitHub ORGANIZATION settings across all orgs you administer (DEV PC).
#
#   ./org.sh                           status of every org you are an admin of (read-only)
#   ./org.sh settings [--go]           members may NOT change repository visibility, NOT delete
#                                                repositories (admins only); verified by reading back
#   ./org.sh rulesets <org> [--go]     org-wide rulesets from rulesets/org-*.json (all repos,
#                                                default branch); create, or update only if different
#   ./org.sh transfer <from> <to> [--go]   move every PRIVATE repository of <from> into <to>
#
# Needs `gh` with the admin:org scope (gh auth refresh -h github.com -s admin:org).
# The 2FA requirement cannot be set through the API: `status` lists the orgs without it, with the link.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-status}"; [ $# -gt 0 ] && shift
GO=0; ARGS=()
for a in "$@"; do if [ "$a" = "--go" ]; then GO=1; else ARGS+=("$a"); fi; done
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "ERROR: gh missing or not authenticated" >&2; exit 1; }

admin_orgs() {
    gh api user/memberships/orgs --paginate --jq '.[] | select(.role=="admin" and .state=="active") | .organization.login'
}
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }

cmd_status() {
    printf '%-16s %-6s %-7s %-7s %-5s %-12s %-12s %s\n' ORG PLAN PUBLIC PRIVATE 2FA MEMBER-VIS MEMBER-DEL ORG-RULESETS
    local todo2fa=()
    for org in $(admin_orgs); do
        o="$(gh api "orgs/${org}")"
        # On failure gh prints GitHub's error body on stdout (a 403 on free plans): show a
        # short reason instead of the raw JSON.
        rs="$(gh api "orgs/${org}/rulesets" --jq '[.[] | .name + "(" + .enforcement + ")"] | join(",")' 2>/dev/null)" \
            || rs="n/a ($(printf '%s' "$o" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("plan") or {}).get("name"))') plan)"
        printf '%-16s %-6s %-7s %-7s %-5s %-12s %-12s %s\n' "${org}" \
            "$(printf '%s' "$o" | python3 -c 'import sys,json; print((json.load(sys.stdin).get("plan") or {}).get("name"))')" \
            "$(printf '%s' "$o" | jget public_repos)" "$(printf '%s' "$o" | jget total_private_repos)" \
            "$(printf '%s' "$o" | jget two_factor_requirement_enabled)" \
            "$(printf '%s' "$o" | jget members_can_change_repo_visibility)" \
            "$(printf '%s' "$o" | jget members_can_delete_repositories)" "${rs:-none}"
        [ "$(printf '%s' "$o" | jget two_factor_requirement_enabled)" = "True" ] || todo2fa+=("${org}")
    done
    if [ "${#todo2fa[@]}" -gt 0 ]; then
        echo ""
        echo "2FA NOT REQUIRED (UI only; members/outside collaborators without 2FA are REMOVED when enabled):"
        for org in "${todo2fa[@]}"; do echo "   https://github.com/organizations/${org}/settings/security"; done
    fi
}

cmd_settings() {
    echo "(note: GitHub's API accepts but IGNORES these two fields on most plans; the result is"
    echo " read back, and where it did not apply the settings page to do it by hand is printed)"
    for org in $(admin_orgs); do
        o="$(gh api "orgs/${org}")"
        vis="$(printf '%s' "$o" | jget members_can_change_repo_visibility)"
        del="$(printf '%s' "$o" | jget members_can_delete_repositories)"
        if [ "${vis}" = "False" ] && [ "${del}" = "False" ]; then echo "${org}: already admins-only"; continue; fi
        if [ "${GO}" != 1 ]; then echo "${org}: [dry-run] set members_can_change_repo_visibility=false members_can_delete_repositories=false (now ${vis}/${del})"; continue; fi
        gh api -X PATCH "orgs/${org}" -F members_can_change_repo_visibility=false -F members_can_delete_repositories=false >/dev/null 2>&1
        o="$(gh api "orgs/${org}")"
        if [ "$(printf '%s' "$o" | jget members_can_change_repo_visibility)" = "False" ] && [ "$(printf '%s' "$o" | jget members_can_delete_repositories)" = "False" ]; then
            echo "${org}: set to admins-only (verified)"
        else
            echo "${org}: NOT APPLIED by the API - set by hand: https://github.com/organizations/${org}/settings/member_privileges"
            echo "        ('Repository visibility change' and 'Repository deletion and transfer': admins only)"
        fi
    done
}

cmd_rulesets() {
    local org="${ARGS[0]:?usage: rulesets <org> [--go]}"
    existing="$(gh api "orgs/${org}/rulesets")" || { echo "${org}: cannot read org rulesets (plan or admin:org scope?)"; exit 1; }
    for f in "${HERE}"/rulesets/org-*.json; do
        name="$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["name"])' "$f")"
        id="$(printf '%s' "${existing}" | python3 -c 'import sys,json; n=sys.argv[1]; print(next((str(r["id"]) for r in json.load(sys.stdin) if r["name"]==n), ""))' "${name}")"
        if [ -n "${id}" ]; then
            same="$(gh api "orgs/${org}/rulesets/${id}" | python3 "${HERE}/lib/ruleset-matches.py" "$f")"
            if [ "${same}" = yes ]; then echo "${org}: ruleset '${name}' (#${id}) up to date"; continue; fi
            if [ "${GO}" = 1 ]; then gh api -X PUT "orgs/${org}/rulesets/${id}" --input "$f" >/dev/null && echo "${org}: updated '${name}' (#${id})"
            else echo "${org}: [dry-run] update '${name}' (#${id}) - differs"; fi
        else
            if [ "${GO}" = 1 ]; then gh api -X POST "orgs/${org}/rulesets" --input "$f" >/dev/null && echo "${org}: created '${name}'"
            else echo "${org}: [dry-run] create '${name}'"; fi
        fi
    done
}

cmd_transfer() {
    local from="${ARGS[0]:?usage: transfer <from> <to> [--go]}" to="${ARGS[1]:?usage: transfer <from> <to> [--go]}"
    for r in $(gh repo list "${from}" --visibility private --limit 1000 --json name --jq '.[].name'); do
        # Exists only if GitHub answers with THAT full name: a lookup can resolve to another
        # repository (redirects), which once reported a false "already exists" for a real transfer.
        fn="$(gh api "repos/${to}/${r}" --jq .full_name 2>/dev/null || true)"
        if [ "${fn,,}" = "${to,,}/${r,,}" ]; then echo "${from}/${r}: SKIP - ${to}/${r} already exists"; continue; fi
        if [ "${GO}" != 1 ]; then echo "${from}/${r}: [dry-run] transfer to ${to}/${r}"; continue; fi
        gh api -X POST "repos/${from}/${r}/transfer" -f new_owner="${to}" >/dev/null \
            && echo "${from}/${r}: transferred to ${to}/${r}" || echo "${from}/${r}: TRANSFER FAILED"
    done
    echo ""
    echo "After a transfer: GitHub redirects the old URL, and \`git ls-remote\` follows it SILENTLY."
    echo "Update each clone:  git remote set-url upstream git@github.com:${to}/<repo>.git   (and any fleet.toml slug)"
}

case "${cmd}" in
    status) cmd_status ;;
    settings) cmd_settings ;;
    rulesets) cmd_rulesets ;;
    transfer) cmd_transfer ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "unknown command: ${cmd}" >&2; exit 2 ;;
esac
[ "${GO}" = 1 ] || [ "${cmd}" = status ] || echo -e "\n(dry run - nothing changed; re-run with --go)"
