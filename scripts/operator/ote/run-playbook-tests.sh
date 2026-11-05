#!/bin/bash
# Runs a non-OTE operator's tests with its ocp4-playbooks-extras playbook (via the existing scripts/operator/*.sh)
# and copies the e2e results back from the bastion.
#
# Needs: WORKSPACE, BASTION_IP, OPERATOR_NAME, ocp4-playbooks-extras cloned in WORKSPACE
# Optional: INDEX_IMAGE (catalog source image; empty = default redhat-operators catalog)
set -euo pipefail

CONF="${WORKSPACE}/scripts/operator/ote/operators.conf"
KEY="${WORKSPACE}/deploy/id_rsa"
OUT_DIR="${WORKSPACE}/deploy/operator-results"
SSH_OPTS=(-o StrictHostKeyChecking=no -i "${KEY}")

line=$(grep -v '^\s*#' "${CONF}" | awk -F'|' -v n="${OPERATOR_NAME}" '$1==n {print; exit}')
SCRIPT=$(echo "${line}" | cut -d'|' -f3)
CATALOG_VAR=$(echo "${line}" | cut -d'|' -f4)
RESULTS_DIR=$(echo "${line}" | cut -d'|' -f5)

echo "Operator  : ${OPERATOR_NAME}"
echo "Script    : ${SCRIPT}"
echo "Catalog   : ${INDEX_IMAGE:-<default redhat-operators>}"
echo "Results   : ${RESULTS_DIR} on the bastion"

if [ -n "${CATALOG_VAR}" ]; then
    export "${CATALOG_VAR}=${INDEX_IMAGE:-}"
fi

rc=0
chmod +x "${WORKSPACE}/${SCRIPT}"
"${WORKSPACE}/${SCRIPT}" || rc=$?

mkdir -p "${OUT_DIR}"
scp "${SSH_OPTS[@]}" root@"${BASTION_IP}":"${RESULTS_DIR}"/e2e-*.txt "${OUT_DIR}/" 2>/dev/null || true
if [ -f "${OUT_DIR}/e2e-summary.txt" ]; then
    echo ""; cat "${OUT_DIR}/e2e-summary.txt"
fi

if [ "${rc}" -ne 0 ]; then
    echo "Playbook failed (exit ${rc})"
    exit 1
fi
if [ ! -f "${OUT_DIR}/e2e-summary.txt" ]; then
    echo "Playbook finished but no e2e summary was found in ${RESULTS_DIR}"
    exit 2
fi
# extended-platform-tests prints a final line like "N pass, N fail, N skip"; fail if any test still failed after re-run
if tail -3 "${OUT_DIR}/e2e-summary.txt" | grep -qE '\b[1-9][0-9]* fail'; then
    echo "Some tests failed"
    exit 2
fi
echo "All tests passed"
