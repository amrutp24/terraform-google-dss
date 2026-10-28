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
