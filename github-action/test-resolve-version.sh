#!/usr/bin/env sh
# Table-driven tests for resolve-version.sh. Run from anywhere:
#   sh github-action/test-resolve-version.sh
set -eu

script="$(dirname "$0")/resolve-version.sh"
fails=0

check() {
  desc="$1"
  explicit="$2"
  ref="$3"
  want="$4"
  got="$(sh "$script" "$explicit" "$ref" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    echo "ok: ${desc}"
  else
    echo "FAIL: ${desc} (want '${want}', got '${got}')" >&2
    fails=$((fails + 1))
  fi
}

#     description                              explicit   ref                                          expected
check "exact tag"                              ""         "v5.1.0"                                     "v5.1.0"
check "exact tag without v prefix"             ""         "5.1.0"                                      "5.1.0"
check "prerelease tag"                         ""         "v5.2.0-rc.1"                                "v5.2.0-rc.1"
check "prerelease tag with build metadata"     ""         "v5.2.0-rc.1+build.5"                        "v5.2.0-rc.1+build.5"
check "moving major tag falls back to latest"  ""         "v5"                                         ""
check "major.minor falls back to latest"       ""         "v5.1"                                       ""
check "branch falls back to latest"            ""         "master"                                     ""
check "commit SHA falls back to latest"        ""         "0123456789abcdef0123456789abcdef01234567"   ""
check "empty ref falls back to latest"         ""         ""                                           ""
check "explicit version wins over ref"         "v5.0.0"   "v5.1.0"                                     "v5.0.0"
check "explicit version wins over branch ref"  "5.0.0"    "master"                                     "5.0.0"

if [ "$fails" -ne 0 ]; then
  echo "${fails} test(s) failed" >&2
  exit 1
fi
echo "all resolve-version tests passed"
