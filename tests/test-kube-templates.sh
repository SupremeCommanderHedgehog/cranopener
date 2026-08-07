#!/usr/bin/env bash
# Offline structural checks on the kube and opencode templates.
#
# These run without podman, which is the point: CI has no container engine, so
# without this the templates would go unverified until someone played them on a
# Windows host. python3 covers both YAML and JSON rather than adding jq as a
# second prerequisite -- the value of this file is that it runs everywhere.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  printf 'SKIP %s: python3 with PyYAML is not available\n' "${0##*/}"
  exit 0
fi

# --- valid syntax ----------------------------------------------------------
# The template must parse exactly as it ships. An operator playing it by hand
# should get a gateway with empty credentials, not a syntax error -- which is
# why the substitution marker is a comment on a real field, not a bare token.
assert_ok 'gateway.yaml is valid YAML' \
  python3 -c 'import yaml; yaml.safe_load(open("kube/gateway.yaml"))'
assert_ok 'litellm config example is valid YAML' \
  python3 -c 'import yaml; yaml.safe_load(open("kube/litellm/config.example.yaml"))'
assert_ok 'opencode.proxied.json is valid JSON' \
  python3 -c 'import json; json.load(open("kube/opencode/opencode.proxied.json"))'
assert_ok 'opencode.direct.json is valid JSON' \
  python3 -c 'import json; json.load(open("kube/opencode/opencode.direct.json"))'

# --- the manifest shape ----------------------------------------------------
kind=$(python3 -c '
import yaml
print(yaml.safe_load(open("kube/gateway.yaml"))["kind"])
')
assert_eq 'gateway.yaml declares a Pod' 'Pod' "$kind"

ctrs=$(python3 -c '
import yaml
spec = yaml.safe_load(open("kube/gateway.yaml"))["spec"]
print(" ".join(c["name"] for c in spec["containers"]))
')
assert_eq 'the gateway pod holds litellm alone' 'litellm' "$ctrs"

# The launcher polls this container by name. A rename here would leave it
# waiting 90s on a container that never appears.
podname=$(python3 -c '
import yaml
print(yaml.safe_load(open("kube/gateway.yaml"))["metadata"]["name"])
')
assert_eq 'the pod name matches the one the launcher polls' 'cranopener-gateway' "$podname"

# --- readiness must not name a binary the image lacks ----------------------
# The litellm image ships no curl. A probe naming a missing binary never
# reports healthy, so the symptom is a 60s timeout in front of a gateway that
# is running and entirely functional. That cost real time once already.
probe=$(python3 -c '
import yaml
c = yaml.safe_load(open("kube/gateway.yaml"))["spec"]["containers"][0]
print(" ".join(c["livenessProbe"]["exec"]["command"]))
')
assert_ok 'the gateway declares a liveness probe' test -n "$probe"

case "$probe" in
  *curl*) uses_curl=yes ;;
  *)      uses_curl=no  ;;
esac
assert_eq 'the probe does not depend on curl' 'no' "$uses_curl"

# --- the substitution marker must survive ----------------------------------
# The launcher replaces this exact line. Rename or reformat it and the gateway
# starts with no credentials, failing at the provider in a way that reads like
# an auth problem rather than a template one.
assert_ok 'the env substitution marker is present' \
  grep -q '__CRANOPENER_GATEWAY_ENV__' kube/gateway.yaml

envcount=$(python3 -c '
import yaml
c = yaml.safe_load(open("kube/gateway.yaml"))["spec"]["containers"][0]
print(len(c.get("env") or []))
')
assert_eq 'the shipped template carries no env values' '0' "$envcount"

# --- host paths must not be machine-specific -------------------------------
# install.ps1 substitutes these with a VM-side path. A real path here would be
# wrong on every other machine and a disclosure in a public repository.
badpaths=$(python3 -c '
import yaml
vols = yaml.safe_load(open("kube/gateway.yaml"))["spec"]["volumes"]
print(" ".join(v["hostPath"]["path"] for v in vols
               if not v["hostPath"]["path"].startswith("__CRANOPENER_HOME__")))
')
assert_eq 'every hostPath uses the install-time placeholder' '' "$badpaths"

# --- the agent must reach the gateway over the pod -------------------------
# Containers in a pod share one network namespace, so the old separate-stack
# http://litellm:4000 does not resolve at all now. Left stale it surfaces at
# the first prompt of a session and reads like a gateway outage.
baseurl=$(python3 -c '
import json
cfg = json.load(open("kube/opencode/opencode.proxied.json"))
print(cfg["provider"]["cranopener"]["options"]["baseURL"])
')
assert_eq 'the proxied config reaches the gateway on localhost' \
  'http://localhost:4000/v1' "$baseurl"

# --- no real endpoints in a public repository ------------------------------
leaked=$(grep -rEoh '[a-z0-9-]+\.(mil|gov)\b' kube/ scripts/ 2>/dev/null | sort -u | tr '\n' ' ')
assert_eq 'no .mil or .gov hostnames in templates' '' "${leaked% }"

# Backends are PROVIDER_A/B/C on purpose. Which vendor sits behind each slot is
# local configuration -- naming them in a public repository discloses an
# affiliation that cannot be taken back once indexed.
#
# An allowlist rather than a denylist, because a denylist would have to spell
# out the very names it exists to keep out. scripts/ is in scope because the
# launcher now names these variables, not the templates.
unexpected=$(grep -rIohE '\b[A-Z][A-Z0-9_]*_API_KEY\b' kube/ scripts/ 2>/dev/null \
  | sort -u \
  | grep -vE '^(PROVIDER_[ABC]|ANTHROPIC|OPENAI)_API_KEY$' \
  | tr '\n' ' ')
assert_eq 'gateway credentials use generic PROVIDER_* names' '' "${unexpected% }"

# --- the gateway must not double-transform ---------------------------------
# If LiteLLM also injects tool definitions the prompts double and the output
# becomes unparseable, and it presents as a model defect.
afp=$(python3 -c '
import yaml
cfg = yaml.safe_load(open("kube/litellm/config.example.yaml"))
print(cfg.get("litellm_settings", {}).get("add_function_to_prompt"))
')
assert_eq 'gateway leaves prompt-mode tools to the shim' 'False' "$afp"

# --- unattended runs must not block ---------------------------------------
# opencode defaults to asking for confirmation; an autonomous run hangs
# forever on the first prompt.
perm=$(python3 -c '
import json
print(json.load(open("kube/opencode/opencode.proxied.json"))["permission"]["*"])
')
assert_eq 'proxied config allows tools without prompting' 'allow' "$perm"

# --- the spend cap must not be claimed where it is not enforced ------------
# LiteLLM tracks spend in Postgres and this stack provisions none, so the
# budget keys are inert. They belong under litellm_settings regardless -- the
# earlier general_settings placement was silently ignored twice over -- and the
# template must say plainly that they do nothing here.
budget=$(python3 -c '
import yaml
cfg = yaml.safe_load(open("kube/litellm/config.example.yaml"))
print(cfg.get("litellm_settings", {}).get("max_budget"))
')
assert_eq 'budget keys sit under litellm_settings' '50' "$budget"

stray=$(python3 -c '
import yaml
cfg = yaml.safe_load(open("kube/litellm/config.example.yaml"))
gs = cfg.get("general_settings") or {}
print(" ".join(sorted(k for k in gs if "budget" in k)))
')
assert_eq 'no budget keys stranded in general_settings' '' "$stray"

assert_ok 'the template warns the cap is unenforced' \
  grep -q 'NOT enforced' kube/litellm/config.example.yaml

# --- the CA bundle must not be described as optional -----------------------
# SSL_CERT_FILE replaces the default trust store rather than adding to it, so
# telling an operator "an empty file is fine" breaks every upstream TLS call
# and presents as a provider outage.
assert_ok 'nothing advertises an empty CA bundle as acceptable' \
  bash -c '! grep -rq "empty file is fine" kube/ scripts/'

# --- credentials belong to the gateway alone -------------------------------
# The isolation argument for this whole topology is that a command executed by
# the agent has nothing worth stealing in its own container.
agent_keys=$(grep -lE '\b[A-Z][A-Z0-9_]*_API_KEY\b' kube/opencode/* 2>/dev/null | tr '\n' ' ')
assert_eq 'no opencode template carries an API key' '' "${agent_keys% }"

finish
