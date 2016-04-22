#!/bin/bash
set -exuo pipefail

for script in scripts/*.sh ../common/bash/validation/*.sh ../common/bash/deploy/*.sh; do
  source $script
done

mode=${MODE:-install}
project=${PROJECT:-openshift-infra}
scratch_dir=${SCRATCH_DIR:-_output}
secret_dir=${SECRET_DIR:-_secret}
ignore_preflight=${IGNORE_PREFLIGHT:-false}

# following are useful in dev, but expected to fail inside container
mkdir -p $scratch_dir && chmod 700 $scratch_dir && rm -rf $scratch_dir/* || :
mkdir -p $secret_dir && chmod 700 $secret_dir || :

os::int::deploy::write_kubeconfig "$scratch_dir" "$project"

case "${mode}" in
  preflight)
      validate_preflight
    ;;
  install|deploy)
      validate_preflight || [ "$ignore_preflight" = true ]
      run_installation
      validate_deployment
    ;;
  reinstall|redeploy)
      validate_preflight || [ "$ignore_preflight" = true ]
      delete_installation
      run_installation
      validate_deployment
    ;;
  uninstall|delete|remove)
      delete_installation
    ;;
  validate)
      validate_preflight || [ "$ignore_preflight" = true ]
      validate_deployment
    ;;
  *)
    echo "Invalid mode provided. One of [preflight|install|reinstall|uninstall|validate] was expected";
    exit 1
    ;;
esac
