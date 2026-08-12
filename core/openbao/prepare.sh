#!/bin/sh
set -eu

state_root="${OPENBAO_STATE_ROOT:-/srv/polinetwork/state/openbao}"
tls_dir="$state_root/tls"
tmp_dir=

fail() {
  printf 'prepare-openbao: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$tmp_dir" ]; then
    case "$tmp_dir" in
      /dev/shm/openbao-tls.*)
        rm -f "$tmp_dir/ca.key" "$tmp_dir/ca.crt" "$tmp_dir/ca.srl" \
          "$tmp_dir/tls.key" "$tmp_dir/tls.csr" "$tmp_dir/tls.crt"
        rmdir "$tmp_dir" 2>/dev/null || true
        ;;
      *) printf 'prepare-openbao: refusing unexpected temporary path: %s\n' "$tmp_dir" >&2 ;;
    esac
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root through sudo'
install -d -o pnadmin -g pnadmin -m 0710 "$state_root"
install -d -o root -g root -m 0755 "$tls_dir"

tls_file_count=0
for tls_file in ca.crt tls.crt tls.key; do
  if [ -e "$tls_dir/$tls_file" ]; then
    tls_file_count=$((tls_file_count + 1))
  fi
done

case "$tls_file_count" in
  0)
    tmp_dir="$(mktemp -d /dev/shm/openbao-tls.XXXXXX)"
    umask 077

    openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
      -subj '/CN=PoliNetwork OpenBao Internal CA' \
      -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout "$tmp_dir/ca.key" \
      -out "$tmp_dir/ca.crt"

    openssl req -new -newkey rsa:3072 -nodes -sha256 \
      -subj '/CN=openbao' \
      -addext 'subjectAltName=DNS:openbao,DNS:openbao.polinetwork.org,IP:127.0.0.1' \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
      -addext 'extendedKeyUsage=serverAuth' \
      -keyout "$tmp_dir/tls.key" \
      -out "$tmp_dir/tls.csr"

    openssl x509 -req -sha256 -days 397 \
      -in "$tmp_dir/tls.csr" \
      -CA "$tmp_dir/ca.crt" \
      -CAkey "$tmp_dir/ca.key" \
      -CAcreateserial \
      -copy_extensions copy \
      -out "$tmp_dir/tls.crt"

    openssl verify -CAfile "$tmp_dir/ca.crt" "$tmp_dir/tls.crt"
    openssl x509 -in "$tmp_dir/tls.crt" -noout -checkhost openbao >/dev/null
    install -o root -g root -m 0644 "$tmp_dir/ca.crt" "$tls_dir/ca.crt"
    install -o 100 -g 1000 -m 0644 "$tmp_dir/tls.crt" "$tls_dir/tls.crt"
    install -o 100 -g 1000 -m 0600 "$tmp_dir/tls.key" "$tls_dir/tls.key"
    ;;
  3)
    openssl verify -CAfile "$tls_dir/ca.crt" "$tls_dir/tls.crt"
    openssl x509 -in "$tls_dir/tls.crt" -noout -checkhost openbao >/dev/null
    ;;
  *)
    fail "partial TLS state below $tls_dir; refusing to replace or complete it"
    ;;
esac

printf 'OpenBao internal TLS is ready below %s.\n' "$state_root"
