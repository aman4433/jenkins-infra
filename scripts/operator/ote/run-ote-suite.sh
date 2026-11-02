#!/bin/bash
# Runs an OTE (openshift-tests-extension) suite for one operator against the deployed cluster.
# Runs on the Jenkins agent and does the work on the bastion over ssh.
#
# Needs: WORKSPACE, BASTION_IP, OPERATOR_NAME, OTE_SUITE (optional, defaults to the first suite in operators.conf)
set -euo pipefail

CONF="${WORKSPACE}/scripts/operator/ote/operators.conf"
KEY="${WORKSPACE}/deploy/id_rsa"
PULL_SECRET_FILE="${WORKSPACE}/deploy/data/pull-secret.txt"
OUT_DIR="${WORKSPACE}/deploy/ote"
SSH_OPTS=(-o StrictHostKeyChecking=no -o ServerAliveInterval=5 -o ServerAliveCountMax=1200 -i "${KEY}")

line=$(grep -v '^\s*#' "${CONF}" | awk -F'|' -v n="${OPERATOR_NAME}" '$1==n {print; exit}')
if [ -z "${line}" ]; then
    echo "Operator '${OPERATOR_NAME}' not found in ${CONF}"
    exit 1
fi
IMAGE=$(echo "${line}" | cut -d'|' -f2)
BINARY_PATH=$(echo "${line}" | cut -d'|' -f3)
SUITES=$(echo "${line}" | cut -d'|' -f4)
SUITE="${OTE_SUITE:-}"
if [ -z "${SUITE}" ]; then
    SUITE=$(echo "${SUITES}" | cut -d',' -f1)
fi

echo "Operator : ${OPERATOR_NAME}"
echo "Image    : ${IMAGE}"
echo "Binary   : ${BINARY_PATH}"
echo "Suite    : ${SUITE}"

mkdir -p "${OUT_DIR}"
scp "${SSH_OPTS[@]}" "${PULL_SECRET_FILE}" root@"${BASTION_IP}":/root/ote-pull-secret.txt

ssh "${SSH_OPTS[@]}" root@"${BASTION_IP}" \
    IMAGE="'${IMAGE}'" BINARY_PATH="'${BINARY_PATH}'" SUITE="'${SUITE}'" bash -s <<'EOF'
set -euo pipefail
export KUBECONFIG=/root/openstack-upi/auth/kubeconfig
rm -rf /root/ote && mkdir -p /root/ote && cd /root/ote

echo "Extracting ${BINARY_PATH} from the operator image"
oc image extract "${IMAGE}" --path "${BINARY_PATH}:." \
    --registry-config /root/ote-pull-secret.txt --filter-by-os=linux/ppc64le --confirm

BIN=$(basename "${BINARY_PATH}")
if [[ "${BIN}" == *.gz ]]; then
    gzip -dc "${BIN}" > "${BIN%.gz}"
    BIN="${BIN%.gz}"
fi
chmod +x "${BIN}"

./"${BIN}" list suites > suites.txt 2>&1 || true
set +e
./"${BIN}" run-suite "${SUITE}" 2>&1 | tee ote-run.log
rc=${PIPESTATUS[0]}
echo "${rc}" > ote-exit-code
exit 0
EOF

scp "${SSH_OPTS[@]}" root@"${BASTION_IP}":/root/ote/{ote-run.log,suites.txt,ote-exit-code} "${OUT_DIR}/" || true
rc=$(cat "${OUT_DIR}/ote-exit-code" 2>/dev/null || echo 1)
echo "OTE suite '${SUITE}' finished with exit code ${rc}"
exit "${rc}"
