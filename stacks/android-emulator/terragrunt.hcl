include "root" {
  path = find_in_parent_folders()
}

# apply-trigger: non-merge commit so the stack detector sees this stack
# (merge-commit diffs hide stacks from it — same issue as the tts 798b0255 fix)

# apply-trigger 2026-06-12: non-merge commit so the detector sees this stack

# apply-trigger 2026-06-12b: non-merge commit for the GPU+gate rollout
