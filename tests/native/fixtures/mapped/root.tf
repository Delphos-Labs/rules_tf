module "parent" {
  source = "./parent"
}
output "answer" {
  value = module.parent.answer
}
output "text" {
  value = trimspace(file("${path.module}/data/value.txt"))
}
