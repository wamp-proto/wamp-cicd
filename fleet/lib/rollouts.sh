# fleet/lib/rollouts.sh - sourced: which rollouts exist, which a repository has, what is next.
#
# A cohort's rollouts are the directories rollouts/<cohort>/<NNNN>-<name>/ of the definition, in
# that order. A repository HAS a rollout when its marker .waves/<cohort>/<NNNN>-<name>.toml is
# there - on its default branch, which is what "landed" means. Nothing is skipped: what is next
# is simply the first rollout without a marker.

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

# applied_count <clone> <ref> <definition dir> <cohort>  -> "<applied>/<total>"
applied_count() {
    local r n=0 t=0
    while read -r r; do
        [ -n "${r}" ] || continue
        t=$((t+1)); has_marker "$1" "$2" "$4" "${r}" && n=$((n+1))
    done < <(rollouts_of "$3" "$4")
    echo "${n}/${t}"
}
