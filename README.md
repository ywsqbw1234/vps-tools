# vps-tools

Public subscription publishing was retired on 2026-11-19 following credential exposure.

The legacy shell entry points now only invoke the installed private exporter on the
German server. They do not upload files or credentials. Generated subscriptions are
root-only files under `/root/private-subscriptions`, retrieved through authenticated
SSH and imported locally into the client. No public subscription URL is provided.

`export_private_subscriptions.py` reads the current three Hysteria2 inbounds and a
private routing template; it does not rotate credentials, restart services, or make
network requests. It pins the existing server certificate in the Clash configuration.

Old generated files have been removed from the current branch. Historical revisions
may still contain revoked credentials; deletion is not a substitute for rotation.
