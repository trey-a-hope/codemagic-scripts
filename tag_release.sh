#!/usr/bin/env bash
# Tags a Codemagic test build in GitHub and creates its pre-release.
#
# Run as the Post-publish script of the Codemagic "Android Test" and
# "iOS Test" workflows:
#
#   bash scripts/tag_release.sh
#
# What it does, after a successful build:
#   1. Reads the version from pubspec.yaml (e.g. 26.11.7+12) and names the
#      tag v<versionName>+<versionCode> (e.g. v26.11.7+12).
#   2. Creates an annotated tag on $CM_COMMIT, the exact commit built, with
#      the Codemagic build number and workflow in its message.
#   3. Creates a GitHub pre-release for the tag, titled
#      "<versionName> (<versionCode>)", whose body is release_notes.txt at
#      that commit, unchanged. release_notes.txt is the only source of
#      release notes; GitHub's generated notes are never used.
#
# It never fails the build: the build has already reached testers by the
# time it runs, so every problem is printed as a WARNING with what to fix,
# and the script exits 0.
#
# Needs GITHUB_TAG_TOKEN, a fine-grained token for trey-a-hope/scorbord only
# with Contents read and write, stored in Codemagic as a secure variable.
# The token is only ever sent in a request header and never printed.
#
# Environment (Codemagic sets all but the token):
#   GITHUB_TAG_TOKEN      the token above (required)
#   CM_COMMIT             commit that was built (required)
#   CM_BUILD_STEP_STATUS  "success" when the build step passed
#   BUILD_NUMBER          Codemagic build number, for the tag message
#   CM_WORKFLOW_NAME      workflow name, for the tag message (optional)
#   GITHUB_REPOSITORY     owner/repo, default trey-a-hope/scorbord
#   GITHUB_API_URL        default https://api.github.com (tests point it at
#                         a local fake)

set -uo pipefail

REPO="${GITHUB_REPOSITORY:-trey-a-hope/scorbord}"
API="${GITHUB_API_URL:-https://api.github.com}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

warn() { echo "WARNING (build tag): $*" >&2; }
info() { echo "build tag: $*"; }

# Prints a JSON field from stdin, or nothing. Uses python3, which Codemagic's
# macOS machines have.
json_field() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key in sys.argv[1].split("."):
    data = data.get(key) if isinstance(data, dict) else None
print("" if data is None else data)
' "$1"
}

# One GitHub API call. Sets BODY to the response body and STATUS to the HTTP
# status (000 when the request itself failed). It runs in the current shell,
# never in $(...), so both stay set for the caller. The token goes in a
# header read from stdin, so it never shows up in a process list or log.
STATUS=""
BODY=""
gh_api() {
  local method="$1" path="$2" body="${3:-}"
  local out
  out="$(mktemp)"
  local args=(-sS -o "$out" -w '%{http_code}' -X "$method"
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
    -H @-)
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  STATUS="$(printf 'Authorization: Bearer %s\n' "$GITHUB_TAG_TOKEN" |
    curl "${args[@]}" "$API$path" 2>/dev/null)" || STATUS="000"
  BODY="$(cat "$out")"
  rm -f "$out"
}

# A JSON object built from KEY=VALUE pairs, every value a string except the
# literal true/false.
json_object() {
  python3 -c '
import json, sys
obj = {}
for pair in sys.argv[1:]:
    key, value = pair.split("=", 1)
    obj[key] = {"true": True, "false": False}.get(value, value)
print(json.dumps(obj))
' "$@"
}

main() {
  # 1. Only after a successful build.
  if [[ "${CM_BUILD_STEP_STATUS:-}" != "success" ]]; then
    info "build step status is '${CM_BUILD_STEP_STATUS:-unset}', not 'success', so no tag."
    return 0
  fi
  if [[ -z "${GITHUB_TAG_TOKEN:-}" ]]; then
    warn "GITHUB_TAG_TOKEN is not set. Add it in Codemagic (Scorbord app, Environment variables, Secure) and import its group in this workflow. The build itself shipped."
    return 0
  fi
  if [[ -z "${CM_COMMIT:-}" ]]; then
    warn "CM_COMMIT is not set, so the built commit is unknown. No tag."
    return 0
  fi

  # 2. The version from pubspec.yaml: "version: 26.11.6+11".
  local version name code
  version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$ROOT/pubspec.yaml" | head -n 1 | tr -d "\"'")"
  name="${version%%+*}"
  code="${version#*+}"
  if [[ ! "$name" =~ ^[0-9]+(\.[0-9]+)*$ || ! "$code" =~ ^[0-9]+$ ]]; then
    warn "couldn't read 'version: <name>+<code>' from pubspec.yaml (got '$version'). No tag."
    return 0
  fi
  local tag="v$name+$code"
  local ref_path="/repos/$REPO/git/ref/tags/v$name%2B$code"
  info "tagging $CM_COMMIT as $tag"

  # 3. Idempotent: an existing tag on this commit is fine; on another commit
  # it is left alone.
  local existing_sha existing_type
  gh_api GET "$ref_path"
  case "$STATUS" in
    200)
      check_existing_tag "$tag" || return 0
      ;;
    404)
      create_tag "$tag" "$name" "$code"
      case $? in
        0) ;;
        2)
          # The other workflow (Android or iOS) tagged this version first.
          gh_api GET "$ref_path"
          if [[ "$STATUS" != "200" ]]; then
            warn "couldn't re-read $tag after another build created it (HTTP $STATUS)."
            return 0
          fi
          check_existing_tag "$tag" || return 0
          ;;
        *) return 0 ;;
      esac
      ;;
    401|403)
      warn "GitHub refused the token (HTTP $STATUS). It may have expired or lack Contents read and write on $REPO. Renew GITHUB_TAG_TOKEN in Codemagic."
      return 0
      ;;
    *)
      warn "couldn't check for $tag on GitHub (HTTP $STATUS). No tag."
      return 0
      ;;
  esac

  create_release "$tag" "$name" "$code"
  return 0
}

# With BODY holding an existing tag ref, succeeds when the tag points at
# CM_COMMIT, and warns and fails otherwise.
check_existing_tag() {
  local tag="$1" existing_sha existing_type
  existing_sha="$(json_field object.sha <<<"$BODY")"
  existing_type="$(json_field object.type <<<"$BODY")"
  if [[ "$existing_type" == "tag" ]]; then
    # Annotated tag: follow it to the commit it points at.
    gh_api GET "/repos/$REPO/git/tags/$existing_sha"
    if [[ "$STATUS" != "200" ]]; then
      warn "couldn't read the tag object for $tag (HTTP $STATUS), so the pre-release was not checked."
      return 1
    fi
    existing_sha="$(json_field object.sha <<<"$BODY")"
  fi
  if [[ "$existing_sha" != "$CM_COMMIT" ]]; then
    warn "$tag already exists on $existing_sha, not on the built commit $CM_COMMIT. Left it where it is. Bump the version in pubspec.yaml so each build gets its own tag."
    return 1
  fi
  info "$tag already on $CM_COMMIT, keeping it."
}

# Creates the annotated tag object, then the refs/tags ref pointing at it.
# Returns 2 when the ref already exists (another build won the race), 1 on
# any other failure.
create_tag() {
  local tag="$1" name="$2" code="$3"
  local message="Scorbord $name ($code)
Codemagic build ${BUILD_NUMBER:-?}, workflow ${CM_WORKFLOW_NAME:-${FCI_WORKFLOW_NAME:-unknown}}"
  local sha
  gh_api POST "/repos/$REPO/git/tags" "$(json_object \
    "tag=$tag" "message=$message" "object=$CM_COMMIT" "type=commit")"
  if [[ "$STATUS" != "201" ]]; then
    warn "couldn't create tag $tag (HTTP $STATUS): $(json_field message <<<"$BODY"). Check that GITHUB_TAG_TOKEN is valid and has Contents read and write."
    return 1
  fi
  sha="$(json_field sha <<<"$BODY")"
  gh_api POST "/repos/$REPO/git/refs" "$(json_object \
    "ref=refs/tags/$tag" "sha=$sha")"
  if [[ "$STATUS" == "422" ]]; then
    info "$tag was created by another build in the meantime."
    return 2
  fi
  if [[ "$STATUS" != "201" ]]; then
    warn "created the tag object for $tag but couldn't add refs/tags/$tag (HTTP $STATUS)."
    return 1
  fi
  info "created $tag on $CM_COMMIT"
}

# Creates the pre-release from release_notes.txt at the built commit, unless
# one already exists for the tag.
create_release() {
  local tag="$1" name="$2" code="$3"
  local enc_tag="v$name%2B$code"
  gh_api GET "/repos/$REPO/releases/tags/$enc_tag"
  if [[ "$STATUS" == "200" ]]; then
    info "pre-release for $tag already exists, keeping it."
    return 0
  fi

  local notes
  notes="$(git -C "$ROOT" show "$CM_COMMIT:release_notes.txt" 2>/dev/null || true)"
  if [[ -z "${notes//[[:space:]]/}" ]]; then
    warn "release_notes.txt is missing or empty at $CM_COMMIT, so $tag has no pre-release. Add notes and create the release on GitHub by hand if needed."
    return 0
  fi

  gh_api POST "/repos/$REPO/releases" "$(json_object \
    "tag_name=$tag" "name=$name ($code)" "body=$notes" \
    "prerelease=true" "generate_release_notes=false")"
  if [[ "$STATUS" != "201" ]]; then
    warn "tagged $tag but couldn't create its pre-release (HTTP $STATUS): $(json_field message <<<"$BODY")."
    return 0
  fi
  info "created pre-release $(json_field html_url <<<"$BODY")"
}

main
exit 0
