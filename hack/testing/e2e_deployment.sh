#!/bin/bash
set -euo pipefail

ORIGIN_APIMAN_ROOT=$(realpath --no-symlinks "$(dirname "$BASH_SOURCE")/../..")
export INTEGRATION_COMMON_ROOT=$ORIGIN_APIMAN_ROOT/deployer/common
export VERBOSE=1
readonly ORIGIN_APIMAN_ROOT INTEGRATION_COMMON_ROOT VERBOSE

source "$INTEGRATION_COMMON_ROOT/bash/testing/cmd_util.sh"
source "$INTEGRATION_COMMON_ROOT/bash/testing/lib/util/environment.sh"
os::util::environment::setup_time_vars

main() {
    parse_args "$@"
    [ "${BOOTSTRAP_OS:-}" ] && bootstrap_os
    [ "${CLEANUP:-}" ] && trap "oc delete project/$TMP_PROJECT" EXIT
    [ "${TMP_PROJECT:-}" ] \
        && oc new-project "apiman-e2e-test-$(mktemp -u XXXXX | tr [A-Z] [a-z])"
    [ "${DEPLOY:-}" ] && setup_for_deployer
    build_images \
        "${LOCAL_SOURCE:-}" "${IMAGE_PREFIX:-}" "${INSECURE_REPOSITORY:-}"
    run_deployer \
        "${DEPLOY:+deploy}" \
        "$(get_image_prefix "${LOCAL_SOURCE:-}" "${IMAGE_PREFIX:-}")"
    check_deployer
}

parse_args() {
    local long tmp
    long=bootstrap-os,cleanup,deploy,image-prefix:,insecure-repository
    long=$long,local-source,tmp-project
    tmp=$(getopt --options '' --long "$long" --name "$(basename "$0")" -- "$@")
    eval set -- "$tmp"
    while [ "$1" != -- ]; do
        case "$1" in
            --bootstrap-os) BOOTSTRAP_OS=bootstrap_os; shift;;
            --local-source) LOCAL_SOURCE=local_source; shift;;
            --image-prefix) IMAGE_PREFIX=$2; shift 2;;
            --insecure-repository)
                INSECURE_REPOSITORY=insecure_repository; shift;;
            --deploy) DEPLOY=deploy; shift;;
            --cleanup) CLEANUP=cleanup; shift;;
            --tmp-project) TMP_PROJECT=tmp_project; shift;;
        esac
    done
    if [ ! "${DEPLOY:-}" ]; then
        [ "${TMP_PROJECT:-}" ] \
            && args_error 'can only use temporary project when deploying'
        [ "${CLEANUP:-}" ] \
            && args_error 'can only use "cleanup" when deploying'
    fi
    [ "${CLEANUP:-}" -a ! "${TMP_PROJECT:-}" ] \
        && args_error 'can only use "cleanup" with a temporary project'
    return 0
}

args_error() {
    printf >&2 "%s: %s\n" "$(basename "$0")" "$@"
    exit 1
}

bootstrap_os() {
    os::util::environment::use_sudo
    os::util::environment::setup_tmpdir_vars origin-apiman
    os::util::environment::setup_kubelet_vars
    os::util::environment::setup_etcd_vars
    os::util::environment::setup_server_vars
    export USE_IMAGES='openshift/origin-${component}:latest'
    os::util::environment::setup_images_vars
    configure_os_server
    start_os_server
    install_registry
    wait_for_registry
    export KUBECONFIG="${ADMIN_KUBECONFIG}"
}

setup_for_deployer() {
    os::cmd::expect_success \
        'oc create -f "$ORIGIN_APIMAN_ROOT/deployer/deployer.yaml"'
    os::cmd::expect_success \
        'oc new-app --template=apiman-deployer-account-template'
    os::cmd::expect_success \
        "$(echo \
            oadm policy add-cluster-role-to-user cluster-reader \
            "system:serviceaccount:$(oc project --short):apiman-console")"
    os::cmd::expect_success \
        'oc secrets new apiman-deployer nothing=/dev/null'
    os::cmd::expect_success \
        "$(echo \
            oc create configmap apiman-deployer \
                --from-literal gateway-hostname=gateway.example.com \
                --from-literal console-hostname=console.example.com \
                --from-literal public-master-url=master.example.com \
                --from-literal es-cluster-size=1)"
}

build_images() {
    local local_source=$1 image_prefix=$2 insecure_repository=$3 get_is_tags
    if [ ! "$local_source" -a ! "$image_prefix"]; then
        os::cmd::expect_success \
            'oc new-app -f $ORIGIN_APIMAN_ROOT/hack/dev-builds.yaml'
    else
        oc new-app \
            -f $ORIGIN_APIMAN_ROOT/hack/dev-local-builds.yaml \
            ${image_prefix:+-p "IMAGE_PREFIX=$image_prefix"} \
            ${insecure_repository:+-p INSECURE_REPOSITORY=true} \
                || true
    fi
    if [ "$local_source" ]; then
        for x in deployer elasticsearch curator builder; do
            oc start-build "apiman-$x" \
                --follow --wait --from-dir="$ORIGIN_APIMAN_ROOT"
        done
    fi
    get_is_tags='{{range .status.tags}}{{.tag}}{{"\n"}}{{end}}'
    get_is_tags="oc get --template '$get_is_tags' imagestream"
    for x in deployer elasticsearch curator builder gateway console; do
        os::cmd::try_until_text \
            "$get_is_tags apiman-$x" '^latest$' "$((5 * TIME_MIN ))" 10
    done
}

get_image_prefix() {
    local local_source=$1 image_prefix=$2
    [ "$image_prefix" ] && { echo "$image_prefix"; return; }
    oc get imagestream/apiman-elasticsearch \
        --template '{{.status.dockerImageRepository}}' \
        | sed 's,[^/]*$,,'
}

run_deployer() {
    local mode=$1 image_prefix=$2
    os::cmd::expect_success "$(echo \
        oc new-app --template=apiman-deployer-template \
            --param MODE=${mode:-validate} \
            ${image_prefix:+--param "IMAGE_PREFIX=$image_prefix"})"
}

check_deployer() {
    local tmpl deployer_pod
    tmpl='{{.metadata.creationTimestamp}} {{.metadata.name}}'
    tmpl="{{range .items}}$tmpl{{\"\n\"}}{{end}}"
    deployer_pod=pod/$(oc get pods \
        --selector component=deployer --template "$tmpl" \
            | sort -rn | { awk 'NR=1{print$2;exit}' || true; })
    tmpl='{{.status.phase}}{{"\n"}}'
    os::cmd::try_until_text \
        "oc get '$deployer_pod' --template '$tmpl'" \
        '^Running|Succeeded|Failed$' "$((5 * TIME_MIN))" 5
    oc logs -f "$deployer_pod"
    os::cmd::try_until_text \
        "oc get '$deployer_pod' --template '$tmpl'" \
        '^Succeeded|Failed$' "$((30 * TIME_SEC))" 1
    os::cmd::expect_success_and_text \
        "oc get '$deployer_pod' --template '$tmpl'" \
        '^Succeeded$'
}

main "$@"
