module "middle" {
  source = "../middle"
}
output "answer" {
  value = module.middle.answer
}
