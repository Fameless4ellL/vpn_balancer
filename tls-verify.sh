#!/bin/sh
# openvpn --tls-verify hook: remember the server certificate's CN (depth 0). Never rejects.
[ "$1" = 0 ] && printf '%s\n' "${X509_0_CN:-}" > /run/server_cn
exit 0
