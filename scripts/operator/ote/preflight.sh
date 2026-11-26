#!/bin/bash
# Checks everything the test stage needs before a cluster is deployed, so a bad credential,
# image or branch fails the build in a minute instead of after the deploy.
#
# Needs: WORKSPACE, OPERATOR_NAME, GITHUB_USER, GITHUB_TOKEN
# Existing cluster: EXISTING_BASTION_IP (key at ${WORKSPACE}/deploy/id_rsa)
# Optional: OPERATOR_IMAGE_OVERRIDE, INDEX_IMAGE, GOLANG_VERSION, PLAYBOOKS_REPO, PLAYBOOKS_BRANCH
set -uo pipefail
source "${WORKSPACE}/scripts/operator/ote/common.sh"

errors=0
info() { echo "  [info] $*"; }
fail() { echo "  [FAIL] $*"; errors=$((errors+1)); }
warn() { echo "  [warn] $*"; }   # could not check (network), not a failure

echo "Preflight checks for ${OPERATOR_NAME}"

# Existing cluster: the job must be able to log in to the bastion and use the cluster from there
if [ -n "${EXISTING_BASTION_IP:-}" ]; then
    ssh_cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout="${NET_TIMEOUT}"
             -i "${WORKSPACE}/deploy/id_rsa" root@"${EXISTING_BASTION_IP}")
    if ! "${ssh_cmd[@]}" true >/dev/null 2>&1; then
        fail "cannot ssh to root@${EXISTING_BASTION_IP}, add the job's public key to /root/.ssh/authorized_keys (see README)"
        exit 1
    fi
    info "ssh to bastion ${EXISTING_BASTION_IP} works"
    "${ssh_cmd[@]}" 'test -f /root/openstack-upi/auth/kubeconfig' \
        && info "kubeconfig found at /root/openstack-upi/auth/kubeconfig" \
        || fail "no /root/openstack-upi/auth/kubeconfig on the bastion (was the cluster created with ocp4-upi-powervm?)"
    "${ssh_cmd[@]}" 'test -f /root/.kube/config' \
        && info "/root/.kube/config found" \
        || fail "no /root/.kube/config on the bastion (playbooks use it)"
    "${ssh_cmd[@]}" 'KUBECONFIG=/root/openstack-upi/auth/kubeconfig timeout 30 oc whoami' >/dev/null 2>&1 \
        && info "cluster API reachable from the bastion" \
        || fail "oc cannot reach the cluster from the bastion"
fi

line=$(conf_line)
if [ -z "${line}" ]; then
    fail "operator '${OPERATOR_NAME}' not found in operators.conf"
    exit 1
fi
type=$(echo "${line}" | cut -d'|' -f2)
info "found in operators.conf (type: ${type})"

case "${type}" in
ote)
    image="${OPERATOR_IMAGE_OVERRIDE:-$(echo "${line}" | cut -d'|' -f3)}"
    repo="${image%%@*}"; last="${repo##*/}"
    tag=""
    if [[ "${last}" == *:* ]]; then tag="${last##*:}"; repo="${repo%:*}"; fi
    repo_path="${repo#quay.io/}"
    if [[ "${repo}" != quay.io/* ]]; then
        info "image ${image} is not on quay, not checked"
    elif [[ "${image}" == *@* ]]; then
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${NET_TIMEOUT}" "${QUAY_API}/${repo_path}" 2>/dev/null) || code=000
        case "${code}" in
            200) info "image repo ${repo} exists (digest pin not checked)" ;;
            000) warn "could not reach quay to check ${repo}" ;;
            *)   fail "image repo ${repo} not found on quay (HTTP ${code})" ;;
        esac
    else
        body=$(curl -sS --max-time "${NET_TIMEOUT}" "${QUAY_API}/${repo_path}/tag/?onlyActiveTags=true&limit=100${tag:+&specificTag=${tag}}" 2>/dev/null) || body=""
        if [ -z "${body}" ]; then
            warn "could not reach quay to check ${image}"
        elif [ -n "${tag}" ]; then
            echo "${body}" | grep -q "\"name\": *\"${tag}\"" && info "image tag ${repo}:${tag} exists" || fail "image tag ${repo}:${tag} not found on quay"
        else
            echo "${body}" | grep -qE '"name": *"[0-9a-f]{40}"' && info "image ${repo} has main-branch builds" || fail "no main-branch build (commit SHA tag) found for ${repo}"
        fi
    fi
    ;;
playbook)
    script=$(echo "${line}" | cut -d'|' -f3)
    pb_repo="${PLAYBOOKS_REPO:-https://github.com/ocp-power-automation/ocp4-playbooks-extras}"
    pb_branch="${PLAYBOOKS_BRANCH:-main}"
    if timeout "${NET_TIMEOUT}" git ls-remote --exit-code --heads "${pb_repo}" "${pb_branch}" >/dev/null 2>&1; then
        info "playbooks ${pb_repo} (${pb_branch}) found"
    else
        fail "playbooks branch ${pb_branch} not found in ${pb_repo}"
    fi
    [ -f "${WORKSPACE}/${script}" ] && info "script ${script} exists" || fail "script ${script} not found in the repo"

    # The playbook clones the e2e repo with user:token in the URL, so both must be plain values
    if [ -z "${GITHUB_USER:-}" ] || [[ "${GITHUB_USER}" =~ [[:space:]@:{}/] ]]; then
        fail "GitHub user credential (PUBLIC_GITHUB_USER) is empty or not a plain GitHub username"
    else
        info "GitHub user credential looks like a username"
    fi
    if [ -z "${GITHUB_TOKEN:-}" ] || [ "${GITHUB_TOKEN}" = "None" ]; then
        fail "GitHub token credential (PUBLIC_GITHUB_TOKEN) is empty"
    else
        code=$(gh_get "repos/${E2E_TESTS_REPO}")
        case "${code}" in
            200) info "GitHub token can read ${E2E_TESTS_REPO}" ;;
            401) fail "GitHub token is invalid or expired (HTTP 401)" ;;
            404) fail "GitHub token has no access to ${E2E_TESTS_REPO} (HTTP 404)" ;;
            000) warn "could not reach GitHub to check ${E2E_TESTS_REPO}" ;;
            *)   fail "unexpected answer from GitHub for ${E2E_TESTS_REPO} (HTTP ${code})" ;;
        esac
        if [ "${code}" = "200" ]; then
            code=$(gh_get "repos/${E2E_TESTS_REPO}/branches/${E2E_TESTS_BRANCH}")
            [ "${code}" = "200" ] && info "branch ${E2E_TESTS_BRANCH} exists" || fail "branch ${E2E_TESTS_BRANCH} not found in ${E2E_TESTS_REPO}"
        fi
    fi

    go_ver="${GOLANG_VERSION:-}"
    if [ -z "${go_ver}" ] && [ "${code:-}" != "200" ]; then
        warn "Go version not checked (needs GitHub access to read go.mod)"
    elif [ -z "${go_ver}" ]; then
        go_ver=$(e2e_go_version) && info "e2e repo needs Go ${go_ver}" || { fail "could not read the Go version from ${E2E_TESTS_REPO} go.mod"; go_ver=""; }
    fi
    if [ -n "${go_ver}" ]; then
        url="https://go.dev/dl/go${go_ver}.linux-ppc64le.tar.gz"
        code=$(curl -sSIL --max-time "${NET_TIMEOUT}" -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null) || code=000
        case "${code}" in
            200) info "Go tarball ${url} exists" ;;
            000) warn "could not reach go.dev to check ${url}" ;;
            *)   fail "Go tarball ${url} not found (HTTP ${code})" ;;
        esac
    fi
    ;;
*)
    fail "unknown test type '${type}'"
    ;;
esac

if [ "${errors}" -gt 0 ]; then
    echo "Preflight failed with ${errors} problem(s), nothing was deployed"
    exit 1
fi
echo "Preflight passed"
