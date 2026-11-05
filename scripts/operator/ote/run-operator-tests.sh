#!/bin/bash
# Picks the test runner for the selected operator from the type in operators.conf (ote or playbook).
# Exit codes: 0 = all passed, 2 = tests failed (build UNSTABLE), anything else = automation failed (build FAILED).
set -euo pipefail

CONF="${WORKSPACE}/scripts/operator/ote/operators.conf"
type=$(grep -v '^\s*#' "${CONF}" | awk -F'|' -v n="${OPERATOR_NAME}" '$1==n {print $2; exit}')
case "${type}" in
    ote)      script=run-ote-suite.sh ;;
    playbook) script=run-playbook-tests.sh ;;
    "")       echo "Operator '${OPERATOR_NAME}' not found in ${CONF}"; exit 1 ;;
    *)        echo "Unknown test type '${type}' for ${OPERATOR_NAME} in ${CONF}"; exit 1 ;;
esac
echo "Test type: ${type}"
chmod +x "${WORKSPACE}/scripts/operator/ote/${script}"
"${WORKSPACE}/scripts/operator/ote/${script}"
