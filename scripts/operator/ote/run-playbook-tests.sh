#!/bin/bash
# Runs a non-OTE operator's tests with its ocp4-playbooks-extras playbook (via the existing scripts/operator/*.sh)
# and copies the e2e results back from the bastion.
#
# Needs: WORKSPACE, BASTION_IP, OPERATOR_NAME, ocp4-playbooks-extras cloned in WORKSPACE
# Optional: INDEX_IMAGE (catalog source image; empty = default redhat-operators catalog)
#           GOLANG_VERSION (empty = the version the e2e repo's go.mod asks for)
set -euo pipefail
source "${WORKSPACE}/scripts/operator/ote/common.sh"

KEY="${WORKSPACE}/deploy/id_rsa"
OUT_DIR="${WORKSPACE}/deploy/operator-results"
LOG="${WORKSPACE}/deploy/playbook.log"   # not archived: may contain credentials
SSH_OPTS=(-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -i "${KEY}")

line=$(conf_line)
SCRIPT=$(echo "${line}" | cut -d'|' -f3)
CATALOG_VAR=$(echo "${line}" | cut -d'|' -f4)
RESULTS_DIR=$(echo "${line}" | cut -d'|' -f5)

go_ver="${GOLANG_VERSION:-}"
if [ -z "${go_ver}" ]; then
    go_ver=$(e2e_go_version) || { echo "Could not read the Go version from ${E2E_TESTS_REPO} go.mod"; exit 1; }
fi
export GOLANG_TARBALL="https://go.dev/dl/go${go_ver}.linux-ppc64le.tar.gz"

echo "Operator  : ${OPERATOR_NAME}"
echo "Script    : ${SCRIPT}"
echo "Catalog   : ${INDEX_IMAGE:-<default redhat-operators>}"
echo "E2E repo  : ${E2E_TESTS_REPO} (${E2E_TESTS_BRANCH}), Go ${go_ver}"
echo "Results   : ${RESULTS_DIR} on the bastion"

if [ -n "${CATALOG_VAR}" ]; then
    export "${CATALOG_VAR}=${INDEX_IMAGE:-}"
fi
mkdir -p "${OUT_DIR}"

# Live e2e progress: follow the test output on the bastion and print one line per test result
( sleep 60
  ssh "${SSH_OPTS[@]}" root@"${BASTION_IP}" \
      "tail -n0 -F ${RESULTS_DIR}/e2e-output.txt 2>/dev/null | grep --line-buffered -E '^(passed|failed|skipped):'" \
      | sed -u 's/^/[e2e progress] /' ) &
progress_pid=$!

set +e
chmod +x "${WORKSPACE}/${SCRIPT}"
"${WORKSPACE}/${SCRIPT}" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e
pkill -P "${progress_pid}" 2>/dev/null || true
kill "${progress_pid}" 2>/dev/null || true

scp "${SSH_OPTS[@]}" root@"${BASTION_IP}":"${RESULTS_DIR}"/e2e-*.txt "${OUT_DIR}/" 2>/dev/null || true

# The roles use ignore_errors a lot, so a failed step does not stop the playbook. List every ignored failure.
ignored=$(awk '
    /^TASK \[/ { task=$0; sub(/^TASK \[/, "", task); sub(/\].*$/, "", task) }
    /^fatal: / { msg=$0; sub(/^fatal: \[[^]]*\]: FAILED! => /, "", msg); last=task " | " substr(msg, 1, 300) }
    /\.\.\.ignoring/ && last != "" { print last; last="" }
' "${LOG}" | sed -E 's#https?://[^@/ ]+@#https://***@#g')
critical=0
if [ -n "${ignored}" ]; then
    echo ""
    echo "===== Failed steps the playbook ignored ====="
    echo "${ignored}" | sed 's/^/  - /'
    # A failed clone or build of the e2e repo means the tests never ran
    if echo "${ignored}" | cut -d'|' -f1 | grep -qiE 'clone|make target'; then
        critical=1
    fi
    echo "============================================="
fi

if [ -f "${OUT_DIR}/e2e-summary.txt" ]; then
    echo ""; cat "${OUT_DIR}/e2e-summary.txt"
fi

if [ "${rc}" -ne 0 ]; then
    echo "Playbook failed (exit ${rc})"
    exit 1
fi
if [ ! -f "${OUT_DIR}/e2e-summary.txt" ]; then
    echo "No e2e summary in ${RESULTS_DIR}: the tests did not run, see the failed steps above"
    exit 1
fi
if [ "${critical}" -eq 1 ]; then
    echo "An e2e setup step failed (see above), results may be incomplete"
    exit 1
fi
# extended-platform-tests prints a final line like "N pass, N fail, N skip"; fail if any test still failed after re-run
if tail -3 "${OUT_DIR}/e2e-summary.txt" | grep -qE '\b[1-9][0-9]* fail'; then
    echo "Some tests failed"
    exit 2
fi
echo "All tests passed"
