#!/bin/bash
#
# Apply the GSI patches on top of a synced ROM tree.
#
# Usage (from the root of the ROM source):
#   bash LineageOS_gsi/patches/apply-patches.sh .
#
# Each patch is tried in order:
#   1. already applied (reverse applies cleanly)  -> skipped
#   2. git am -3 (3-way merge)                    -> applied
#   3. patch(1) with fuzz, then committed via am  -> applied (fuzzy)
#   4. otherwise                                  -> reported as failed
#
# A failed patch never leaves a repository in the middle of a `git am`
# session, and a summary of all skipped/fuzzy/failed patches is printed
# at the end. The exit code is 1 if any patch failed.

set -u

root="$(cd "${1:-.}" && pwd)"
source="$root/LineageOS_gsi"
trebledroid="$source/patches/trebledroid"
trebledroid_staging="$source/patches/trebledroid-staging"
personal="$source/patches/personal"

applied=0
skipped=()
fuzzy=()
failed=()
missing=()

# Map a patch directory name (e.g. platform_frameworks_base) to a tree path.
tree_for() {
    local tree
    tree="$(tr _ / <<<"$1" | sed -e 's;platform/;;g')"

    case "$tree" in
        build) tree=build/make ;;
        testing) tree=platform_testing ;;
        vendor/hardware/overlay) tree=vendor/hardware_overlay ;;
        treble/app) tree=treble_app ;;
        vendor/partner/gms) tree=vendor/partner_gms ;;
    esac

    echo "$tree"
}

# Abort any `git am` session left in the current repository.
am_abort() {
    if [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
        git am --abort > /dev/null 2>&1
    fi
}

# Files touched by a patch (both old and new names), for `git add`.
patch_files() {
    sed -n 's;^diff --git a/\(.*\) b/\(.*\)$;\1\n\2;p' "$1" | sort -u
}

apply_one() {
    local patch=$1
    local name=${patch#"$source/patches/"}

    # Already present in the tree (e.g. merged upstream or in iodé's fork).
    if git apply --check --reverse "$patch" > /dev/null 2>&1; then
        printf "    = already applied: %s\n" "$name"
        skipped+=("$name")
        return 0
    fi

    # Clean apply, falling back to a 3-way merge using the blob ids.
    if git am -3 --keep-cr "$patch" > /dev/null 2>&1; then
        printf "    + applied: %s\n" "$name"
        applied=$((applied + 1))
        return 0
    fi
    am_abort

    # Fuzzy apply with patch(1), keeping the original author and message.
    if patch -f -p1 --dry-run < "$patch" > /dev/null 2>&1; then
        git am --keep-cr "$patch" > /dev/null 2>&1   # starts the session, fails
        if patch -f -p1 --no-backup-if-mismatch < "$patch" > /dev/null 2>&1; then
            mapfile -t files < <(patch_files "$patch")
            git add -A -- "${files[@]}" 2> /dev/null
            if git am --continue > /dev/null 2>&1; then
                printf "    ~ applied with fuzz: %s\n" "$name"
                fuzzy+=("$name")
                applied=$((applied + 1))
                return 0
            fi
        fi
        am_abort
        git reset -q --hard HEAD
    fi

    printf "    ! FAILED: %s\n" "$name"
    failed+=("$name")
    return 1
}

apply_patch_dir() {
    local patch_dir=$1
    local patch_name=$2

    printf "\n ### APPLYING %s PATCHES ###\n" "$patch_name"

    if [ ! -d "$patch_dir" ]; then
        printf "Directory %s not found, skipping...\n" "$patch_dir"
        return 0
    fi

    local path tree patch
    for path in "$patch_dir"/*/; do
        path="$(basename "$path")"
        tree="$(tree_for "$path")"
        printf "\n| %s -> %s\n" "$path" "$tree"

        if [ ! -d "$root/$tree" ]; then
            printf "    ! tree %s not found, skipping its patches\n" "$tree"
            missing+=("$path -> $tree")
            continue
        fi

        pushd "$root/$tree" > /dev/null || continue
        am_abort

        for patch in "$patch_dir/$path"/*.patch; do
            [ -e "$patch" ] || continue
            apply_one "$patch"
        done

        popd > /dev/null
    done
}

apply_patch_dir "$trebledroid" "TREBLEDROID"
apply_patch_dir "$trebledroid_staging" "TREBLEDROID STAGING"
apply_patch_dir "$personal" "PERSONAL"

print_list() {
    local title=$1; shift
    [ $# -eq 0 ] && return
    printf "\n%s (%d):\n" "$title" "$#"
    printf "  - %s\n" "$@"
}

printf "\n ### SUMMARY ###\n"
printf "Applied: %d\n" "$applied"
print_list "Already applied (skipped)" "${skipped[@]}"
print_list "Applied with fuzz (review these)" "${fuzzy[@]}"
print_list "Missing trees" "${missing[@]}"
print_list "FAILED (apply manually)" "${failed[@]}"

[ ${#failed[@]} -eq 0 ]
