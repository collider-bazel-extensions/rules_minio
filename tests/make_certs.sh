#!/usr/bin/env bash
# genrule: a test CA and a server certificate (127.0.0.1 / localhost),
# made with the toolchain's openssl. Argv: <openssl> <out dir>
set -euo pipefail
openssl="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="$2"
mkdir -p "$out"
cd "$out"
printf '[req]\ndistinguished_name = dn\n[dn]\n' > openssl.cnf
export OPENSSL_CONF="$PWD/openssl.cnf"
"$openssl" req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=provided CA" \
  -keyout ca.key -out ca.crt -addext basicConstraints=critical,CA:TRUE \
  -addext keyUsage=critical,keyCertSign,cRLSign -addext subjectKeyIdentifier=hash 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n' > server.ext
"$openssl" req -newkey rsa:2048 -nodes -subj "/CN=provided server" -keyout server.key -out server.csr 2>/dev/null
"$openssl" x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
  -extfile server.ext -out server.crt 2>/dev/null
rm -f openssl.cnf server.ext server.csr ca.srl ca.key
