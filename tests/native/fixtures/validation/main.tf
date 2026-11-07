resource "null_resource" "invalid" {
  triggers = {
    value = aws_instance.missing.id
  }
}
