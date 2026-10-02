# fleet/lib/rollouts.sh - sourced: which rollouts exist, which a repository has, what is next.
#
# A cohort's rollouts are the directories rollouts/<cohort>/<NNNN>-<name>/ of the definition, in
# that order. A repository HAS a rollout when its marker .waves/<cohort>/<NNNN>-<name>.toml is
# there - on its default branch, which is what "landed" means. Nothing is skipped.
#
# What is NEXT is not simply the first rollout without a marker: a rollout that is already in
# place (its check.sh passes) is ADOPTED by the runner when it applies a later one, so it is not
# something to do. The answer therefore comes from the runner itself (apply-rollout.sh --next,
# #73) - `next_due` below. `next_rollout` is the marker-only answer and is kept for counting.

# rollouts_of <definition dir> <cohort>  -> the cohort's rollouts, one per line, in order
rollouts_of() {
    [ -d "$1/rollouts/$2" ] || return 0
    find "$1/rollouts/$2" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

# default_ref <clone> <default branch>  -> the ref that says what has landed: upstream's copy if
# this clone knows one, else the local branch
default_ref() {
    if git -C "$1" show-ref -q --verify "refs/remotes/upstream/$2"; then echo "upstream/$2"; else echo "$2"; fi
}

# has_marker <clone> <ref> <cohort> <rollout>
has_marker() { git -C "$1" cat-file -e "$2:.waves/$3/$4.toml" 2>/dev/null; }

# next_rollout <clone> <ref> <definition dir> <cohort>  -> the first rollout without a marker, or nothing
next_rollout() {
    local r
    while read -r r; do
        [ -n "${r}" ] || continue
        has_marker "$1" "$2" "$4" "${r}" || { echo "${r}"; return 0; }
    done < <(rollouts_of "$3" "$4")
}

# next_due <clone> <ref> <definition dir> <cohort> <inventory name>
#   -> "<rollout><TAB><what it would adopt, comma separated>"   the next rollout to apply
#      nothing                                                   up to date
#      "?<TAB><why>"                                             cannot tell
# Adoption is judged on the checked-out tree, so the clone must be clean and AT <ref> (its
# default branch as landed); otherwise the answer is "cannot tell", never a guess.
next_due() {
    local out rc
    if [ "$(git -C "$1" rev-parse -q --verify HEAD 2>/dev/null)" != "$(git -C "$1" rev-parse -q --verify "$2" 2>/dev/null)" ]; then
        printf '?\tnot checked out at %s\n' "$2"; return 0
    fi
    out="$(bash "${FLEET_TOOLS_DIR}/apply-rollout.sh" "$1" "$3" "$4" --next --repo "$5" 2>/dev/null)"; rc=$?
    out="$(tail -1 <<<"${out}")"
    case "${rc}" in
        0)  [[ "${out}" =~ ^NEXT\ ([^ ]+)\ adopt=(.*)$ ]] && printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
                || printf '?\tunexpected answer from the runner\n' ;;
        10) ;;
        11) printf '?\tthe working tree is not clean\n' ;;
        *)  printf '?\tthe runner cannot tell (exit %s)\n' "${rc}" ;;
    esac
}

# applied_count <clone> <ref> <definition dir> <cohort>  -> "<applied>/<total>"
applied_count() {
    local r n=0 t=0
    while read -r r; do
        [ -n "${r}" ] || continue
        t=$((t+1)); has_marker "$1" "$2" "$4" "${r}" && n=$((n+1))
    done < <(rollouts_of "$3" "$4")
    echo "${n}/${t}"
}
