output "answer" {
  value = file("${path.module}/undeclared.txt")
}
