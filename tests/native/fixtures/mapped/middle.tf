module "leaf" {
  source = "../leaf"
}
output "answer" {
  value = module.leaf.answer
}
