
usage(){
  echo "$0 <service-name>"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

SERVICE=$1

openssl genrsa -out certs/${SERVICE}.key 2048

openssl req -new -key certs/${SERVICE}.key -out certs/${SERVICE}.csr -subj "/C=PT/ST=Lisbon/L=Lisbon/O=Marionete/OU=IT/CN=${SERVICE}"

openssl x509 -req \
  -in certs/${SERVICE}.csr \
  -CAkey ca/ca.key \
  -CA ca/ca.crt \
  -CAcreateserial \
  -out certs/${SERVICE}.crt \
  -days 3650 \
  -sha256 \
  -extfile <(printf "subjectAltName=DNS:${SERVICE},DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=digitalSignature,keyEncipherment,keyAgreement\nsubjectKeyIdentifier=hash")