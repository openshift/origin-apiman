FROM openshift/origin:latest

MAINTAINER OpenShift Development <dev@lists.openshift.redhat.com>

ENV BIN_DIR=/opt/deploy \
    HOME=/etc/deploy \
    SCRATCH_DIR=/etc/deploy \
    SECRET_DIR=/secret \
    KUBECONFIG=/etc/deploy/.kubeconfig \
    CREATE_KUBECONFIG=1 \
    JAVA_HOME=/usr/lib/jvm/jre-1.8.0-openjdk

RUN yum install -y java-1.8.0-openjdk openssl && yum clean all

RUN mkdir -p ${HOME} ${BIN_DIR} && chmod 777 ${HOME} && chmod 555 ${BIN_DIR}
COPY .  ${BIN_DIR}
WORKDIR ${BIN_DIR}

VOLUME ${HOME}
ENTRYPOINT ["./run.sh"]
USER 1000
