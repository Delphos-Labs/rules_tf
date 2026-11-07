run "must_not_execute" {
  command = plan
  assert {
    condition     = output.answer == 0
    error_message = "NATIVE_INIT_DID_NOT_STOP"
  }
}
