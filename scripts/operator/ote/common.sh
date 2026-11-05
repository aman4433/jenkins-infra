# Shared helpers for the operator test scripts. Source it, don't run it.

CONF="${WORKSPACE}/scripts/operator/ote/operators.conf"

# Repo/branch the playbook roles build the e2e tests from
export E2E_TESTS_REPO="${E2E_TESTS_REPO:-openshift/openshift-tests-private}"
export E2E_TESTS_BRANCH="${E2E_TESTS_BRANCH:-main}"

# Prints the operators.conf line for OPERATOR_NAME (empty if not found)
conf_line() {
    grep -v '^\s*#' "${CONF}" | awk -F'|' -v n="${OPERATOR_NAME}" '$1==n {print; exit}'
}

# GitHub API GET. Prints the HTTP code; body goes to $2 (default /dev/null)
gh_get() {
    curl -sS -o "${2:-/dev/null}" -w '%{http_code}' --max-time 30 \
        -H "Authorization: token ${GITHUB_TOKEN:-}" -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/$1" 2>/dev/null || true
}

# Go version the e2e repo needs, from its go.mod (toolchain line wins over the go line)
e2e_go_version() {
    local tmp v
    tmp=$(mktemp)
    if [ "$(gh_get "repos/${E2E_TESTS_REPO}/contents/go.mod?ref=${E2E_TESTS_BRANCH}" "${tmp}")" != "200" ]; then
        rm -f "${tmp}"; return 1
    fi
    v=$(awk '$1=="toolchain"{sub(/^go/,"",$2); print $2; exit}' "${tmp}")
    [ -z "${v}" ] && v=$(awk '$1=="go"{print $2; exit}' "${tmp}")
    rm -f "${tmp}"
    [ -z "${v}" ] && return 1
    # "go 1.26" means 1.26.0
    [[ "${v}" =~ ^[0-9]+\.[0-9]+$ ]] && v="${v}.0"
    echo "${v}"
}
