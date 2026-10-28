# The variable validations exist to fail at plan time rather than after an
# instance is already running. These check they fire.
#
# The provider is mocked. This module reads google_compute_image to find the
# current Ubuntu image, which is a real API call, so a plan needs either
# credentials or a mock. A mock keeps the suite runnable on any machine and on
# a runner with nothing configured, and nothing here depends on what the image
# lookup returns.
mock_provider "google" {}

variables {
  project_id          = "example-project"
  allowed_cidr_blocks = ["203.0.113.10/32"]
}

run "accepts_a_valid_configuration" {
  command = plan
}

run "rejects_an_empty_allowed_list" {
  command = plan

  variables {
    allowed_cidr_blocks = []
  }

  expect_failures = [var.allowed_cidr_blocks]
}

run "rejects_opening_dss_to_the_internet" {
  command = plan

  variables {
    allowed_cidr_blocks = ["0.0.0.0/0"]
  }

  expect_failures = [var.allowed_cidr_blocks]
}
