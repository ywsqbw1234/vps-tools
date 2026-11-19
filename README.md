# vps-tools

Public subscription publishing was retired on 2026-11-19 following credential exposure.

The legacy shell entry points now only invoke the installed private exporter on the
German server. They do not upload files or credentials. Generated subscriptions are
root-only files under `/root/private-subscriptions`, retrieved through authenticated
SSH or a shared HTTPS endpoint protected by a random bearer path. The endpoint URL is stored privately on the server; it is never committed here.

`export_private_subscriptions.py` reads the current three Hysteria2 inbounds and a
private routing template, plus an optional validated JP-CF-WS node. It updates the restricted HTTPS serving directory when configured. It does not rotate credentials, restart services, or make
network requests. It pins the existing server certificate in the Clash configuration.

Old generated files have been removed from the current branch. Historical revisions
may still contain revoked credentials; deletion is not a substitute for rotation.
