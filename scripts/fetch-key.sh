#!/usr/bin/env bash
# Read the admin API key the bootstrap wrote at boot, save it to .apikey, and
# prove it authenticates.
#
# This does both halves in one go. Getting onto the host is the hard part on
# GCP: the instance has no SSH rule, so the only route in is IAP TCP
# forwarding (enable_iap_ssh), and the key file is root owned and mode 0600,
# so reading it needs sudo, which under OS Login means
# roles/compute.osAdminLogin rather than roles/compute.osLogin.
#
#   ./fetch-key.sh
#
# Run it from your root configuration, the directory holding terraform.tfvars
# and the state. .apikey is written to the directory you run it from.
#
# Optional environment, each falling back as described:
#   PROJECT_ID     GCP project. Else project_id in terraform.tfvars, else the
#                  "project" terraform output, else gcloud config.
#   ZONE           Else the zone in terraform.tfvars, else the "zone"
#                  terraform output, else gcloud config.
#   INSTANCE_NAME  Else the instance_name terraform output.
#   DSS_URL        Else the dss_url terraform output.
#   KEY_PATH       Else the api_key_path terraform output, else
#                  /var/lib/dataiku-terraform-key.json.
#   TF_DIR         Directory holding the Terraform configuration. Default is
#                  the current directory.
#
# Terraform outputs are those of the configuration you run this from. If you
# call the module as module "dss", re-export what you need at the root, for
# example instance_name = module.dss.instance_name.
set -euo pipefail

# No MSYS_NO_PATHCONV here, and that is deliberate. It was set, with a comment
# reasoning that gcloud is a native Windows binary and would mangle the remote
# path. Both halves of that were wrong.
#
# gcloud on Windows is a bash wrapper that works out its own library path and
# hands it to a native python. It NEEDS Git Bash path conversion to do that.
# With the conversion switched off, every call died with
#
#   python3.13.exe: can't open file 'C:\c\Users\...\lib\gcloud.py'
#
# and the script reported it as "cannot reach the host yet", which blamed the
# instance for a problem on this machine.
#
# The remote path needs no protection either: it is passed inside the longer
# string "sudo cat /var/lib/...", and Git Bash only rewrites an argument that
# begins with a slash.
#
# The opposite is true of the AWS CLI, which is a real native binary: there
# the guard is required, and in save-license.sh it is set on the one aws call
# that passes a leading-slash argument rather than exported for the script.

TF_DIR="${TF_DIR:-.}"

# Quiet on failure: no state, no outputs, or no terraform at all all mean the
# same thing here, which is "ask something else". Outputs the module declares
# null (api_key_path without enable_iap_ssh) land here too.
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }

# Read a quoted string assignment from terraform.tfvars, if there is one.
tfvar() {
  [ -f "$TF_DIR/terraform.tfvars" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    "$TF_DIR/terraform.tfvars" | head -1
}

# Anything read from terraform output is checked against the shape of what it
# should be. "terraform output -raw" prints a warning on stdout when there are
# no outputs, and an unchecked warning becomes a project name.
PROJECT="${PROJECT_ID:-}"
[ -n "$PROJECT" ] || PROJECT="$(tfvar project_id)"
[ -n "$PROJECT" ] || PROJECT="$(tf_out project)"
[ -n "$PROJECT" ] || PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
printf '%s' "$PROJECT" | grep -qE '^[a-z][-a-z0-9]{4,28}[a-z0-9]$' || {
  echo "no project: set PROJECT_ID, put project_id in terraform.tfvars, or gcloud config set project" >&2
  exit 1
}

ZONE="${ZONE:-}"
[ -n "$ZONE" ] || ZONE="$(tfvar zone)"
[ -n "$ZONE" ] || ZONE="$(tf_out zone)"
[ -n "$ZONE" ] || ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"
printf '%s' "$ZONE" | grep -qE '^[a-z]+-[a-z]+[0-9]+-[a-z]$' || {
  echo "no zone: set ZONE, put zone in terraform.tfvars, or gcloud config set compute/zone" >&2
  exit 1
}

INSTANCE="${INSTANCE_NAME:-$(tf_out instance_name)}"
printf '%s' "$INSTANCE" | grep -qE '^[a-z]([-a-z0-9]*[a-z0-9])?$' || {
  echo "no instance: set INSTANCE_NAME, or expose an instance_name output" >&2
  exit 1
}

HOST="${DSS_URL:-$(tf_out dss_url)}"
case "$HOST" in
  http://*|https://*) : ;;
  *) echo "no DSS address: set DSS_URL, or expose a dss_url output" >&2; exit 1 ;;
esac

KEYPATH="${KEY_PATH:-$(tf_out api_key_path)}"
case "$KEYPATH" in
  /*) : ;;
  *) KEYPATH=/var/lib/dataiku-terraform-key.json ;;
esac

echo "instance: $INSTANCE ($PROJECT, $ZONE)"
echo "reading:  $KEYPATH"

# DSS answers on its port before the bootstrap has written the key: it waits
# for the backend to accept dsscli first, which is a good half minute later.
# Waiting for the file on the host is the condition that matters, so the
# remote command does the waiting rather than this script guessing a delay.
# Ten minutes of patience on the host, which also covers the installer still
# downloading when you run this.
REMOTE="for i in \$(seq 1 120); do sudo test -s $KEYPATH && break; sleep 5; done; sudo cat $KEYPATH"

# The tunnel and sshd are not ready the instant the instance exists, and the
# first connection also generates an SSH key and propagates an OS Login
# profile. So the connection itself gets retried, separately from the wait
# that happens on the host once connected.
ERR="$(dirname "$0")/.fetch-key.err"
trap 'rm -f "$ERR"' EXIT
OUT=""
for attempt in $(seq 1 10); do
  if OUT="$(gcloud compute ssh "$INSTANCE" \
      --project "$PROJECT" \
      --zone "$ZONE" \
      --tunnel-through-iap \
      --quiet \
      --command "$REMOTE" 2>"$ERR")"; then
    break
  fi
  echo "attempt $attempt: cannot reach the host yet"
  tail -n 2 "$ERR" >&2 || true
  OUT=""
  sleep 15
done
[ -n "$OUT" ] || {
  echo "could not read the key over IAP. Full error:" >&2
  cat "$ERR" >&2
  echo "Check: enable_iap_ssh on the module, roles/iap.tunnelResourceAccessor and roles/compute.osAdminLogin on you, and that the instance has finished booting." >&2
  exit 1
}

PY=""
for candidate in python3 python; do
  if "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
[ -n "$PY" ] || { echo "python3 is needed to extract the key" >&2; exit 1; }

printf '%s' "$OUT" | "$PY" -c '
import json, re, sys
raw = sys.stdin.read()
key = None
# The bootstrap writes dsscli output, which is JSON with a "key" field. Fall
# back to a pattern match, because the remote shell can prepend banners and
# gcloud can append its own lines.
try:
    for candidate in re.findall(r"\{.*?\}", raw, re.S):
        doc = json.loads(candidate)
        if isinstance(doc, dict) and doc.get("key"):
            key = doc["key"]
            break
except Exception:
    pass
if not key:
    m = re.search(r"dkuaps-[A-Za-z0-9]+", raw)
    key = m.group(0) if m else None
if not key:
    sys.exit("no DSS key in the output; the bootstrap may not have written one yet")
open(".apikey", "w").write(key)
print("wrote .apikey: %d chars, starts %s" % (len(key), key[:7]))
'
chmod 600 .apikey 2>/dev/null || true

# Prove it actually authenticates, rather than assuming. DSS can be mid
# restart right after the install, so this gets a few goes before it counts
# as a failure.
CODE=000
for _ in $(seq 1 12); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -u "$(cat .apikey):" "$HOST/public/api/admin/users/" || echo 000)"
  [ "$CODE" = "200" ] && break
  sleep 10
done
echo "auth check against $HOST: http=$CODE"
[ "$CODE" = "200" ] || {
  echo "the key did not authenticate. If this is 000, your address is probably not in allowed_cidr_blocks any more: curl -4 ifconfig.me" >&2
  exit 1
}
