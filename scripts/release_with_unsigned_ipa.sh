#!/usr/bin/env bash
set -euo pipefail

# Publish repository state + GitHub release with existing unsigned IPA.
#
# Requirements:
#   - git, curl, jq
#   - git auth configured for push to origin
#   - GITHUB_TOKEN with repo write access
#
# Optional env vars:
#   TAG=0.0.3
#   RELEASE_NAME=0.0.3
#   RELEASE_BODY="..."                        # if empty, extracted from CHANGELOG.md
#   RELEASE_NOTES_FILE=CHANGELOG.md
#   IPA_PATH=/absolute/path/to/AiryWay-unsigned.ipa
#   ASSET_NAME=AiryWay-v0.0.3-unsigned.ipa
#   REPO=owner/repo
#   SOURCE_REF=main
#   COMMIT_ALL=true
#   SYNC_COMMIT_MESSAGE="chore(release): 0.0.3"
#   PUSH_FORCE_WITH_LEASE=true
#   REPO_DESCRIPTION="Offline-first iOS chat app powered by local GGUF models via llama.cpp"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd git
need_cmd curl
need_cmd jq

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN is not set." >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "Run this script inside the git repository." >&2
  exit 1
fi
cd "$repo_root"

origin_url="$(git remote get-url origin)"
detected_repo="$(printf '%s' "$origin_url" | sed -E 's#^git@github.com:##; s#^https://([^@/]+@)?github.com/##; s#\.git$##')"
REPO="${REPO:-$detected_repo}"
if [[ -z "$REPO" || "$REPO" != */* ]]; then
  echo "Unable to detect REPO from origin URL. Set REPO=owner/name." >&2
  exit 1
fi

TAG="${TAG:-0.0.3}"
RELEASE_NAME="${RELEASE_NAME:-$TAG}"
SOURCE_REF="${SOURCE_REF:-main}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-$repo_root/CHANGELOG.md}"
RELEASE_BODY="${RELEASE_BODY:-}"
COMMIT_ALL="${COMMIT_ALL:-true}"
SYNC_COMMIT_MESSAGE="${SYNC_COMMIT_MESSAGE:-chore(release): publish $TAG}"
PUSH_FORCE_WITH_LEASE="${PUSH_FORCE_WITH_LEASE:-true}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:-Offline-first iOS chat app powered by local GGUF models via llama.cpp}"

if [[ -z "${IPA_PATH:-}" ]]; then
  candidate_tagged="$repo_root/build_unsigned_ipa/AiryWay-v${TAG}-unsigned.ipa"
  candidate_legacy="$repo_root/build_unsigned_ipa/AiryWay-unsigned.ipa"
  if [[ -f "$candidate_tagged" ]]; then
    IPA_PATH="$candidate_tagged"
  else
    IPA_PATH="$candidate_legacy"
  fi
fi

if [[ ! -f "$IPA_PATH" ]]; then
  echo "IPA not found: $IPA_PATH" >&2
  exit 1
fi

ASSET_NAME="${ASSET_NAME:-$(basename "$IPA_PATH")}"

if [[ -z "$RELEASE_BODY" && -f "$RELEASE_NOTES_FILE" ]]; then
  RELEASE_BODY="$(awk -v tag="$TAG" '
    BEGIN { in_section = 0 }
    $0 ~ "^##[[:space:]]*" tag "([[:space:]]*-.*)?$" { in_section = 1; next }
    $0 ~ "^##[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+" && in_section { exit }
    in_section { print }
  ' "$RELEASE_NOTES_FILE" | sed '/^[[:space:]]*$/N;/^\n$/D')"
fi

if [[ -z "$RELEASE_BODY" ]]; then
  RELEASE_BODY="Release $TAG"
fi

echo "Repository: $REPO"
echo "Tag: $TAG (from $SOURCE_REF)"
echo "IPA: $IPA_PATH"
echo "Asset: $ASSET_NAME"

git checkout main >/dev/null 2>&1 || git checkout -b main
git fetch origin --tags || true

if [[ "$COMMIT_ALL" == "true" ]]; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$SYNC_COMMIT_MESSAGE"
  fi
fi

if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  if [[ "$PUSH_FORCE_WITH_LEASE" == "true" ]]; then
    git push -u origin main --force-with-lease
  else
    git push -u origin main
  fi
else
  git push -u origin main
fi

git tag -f "$TAG" "$SOURCE_REF"
git push origin "refs/tags/$TAG" --force

api_call() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local tmp_body
  tmp_body="$(mktemp)"
  local http_code

  if [[ -n "$data" ]]; then
    http_code="$(curl -sS -o "$tmp_body" -w "%{http_code}" -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      "$url" \
      -d "$data")"
  else
    http_code="$(curl -sS -o "$tmp_body" -w "%{http_code}" -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$url")"
  fi

  API_HTTP_CODE="$http_code"
  API_BODY="$(cat "$tmp_body")"
  rm -f "$tmp_body"
}

desc_payload="$(jq -n --arg d "$REPO_DESCRIPTION" '{description:$d}')"
api_call PATCH "https://api.github.com/repos/$REPO" "$desc_payload"
if [[ "$API_HTTP_CODE" != "200" ]]; then
  echo "Failed to update repository description ($API_HTTP_CODE)." >&2
  echo "$API_BODY" >&2
  exit 1
fi

api_call GET "https://api.github.com/repos/$REPO/releases/tags/$TAG"
release_json=""
release_id=""

if [[ "$API_HTTP_CODE" == "200" ]]; then
  release_json="$API_BODY"
  release_id="$(printf '%s' "$release_json" | jq -r '.id // empty')"
elif [[ "$API_HTTP_CODE" == "404" ]]; then
  release_json=""
else
  echo "Failed to query release by tag ($API_HTTP_CODE)." >&2
  echo "$API_BODY" >&2
  exit 1
fi

if [[ -z "$release_id" ]]; then
  create_payload="$(jq -n \
    --arg tag "$TAG" \
    --arg name "$RELEASE_NAME" \
    --arg target "$SOURCE_REF" \
    --arg body "$RELEASE_BODY" \
    '{tag_name:$tag,name:$name,target_commitish:$target,body:$body,draft:false,prerelease:false}')"
  api_call POST "https://api.github.com/repos/$REPO/releases" "$create_payload"
  if [[ "$API_HTTP_CODE" != "201" ]]; then
    echo "Failed to create release ($API_HTTP_CODE)." >&2
    echo "$API_BODY" >&2
    exit 1
  fi
  release_json="$API_BODY"
  release_id="$(printf '%s' "$release_json" | jq -r '.id')"
else
  update_payload="$(jq -n \
    --arg name "$RELEASE_NAME" \
    --arg target "$SOURCE_REF" \
    --arg body "$RELEASE_BODY" \
    '{name:$name,target_commitish:$target,body:$body,draft:false,prerelease:false}')"
  api_call PATCH "https://api.github.com/repos/$REPO/releases/$release_id" "$update_payload"
  if [[ "$API_HTTP_CODE" != "200" ]]; then
    echo "Failed to update release ($API_HTTP_CODE)." >&2
    echo "$API_BODY" >&2
    exit 1
  fi
  release_json="$API_BODY"
fi

upload_url="$(printf '%s' "$release_json" | jq -r '.upload_url' | sed 's/{?name,label}//')"
html_url="$(printf '%s' "$release_json" | jq -r '.html_url')"
if [[ -z "$release_id" || -z "$upload_url" || "$upload_url" == "null" ]]; then
  echo "Release payload incomplete. Aborting." >&2
  exit 1
fi

api_call GET "https://api.github.com/repos/$REPO/releases/$release_id/assets"
if [[ "$API_HTTP_CODE" != "200" ]]; then
  echo "Failed to list release assets ($API_HTTP_CODE)." >&2
  echo "$API_BODY" >&2
  exit 1
fi

existing_asset_id="$(printf '%s' "$API_BODY" | jq -r --arg n "$ASSET_NAME" '.[] | select(.name==$n) | .id' | head -n1)"
if [[ -n "$existing_asset_id" ]]; then
  api_call DELETE "https://api.github.com/repos/$REPO/releases/assets/$existing_asset_id"
  if [[ "$API_HTTP_CODE" != "204" ]]; then
    echo "Failed to delete previous asset ($API_HTTP_CODE)." >&2
    echo "$API_BODY" >&2
    exit 1
  fi
fi

encoded_asset_name="$(jq -rn --arg v "$ASSET_NAME" '$v|@uri')"
upload_response_file="$(mktemp)"
upload_http_code="$(curl -sS -o "$upload_response_file" -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$IPA_PATH" \
  "$upload_url?name=$encoded_asset_name")"

if [[ "$upload_http_code" != "201" ]]; then
  echo "Failed to upload IPA asset ($upload_http_code)." >&2
  cat "$upload_response_file" >&2 || true
  rm -f "$upload_response_file"
  exit 1
fi
rm -f "$upload_response_file"

echo "Repository synced on main."
echo "Release published: $html_url"
echo "Asset uploaded: $ASSET_NAME"
