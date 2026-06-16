#!/usr/bin/env bash
# tests/test_registry_v2.sh — sourced by run_tests.sh
echo "--- test_registry_v2 ---"

TMP=$(mktemp -d); export HUB_DIR_OVERRIDE="$TMP"

# set writes into machines.<machine>.<sid>
session-registry-set "sid-1" "nexus" "projects/foo" "/home/yann/projects/foo"
RAW=$(cat "$TMP/registry.json")
VER=$(echo "$RAW" | python3 -c "import json,sys;print(json.load(sys.stdin)['version'])")
MACH=$(echo "$RAW" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines']['nexus']['sid-1']['project_relative'])")
CWD=$(echo "$RAW" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines']['nexus']['sid-1']['cwd'])")
assert_eq "registry v2 version" "2" "$VER"
assert_eq "registry v2 project_relative" "projects/foo" "$MACH"
assert_eq "registry v2 cwd" "/home/yann/projects/foo" "$CWD"

# get finds a session across machines, returns owner+entry merged
GOT=$(session-registry-get "sid-1")
OWNER=$(echo "$GOT" | python3 -c "import json,sys;print(json.load(sys.stdin)['machine'])")
assert_eq "registry get reports owner machine" "nexus" "$OWNER"

# get on missing returns {}
assert_eq "registry get missing" "{}" "$(session-registry-get nope)"

# set preserves an existing 'archived' status on re-upsert
python3 - "$TMP/registry.json" << 'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d['machines']['nexus']['sid-1']['status']='archived'
json.dump(d,open(p,'w'))
PY
session-registry-set "sid-1" "nexus" "projects/foo" "/home/yann/projects/foo"
ST=$(cat "$TMP/registry.json" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines']['nexus']['sid-1']['status'])")
assert_eq "registry set preserves archived status" "archived" "$ST"

# set preserves an existing 'subject' on re-upsert (when subject arg is empty)
session-registry-set "sid-2" "mac" "projects/bar" "/Users/y/projects/bar" "my subject"
session-registry-set "sid-2" "mac" "projects/bar" "/Users/y/projects/bar"
SUBJ=$(cat "$TMP/registry.json" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines']['mac']['sid-2']['subject'])")
assert_eq "registry set preserves subject" "my subject" "$SUBJ"

rm -rf "$TMP"; unset HUB_DIR_OVERRIDE
