resource "kubernetes_namespace" "iscsi_csi" {
  metadata {
    name = "iscsi-csi"
    labels = {
      tier                                  = var.tier
      "resource-governance/custom-quota"     = "true"
    }
  }
}

resource "helm_release" "democratic_csi" {
  namespace        = kubernetes_namespace.iscsi_csi.metadata[0].name
  create_namespace = false
  name             = "democratic-csi-iscsi"
  atomic           = true
  timeout          = 300

  repository = "https://democratic-csi.github.io/charts/"
  chart      = "democratic-csi"

  values = [yamlencode({
    csiDriver = {
      name = "org.democratic-csi.iscsi"
    }

    storageClasses = [{
      name                 = "iscsi-truenas"
      defaultClass         = false
      reclaimPolicy        = "Retain"
      volumeBindingMode    = "Immediate"
      allowVolumeExpansion = true
      parameters = {
        fsType = "ext4"
      }
      mountOptions = []
    }]

    controller = {
      replicas = 2
      driver = {
        resources = {
          requests = { cpu = "25m", memory = "192Mi" }
          limits   = { memory = "192Mi" }
        }
      }
      externalProvisioner = {
        resources = {
          requests = { cpu = "5m", memory = "64Mi" }
          limits   = { memory = "64Mi" }
        }
      }
      externalAttacher = {
        resources = {
          requests = { cpu = "5m", memory = "64Mi" }
          limits   = { memory = "64Mi" }
        }
      }
      externalResizer = {
        resources = {
          requests = { cpu = "5m", memory = "64Mi" }
          limits   = { memory = "64Mi" }
        }
      }
      externalSnapshotter = {
        resources = {
          requests = { cpu = "5m", memory = "80Mi" }
          limits   = { memory = "80Mi" }
        }
      }
    }

    # csiProxy is a top-level chart key, NOT nested under controller/node
    csiProxy = {
      resources = {
        requests = { cpu = "5m", memory = "32Mi" }
        limits   = { memory = "32Mi" }
      }
    }

    node = {
      driver = {
        resources = {
          requests = { cpu = "25m", memory = "192Mi" }
          limits   = { memory = "192Mi" }
        }
      }
      driverRegistrar = {
        resources = {
          requests = { cpu = "5m", memory = "32Mi" }
          limits   = { memory = "32Mi" }
        }
      }
      cleanup = {
        resources = {
          requests = { cpu = "5m", memory = "32Mi" }
          limits   = { memory = "32Mi" }
        }
      }

      hostPID  = true
      hostPath = "/lib/modules"
    }

    driver = {
      config = {
        driver = "freenas-iscsi"

        instance_id = "truenas-iscsi"

        httpConnection = {
          protocol = "http"
          host     = var.truenas_host
          port     = 80
          apiKey   = var.truenas_api_key
        }

        sshConnection = {
          host       = var.truenas_host
          port       = 22
          username   = "root"
          privateKey = var.truenas_ssh_private_key
        }

        zfs = {
          datasetParentName                  = "main/iscsi"
          detachedSnapshotsDatasetParentName = "main/iscsi-snaps"
        }

        iscsi = {
          targetPortal = "${var.truenas_host}:3260"
          namePrefix   = "csi-"
          nameSuffix   = ""
          targetGroups = [{
            targetGroupPortalGroup    = 1
            targetGroupInitiatorGroup = 1
            targetGroupAuthType       = "None"
          }]
          extentInsecureTpc              = true
          extentXenCompat                = false
          extentDisablePhysicalBlocksize = true
          extentBlocksize                = 512
          extentRpm                      = "SSD"
          extentAvailThreshold           = 0
        }
      }
    }
  })]
}
