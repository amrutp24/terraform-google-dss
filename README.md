# terraform-google-dss

Runs [Dataiku DSS](https://www.dataiku.com/) on a Compute Engine instance.

The module creates firewall rules and an instance, and installs DSS through a
startup script: download, install, apply a licence, register the boot service,
and optionally mint the API key needed to configure the instance afterwards.

```hcl
module "dss" {
  source  = "amrutp24/dss/google"
  version = "~> 0.1"

  project_id          = "my-project"
  allowed_cidr_blocks = ["203.0.113.0/24"]
  license_json        = var.dss_license_json
}

output "dss_url" {
  value = module.dss.dss_url
}
```

DSS answers on `module.dss.dss_url` once it has finished installing. Allow
several minutes on first boot — the installer downloads about two gigabytes and
then builds a Python environment. Until that finishes the port simply does not
answer. Watch progress in the instance's serial console output.

## Configuring the instance is a second apply

This module gets you a running DSS. Creating projects, groups, connections and
code environments inside it is done with the
[`dataiku` provider](https://registry.terraform.io/providers/amrutp24/dataiku/latest),
and it has to be a **separate root configuration**.

Terraform resolves provider configuration during *planning*, before any resource
exists. A configuration that creates this instance and then points the `dataiku`
provider at it would need the instance's address and an API key before creating
anything. It deadlocks. No module structure avoids that.

So: apply this, wait for DSS to answer, then apply a second configuration that
reads this one's outputs.

That split is worth having anyway. You can rebuild the instance without touching
its configuration, and change configuration without risking the instance.

## Getting the API key out

The `dataiku` provider needs an API key, and a brand-new DSS has no way to
produce one without a browser. With `create_api_key` left on, the bootstrap runs
`dsscli api-key-create` and writes the result to `api_key_path`, mode 0600.

Moving it off the instance is the part this module deliberately leaves to you.

Secret Manager is the cleanest of these: give the instance's service account
`secretmanager.secretAccessor`, push the key from the startup script, and read it
back with `google_secret_manager_secret_version`, so nothing sensitive passes
through Terraform state. Fetching the file over SSH or IAP with an `external`
data source works too.

Or skip it entirely. Set `create_api_key = false` and create a global API key
under Administration → Security once DSS is up.

## Networking

Firewall rules target the instance by network tag rather than opening a port
across the network, so they cannot accidentally expose something else. The tag
is derived from `name`.

Setting `assign_public_ip = false` leaves the instance without an external
address, which is the right answer for anything lasting — reach it over IAP or a
VPN, and give it Cloud NAT so the installer can still fetch its two gigabytes.

## Limits

The data directory sits on the boot disk, which keeps the module small and means
replacing the instance loses every project. Attach a persistent disk and mount it
at `data_dir` if you want it to survive a rebuild.

There is no load balancer, TLS or DNS. DSS answers directly on its port over
plain HTTP, so put it behind a load balancer with a managed certificate before
anyone types a password into it.

Leaving `service_account_email` null falls back to the project's default compute
account with `cloud-platform` scope, which is far broader than this needs. Give
it a dedicated account.

Nothing replaces a broken node either: no managed instance group, no health
check. DSS is stateful and does not cluster this way, so recovery means
restoring the data directory from a backup you took yourself.

It also costs money. DSS drops into a low-memory mode below roughly 16 GB and
says so in its logs, which is why the default is `n2-standard-4` — that bills for
as long as it exists. Destroy it when you are done.

## Licensing DSS

The `dataiku` provider talks to the DSS public REST API, which the Free Edition
does not licence on its own — though the Enterprise trial bundled with it does,
while that trial lasts. Pass a licence at install time with `license_json`, or
register the instance through its web interface on first visit.

`license_json` reaches instance metadata and Terraform state, so supply it from
a secret store rather than a file in your repository.

## Security defaults

`allowed_cidr_blocks` has **no default and refuses `0.0.0.0/0`**. DSS holds your
data, and its login page should not become reachable from the whole internet
because a variable had a convenient default. Edit the validation if you
genuinely mean it.

No SSH rule is created unless you set `ssh_cidr_blocks`. Shielded VM features —
secure boot, vTPM, integrity monitoring — are on.

## License

Mozilla Public License 2.0.
