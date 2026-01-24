variable "namespace" {}
variable "password" {}
variable "dockerhub_creds_secret_name" {
  default = "dockerhub-creds"
}
variable "username" {
  default = "viktorbarzin"
}

# DO NOT USE until able to store `stringData`
resource "kubernetes_secret" "dockerhub_creds" {
  metadata {
    name      = var.dockerhub_creds_secret_name
    namespace = var.namespace
  }

  # data is additionally base64 encode, no stringData yet :/ https://github.com/hashicorp/terraform-provider-kubernetes/issues/901
  data = {
    "username" = var.username
    "password" = var.password
  }
  type = "kubernetes.io/basic-auth"
}
