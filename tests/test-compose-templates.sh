#!/usr/bin/env bash
# Offline structural checks on the compose and opencode templates.
#
# These run without podman, which is the point: the authoring machine has no
# container engine, so without this the templates would go unverified until
# someone tried them on a Windows host. python3 handles both YAML and JSON
# here rather than pulling in jq as a second prerequisite -- the value of
# this file is that it runs everywhere.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  printf 'SKIP %s: python3 with PyYAML is not available\n' "${0##*/}"
  exit 0
fi

# --- valid syntax ----------------------------------------------------------
assert_ok 'compose.yaml is valid YAML' \
  python3 -c 'import yaml; yaml.safe_load(open("compose/compose.yaml"))'
assert_ok 'compose.direct.yaml is valid YAML' \
  python3 -c 'import yaml; yaml.safe_load(open("compose/compose.direct.yaml"))'
assert_ok 'litellm config example is valid YAML' \
  python3 -c 'import yaml; yaml.safe_load(open("compose/litellm/config.example.yaml"))'
assert_ok 'opencode.proxied.json is valid JSON' \
  python3 -c 'import json; json.load(open("compose/opencode/opencode.proxied.json"))'
assert_ok 'opencode.direct.json is valid JSON' \
  python3 -c 'import json; json.load(open("compose/opencode/opencode.direct.json"))'

# --- the bypass must really bypass ----------------------------------------
# An override layered on compose.yaml could never remove litellm. Assert the
# file is standalone in fact, not merely in intent.
services=$(python3 -c '
import yaml
print(" ".join(sorted(yaml.safe_load(open("compose/compose.direct.yaml"))["services"])))
')
assert_eq 'direct stack contains only opencode' 'opencode' "$services"

depends=$(python3 -c '
import yaml
svc = yaml.safe_load(open("compose/compose.direct.yaml"))["services"]["opencode"]
print(",".join(svc.get("depends_on", [])))
')
assert_eq 'direct stack opencode depends on nothing' '' "$depends"

# --- the workspace must not be pinned -------------------------------------
# A relative or absolute path here would silently point every project at one
# directory, and the symptom would be edits landing in the wrong repository.
for f in compose/compose.yaml compose/compose.direct.yaml; do
  ws=$(python3 -c "
import yaml
vols = yaml.safe_load(open('$f'))['services']['opencode']['volumes']
print([v for v in vols if v.endswith(':/workspace')][0])
")
  assert_eq "$f mounts the workspace from a variable" \
    '${CRANOPENER_WORKSPACE}:/workspace' "$ws"
done

# --- no real endpoints in a public repository ------------------------------
# Every host in the templates must be a placeholder or an internal service
# name. A .mil or .gov hostname reaching a public repo is the failure this
# guards against.
leaked=$(grep -rEoh '[a-z0-9-]+\.(mil|gov)\b' compose/ 2>/dev/null | sort -u | tr '\n' ' ')
assert_eq 'no .mil or .gov hostnames in templates' '' "${leaked% }"

# --- the gateway must not double-transform ---------------------------------
# If LiteLLM also injects tool definitions the prompts double and the output
# becomes unparseable, and it presents as a model defect.
afp=$(python3 -c '
import yaml
cfg = yaml.safe_load(open("compose/litellm/config.example.yaml"))
print(cfg.get("litellm_settings", {}).get("add_function_to_prompt"))
')
assert_eq 'gateway leaves prompt-mode tools to the shim' 'False' "$afp"

# --- unattended runs must not block ---------------------------------------
# opencode defaults to asking for confirmation; an autonomous run hangs
# forever on the first prompt.
perm=$(python3 -c '
import json
print(json.load(open("compose/opencode/opencode.proxied.json"))["permission"]["*"])
')
assert_eq 'proxied config allows tools without prompting' 'allow' "$perm"

# --- credentials belong to the gateway alone -------------------------------
# The isolation argument for this whole topology is that a command executed by
# the agent has nothing worth stealing in its own container.
opencode_env=$(python3 -c '
import yaml
env = yaml.safe_load(open("compose/compose.yaml"))["services"]["opencode"]["environment"]
print(" ".join(sorted(k for k in env if k.endswith("_API_KEY"))))
')
assert_eq 'opencode container carries no API keys' '' "$opencode_env"

finish
