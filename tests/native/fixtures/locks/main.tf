terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "3.1.1"
    }
  }
}
resource "null_resource" "declared_provider" {}

output "answer" {
  value = 7
}
