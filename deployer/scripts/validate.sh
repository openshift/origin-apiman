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
  # likewise, just reading nodes isn't enough, but lack of access is a good indicator.
  if ! output=$(os::int::util::check_exists nodes --context=apiman-console-serviceaccount); then
    echo "The apiman-console ServiceAccount does not have the required access."
    echo "Give it cluster-reader access with:"
    echo "  \$ oadm policy add-cluster-role-to-user cluster-reader system:serviceaccount:${project}:apiman-console"
    return 1
  fi
  return 0
}

function check_routes() {
  local route failure=false
  for route in apiman-{console,gateway}; do
    os::int::post::test_deployed_route $route || failure=true
  done
  [ "$failure" = false ] || return 1
}

function validate_deployment() {
  printf '\n%s\n' 'DEPLOYMENT VALIDATION'
  os::int::util::check_chained_validations \
    check_secrets check_deployer check_elasticsearch \
      || exit
}

function check_secrets() {
  local tmpl secret keys out
  tmpl='{{range $k, $_ := .data}}{{$k}}{{"\n"}}{{end}}'
  while read secret keys; do
    out=$(oc get "secret/$secret" --template "$tmpl" | xargs echo)
    [ "$out" == "$keys" ] && continue
    validation_failure \
      "Wrong data on deployer-generated secret $secret" \
      "$(printf 'Expected:\n%s\nGot:\n%s\n' "$keys" "$out")"
    return 1
  done <<-'EOF'
		apiman-elasticsearch \
			ca.crt client.crt client.key client.keystore client.keystore.password \
			keystore keystore.password searchguard-node-key truststore \
			truststore.password
		apiman-console \
			ca.crt client.crt client.key client.keystore client.keystore.password \
			gateway.user keystore keystore.password truststore truststore.password
		apiman-gateway \
			ca.crt client.crt client.key client.keystore client.keystore.password \
			gateway.user keystore keystore.password truststore truststore.password
		EOF
}

function check_deployer() {
  local line out
  while read line; do
    out=$(os::int::util::check_exists $line 2>&1) && continue
    printf >&2 '%s\n' "$out"
    return 1
  done <<-'EOF'
		imagestreams apiman-console apiman-elasticsearch apiman-gateway
		serviceaccounts \
			apiman-console apiman-deployer apiman-elasticsearch apiman-gateway
		configmaps apiman-elasticsearch apiman-curator
		deploymentconfigs \
			apiman-console apiman-gateway apiman-console apiman-gateway
		deploymentconfigs --selector component=elasticsearch
		services apiman-console apiman-es-cluster apiman-gateway apiman-storage
		routes apiman-console apiman-gateway
		EOF
}

check_elasticsearch() {
  # curl(1):
  # 52: The server didn't reply anything.
  # 58: Problem with the local certificate.
  # 60: Peer certificate cannot be authenticated with known CA certificates.
  local deadline es_url
  es_url=apiman-storage:9200
  deadline=$(($(date +%s) + 3 * 60))
  while :; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf >&2 '%s\n' 'Timeout waiting for elasticsearch to be up.'
      return 1
    fi
    curl --max-time 18 "$es_url" &> /dev/null
    [ $? -eq 52 ] && break
    sleep 18
  done
  if curl "$es_url" &> /dev/null || [ $? != 52 ]; then
    validation_failure \
      'Invalid response from Elasticsearch' \
      'Should have received an empty response when accessing using http'
  fi
  es_url=https://$es_url
  if curl "$es_url" &> /dev/null || [ $? != 60 ]; then
    validation_failure \
      'Invalid response from Elasticsearch' \
      'Should get an error connecting without a CA to verify the server'
  fi
  if curl --insecure "$es_url" &> /dev/null || [ $? != 58 ]; then
    validation_failure \
      'Invalid response from Elasticsearch' \
      'Should get an error without configuring a client certificate'
  fi
}

validation_failure() {
  printf >&2 '%s.\n\n%s\n' "$@"
  return 1
}
