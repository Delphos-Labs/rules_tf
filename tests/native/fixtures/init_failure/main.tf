terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "99.0.0"
    }
  }
}
output "answer" {
  value = 7
}
