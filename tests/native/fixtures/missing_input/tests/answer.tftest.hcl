run "missing_declared_input" {
  command = plan
  assert {
    condition     = output.answer != ""
    error_message = "NATIVE_UNDECLARED_FILE_LEAKED"
  }
}
