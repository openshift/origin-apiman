#!/bin/bash

function validate_preflight() {
  set +x
  echo 
  echo PREFLIGHT VALIDATION

  os::int::util::validate check_master_accessible check_provided_certs

  return 0
}

function check_master_accessible() {
  local master_url=${MASTER_URL:-$(oc config view --minify -o jsonpath='{$.clusters[0].cluster.server}')}
  # extracting CA from kubeconfig turns out to be too annoying; just set this for dev:
  local master_ca=${MASTER_CA:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
  os::int::post::check_master_accessible "$master_ca" "$master_url"
}

function check_provided_certs() {
  [ -e "$secret_dir/console.crt" ] && \
  os::int::post::cert_should_have_names "$secret_dir/console.crt" "${console_hostname}"
  [ -e "$secret_dir/gateway.crt" ] && \
  os::int::post::cert_should_have_names "$secret_dir/gateway.crt" "${gateway_hostname}"
  return 0
}

function validate_deployment() {
  return 0
}
