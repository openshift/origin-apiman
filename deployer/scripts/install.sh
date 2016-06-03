#!/bin/bash

function delete_installation() {
  initialize_vars
  echo "Deleting supporting objects"
  oc delete all,templates,secrets,configmaps --selector $label
}

readonly label=apiman-infra  # "constant" label name applied to all our objects
readonly support_label="apiman-infra=support"

function run_installation() {
  set -x
  initialize_vars
  create_config
  create_templates
  create_deployment
  report_success
}

######################################
#
# initialize a lot of variables from env
#
declare -A input_vars=()
function initialize_vars() {
  set +x
  local configmap secret index value var
  local index_template='{{range $index, $element :=.data}}{{println $index}}{{end}}'
  # if configmap exists, get values from it
  if configmap=$(oc get configmap/apiman-deployer --template="$index_template"); then
    for index in $configmap; do
      input_vars[$index]=$(oc get configmap/apiman-deployer --template="{{println (index .data \"$index\")}}")
    done
  fi
  # if secret exists, get values from it
  if secret=$(oc get secret/apiman-deployer --template="$index_template"); then
    for index in $secret; do
      : ${input_vars[$index]:=$(oc get secret/apiman-deployer --template="{{println (index .data \"$index\")}}" | base64 -d)}
    done
  fi
  # if legacy variables set, use them to fill unset inputs
  for var in PUBLIC_MASTER_URL MASTER_URL {CONSOLE,GATEWAY}_HOSTNAME {STORAGE,CURATOR,CONSOLE,GATEWAY}_NODESELECTOR \
             ES_{INSTANCE_RAM,PVC_SIZE,PVC_PREFIX,CLUSTER_SIZE,NODE_QUORUM,RECOVER_AFTER_NODES,RECOVER_EXPECTED_NODES,RECOVER_AFTER_TIME}
  do
    [ ${!var+set} ] || continue
    index=${var,,} # lowercase
    index=${index//_/-} # underscore to hyphen
    : ${input_vars[$index]:=${!var}}
  done
  set -x

  console_hostname=${input_vars[console-hostname]:-apiman.example.com}
  gateway_hostname=${input_vars[gateway-hostname]:-api-gateway.example.com}
  public_master_url=${input_vars[public-master-url]:-https://localhost:8443}
  master_url=${input_vars[master-url]:-https://kubernetes.default.svc.cluster.local:443}
  # ES cluster parameters:
  es_instance_ram=${input_vars[es-instance-ram]:-512M}
  es_pvc_size=${input_vars[es-pvc-size]:-}
  es_pvc_prefix=${input_vars[es-pvc-prefix]:-}
  es_cluster_size=${input_vars[es-cluster-size]:-1}
  es_node_quorum=${input_vars[es-node-quorum]:-$((es_cluster_size/2+1))}
  es_recover_after_nodes=${input_vars[es-recover-after-nodes]:-$((es_cluster_size-1))}
  es_recover_expected_nodes=${input_vars[es-recover-expected-nodes]:-$es_cluster_size}
  es_recover_after_time=${input_vars[es-recover-after-time]:-5m}

  image_prefix=${IMAGE_PREFIX:-openshift/origin-}
  image_version=${IMAGE_VERSION:-latest}

}

######################################
#
# generate contents and API objects for secrets and configmap
#
function create_config() {
  # generate elasticsearch configmap
  oc create configmap apiman-elasticsearch \
    --from-file=common/elasticsearch/logging.yml \
    --from-file=conf/elasticsearch.yml
  oc label configmap/apiman-elasticsearch $support_label # make easier to delete later
  # generate curator configmap
  oc create configmap apiman-curator \
    --from-file=config.yaml=conf/curator.yml
  oc label configmap/apiman-curator $support_label # make easier to delete later

  # generate common node key for the SearchGuard plugin
  openssl rand 16 | openssl enc -aes-128-cbc -nosalt -out $scratch_dir/searchguard-node-key.key -pass pass:pass
  # generate credentials for u/p access to the gateway from the console
  echo -n "console_user," > $scratch_dir/gateway.user
  mktemp -u XXXXXXXXXXXXXX >> $scratch_dir/gateway.user

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
      console|gateway) secret+=( gateway.user=$scratch_dir/gateway.user ) ;;
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
  if [ "${input_vars[image-pull-secret]+set}" ]; then
    for account in apiman-{console,gateway,elasticsearch,curator}; do
      oc secrets add --for=pull "serviceaccount/$account" "secret/${input_vars[image-pull-secret]}" 
    done
  fi

}

######################################
#
# generate templates needed
#
function create_templates() {
  echo "Creating templates"
  local image_params="IMAGE_VERSION_DEFAULT=${image_version},IMAGE_PREFIX_DEFAULT=${image_prefix}"
  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${input_vars[storage-nodeselector]:-})" \
           templates/es.yaml | oc process -f -  \
           --value "ES_INSTANCE_RAM=${es_instance_ram}" \
           --value "ES_NODE_QUORUM=${es_node_quorum}" \
           --value "ES_RECOVER_AFTER_NODES=${es_recover_after_nodes}" \
           --value "ES_RECOVER_EXPECTED_NODES=${es_recover_expected_nodes}" \
           --value "ES_RECOVER_AFTER_TIME=${es_recover_after_time}" \
           --value "$image_params" \
           | oc create -f -

  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${input_vars[curator-nodeselector]:-})" \
           templates/curator.yaml | oc process -f - \
           --value "ES_HOST=apiman-storage" \
           --value "MASTER_URL=${master_url}" \
           --value "$image_params" \
           | oc create -f -

  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${input_vars[console-nodeselector]:-})" \
           templates/console.yaml | oc process -f - \
           --value "PUBLIC_MASTER_URL=${public_master_url}" \
           --value "GATEWAY_PUBLIC_HOSTNAME=${gateway_hostname}" \
           --value "$image_params" \
           | oc create -f -

  sed "/serviceAccountName/ i\
\          $(os::int::deploy::extract_nodeselector ${input_vars[gateway-nodeselector]:-})" \
           templates/gateway.yaml | oc process -f - \
           --value "ES_HOST=apiman-storage" \
           --value "$image_params" \
           | oc create -f -

  oc new-app -f templates/support.yaml \
           --param "CONSOLE_HOSTNAME=${console_hostname}" \
           --param "IMAGE_PREFIX_DEFAULT=${image_prefix}"
}

######################################
#
# Create "things", mostly from templates
#
function create_deployment() {
  echo "Creating deployed objects"
  oc new-app apiman-support-template

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

  # PVCs and deployments
  local -A pvcs=()
  local pvc n dc
  for pvc in $(oc get persistentvolumeclaim --template='{{range .items}}{{.metadata.name}} {{end}}' 2>/dev/null); do
    pvcs["$pvc"]=1  # note, map all that exist, not just ones labeled as supporting
  done
  for ((n=1;n<=${es_cluster_size};n++)); do
    pvc="${es_pvc_prefix}$n"
    if [ "${pvcs[$pvc]:-}" != 1 -a "${es_pvc_size:-}" != "" ]; then # doesn't exist, create it
      oc new-app apiman-pvc-template --parameter "NAME=$pvc,SIZE=${es_pvc_size}"
      pvcs["$pvc"]=1
    fi
    dc=$(oc new-app apiman-es-template -o name)
    [ "${pvcs[$pvc]:-}" = 1 ] &&
      oc set volume $dc --add --overwrite --name=elasticsearch-storage \
                        --type=persistentVolumeClaim --claim-name="$pvc"
    oc deploy --latest $dc
  done
  oc new-app apiman-curator-template
  oc new-app apiman-gateway-template
  oc new-app apiman-console-template
  for dc in apiman-{curator,gateway,console}; do
    oc deploy --latest $dc
  done
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
