#!/bin/bash
echo 'Creating compliance_vars.yaml'
rm -rf ~/.ansible
ansible all -m setup -a 'gather_subset=!all'
cd ${WORKSPACE}/ocp4-playbooks-extras
cp examples/ocp_compliance_vars.yaml ocp_compliance_vars.yaml
sed -i "s|compliance_enabled:.*$|compliance_enabled: true|g" ocp_compliance_vars.yaml
sed -i "s|compliance_catalogsource_image:.*$|compliance_catalogsource_image: ${COMPLIANCE_CATALOGSOURCE_IMAGE}|g" ocp_compliance_vars.yaml
sed -i "s|compliance_e2e:.*$|compliance_e2e: true|g" ocp_compliance_vars.yaml
sed -i "s|compliance_e2e_github_repo:.*$|compliance_e2e_github_repo: https://github.com/${E2E_TESTS_REPO:-openshift/openshift-tests-private}.git|g" ocp_compliance_vars.yaml
sed -i "s|compliance_e2e_github_branch:.*$|compliance_e2e_github_branch: ${E2E_TESTS_BRANCH:-main}|g" ocp_compliance_vars.yaml
sed -i "s|compliance_github_username:.*$|compliance_github_username: ${GITHUB_USER}|g" ocp_compliance_vars.yaml
sed -i "s|compliance_github_token:.*$|compliance_github_token: ${GITHUB_TOKEN}|g" ocp_compliance_vars.yaml
sed -i "s|compliance_go_tarball:.*$|compliance_go_tarball: ${GOLANG_TARBALL}|g" ocp_compliance_vars.yaml
sed -i "s|compliance_cleanup:.*$|compliance_cleanup: true|g" ocp_compliance_vars.yaml
cat ocp_compliance_vars.yaml
#Inventory Details
cp examples/inventory ./compliance_inventory
sed -i "s|localhost|${BASTION_IP}|g" compliance_inventory
sed -i 's/ansible_connection=local/ansible_connection=ssh/g' compliance_inventory
sed -i "s|ssh|ssh ansible_ssh_private_key_file=${WORKSPACE}/deploy/id_rsa|g" compliance_inventory
cat compliance_inventory
cat ansible.cfg
ansible-playbook  -i compliance_inventory -e @ocp_compliance_vars.yaml playbooks/ocp-compliance.yml
