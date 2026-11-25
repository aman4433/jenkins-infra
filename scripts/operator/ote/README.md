# OCP operator tests on PowerVC

Jenkins job: `powervm/ocp/custom-powervm-jobs/custom-ocp4.x-powervm-ote-operator-tests`
(Jenkinsfile in `jobs/pipelines/powervm/ocp/custom-powervm-jobs/custom-ocp4.x-powervm-ote-operator-tests/`)

The job deploys a fresh OCP cluster on the on-prem PowerVC (scnlonprem, host group `ocp-qe-operators`),
runs the tests for the operator you pick, keeps the cluster for `KeepFor` minutes and then destroys it.

There are two ways an operator gets tested:

- **ote**: the operator image ships an OTE (openshift-tests-extension) test binary. The job extracts
  it from the image and runs a suite, one test at a time. Results show up in the Test Result tab.
- **playbook**: the operator has a role in [ocp4-playbooks-extras](https://github.com/ocp-power-automation/ocp4-playbooks-extras).
  The job runs it through a small script in `scripts/operator/` (the same scripts the older
  `custom-ocp4.x-powervm-p9-deploy-operator-tests` job uses). Results are archived as `e2e-summary.txt` / `e2e-output.txt`.

## Running it

Build with Parameters, pick `Release` and `Operator`, leave the rest as default. Useful ones:

| Parameter | Used for | Notes |
|---|---|---|
| `Build` | all | OCP build image. Empty = latest stable build of the release |
| `TestFilter` | ote | regex to run only some tests, e.g. `metrics\|ServiceMonitor` |
| `Suite`, `OperatorImage` | ote | override the suite / image from `operators.conf` for one run |
| `IndexImage` | playbook | catalog source index image. Empty = `redhat-operators` |
| `PlaybooksRepo`, `PlaybooksBranch` | playbook | point to your fork to test a playbook change before it is merged |
| `KeepFor` | all | minutes to keep the cluster after the tests (for debugging) |

Build result: green = all passed, yellow (UNSTABLE) = some tests failed, red = the automation itself failed
(the console says which step). A "Preflight checks" stage runs first and fails in about a minute on bad
credentials, a missing image or a missing branch, before anything is deployed.

## Adding an operator

1. Add one line to `operators.conf` (format is described at the top of that file).
2. Add the same name to the `Operator` choice list in the Jenkinsfile.
3. Raise a PR. After it is merged, run the job once with your operator.

### OTE operator

```
my-operator|ote|quay.io/<org>/<operator-image>|/usr/bin/<tests-ext-binary>.gz|<default suite>[,<other suite>]
```

- Image without a tag = newest main-branch build on quay. A `repo:tag` or `repo@sha256:...` is used as is.
- To find the binary path and suites: `oc image extract <image> --path /usr/bin/:/tmp/bin --confirm`,
  then `./<binary> list suites`.

### Playbook operator

```
my-operator|playbook|scripts/operator/<my_operator>.sh|<MY_CATALOGSOURCE_IMAGE>|<results dir on the bastion>
```

The script copies the role's example vars, fills them in and runs the playbook against the bastion.
`compliance_operator.sh` is a good template. Your script gets these from the job:
`WORKSPACE`, `BASTION_IP` (inventory uses `${WORKSPACE}/deploy/id_rsa`), `GITHUB_USER`/`GITHUB_TOKEN`,
`GOLANG_TARBALL` and the catalog env var named in the 4th field.

The playbook must leave an `e2e-summary.txt` in the results dir; its last lines are checked for
`N fail` to decide pass/fail.

Scripts already in `scripts/operator/` that only need a line in `operators.conf`
(check the role still works before adding):

| Script | Catalog env var | Playbook |
|---|---|---|
| `cro_o.sh` | none | `cro.yml` |
| `fio_operator.sh` | `FIO_CATALOGSOURCE_IMAGE` | `ocp-fio.yaml` |
| `ingressnfw_opeator.sh` | `INFO_CATALOGSOURCE_IMAGE` | `ocp-ingress-firewall-operator.yml` |
| `lso_operator.sh` | `LSO_CATALOGSOURCE_IMAGE` | `ocp-lso.yml` |
| `metallbOP.sh` | `METALLB_CATALOGSOURCE_IMAGE` | `ocp-metallb-operator.yml` |
| `quay_operator.sh` | `QUAY_CATALOGSOURCE_IMAGE` | `ocp-quay.yml` |

## Notes

- Roles that build openshift-tests-private need the Go modules downloaded before `make build`
  (`go mod download` in the repo dir; added for the ocp-compliance role in a pending ocp4-playbooks-extras PR). Without it the build fails with
  `chmod: cannot access .../bindata.go`.
- A full compliance run takes about 4.5 hours (deploy ~55 min, tests ~3.5 h, they run serially).
