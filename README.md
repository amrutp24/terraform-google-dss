# terraform-google-dss

Runs [Dataiku DSS](https://www.dataiku.com/) on a Compute Engine instance.

The module creates firewall rules and an instance, then installs DSS through a
startup script: download, install, apply a licence, register the boot service,
and optionally mint the API key needed to configure the instance afterwards.

| Requirement | Version |
| --- | --- |
| Terraform | >= 1.5 |
| `hashicorp/google` | ~> 6.0 |

## Usage

```hcl
provider "google" {
  project = "my-project"
  region  = "europe-west1"
}

module "dss" {
  source  = "amrutp24/dss/google"
  version = "~> 0.1"

  project_id          = "my-project"
  allowed_cidr_blocks = ["203.0.113.0/24"] # replace: your office or VPN range
  license_json        = var.dss_license_json
}

output "dss_url" {
  value = module.dss.dss_url
}
```

`203.0.113.0/24` above is RFC 5737 documentation space and matches nothing real.
Put your own range there.

Enable `compute.googleapis.com` on the project first, plus
`secretmanager.googleapis.com` if you plan to stash the API key there.

## While it installs

`terraform apply` returns in about a minute. DSS does not answer for several
more: the installer pulls down roughly two gigabytes and then builds a Python
environment. Until that finishes the port refuses connections outright, so a
browser shows a connection error rather than a DSS page.

The startup script logs to the journal, which the serial console mirrors:

```bash
gcloud compute instances get-serial-port-output "$(terraform output -raw instance_name)" --zone europe-west1-b
```

Or on the instance itself:

```bash
gcloud compute ssh "$(terraform output -raw instance_name)" \
  --command 'sudo journalctl -u google-startup-scripts.service -f'
```

Every line the bootstrap writes is prefixed `[dss-bootstrap]`, and the last one
is `done`. If it never gets there, that log names the step that failed. DSS
keeps its own logs under `run/` inside the data directory once the installer has
got that far.

## Configuring DSS is a second apply

This module gets you a running instance. Everything inside it (projects, groups,
connections, code environments) belongs to the
[`dataiku` provider](https://registry.terraform.io/providers/amrutp24/dataiku/latest),
which has to live in a **separate root configuration**.

The obstacle is that Terraform builds provider configuration while planning,
before a single resource exists. A configuration that both created this instance
and aimed the `dataiku` provider at it would have to know the address, and hold
an API key from a machine that has not booted, before it could plan at all. That
deadlocks whatever way the modules are arranged.

So apply this, wait for DSS to answer, then apply a second configuration that
reads these outputs:

```hcl
provider "dataiku" {
  host = data.terraform_remote_state.instance.outputs.dss_url
  # api_key from DATAIKU_API_KEY
}
```

The split is worth having on its own merits. It lets you rebuild the instance
without touching its configuration, and change configuration without risking the
instance.

## Getting the API key out

The `dataiku` provider needs an API key, and a brand-new DSS has no way to
produce one without a browser. With `create_api_key` left on, the bootstrap runs
`dsscli api-key-create` and writes the result to `api_key_path`, mode 0600.

It writes an array of one object, not a bare object, so anything reading it
has to index in: `[{"id": ..., "key": ..., "label": "terraform"}]`.

Moving it off the instance is the part this module deliberately leaves to you.
Secret Manager is the cleanest option: give the instance's service account
`secretmanager.secretAccessor`, push the key from the startup script, and read it
back with `google_secret_manager_secret_version`, so nothing sensitive passes
through Terraform state. Fetching the file over SSH or IAP with an `external`
data source works too.

Or skip it. Set `create_api_key = false` and create a global API key under
Administration → Security once DSS is up.

## Outputs

| Output | Use |
| --- | --- |
| `dss_url` | The `dataiku` provider's `host`. |
| `public_ip`, `private_ip` | Instance addresses. |
| `instance_name` | `gcloud compute ssh`, snapshots, anything naming the instance. |
| `data_dir` | Path holding every project. This is what to back up. |

## Networking

Firewall rules target the instance by network tag rather than opening a port
across the network, so they cannot accidentally expose something else. The tag
is derived from `name`.

Setting `assign_public_ip = false` leaves the instance without an external
address, which is the right answer for anything lasting. Reach it over IAP or a
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

Code environments need `python_interpreter` set. The image is Ubuntu 24.04,
which ships Python 3.12 only, while DSS 15 defaults new Python environments to
`python3.9`. Left unset the build fails with `python3.9: command not found`,
and DSS reports the environment as created anyway. Pass `PYTHON312` to
`dataiku_code_env`.

It also costs money. DSS drops into a low-memory mode below roughly 16 GB and
says so in its logs, so the default is `n2-standard-4`, which bills for as long
as it exists. Destroy it when you are done.

## Licensing DSS

The `dataiku` provider talks to the DSS public REST API.

Whether a given instance serves it depends on the version and the licence, so
check rather than assume. A stock DSS 15 Community Edition installed by this
module answered the API with `license_json` unset, and projects, groups, users,
connections and scenarios were all created through it. An older `dataiku/dss` container, by
contrast, refused with `DSS API is not available with your Free Edition
license`.

The check that matters is whether the API answers at all:

```bash
curl -su "$DATAIKU_API_KEY:" "$(terraform output -raw dss_url)/public/api/admin/general-settings/" -o /dev/null -w '%{http_code}'; echo
```

`200` means the provider will work. `401` is a bad key. A licence error names
itself in the body, and then you need a licence with API access.

Pass a licence at install time with `license_json` if you have one, or register
the instance through its web interface on first visit.

`license_json` reaches instance metadata and Terraform state, so supply it from a
secret store rather than a file in your repository.

## Security defaults

`allowed_cidr_blocks` has **no default and refuses `0.0.0.0/0`**. DSS holds your
data, and its login page should not become reachable from the whole internet
because a variable had a convenient default. Edit the validation if you
genuinely mean it.

No SSH rule is created unless you set `ssh_cidr_blocks`. Shielded VM features
(secure boot, vTPM, integrity monitoring) are on.

## License

Mozilla Public License 2.0.
