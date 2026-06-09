include "root" {
  path = find_in_parent_folders()
}

# No platform dependency — Calico provides the cluster network the rest
# of the platform runs on. This stack must not introduce a dep cycle.
