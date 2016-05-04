#!/bin/bash

set -euo pipefail

if [ -z "${DOCKER_SOCKET:-}" ]; then
  echo "Docker socket not specified with DOCKER_SOCKET."
  echo "Ensure exposeDockerSocket is set to true."
  exit 1
elif [ ! -e "${DOCKER_SOCKET}" ]; then
  echo "Docker socket missing at ${DOCKER_SOCKET}"
  exit 1
fi

tag=""
[ -n "${OUTPUT_IMAGE:-}" ] && tag="${OUTPUT_REGISTRY}/${OUTPUT_IMAGE}"

# preflight check whether remote addr comes back in a reasonable time
if ! [[ $SOURCE_REPOSITORY =~ ^git[@:] ]] ; then
  url="${SOURCE_REPOSITORY}"
  [[ $url =~ ^https?:// ]] || url="https://${url}"
  if ! curl --head --silent --fail --location --max-time 16 $url > /dev/null; then
    echo "Could not access source url: ${SOURCE_REPOSITORY}"
    exit 1
  fi
fi

# actually check out the code
BUILD_DIR=$(mktemp --directory)
if ! git clone --recursive "${SOURCE_REPOSITORY}" "${BUILD_DIR}"; then
  echo "Error trying to fetch git source: ${SOURCE_REPOSITORY}"
  exit 1
fi
pushd "${BUILD_DIR}"
if [ -n "${SOURCE_REF:-}" ]; then
  if ! git checkout "${SOURCE_REF}"; then
    echo "Error trying to checkout branch: ${SOURCE_REF}"
    exit 1
  fi
fi
[ -n "${SOURCE_CONTEXT_DIR:-}" ] && cd $SOURCE_CONTEXT_DIR

# build and push
if [ -n "${tag:-}" ]; then
  [ -d /var/run/secrets/openshift.io/push ] && [ ! -e $HOME/.dockercfg ] && \
    cp /var/run/secrets/openshift.io/push/.dockercfg $HOME/.dockercfg
  mvn -Pf8-build -Pssl -Ddocker.image="${tag}" && docker push "$tag"
else
  mvn -Pf8-build -Pssl
fi

popd
