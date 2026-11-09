# Getting a licence onto the instance

DSS will install and run without a licence, but a fresh instance asks whoever
opens it first to register Free Edition: a form wanting a first name, a last
name and an email address. Until somebody fills that in, the instance
licenses only the `NONE` user profile, which means the dataiku provider cannot
create a usable user and `terraform apply` on a configuration that creates
one will fail.

That makes a rebuild a manual job, which is the thing worth fixing if you
destroy and recreate often.

One clarification first, because it is easy to expect too much: none of this
removes the DSS **login page**. DSS is an application with user accounts and
always asks for credentials, `admin` / `admin` on a fresh install. What the
options below remove is the **registration form**.

## Option A: store the licence, let the instance read it

This is what `license_secret_id` is for. Register once, keep the licence in
Secret Manager, and every instance after that reads it at boot and installs it
before DSS finishes starting.

1. Bring up an instance and register Free Edition in the browser, once. The
   instance needs `enable_iap_ssh = true` for the next step to reach it.
2. Copy the licence into Secret Manager while that instance is still up. Run
   this from your root configuration, where `terraform.tfvars` and the state
   are:

   ```
   ./scripts/save-license.sh --from-instance
   ```

   It reads the licence off the host over IAP, checks it looks like a
   licence, and stores it as a new version of the secret, creating the secret
   if it is not there. It prints nothing of the licence: it goes from the
   instance to Secret Manager through a temporary file that is removed on
   exit. It needs the `secretmanager.googleapis.com` API enabled in the
   project and permission to create secrets.

   Already have a licence file? `--file license.json` does the same from
   disk, and `--from-aws` copies one out of an AWS SSM parameter, since a
   licence is not tied to a cloud.

3. Name the secret in your module call:

   ```hcl
   module "dss" {
     source  = "amrutp24/dss/google"
     version = "~> 0.3"

     license_secret_id = "dss-license"
     # ...
   }
   ```

   `dss-license` is the script's default. Use another name with `SECRET_ID`,
   and pass the same one here.

The script works before the first apply, which matters: the module grants the
instance access to a secret that has to exist already, so the secret comes
first and there is no state or output to read the project from yet. It takes
it from `project_id` in `terraform.tfvars`.

From then on `terraform apply` produces a licensed instance with no browser
step. The boot log says so:

```
[dss-bootstrap] fetching licence
[dss-bootstrap] licence fetched
[+] Installing license file
```

Things worth knowing about how this works:

- **The licence is portable.** Its `instanceId` is generated during
  registration and travels inside the signed licence rather than being
  derived from the hardware, so the same licence works on a machine that did
  not exist when it was issued. That is what makes storing it viable at all.
- **The instance reads the secret itself**, using its own service account,
  which is why naming one creates a service account when you did not pass
  `service_account_email`. The grant is
  `roles/secretmanager.secretAccessor` on that one secret. Only the project
  and the secret id reach Terraform state and instance metadata; the licence
  does not.
- **The version read is `latest`**, so adding a version rotates the licence
  for the next instance without a Terraform change.
- **The fetch uses python3 and the metadata server, not gcloud.** gcloud is
  not guaranteed to be on the image. The AWS module shelled out to the AWS
  CLI, Ubuntu 24.04 has no awscli package in any component, and the fetch
  failed in a way indistinguishable from success: a healthy instance that was
  simply unlicensed. The metadata server issues a bearer token and Secret
  Manager has a REST API, so python3 and curl are enough and neither needs
  installing.
- **It needs egress to `secretmanager.googleapis.com`.** With
  `assign_public_ip = false` that means Cloud NAT or Private Google Access,
  which the installer's two-gigabyte download needs anyway.

`license_json` does the same job in one step and is simpler, but it is
rendered into the boot script, so the licence ends up in Terraform state and
in instance metadata where anyone who can read the instance can read it back.
Prefer the secret.

## Reaching the host

Both scripts, and anything else that needs a shell, go through IAP TCP
forwarding. `enable_iap_ssh = true` opens the IAP range for SSH and turns on
OS Login, so you need no key pair, no public address and no address of yours
in a firewall rule. The module does not grant the two roles the person
connecting needs, because it does not know who that is:
`roles/iap.tunnelResourceAccessor` and `roles/compute.osAdminLogin`. The
second is the admin one because the licence and the key are root-owned, so
reading them takes `sudo`.

IAP TCP forwarding does **not** require `iap.googleapis.com` to be enabled.
That API is only needed if you want to scope tunnel access per instance.

## Option B: let the instance register itself

Not implemented here, and described so you can decide against it knowingly.

Selecting Free Edition in the browser sends one unauthenticated request:

```
POST /api/registration/initial-register-community
  userFirstName, userLastName, userEmail, instanceId
```

Dataiku answers with a signed licence and DSS writes it to
`<data_dir>/config/license.json`. A step in the bootstrap could do the same
with `curl` after the backend comes up, and then there is no licence to store
anywhere.

The reasons this module does not do that:

- It accepts Dataiku's Free Edition terms as a side effect of a boot, on
  every rebuild, rather than once deliberately.
- The name and email have to reach the boot script, which puts them in
  instance metadata.
- It depends on an undocumented endpoint at boot. If that changes, instances
  come up unlicensed and the reason is several layers down in a startup log.

## Reading the admin API key

Separate from licensing, and needed either way. The bootstrap creates an
admin API key at boot and writes it to the path the `api_key_path` output
reports, which is null unless `enable_iap_ssh` is on or `ssh_cidr_blocks` is
set. Getting it off the host means a shell on the host, so:

```
./scripts/fetch-key.sh
```

It connects over IAP, waits for the file to exist, since DSS answers on its
port about half a minute before the key is written, writes the key to
`.apikey` in the current directory, and checks that it authenticates before
exiting.

## Script options

Both scripts take the same optional environment variables, and each falls
back to something sensible when unset:

| Variable | Meaning |
| --- | --- |
| `PROJECT_ID` | GCP project. Unset reads `project_id` from `terraform.tfvars`, then a `project` output, then `gcloud config`. |
| `ZONE` | Zone of the instance. Unset reads `zone` from `terraform.tfvars`, then a `zone` output, then `gcloud config`. |
| `INSTANCE_NAME` | Instance name. Unset reads the `instance_name` output. |
| `TF_DIR` | Directory holding the Terraform configuration. Unset is the current directory. |

The outputs are those of the configuration you run the scripts from. If you
call the module as `module "dss"`, re-export what they read at the root, for
example `instance_name = module.dss.instance_name`.

`save-license.sh` also takes `SECRET_ID` (default `dss-license`), which has to
match the `license_secret_id` you pass the module, `DATA_DIR` if you changed
the module's `data_dir`, and for `--from-aws` the `PROFILE`, `REGION` and
`PARAM` (default `/dss/license`) of the AWS side.

`fetch-key.sh` also takes `DSS_URL` (default the `dss_url` output) and
`KEY_PATH` (default the `api_key_path` output).
