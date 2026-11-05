#!/bin/bash
# Checks everything the test stage needs before a cluster is deployed, so a bad credential,
# image or branch fails the build in a minute instead of after the deploy.
#
# Needs: WORKSPACE, OPERATOR_NAME, GITHUB_USER, GITHUB_TOKEN
# Optional: OPERATOR_IMAGE_OVERRIDE, INDEX_IMAGE, GOLANG_VERSION, PLAYBOOKS_REPO, PLAYBOOKS_BRANCH
set -uo pipefail
source "${WORKSPACE}/scripts/operator/ote/common.sh"

errors=0
ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [FAIL] $*"; errors=$((errors+1)); }
warn() { echo "  [warn] $*"; }   # could not check (network), not a failure

echo "Preflight checks for ${OPERATOR_NAME}"

line=$(conf_line)
if [ -z "${line}" ]; then
    bad "operator '${OPERATOR_NAME}' not found in operators.conf"
    exit 1
fi
type=$(echo "${line}" | cut -d'|' -f2)
ok "found in operators.conf (type: ${type})"

case "${type}" in
ote)
    image="${OPERATOR_IMAGE_OVERRIDE:-$(echo "${line}" | cut -d'|' -f3)}"
    repo="${image%%@*}"; last="${repo##*/}"
    tag=""
    if [[ "${last}" == *:* ]]; then tag="${last##*:}"; repo="${repo%:*}"; fi
    repo_path="${repo#quay.io/}"
    if [[ "${repo}" != quay.io/* ]]; then
        ok "image ${image} is not on quay, not checked"
    elif [[ "${image}" == *@* ]]; then
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "https://quay.io/api/v1/repository/${repo_path}" 2>/dev/null) || code=000
        case "${code}" in
            200) ok "image repo ${repo} exists (digest pin not checked)" ;;
            000) warn "could not reach quay to check ${repo}" ;;
            *)   bad "image repo ${repo} not found on quay (HTTP ${code})" ;;
        esac
    else
        body=$(curl -sS --max-time 30 "https://quay.io/api/v1/repository/${repo_path}/tag/?onlyActiveTags=true&limit=100${tag:+&specificTag=${tag}}" 2>/dev/null) || body=""
        if [ -z "${body}" ]; then
            warn "could not reach quay to check ${image}"
        elif [ -n "${tag}" ]; then
            echo "${body}" | grep -q "\"name\": *\"${tag}\"" && ok "image tag ${repo}:${tag} exists" || bad "image tag ${repo}:${tag} not found on quay"
        else
            echo "${body}" | grep -qE '"name": *"[0-9a-f]{40}"' && ok "image ${repo} has main-branch builds" || bad "no main-branch build (commit SHA tag) found for ${repo}"
        fi
    fi
    ;;
playbook)
    script=$(echo "${line}" | cut -d'|' -f3)
    pb_repo="${PLAYBOOKS_REPO:-https://github.com/ocp-power-automation/ocp4-playbooks-extras}"
    pb_branch="${PLAYBOOKS_BRANCH:-main}"
    if timeout 60 git ls-remote --exit-code --heads "${pb_repo}" "${pb_branch}" >/dev/null 2>&1; then
        ok "playbooks ${pb_repo} (${pb_branch}) found"
    else
        bad "playbooks branch ${pb_branch} not found in ${pb_repo}"
    fi
    [ -f "${WORKSPACE}/${script}" ] && ok "script ${script} exists" || bad "script ${script} not found in the repo"

    # The playbook clones the e2e repo with user:token in the URL, so both must be plain values
    if [ -z "${GITHUB_USER:-}" ] || [[ "${GITHUB_USER}" =~ [[:space:]@:{}/] ]]; then
        bad "GitHub user credential (PUBLIC_GITHUB_USER) is empty or not a plain GitHub username"
    else
        ok "GitHub user credential looks like a username"
    fi
    if [ -z "${GITHUB_TOKEN:-}" ] || [ "${GITHUB_TOKEN}" = "None" ]; then
        bad "GitHub token credential (PUBLIC_GITHUB_TOKEN) is empty"
    else
        code=$(gh_get "repos/${E2E_TESTS_REPO}")
        case "${code}" in
            200) ok "GitHub token can read ${E2E_TESTS_REPO}" ;;
            401) bad "GitHub token is invalid or expired (HTTP 401)" ;;
            404) bad "GitHub token has no access to ${E2E_TESTS_REPO} (HTTP 404)" ;;
            000) warn "could not reach GitHub to check ${E2E_TESTS_REPO}" ;;
            *)   bad "unexpected answer from GitHub for ${E2E_TESTS_REPO} (HTTP ${code})" ;;
        esac
        if [ "${code}" = "200" ]; then
            code=$(gh_get "repos/${E2E_TESTS_REPO}/branches/${E2E_TESTS_BRANCH}")
            [ "${code}" = "200" ] && ok "branch ${E2E_TESTS_BRANCH} exists" || bad "branch ${E2E_TESTS_BRANCH} not found in ${E2E_TESTS_REPO}"
        fi
    fi

    go_ver="${GOLANG_VERSION:-}"
    if [ -z "${go_ver}" ] && [ "${code:-}" != "200" ]; then
        warn "Go version not checked (needs GitHub access to read go.mod)"
    elif [ -z "${go_ver}" ]; then
        go_ver=$(e2e_go_version) && ok "e2e repo needs Go ${go_ver}" || { bad "could not read the Go version from ${E2E_TESTS_REPO} go.mod"; go_ver=""; }
    fi
    if [ -n "${go_ver}" ]; then
        url="https://go.dev/dl/go${go_ver}.linux-ppc64le.tar.gz"
        code=$(curl -sSIL --max-time 30 -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null) || code=000
        case "${code}" in
            200) ok "Go tarball ${url} exists" ;;
            000) warn "could not reach go.dev to check ${url}" ;;
            *)   bad "Go tarball ${url} not found (HTTP ${code})" ;;
        esac
    fi
    ;;
*)
    bad "unknown test type '${type}'"
    ;;
esac

if [ "${errors}" -gt 0 ]; then
    echo "Preflight failed with ${errors} problem(s), nothing was deployed"
    exit 1
fi
echo "Preflight passed"
