output "deployment_name" {
  value = kubernetes_deployment.app.metadata[0].name
}

output "url" {
  value = "https://${var.host}.viktorbarzin.me"
}
