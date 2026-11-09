run "declared_answer" {
  command = plan
  assert {
    condition     = output.answer == 7
    error_message = "NATIVE_ANSWER_MISMATCH"
  }
}
