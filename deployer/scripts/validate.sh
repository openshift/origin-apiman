#!/bin/bash

function validate_preflight() {
  set +x
  echo 
  echo PREFLIGHT VALIDATION

  if ! os::int::util::validate check_master_accessible check_provided_certs check_service_accounts; then
    echo
    echo "Deployment has been aborted prior to starting, as these failures often indicate fatal problems."
    echo "Please evaluate any error messages above and determine how they can be addressed."
    echo "To ignore this validation failure and continue, specify IGNORE_PREFLIGHT=true."
    echo
    return 1
  fi

  return 0
}

function check_master_accessible() {
  local master_url=${MASTER_URL:-$(oc config view --minify -o jsonpath='{$.clusters[0].cluster.server}')}
  # extracting CA from kubeconfig turns out to be too annoying; just set this for dev:
  local master_ca=${MASTER_CA:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
  os::int::pre::check_master_accessible "$master_ca" "$master_url"
}

function check_provided_certs() {
  [ -e "$secret_dir/console.crt" ] && \
  os::int::pre::cert_should_have_names "$secret_dir/console.crt" "${console_hostname}"
  [ -e "$secret_dir/gateway.crt" ] && \
  os::int::pre::cert_should_have_names "$secret_dir/gateway.crt" "${gateway_hostname}"
  return 0
}

function check_service_accounts() {
  local output sa
  # inability to access SAs indicates that we didn't get the edit role.
  # it's not a perfect test but will catch those who fail to follow directions.
  if ! output=$(os::int::util::check_exists serviceaccounts); then
    echo "Deployer does not have expected access in the ${project} project."
    echo "Give it edit access with:"
    echo '  $ oc policy add-role-to-user edit -z apiman-deployer'
    return 1
  fi
  for sa in apiman-{gateway,console,elasticsearch,curator}; do
    os::int::pre::check_service_account $project $sa || return 1
  done
  return 0
}

function validate_deployment() {
  return 0
}

function check_routes() {
  local route failure=false
  for route in apiman-{console,gateway}; do
    os::int::post::test_deployed_route $route || failure=true
  done
  [ "$failure" = false ] || return 1
}

