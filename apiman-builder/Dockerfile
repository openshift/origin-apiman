# custom builder for doing a maven build of APIMan -
# Origin-only as Enterprise should use productized packaging.

FROM centos:centos7
MAINTAINER OpenShift Development <dev@lists.openshift.redhat.com>
USER 0
ENV HOME=/opt/origin/builder
WORKDIR ${HOME}

RUN yum install -y --setopt=tsflags=nodocs \
                java-1.8.0-openjdk java-1.8.0-openjdk-devel docker jq && \
    yum clean all
ADD install.sh ${HOME}/
RUN ${HOME}/install.sh

ADD build.sh ${HOME}/
CMD ["bash", "build.sh"]
