run "locked_answer" {
  command = plan
  assert {
    condition     = output.answer == 7
    error_message = "NATIVE_LOCKED_ANSWER_MISMATCH"
  }
}
