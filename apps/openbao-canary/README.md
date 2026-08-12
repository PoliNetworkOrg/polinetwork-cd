# OpenBao secret canary

This project proves doco.cd's native OpenBao-to-Compose secret path. Its local
`.doco-cd.yaml` resolves `secret/apps/canary` key `message`; Compose mounts the
resolved value as `/run/secrets/canary_message` in a network-isolated canary.

Store `message=openbao-agent-ok` at that OpenBao path before enabling the
project. No application-specific Agent, AppRole, env file or helper script is
required.
