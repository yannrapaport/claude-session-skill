#!/usr/bin/env bash
# tests/test_encode_path.sh — sourced by run_tests.sh

echo "--- test_encode_path ---"

assert_eq "simple home path" \
  "-home-yrapaport-projects-foo" \
  "$(session-encode-path /home/yrapaport/projects/foo)"

assert_eq "mac path with dashes" \
  "-Users-yann-projects-my-project" \
  "$(session-encode-path /Users/yann/projects/my-project)"

assert_eq "path with underscores becomes dashes" \
  "-home-yrapaport-projects--archive" \
  "$(session-encode-path /home/yrapaport/projects/_archive)"
