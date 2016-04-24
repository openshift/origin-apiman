#!/bin/bash

function delete_installation() {
  initialize_vars
  echo "Attempting to delete supporting objects (may fail)"
  # delete oauthclient created in template; we can't search for it by label. the rest is incidental.
  oc process apiman-support-template | oc delete -f - || :
  oc delete all,templates,secrets --selector $label
}

readonly label=apiman-infra  # "constant" label name applied to all our objects
readonly support_label="apiman-infra=support" 

function run_installation() {
  set -x
  initialize_vars
  create_secrets
  create_templates
  create_deployment
  report_success
}

######################################
#
# initialize a lot of variables from env
#
function initialize_vars() {
  image_prefix=${IMAGE_PREFIX:-openshift/origin-}
  image_version=${IMAGE_VERSION:-latest}
  insecure_repos=${INSECURE_REPOS:-false}
  console_hostname=${CONSOLE_HOSTNAME:-apiman.example.com}
  gateway_hostname=${GATEWAY_HOSTNAME:-api-gateway.example.com}
  public_master_url=${PUBLIC_MASTER_URL:-https://localhost:443}
  master_url=${MASTER_URL:-https://kubernetes.default.svc.cluster.local:443}
  # ES cluster parameters:
  es_pvc_size=${ES_PVC_SIZE:-}
  es_pvc_prefix=${ES_PVC_PREFIX:-apiman-es}
  es_instance_ram=${ES_INSTANCE_RAM:-512M}
  es_cluster_size=${ES_CLUSTER_SIZE:-1}
  es_node_quorum=${ES_NODE_QUORUM:-$((es_cluster_size/2+1))}
  es_recover_after_nodes=${ES_RECOVER_AFTER_NODES:-$((es_cluster_size-1))}
  es_recover_expected_nodes=${ES_RECOVER_EXPECTED_NODES:-$es_cluster_size}
  es_recover_after_time=${ES_RECOVER_AFTER_TIME:-5m}

  # other env vars used:
  # WRITE_KUBECONFIG, KEEP_SUPPORT, ENABLE_OPS_CLUSTER
  # other env vars used (expect base64 encoding):
  # KIBANA_KEY, KIBANA_CERT, SERVER_TLS_JSON

}

######################################
#
# generate secret contents and secrets
#
function create_secrets() {
  # generate common node key for the SearchGuard plugin
  openssl rand 16 | openssl enc -aes-128-cbc -nosalt -out $scratch_dir/searchguard-node-key.key -pass pass:pass
  # generate credentials for u/p access to the gateway from the console
  echo "console_user" > $scratch_dir/gateway.access.user
  mktemp -u XXXXXXXXXXXXXX > $scratch_dir/gateway.access.password

  # use or generate server certs
  local file component hostnames secret domain=${project}.svc.cluster.local
  for component in console gateway elasticsearch curator; do
    if [ -s $secret_dir/apiman-${component}.keystore.jks ]; then
      # use files from secret when present
      for file in apiman-${component}.{key,trust}store.jks{,.password}; do
        cp {$secret_dir,$scratch_dir}/$file
      done
    else #fallback to creating one
      hostnames=apiman-${component},apiman-${component}.${domain},localhost
      case "$component" in
        console) hostnames=$hostnames,${console_hostname} ;;
        gateway) hostnames=$hostnames,${gateway_hostname} ;;
        elasticsearch) hostnames=$hostnames,apiman-storage,apiman-storage.${domain} ;;
      esac
      [ "$component" != curator ] && generate_JKS_chain apiman-${component} $hostnames
    fi
    local user="system.apiman.$component"
    # use or generate client certs for accessing ES
    if [ -s $secret_dir/${user}.key ]; then
      for file in ${user}.{key,cert,keystore.jks,keystore.jks.password}; do
        cp {$secret_dir,$scratch_dir}/$file
      done
    else
      generate_PEM_cert "$user"
      generate_JKS_keystore "$user"
    fi
    # generate secret and add to service account
    local secret=( keystore=$scratch_dir/apiman-${component}.keystore.jks
          keystore.password=$scratch_dir/apiman-${component}.keystore.jks.password
          truststore=$scratch_dir/apiman-${component}.truststore.jks
          truststore.password=$scratch_dir/apiman-${component}.truststore.jks.password
          client.key=$scratch_dir/${user}.key
          client.crt=$scratch_dir/${user}.crt
          client.keystore=$scratch_dir/${user}.keystore.jks
          client.keystore.password=$scratch_dir/${user}.keystore.jks.password
          ca.crt=$scratch_dir/ca.crt
          )
    case "$component" in
      #console|gateway) secret+=( auth-user=$scratch_dir/gateway.access.user auth-password=$scratch_dir/gateway.access.password ) ;;
      elasticsearch)   secret+=( searchguard-node-key=$scratch_dir/searchguard-node-key.key ) ;;
      curator)         secret=(
                          client.key=$scratch_dir/${user}.key
                          client.crt=$scratch_dir/${user}.crt
                          client.keystore=$scratch_dir/${user}.keystore.jks
                          client.keystore.password=$scratch_dir/${user}.keystore.jks.password
                          ca.crt=$scratch_dir/ca.crt
                       ) ;;
    esac
    oc secrets new apiman-$component ${secret[@]}
    oc label secret/apiman-$component $support_label # make them easier to delete later
    oc secrets add serviceaccount/apiman-$component secrets/apiman-$component --for=mount
  done
}

######################################
#
# generate templates needed
#
function create_templates() {
  echo "Creating templates"
  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${STORAGE_NODESELECTOR:-})" \
           templates/es.yaml | oc process -f -  \
           --value "ES_INSTANCE_RAM=${es_instance_ram}" \
           --value "ES_NODE_QUORUM=${es_node_quorum}" \
           --value "ES_RECOVER_AFTER_NODES=${es_recover_after_nodes}" \
           --value "ES_RECOVER_EXPECTED_NODES=${es_recover_expected_nodes}" \
           --value "ES_RECOVER_AFTER_TIME=${es_recover_after_time}" \
           --value "IMAGE_VERSION_DEFAULT=${image_version}" \
           | oc create -f -

  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${CURATOR_NODESELECTOR:-})" \
           templates/curator.yaml | oc process -f - \
           --value "ES_HOST=apiman-storage" \
           --value "MASTER_URL=${master_url}" \
           --value "IMAGE_VERSION_DEFAULT=${image_version}" \
           | oc create -f -

  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${CONSOLE_NODESELECTOR:-})" \
           templates/console.yaml | oc process -f - \
           --value "PUBLIC_MASTER_URL=${public_master_url}" \
           --value "GATEWAY_PUBLIC_HOSTNAME=${gateway_hostname}" \
           --value "IMAGE_VERSION_DEFAULT=${image_version}" \
           | oc create -f -

  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${GATEWAY_NODESELECTOR:-})" \
           templates/gateway.yaml | oc process -f - \
           --value "ES_HOST=apiman-storage" \
           --value "IMAGE_VERSION_DEFAULT=${image_version}" \
           | oc create -f -

  oc new-app -f templates/support.yaml \
           --param "CONSOLE_HOSTNAME=${console_hostname}" \
           --param "IMAGE_PREFIX=${image_prefix}"
}

######################################
#
# Create "things", mostly from templates
#
function create_deployment() {
  echo "Creating deployed objects"
  oc new-app apiman-imagestream-template --param "INSECURE_REPOS=${insecure_repos}" || :
  # these may fail if already created; that's ok
           
  oc process apiman-support-template | oc create -f -

  # routes
  os::int::deploy::procure_route_cert "$scratch_dir" "$secret_dir" console-route
  local -a console_route_params=( --service="apiman-console" 
                                  --hostname="${console_hostname}" 
                                  --dest-ca-cert="$scratch_dir/ca.crt" )
  [ -e "$scratch_dir/console-route.crt" ] && console_route_params+=(
                                  --key="$scratch_dir/console-route.key"
                                  --cert="$scratch_dir/console-route.crt" )
  oc create route reencrypt "${console_route_params[@]}"
  os::int::deploy::procure_route_cert "$scratch_dir" "$secret_dir" gateway-route
  local -a gateway_route_params=( --service="apiman-gateway"
                                  --hostname="${gateway_hostname}"
                                  --dest-ca-cert="$scratch_dir/ca.crt" )
  [ -e "$scratch_dir/gateway-route.crt" ] && gateway_route_params+=(
                                  --key="$scratch_dir/gateway-route.key"
                                  --cert="$scratch_dir/gateway-route.crt" )
  oc create route reencrypt "${gateway_route_params[@]}"

  # PVCs
  local -A pvcs=()
  local pvc n
  for pvc in $(oc get persistentvolumeclaim --template='{{range .items}}{{.metadata.name}} {{end}}' 2>/dev/null); do
    pvcs["$pvc"]=1  # note, map all that exist, not just ones labeled as supporting
  done
  for ((n=1;n<=${es_cluster_size};n++)); do
    pvc="${es_pvc_prefix}$n"
    if [ "${pvcs[$pvc]:-}" != 1 -a "${es_pvc_size:-}" != "" ]; then # doesn't exist, create it
      oc process apiman-pvc-template --value "NAME=$pvc,SIZE=${es_pvc_size}" | oc create -f -
      pvcs["$pvc"]=1
    fi
    if [ "${pvcs[$pvc]:-}" = 1 ]; then # exists (now), attach it
      oc process apiman-es-template | oc volume -f - \
                --add --overwrite --name=elasticsearch-storage \
                --type=persistentVolumeClaim --claim-name="$pvc"
    else
      oc process apiman-es-template | oc create -f -
    fi
  done
  oc process apiman-console-template | oc create -f -
  oc process apiman-gateway-template | oc create -f -
  oc process apiman-curator-template | oc create -f -
}

######################################
#
# Give the user some helpful output
#
function report_success() {
  set +x

  cat <<EOF

Success!
=================================

The deployer has created secrets, templates, and
component deployments required for APIMan integration.

EOF
}
