run "custom_directory" {
  command = plan
  module {
    source = "./checks/helper"
  }
  assert {
    condition     = output.answer == 7
    error_message = "NATIVE_CUSTOM_DIRECTORY_MISMATCH"
  }
}
