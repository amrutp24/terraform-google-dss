#!/usr/bin/env bash
# Put the DSS Community licence into Secret Manager, so a rebuild reads it at
# boot instead of asking you to register again.
#
# Where the licence comes from is chosen explicitly, because there is no safe
# default to guess:
#
#   ./save-license.sh --from-instance      # read off a running, registered instance
#   ./save-license.sh --file license.json  # from a file on disk
#   ./save-license.sh --from-aws           # from an AWS SSM parameter
#
# --from-aws exists because the licence carries its own instanceId rather than
# being tied to any host, so one licence works on both clouds. The parameter
# is read from PARAM (default /dss/license, where terraform-aws-dss puts it).
#
# Run it from your root configuration, the directory holding terraform.tfvars
# and the state, so the project and instance can be worked out. It does not
# need to be run from here.
#
# Nothing of the licence is printed. It goes source-to-file-to-secret and
# this reports names, sizes and the resulting version number only. The
# temporary copy is removed on exit however this ends.
#
# If you would rather not have the licence touch this disk at all, do it by
# hand from a shell on an already-registered instance:
#
#   gcloud compute ssh <instance> --zone <zone> --tunnel-through-iap
#   sudo cat <data_dir>/config/license.json      # copy it
#   # then, locally, paste into a file and use --file
#
# Optional environment, each falling back as described:
#   PROJECT_ID     GCP project. Else project_id in terraform.tfvars, else the
#                  "project" terraform output, else gcloud config.
#   SECRET_ID      Secret to write. Default dss-license. Has to match the
#                  license_secret_id you pass the module.
#   TF_DIR         Directory holding the Terraform configuration. Default is
#                  the current directory.
#   INSTANCE_NAME, ZONE, DATA_DIR   Only for --from-instance. Else the
#                  instance_name, zone and data_dir terraform outputs, else
#                  gcloud config for the zone, else the module's data_dir
#                  default.
#   PROFILE, REGION, PARAM          Only for --from-aws. Unset PROFILE and
#                  REGION leave it to the AWS CLI's own resolution.
set -euo pipefail

# Git Bash rewrites any argument that looks like a POSIX path before a native
# Windows program sees it, so "/dss/license" reaches aws.exe as
# "C:/Program Files/Git/dss/license". GetParameter tolerates that and answers
# ParameterNotFound, which hides it.
#
# This is deliberately NOT exported for the whole script. gcloud on Windows is
# a bash wrapper that works out its own library path and hands it to a native
# python, and it needs the conversion to do that: with it switched off,
# gcloud.py is looked for at C:\c\Users\... and nothing runs. So the guard
# goes on the one aws call that passes a leading-slash argument, and nowhere
# else.

SOURCE=""
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      SOURCE="file"
      FILE="${2:-}"
      [ -n "$FILE" ] || { echo "--file needs a path" >&2; exit 2; }
      shift 2 ;;
    --from-aws)
      SOURCE="aws"
      shift ;;
    --from-instance)
      SOURCE="instance"
      shift ;;
    -h|--help)
      sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2 ;;
  esac
done
[ -n "$SOURCE" ] || {
  echo "say where the licence comes from: --from-instance, --file PATH or --from-aws (see --help)" >&2
  exit 2
}

TF_DIR="${TF_DIR:-.}"

# Quiet on failure: no state, no outputs, or no terraform at all all mean the
# same thing here, which is "ask something else".
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }

# Read a quoted string assignment from terraform.tfvars, if there is one.
tfvar() {
  [ -f "$TF_DIR/terraform.tfvars" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    "$TF_DIR/terraform.tfvars" | head -1
}

# Resolution order matters, and the obvious order was wrong. This script has
# to run BEFORE the first apply, because the module grants access to a secret
# that must already exist, so there is no Terraform state and no outputs yet.
# "terraform output -raw project" then prints its "No outputs found" warning
# on stdout and the warning itself becomes the project name.
#
# So: an explicit PROJECT_ID wins, then terraform.tfvars, which is where the
# project actually lives before anything is built, then the terraform output,
# then gcloud's own default. Whatever comes out is checked against the shape
# of a project id, so a warning or an error message can never be mistaken for
# one again.
PROJECT="${PROJECT_ID:-}"

if [ -z "$PROJECT" ]; then
  PROJECT="$(tfvar project_id)"
fi

if [ -z "$PROJECT" ]; then
  PROJECT="$(tf_out project)"
fi

if [ -z "$PROJECT" ]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
fi

case "$PROJECT" in
  [a-z]*) : ;;
  *) PROJECT="" ;;
esac
printf '%s' "$PROJECT" | grep -qE '^[a-z][-a-z0-9]{4,28}[a-z0-9]$' || PROJECT=""
[ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ] || {
  echo "no project: set PROJECT_ID, put project_id in terraform.tfvars, or gcloud config set project" >&2
  exit 1
}

SECRET="${SECRET_ID:-dss-license}"
printf '%s' "$SECRET" | grep -qE '^[A-Za-z0-9_-]+$' || {
  echo "SECRET_ID must be letters, digits, underscore and dash only" >&2
  exit 1
}

echo "project: $PROJECT"
echo "secret:  $SECRET"

# Deliberately not mktemp. On Git Bash mktemp returns /tmp/tmp.XXXX, which a
# native Windows binary resolves against the current drive root and cannot
# open. A file beside this script is a real path to every program involved,
# and it is gitignored.
TMP="$(dirname "$0")/.license.tmp"
trap 'rm -f "$TMP"' EXIT
: > "$TMP"
chmod 600 "$TMP" 2>/dev/null || true

if [ "$SOURCE" = "aws" ]; then
  PARAM="${PARAM:-/dss/license}"
  # Exported rather than passed as flags: the AWS CLI honours both, and an
  # empty bash array expanded under set -u is an error on bash 3.2, which
  # macOS still ships.
  [ -n "${PROFILE:-}" ] && export AWS_PROFILE="$PROFILE"
  [ -n "${REGION:-}" ] && export AWS_DEFAULT_REGION="$REGION"
  echo "reading: ssm $PARAM"
  MSYS_NO_PATHCONV=1 aws ssm get-parameter \
    --name "$PARAM" \
    --with-decryption \
    --query Parameter.Value --output text > "$TMP"
elif [ "$SOURCE" = "instance" ]; then
  INSTANCE="${INSTANCE_NAME:-$(tf_out instance_name)}"
  ZONE="${ZONE:-$(tf_out zone)}"
  [ -n "$ZONE" ] || ZONE="$(tfvar zone)"
  [ -n "$ZONE" ] || ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"
  DATA_DIR="${DATA_DIR:-$(tf_out data_dir)}"
  DATA_DIR="${DATA_DIR:-/data/dataiku/dss_data}"
  printf '%s' "$INSTANCE" | grep -qE '^[a-z]([-a-z0-9]*[a-z0-9])?$' || {
    echo "no instance: set INSTANCE_NAME, or expose an instance_name output" >&2
    exit 1
  }
  printf '%s' "$ZONE" | grep -qE '^[a-z]+-[a-z]+[0-9]+-[a-z]$' || {
    echo "no zone: set ZONE, put zone in terraform.tfvars, or gcloud config set compute/zone" >&2
    exit 1
  }
  echo "reading: $DATA_DIR/config/license.json on $INSTANCE ($ZONE, over IAP)"
  # Needs roles/iap.tunnelResourceAccessor and roles/compute.osAdminLogin: the
  # file is root-owned, so this takes sudo.
  gcloud compute ssh "$INSTANCE" \
    --project "$PROJECT" \
    --zone "$ZONE" \
    --tunnel-through-iap \
    --quiet \
    --command "sudo cat $DATA_DIR/config/license.json" > "$TMP"
else
  echo "reading: $FILE"
  [ -s "$FILE" ] || { echo "$FILE is missing or empty" >&2; exit 1; }
  cat "$FILE" > "$TMP"
fi

# python3 where it exists, python where that is what the platform calls it
# (Git Bash on Windows). The check runs the interpreter rather than looking it
# up, because Windows ships a python3 stub that exists and does nothing.
PY=""
for candidate in python3 python; do
  if "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
[ -n "$PY" ] || { echo "python3 is needed to check the licence" >&2; exit 1; }

# A licence that is not a licence produces an instance that boots healthy and
# unlicensed, which is the failure mode this whole arrangement exists to
# avoid. Check the shape before storing it, not after.
"$PY" - "$TMP" <<'PYEOF'
import json, sys
raw = open(sys.argv[1]).read()
try:
    doc = json.loads(raw)
except Exception:
    sys.exit("what came back is not JSON, so it is not the licence")
expected = {"content", "r1Pub", "r1PubSig", "r1Sig"}
missing = expected - set(doc)
if missing:
    sys.exit("missing expected licence fields: %s" % sorted(missing))
print("licence looks right: %d bytes, keys %s" % (len(raw), sorted(doc)))
PYEOF

# Create the secret on first run, add a version on every run after. The
# instance reads "latest", so adding a version is how the licence rotates.
#
# Automatic replication: this is one trial instance in one region, and a
# user-managed replica list would be a decision with nothing behind it.
if gcloud secrets describe "$SECRET" --project "$PROJECT" >/dev/null 2>&1; then
  echo "secret exists, adding a version"
  gcloud secrets versions add "$SECRET" \
    --project "$PROJECT" \
    --data-file="$TMP" \
    --format="value(name)" | sed 's#.*/#version: #'
else
  echo "secret does not exist, creating it"
  gcloud secrets create "$SECRET" \
    --project "$PROJECT" \
    --replication-policy=automatic \
    --data-file="$TMP" \
    --labels=purpose=dss-license \
    --quiet
  gcloud secrets versions list "$SECRET" \
    --project "$PROJECT" \
    --limit 1 --format="value(name)" | sed 's/^/version: /'
fi

echo "stored. Nothing of the licence was printed, and the temporary copy is gone."
