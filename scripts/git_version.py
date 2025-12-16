import re


def version() -> tuple[int, int, int, int | None, str | None]:
    """
    Return the exact git version of a vendored Git repo, e.g. FlatBuffers runtime.

    git describe --tags --abbrev=0

    # Checkout the latest tag closest to the current branch tip
    git checkout $(git describe --tags --abbrev=0)

    Handles:

    1. "v25.9.23"              -> (25, 9, 23, None, None)       # Release (Named Tag, CalVer Year.Month.Day)
    2. "v25.9.23-71"           -> (25, 9, 23, 71, None)         # 71 commits ahead of the Release v25.9.23
    3. "v25.9.23-71-g19b2300f" -> (25, 9, 23, 71, "19b2300f")   # dito, with Git commit hash
    """

    # Pattern explanation:
    # ^v                : Start of string, literal 'v'
    # (\d+)\.(\d+)\.(\d+) : Groups 1,2,3 - Major.Minor.Patch (Required)
    #
    # (?: ... )?        : Non-capturing group (grouping only, not saved), optional '?'
    # -(\d+)            : Literal hyphen, Group 4 (Commits)
    #
    # (?: ... )?        : Non-capturing group, optional '?'
    # -g                : Literal hyphen and 'g' (separator)
    # ([0-9a-f]+)       : Group 5 (Hash)

    pattern = r"^v(\d+)\.(\d+)\.(\d+)(?:-(\d+))?(?:-g([0-9a-f]+))?$"

    match = re.match(pattern, __git_version__)

    if match:
        major, minor, patch, commits, commit_hash = match.groups()

        # Convert commits to int if present, else None
        commits_int = int(commits) if commits else None

        return (int(major), int(minor), int(patch), commits_int, commit_hash)

    # Fallback if regex fails entirely (returns 0.0.0 to satisfy type hint)
    return (0, 0, 0, None, None)
