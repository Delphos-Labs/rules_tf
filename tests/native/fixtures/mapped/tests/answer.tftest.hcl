run "mapped_closure" {
  command = plan
  assert {
    condition     = output.answer == 7 && output.text == "mapped input"
    error_message = "NATIVE_MAPPED_CLOSURE_MISMATCH"
  }
}
