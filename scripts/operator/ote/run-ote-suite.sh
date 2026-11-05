#!/bin/bash
# Runs OTE (openshift-tests-extension) tests for one operator against the deployed cluster.
# Runs on the Jenkins agent and does the work on the bastion over ssh.
# Tests run one by one so the console shows live progress; results go to junit.xml.
#
# Needs: WORKSPACE, BASTION_IP, OPERATOR_NAME
# Optional: OTE_SUITE (default: first suite in operators.conf), OTE_TEST_FILTER (regex on test names)
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
IMAGE=$(echo "${line}" | cut -d'|' -f3)
if [ -n "${OPERATOR_IMAGE_OVERRIDE:-}" ]; then
    IMAGE="${OPERATOR_IMAGE_OVERRIDE}"
fi
BINARY_PATH=$(echo "${line}" | cut -d'|' -f4)
SUITES=$(echo "${line}" | cut -d'|' -f5)
SUITE="${OTE_SUITE:-}"
if [ -z "${SUITE}" ]; then
    SUITE=$(echo "${SUITES}" | cut -d',' -f1)
fi
FILTER="${OTE_TEST_FILTER:-}"

echo "Operator : ${OPERATOR_NAME}"
echo "Image    : ${IMAGE}"
echo "Binary   : ${BINARY_PATH}"
echo "Suite    : ${SUITE}"
echo "Filter   : ${FILTER:-<none, whole suite>}"

mkdir -p "${OUT_DIR}"
scp "${SSH_OPTS[@]}" "${PULL_SECRET_FILE}" root@"${BASTION_IP}":/root/ote-pull-secret.txt

ssh "${SSH_OPTS[@]}" root@"${BASTION_IP}" \
    IMAGE="'${IMAGE}'" BINARY_PATH="'${BINARY_PATH}'" SUITE="'${SUITE}'" FILTER="'${FILTER}'" bash -s <<'EOF'
set -euo pipefail
export KUBECONFIG=/root/openstack-upi/auth/kubeconfig
rm -rf /root/ote && mkdir -p /root/ote/results && cd /root/ote

# Repo without a tag or digest: pick the newest main-branch build (Konflux tags it with the 40-char commit SHA)
last_part="${IMAGE##*/}"
if [[ "${IMAGE}" != *@* && "${last_part}" != *:* ]]; then
    repo_path="${IMAGE#quay.io/}"
    echo "Looking up the newest main build of ${IMAGE}"
    tag=$(timeout 60 curl -sSf "https://quay.io/api/v1/repository/${repo_path}/tag/?onlyActiveTags=true&limit=100" | python3 -c '
import json, re, sys
tags = json.load(sys.stdin).get("tags", [])
for t in tags:  # quay returns newest first
    if t.get("is_manifest_list") and re.fullmatch(r"[0-9a-f]{40}", t["name"]):
        print(t["name"]); break')
    if [ -z "${tag}" ]; then
        echo "No main-branch build tag found for ${IMAGE}"; exit 1
    fi
    IMAGE="${IMAGE}:${tag}"
fi
echo "Using image: ${IMAGE}"
echo "${IMAGE}" > image.txt

echo "Extracting ${BINARY_PATH} from the operator image"
timeout 15m oc image extract "${IMAGE}" --path "${BINARY_PATH}:." \
    --registry-config /root/ote-pull-secret.txt --filter-by-os=linux/ppc64le --confirm

BIN=$(basename "${BINARY_PATH}")
if [[ "${BIN}" == *.gz ]]; then
    gzip -dc "${BIN}" > "${BIN%.gz}"
    BIN="${BIN%.gz}"
fi
chmod +x "${BIN}"

./"${BIN}" list suites > suites.txt 2>&1 || true
./"${BIN}" list tests --suite="${SUITE}" -o names > all-tests.txt
if [ -n "${FILTER}" ]; then
    grep -E -- "${FILTER}" all-tests.txt > tests.txt || true
else
    cp all-tests.txt tests.txt
fi
total=$(grep -c . tests.txt || true)
echo "Running ${total} of $(grep -c . all-tests.txt) tests in ${SUITE}"
if [ "${total}" -eq 0 ]; then
    echo "No tests match the filter"; exit 1
fi
cat -n tests.txt

i=0; pass=0; fail=0; skip=0; suite_start=$(date +%s)
: > summary.tsv
while IFS= read -r name; do
    [ -z "${name}" ] && continue
    i=$((i+1))
    echo ""
    echo "==> [${i}/${total}] ${name}"
    for _ in $(seq 1 60); do
        oc get ns --no-headers 2>/dev/null | grep -q " Terminating" || break
        sleep 5
    done
    start=$(date +%s)
    ./"${BIN}" run-test --output=json "${name}" < /dev/null > "results/${i}.json" 2> "results/${i}.log" || true
    dur=$(( $(date +%s) - start ))
    result=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); d=d[0] if isinstance(d,list) else d; print(d.get("result","unknown"))
except Exception: print("unknown")' "results/${i}.json")
    case "${result}" in
        passed)  pass=$((pass+1)); echo "    PASS (${dur}s)";;
        skipped) skip=$((skip+1)); echo "    SKIP (${dur}s)";;
        *)       fail=$((fail+1)); echo "    FAIL (${dur}s) result=${result}"
                 python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); d=d[0] if isinstance(d,list) else d
    print("\n".join(("    | "+l) for l in (d.get("error") or d.get("output") or "")[-2500:].splitlines()[-25:]))
except Exception: pass' "results/${i}.json"
                 tail -5 "results/${i}.log" | sed 's/^/    | /';;
    esac
    printf '%s\t%s\t%s\t%s\n' "${i}" "${result}" "${dur}" "${name}" >> summary.tsv
done < tests.txt

elapsed=$(( $(date +%s) - suite_start ))
echo ""
echo "Done in $((elapsed/60))m$((elapsed%60))s: ${pass} passed, ${fail} failed, ${skip} skipped (of ${total})"

# JUnit for Jenkins
python3 - "${SUITE}" <<'PY'
import json, sys, html
suite = sys.argv[1]
rows = [l.rstrip("\n").split("\t", 3) for l in open("summary.tsv") if l.strip()]
cases, fails, skips, total_t = [], 0, 0, 0
for idx, result, dur, name in rows:
    total_t += int(dur)
    body = ""
    if result == "skipped":
        skips += 1; body = "<skipped/>"
    elif result != "passed":
        fails += 1
        msg = ""
        try:
            d = json.load(open(f"results/{idx}.json")); d = d[0] if isinstance(d, list) else d
            msg = (d.get("error") or d.get("output") or "")[-20000:]
        except Exception:
            msg = open(f"results/{idx}.log", errors="replace").read()[-20000:]
        body = f'<failure message="{html.escape(result)}">{html.escape(msg)}</failure>'
    cases.append(f'  <testcase classname="{html.escape(suite)}" name="{html.escape(name)}" time="{dur}">{body}</testcase>')
open("junit.xml", "w").write(
    f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="{html.escape(suite)}" tests="{len(rows)}" '
    f'failures="{fails}" skipped="{skips}" time="{total_t}">\n' + "\n".join(cases) + "\n</testsuite>\n")
PY

echo "${fail}" > ote-failed-count
tar czf results.tar.gz results
exit 0
EOF

scp "${SSH_OPTS[@]}" root@"${BASTION_IP}":/root/ote/{junit.xml,summary.tsv,tests.txt,suites.txt,results.tar.gz,ote-failed-count,image.txt} "${OUT_DIR}/" || true
failed=$(cat "${OUT_DIR}/ote-failed-count" 2>/dev/null || echo 1)
echo "OTE run finished, ${failed} failed test(s)"
[ "${failed}" -eq 0 ] || exit 2
