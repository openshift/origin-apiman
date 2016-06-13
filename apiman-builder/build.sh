#!/bin/bash

env

set -exuo pipefail

if [ -z "${DOCKER_SOCKET:-}" ]; then
  echo "Docker socket not specified with DOCKER_SOCKET."
  echo "Ensure exposeDockerSocket is set to true."
  exit 1
elif [ ! -e "${DOCKER_SOCKET}" ]; then
  echo "Docker socket missing at ${DOCKER_SOCKET}"
  exit 1
fi

# get properly situated in the source code
pushd $(mktemp --directory)
if [ -z "${SOURCE_REPOSITORY:-}" ]; then
  # assume source is binary tar input
  tar zvfx - <&0
else
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
  if ! git clone --recursive "${SOURCE_REPOSITORY}" . ; then
    echo "Error trying to fetch git source: ${SOURCE_REPOSITORY}"
    exit 1
  fi
  if [ -n "${SOURCE_REF:-}" ]; then
    if ! git checkout "${SOURCE_REF}"; then
      echo "Error trying to checkout branch: ${SOURCE_REF}"
      exit 1
    fi
  fi
fi
# SOURCE_CONTEXT_DIR is blank for binary build, extract from BUILD
contextDir=$(echo -e "$BUILD" | jq -r .spec.source.contextDir)
[ -n "$contextDir" ] && cd $contextDir

# build and push
if [ -n "${OUTPUT_IMAGE:-}" ] ; then
  tag="${OUTPUT_REGISTRY}/${OUTPUT_IMAGE}"
  [ -d "${PUSH_DOCKERCFG_PATH:-}" ] && [ ! -e "$HOME/.dockercfg" ] && \
    cp "$PUSH_DOCKERCFG_PATH/.dockercfg" "$HOME/.dockercfg"
  mvn -Pf8-build -Pssl -Ddocker.image="${tag}" && docker push "$tag" || exit
else
  mvn -Pf8-build -Pssl
fi

popd
