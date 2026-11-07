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

# The secret id is interpolated into a URL inside a command that runs on the
# instance as root. A slash would silently address a different resource; a
# quote or a semicolon would be worse.
run "rejects_a_secret_id_that_is_really_a_path" {
  command = plan

  variables {
    license_secret_id = "projects/example-project/secrets/dss-license"
  }

  expect_failures = [var.license_secret_id]
}

run "rejects_a_secret_id_carrying_shell_syntax" {
  command = plan

  variables {
    license_secret_id = "dss-license; id"
  }

  expect_failures = [var.license_secret_id]
}

run "accepts_a_plain_secret_id" {
  command = plan

  variables {
    license_secret_id = "dss-license"
  }
}

# A service account id is stricter than an instance name: six characters
# minimum, where an instance and a firewall rule are both happy with three.
# GCP rejects a bad one partway through an apply, with the instance already
# created, so the module checks it at plan time instead.
run "rejects_a_name_that_cannot_be_a_service_account_id" {
  command = plan

  variables {
    name              = "dss"
    license_secret_id = "dss-license"
  }

  expect_failures = [google_service_account.dss]
}

# The same name is fine when the caller supplies the account, since then
# nothing is created from it.
run "a_name_only_fit_for_an_instance_is_fine_with_an_account_of_your_own" {
  command = plan

  variables {
    name                  = "dss"
    license_secret_id     = "dss-license"
    service_account_email = "dss@example-project.iam.gserviceaccount.com"
  }
}
