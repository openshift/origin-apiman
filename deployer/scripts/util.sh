#!/bin/bash


function generate_PEM_cert() {
  local name="$1"
  os::int::deploy::initialize_signing_conf "$scratch_dir" "$secret_dir"

  echo Generating certificate for server ${name}

  openssl req -out "$scratch_dir/$name.csr" -new -newkey rsa:2048 -keyout "$scratch_dir/$name.key" -subj "/CN=$name/OU=OpenShift/O=APIMan/L=Deploy/C=DE" -days 712 -nodes

  echo Sign certificate request with CA
  openssl ca \
      -in "$scratch_dir/$name.csr" \
      -notext \
      -out "$scratch_dir/$name.crt" \
      -config $scratch_dir/signing.conf \
      -extensions v3_req \
      -batch \
          -extensions server_ext
}


function generate_JKS_chain() {
  local server_name=$1 cert_names=${2:-$server_name}
  os::int::deploy::initialize_signing_conf "$scratch_dir" "$secret_dir"
  local ks_pass=${KS_PASS:-$(mktemp -u XXXXXXXXXXX)} ts_pass=${TS_PASS:-$(mktemp -u XXXXXXXXXXX)}
  local extension_names=""
  for name in ${cert_names//,/ }; do
          extension_names="${extension_names},dns:${name}"
  done

  echo Generating keystore for server $server_name

  keytool -genkeypair \
          -alias     $server_name \
          -keystore  $scratch_dir/${server_name}.keystore.jks \
          -keypass   $ks_pass \
          -storepass $ks_pass \
          -keyalg    RSA \
          -keysize   2048 \
          -validity  712 \
          -dname "CN=$server_name, OU=APIMan, O=TLS, L=Cert, C=DE"

  echo Generating certificate signing request for server $server_name

  keytool -certreq \
          -alias      $server_name \
          -keystore   $scratch_dir/${server_name}.keystore.jks \
          -storepass  $ks_pass \
          -file       $scratch_dir/$server_name.csr \
          -keyalg     rsa \
          -dname "CN=$server_name, OU=APIMan, O=TLS, L=Cert, C=DE" \
          -ext san=dns:localhost,ip:127.0.0.1"${extension_names}"

  echo Sign certificate request with CA

  openssl ca \
      -in $scratch_dir/$server_name.csr \
      -notext \
      -out $scratch_dir/$server_name.crt \
      -config $scratch_dir/signing.conf \
      -extensions v3_req \
      -batch \
          -extensions server_ext

  echo "Import back to keystore (including CA chain)"

  keytool  \
      -import \
      -file $scratch_dir/ca.crt  \
      -keystore $scratch_dir/${server_name}.keystore.jks   \
      -storepass $ks_pass  \
      -noprompt -alias sig-ca

  keytool \
      -import \
      -file $scratch_dir/$server_name.crt \
      -keystore $scratch_dir/${server_name}.keystore.jks \
      -storepass $ks_pass \
      -noprompt \
      -alias $server_name

  echo "Import CA to truststore for validating client certs"

  keytool  \
      -import \
      -file $scratch_dir/ca.crt  \
      -keystore $scratch_dir/${server_name}.truststore.jks   \
      -storepass $ts_pass  \
      -noprompt -alias sig-ca

  echo -n $ks_pass > $scratch_dir/${server_name}.keystore.jks.password
  echo -n $ts_pass > $scratch_dir/${server_name}.truststore.jks.password

  echo All done for $server_name
}

function generate_JKS_keystore() {
  local name=$1
  os::int::deploy::initialize_signing_conf "$scratch_dir" "$secret_dir"
  local file ks_pass=${KS_PASS:-$(mktemp -u XXXXXXXXXXX)}
  echo $ks_pass > $scratch_dir/${name}.keystore.jks.password

  echo Generating keystore for client $name
  keytool  \
      -genkeypair \
      -keystore $scratch_dir/${name}.keystore.jks   \
      -storepass $ks_pass  \
      -keypass $ks_pass  \
      -keyalg    RSA \
      -keysize   2048 \
      -dname "CN=$name, OU=APIMan, O=TLS, L=Cert, C=DE" \
      -alias $name

  echo Generating certificate signing request for client $name
  keytool -certreq \
      -alias      ${name} \
      -keystore   $scratch_dir/${name}.keystore.jks \
      -storepass  $ks_pass \
      -file       $scratch_dir/${name}.jks.csr \
      -keyalg     rsa \
      -dname "CN=$name, OU=APIMan, O=TLS, L=Cert, C=DE"

  echo Sign certificate request with CA
  openssl ca \
      -in $scratch_dir/${name}.jks.csr \
      -notext \
      -out $scratch_dir/${name}.jks.crt \
      -config $scratch_dir/signing.conf \
      -batch

  echo "Import cert back to keystore (CA required too)"
  keytool  \
      -import \
      -file $scratch_dir/ca.crt  \
      -keystore $scratch_dir/${name}.keystore.jks   \
      -storepass $ks_pass  \
      -noprompt -alias sig-ca
  keytool \
      -import \
      -file $scratch_dir/${name}.jks.crt \
      -keystore $scratch_dir/${name}.keystore.jks \
      -storepass $ks_pass \
      -noprompt \
      -alias ${name}

}
