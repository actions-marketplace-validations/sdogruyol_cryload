#!/usr/bin/env sh
# Maps the ref a workflow pinned the action to (github.action_ref) to the
# release tag whose binary scripts/install.sh should install:
#
#   explicit `version` input   -> that tag, verbatim (highest precedence)
#   v5.1.0 / 5.1.0 / v5.2.0-rc.1 -> that exact tag (reproducible)
#   v5 / v5.1 / branch / SHA / empty -> latest release (printed as empty;
#                                       install.sh treats empty VERSION as
#                                       "latest")
#
# Kept as a standalone script so the mapping is unit-testable without the
# Actions runtime — see test-resolve-version.sh.
#
# Usage: resolve-version.sh <explicit-version> <action-ref>
set -eu

explicit="${1-}"
ref="${2-}"

if [ -n "$explicit" ]; then
  printf '%s\n' "$explicit"
  exit 0
fi

# Exact release tags carry all three semver components (optionally with a
# prerelease and/or build suffix, e.g. v5.2.0-rc.1+build.5); moving refs
# like v5 or v5.1 do not.
if printf '%s' "$ref" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'; then
  printf '%s\n' "$ref"
  exit 0
fi

if [ -n "$ref" ]; then
  echo "cryload-action: ref '${ref}' is not an exact release tag; installing the latest release. Pin 'uses: <owner>/cryload@vX.Y.Z' for reproducible runs." >&2
fi
