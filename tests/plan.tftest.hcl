# Assertions on the shape of the plan: who can reach DSS, and on what.
#
# The provider is mocked, so the image lookup returns a generated value and
# nothing reaches Google. Everything asserted here comes from configuration
# rather than from the API, which is what makes that safe.
mock_provider "google" {}

variables {
  project_id          = "example-project"
  allowed_cidr_blocks = ["203.0.113.10/32"]
}

# The firewall is the whole security story for this module. A rule that opened
# the port to a range nobody chose would be the worst bug it could have, so
# the source ranges are pinned to exactly what was asked for.
run "only_the_given_ranges_reach_dss" {
  command = plan

  variables {
    allowed_cidr_blocks = ["203.0.113.10/32", "198.51.100.0/24"]
  }

  assert {
    condition     = google_compute_firewall.dss.source_ranges == toset(["203.0.113.10/32", "198.51.100.0/24"])
    error_message = "The DSS rule must admit exactly the ranges given, and nothing else."
  }

  assert {
    condition     = length(one(google_compute_firewall.dss.allow).ports) == 1 && contains(one(google_compute_firewall.dss.allow).ports, "10000")
    error_message = "The rule should open the DSS port."
  }
}

run "the_dss_port_follows_the_variable" {
  command = plan

  variables {
    dss_port = 11000
  }

  assert {
    condition     = length(one(google_compute_firewall.dss.allow).ports) == 1 && contains(one(google_compute_firewall.dss.allow).ports, "11000")
    error_message = "Changing dss_port must move the firewall rule with it, or DSS answers on a port nothing can reach."
  }
}

# SSH is off unless asked for. An instance that quietly accepts SSH from the
# same range as the web interface is a different security posture than the one
# the caller chose.
run "no_ssh_rule_unless_asked_for" {
  command = plan

  assert {
    condition     = length(google_compute_firewall.ssh) == 0
    error_message = "SSH must be closed by default."
  }
}

run "ssh_opens_only_to_the_given_ranges" {
  command = plan

  variables {
    ssh_cidr_blocks = ["203.0.113.10/32"]
  }

  assert {
    condition     = length(google_compute_firewall.ssh) == 1
    error_message = "ssh_cidr_blocks is set and no SSH rule was planned."
  }

  assert {
    condition     = google_compute_firewall.ssh[0].source_ranges == toset(["203.0.113.10/32"])
    error_message = "The SSH rule must admit exactly the ranges given."
  }

  assert {
    condition     = length(one(google_compute_firewall.ssh[0].allow).ports) == 1 && contains(one(google_compute_firewall.ssh[0].allow).ports, "22")
    error_message = "The SSH rule should open port 22."
  }
}

# Both rules target the instance by tag. A rule that targeted nothing would
# apply to every instance in the network, which is the opposite of the intent.
run "the_rules_target_the_instance_and_not_the_network" {
  command = plan

  variables {
    ssh_cidr_blocks = ["203.0.113.10/32"]
  }

  assert {
    condition     = length(google_compute_firewall.dss.target_tags) == 1
    error_message = "The DSS rule must target the instance tag, or it applies to every instance in the network."
  }

  assert {
    condition     = google_compute_firewall.ssh[0].target_tags == google_compute_firewall.dss.target_tags
    error_message = "Both rules should target the same instance."
  }

  assert {
    condition     = google_compute_instance.dss.tags == google_compute_firewall.dss.target_tags
    error_message = "The instance must carry the tag the rules target, or neither rule reaches it."
  }
}

# Dataiku asks for at least 16 GB. An instance too small installs and then
# fails under the first real workload.
run "the_instance_clears_dataikus_memory_floor" {
  command = plan

  assert {
    condition     = google_compute_instance.dss.machine_type == "n2-standard-4"
    error_message = "The default machine type should clear Dataiku's 16 GB floor."
  }
}

# ---------------------------------------------------------------------------
# A licence the instance reads itself, and IAP access
# ---------------------------------------------------------------------------

# The headline promise of both features: asking for neither creates neither.
# A module left alone should plan one firewall rule and an instance, and no
# identity, no grant and no change to how logins are authorised.
run "defaults_create_nothing_extra" {
  command = plan

  assert {
    condition     = length(google_service_account.dss) == 0
    error_message = "A module left at its defaults must create no service account."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.license) == 0
    error_message = "A module left at its defaults must grant no secret access."
  }

  assert {
    condition     = length(google_compute_firewall.iap_ssh) == 0 && length(google_compute_firewall.ssh) == 0
    error_message = "A module left at its defaults must plan only the DSS firewall rule."
  }

  assert {
    condition     = length(google_compute_instance.dss.metadata) == 0
    error_message = "A module left at its defaults must not touch instance metadata, so OS Login stays however the project has it."
  }

  assert {
    condition     = !strcontains(module.bootstrap.install_script, "fetching licence")
    error_message = "With no licence asked for, the startup script must not try to fetch one."
  }
}

# Reading a secret needs an identity, so naming one has to create it. The
# alternative the module deliberately avoids is granting secretAccessor to the
# project's default compute account, which every other instance also runs as.
run "a_licence_secret_creates_a_dedicated_service_account" {
  command = plan

  variables {
    license_secret_id = "dss-license"
  }

  # The provider computes a service account's email, so at plan time it is
  # unknown and anything comparing against it cannot be evaluated. Pinning it
  # here is what lets the two assertions below say something: that the
  # instance and the grant both point at the account the module created,
  # rather than at null or at some other identity.
  override_resource {
    target          = google_service_account.dss[0]
    override_during = plan

    values = {
      email = "dataiku-dss@example-project.iam.gserviceaccount.com"
    }
  }

  assert {
    condition     = length(google_service_account.dss) == 1
    error_message = "Naming a licence secret with no service account of your own must create one."
  }

  assert {
    condition     = google_service_account.dss[0].account_id == "dataiku-dss"
    error_message = "The created account should be named after the instance."
  }

  assert {
    condition     = google_compute_instance.dss.service_account[0].email == google_service_account.dss[0].email
    error_message = "The instance must run as the account that was granted the secret, or the fetch has no credentials."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.license[0].member == "serviceAccount:${google_service_account.dss[0].email}"
    error_message = "The grant must land on the account the instance runs as."
  }
}

# Scoped to the one secret, and to the role that reads it. A project-level
# grant, or a wider role, would make a licence worth more than a licence.
run "the_grant_covers_one_secret_and_nothing_else" {
  command = plan

  variables {
    license_secret_id = "dss-license"
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.license) == 1
    error_message = "Naming a licence secret must grant the instance access to it."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.license[0].secret_id == "dss-license"
    error_message = "The grant must name the secret that was asked for."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.license[0].role == "roles/secretmanager.secretAccessor"
    error_message = "The grant should be secretAccessor: read one version, nothing about managing the secret."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.license[0].project == "example-project"
    error_message = "The grant should be made in the project the module was given."
  }
}

# An account the caller already made is used as it is. Creating one alongside
# it would grant the secret to an identity the instance does not use, which
# fails at boot with a permission error and nothing obviously wrong.
run "a_service_account_of_your_own_is_used_rather_than_a_new_one" {
  command = plan

  variables {
    license_secret_id     = "dss-license"
    service_account_email = "dss@example-project.iam.gserviceaccount.com"
  }

  assert {
    condition     = length(google_service_account.dss) == 0
    error_message = "Passing a service account must not create a second one."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.license[0].member == "serviceAccount:dss@example-project.iam.gserviceaccount.com"
    error_message = "The grant must land on the account that was passed in."
  }

  assert {
    condition     = google_compute_instance.dss.service_account[0].email == "dss@example-project.iam.gserviceaccount.com"
    error_message = "The instance must run as the account that was passed in."
  }
}

# The licence must not travel through Terraform. If it is in the startup
# script it is in state and in instance metadata, which is the whole thing
# this avoids, so the script should carry the command and not a licence.
run "the_licence_is_fetched_on_the_instance_rather_than_rendered" {
  command = plan

  variables {
    license_secret_id = "dss-license"
  }

  assert {
    condition     = strcontains(module.bootstrap.install_script, "secretmanager.googleapis.com/v1/projects/")
    error_message = "The startup script should read the licence from the Secret Manager REST API."
  }

  assert {
    condition     = strcontains(module.bootstrap.install_script, "/versions/latest:access")
    error_message = "The fetch should access the latest version of the secret, so rotating it needs no Terraform change."
  }

  assert {
    condition     = strcontains(module.bootstrap.install_script, "dss-license")
    error_message = "The startup script should name the secret it was given."
  }

  assert {
    condition     = !strcontains(module.bootstrap.install_script, "writing licence")
    error_message = "No licence content should be rendered into the startup script."
  }

  # Not gcloud. It is not a deb in the Ubuntu 24.04 cloud image manifest, and
  # where the GCE image carries it, it carries it as a snap that cannot
  # install components and that may not be seeded when a startup script runs.
  # The AWS sibling shipped the same mistake with the AWS CLI, and the
  # instance came up unlicensed, which looks exactly like success.
  assert {
    condition     = !strcontains(module.bootstrap.install_script, "gcloud secrets versions access")
    error_message = "The fetch must not depend on gcloud, which this image may carry only as a snap."
  }

  # The token comes from the metadata server, which is how the instance
  # authenticates with nothing installed and no credential of its own on disk.
  assert {
    condition     = strcontains(module.bootstrap.install_script, "metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token")
    error_message = "The fetch should get its token from the metadata server."
  }

  assert {
    condition     = strcontains(module.bootstrap.install_script, "Metadata-Flavor")
    error_message = "The metadata server refuses a token request without the Metadata-Flavor header."
  }

  # The project and secret id arrive as argv, so the Python body needs no
  # quoting of its own and a secret id cannot terminate a string literal.
  assert {
    condition     = strcontains(module.bootstrap.install_script, "sys.argv[2]")
    error_message = "The secret id should be passed as an argument rather than interpolated into the Python."
  }

  # One command: the bootstrap wraps this in "if <command> > file 2> log", so
  # anything that is really two commands would redirect only the second.
  assert {
    condition = length([
      for line in split("\n", module.bootstrap.install_script) :
      line if strcontains(line, "python3 -c") && strcontains(line, "dss-license")
    ]) == 1
    error_message = "The fetch must be a single command on a single line."
  }
}

# IAP needs no identity on the instance: who may connect is IAM on the human,
# not on the host. So asking for a shell must not quietly grant a secret read.
run "iap_access_grants_the_instance_nothing" {
  command = plan

  variables {
    enable_iap_ssh = true
  }

  assert {
    condition     = length(google_service_account.dss) == 0
    error_message = "IAP access needs no service account, so it must not create one."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.license) == 0
    error_message = "A shell on the host must not come with access to any secret."
  }
}

# The point of IAP over an SSH rule of your own: the only range admitted is
# Google's forwarding range, so no address of yours appears in a firewall rule
# and the instance needs no public address at all.
run "iap_opens_ssh_only_to_googles_forwarding_range" {
  command = plan

  variables {
    enable_iap_ssh = true
  }

  assert {
    condition     = length(google_compute_firewall.iap_ssh) == 1
    error_message = "enable_iap_ssh is set and no firewall rule was planned, so the tunnel would connect to nothing."
  }

  assert {
    condition     = google_compute_firewall.iap_ssh[0].source_ranges == toset(["35.235.240.0/20"])
    error_message = "The IAP rule must admit exactly Google's forwarding range, and nothing else."
  }

  assert {
    condition     = length(one(google_compute_firewall.iap_ssh[0].allow).ports) == 1 && contains(one(google_compute_firewall.iap_ssh[0].allow).ports, "22")
    error_message = "The IAP rule should open port 22 only."
  }

  assert {
    condition     = google_compute_firewall.iap_ssh[0].target_tags == google_compute_instance.dss.tags
    error_message = "The IAP rule must target the instance tag, or it applies to every instance in the network."
  }

  # With OS Login on, who gets a shell is an IAM question rather than a
  # question of whose key reached instance metadata. That is what makes this
  # the counterpart of Session Manager rather than a second route to a key.
  assert {
    condition     = google_compute_instance.dss.metadata["enable-oslogin"] == "TRUE"
    error_message = "enable_iap_ssh should turn on OS Login, or access is still governed by keys in metadata."
  }
}

# Both access outputs are null when nothing can reach the host. That is the
# signal the caller needs: without a shell, the API key the bootstrap writes
# at boot is unreachable and the dataiku provider cannot be pointed anywhere.
run "the_access_outputs_are_null_when_nothing_can_reach_the_host" {
  command = plan

  assert {
    condition     = output.session_command == null
    error_message = "With no way in, session_command must be null rather than a command that cannot work."
  }

  assert {
    condition     = output.api_key_path == null
    error_message = "With no way in, api_key_path must be null: the file exists and nothing can read it."
  }

  assert {
    condition     = output.service_account_email == null
    error_message = "With no account of your own and no licence secret the instance runs as the project default, and null is how this says so."
  }
}

run "iap_access_reports_how_to_use_it" {
  command = plan

  variables {
    enable_iap_ssh = true
  }

  assert {
    condition     = output.session_command == "gcloud compute ssh dataiku-dss --project example-project --zone europe-west1-b --tunnel-through-iap"
    error_message = "session_command should be a command that works as printed, naming the project and zone the module was given."
  }

  assert {
    condition     = output.api_key_path == "/var/lib/dataiku-terraform-key.json"
    error_message = "With a shell available, api_key_path should report where the bootstrap wrote the key."
  }
}

# An SSH rule of your own reaches the host too, so the key is retrievable
# without IAP and the output has to admit it.
run "an_ssh_rule_of_your_own_also_reaches_the_key" {
  command = plan

  variables {
    ssh_cidr_blocks = ["203.0.113.10/32"]
  }

  assert {
    condition     = output.api_key_path == "/var/lib/dataiku-terraform-key.json"
    error_message = "ssh_cidr_blocks is a way onto the host, so api_key_path should not be null."
  }

  assert {
    condition     = output.session_command == null
    error_message = "session_command describes the IAP tunnel only, so it stays null when IAP was not asked for."
  }
}
