locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "isponsorblocktv" {
  source = "../../modules/kubernetes/isponsorblocktv"
  tier                           = local.tiers.edge
}
