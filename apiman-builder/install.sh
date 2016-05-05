#!/bin/bash

set -euo pipefail

# install newer maven than is available in centos
curl -o maven.tgz \
  http://apache.mirrors.tds.net/maven/maven-3/3.3.9/binaries/apache-maven-3.3.9-bin.tar.gz
tar zfx maven.tgz
ln -s $HOME/apache-maven-3.3.9/bin/mvn /bin/mvn
rm maven.tgz
