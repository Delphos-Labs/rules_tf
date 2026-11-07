run "false_answer" {
  command = plan
  assert {
    condition     = output.answer == 0
    error_message = "NATIVE_EXPECTED_FAILURE"
  }
}
