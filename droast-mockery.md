

  ██████╗ ██████╗  ██████╗  █████╗ ███████╗████████╗
  ██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██╔════╝╚══██╔══╝
  ██║  ██║██████╔╝██║   ██║███████║███████╗   ██║
  ██║  ██║██╔══██╗██║   ██║██╔══██║╚════██║   ██║
  ██████╔╝██║  ██║╚██████╔╝██║  ██║███████║   ██║
  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝   ╚═╝
  Dockerfile linter with personality


  🔥 Roasting Dockerfile...

  WARN  [DF020]  No USER instruction found — container will run as root by default
             at Dockerfile

  WARN  [DF058]  Both wget and curl are used — pick one and use it consistently
             at Dockerfile

  INFO  [DF012]  No HEALTHCHECK defined
             at Dockerfile

  INFO  [DF033]  No effective build-context ignore file for '/media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker' (expected '/media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/.dockerignore')
             at Dockerfile

  WARN  [DF003]  7 consecutive RUN instructions could be merged into one
             at Dockerfile:15:1

  INFO  [DF005]  apt-get install without pinned package versions
             at Dockerfile:36:1

  INFO  [DF060]  Command 'vim' makes little sense inside a container
             at Dockerfile:68:1

  WARN  [DF003]  6 consecutive RUN instructions could be merged into one
             at Dockerfile:113:1

  WARN  [DF057]  RUN with pipe but no pipefail — failed commands in the pipe are silently ignored
             at Dockerfile:121:1

  INFO  [DF035]  curl without --fail — HTTP errors won't cause the RUN step to fail
             at Dockerfile:121:1

  INFO  [DF060]  Command 'top' makes little sense inside a container
             at Dockerfile:127:1

  WARN  [DF003]  12 consecutive RUN instructions could be merged into one
             at Dockerfile:136:1

  WARN  [DF057]  RUN with pipe but no pipefail — failed commands in the pipe are silently ignored
             at Dockerfile:150:1

  WARN  [DF057]  RUN with pipe but no pipefail — failed commands in the pipe are silently ignored
             at Dockerfile:156:1

  INFO  [DF008]  Using 'cd' in RUN — prefer WORKDIR instruction
             at Dockerfile:170:1

  INFO  [DF008]  Using 'cd' in RUN — prefer WORKDIR instruction
             at Dockerfile:179:1

  INFO  [DF008]  Using 'cd' in RUN — prefer WORKDIR instruction
             at Dockerfile:185:1

  INFO  [DF008]  Using 'cd' in RUN — prefer WORKDIR instruction
             at Dockerfile:194:1

  INFO  [DF008]  Using 'cd' in RUN — prefer WORKDIR instruction
             at Dockerfile:216:1

  INFO  [DF056]  wget without --progress flag produces verbose progress output in build logs
             at Dockerfile:216:1

  Summary: 0 error(s), 8 warning(s), 12 info(s)

  🤔 Could be worse. Could also be much better.

