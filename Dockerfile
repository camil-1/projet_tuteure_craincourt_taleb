# Image de base : Debian stable 
FROM debian:stable-slim

# Installation des paquets fournissant les commandes utilisées par audit.rb :
#   ruby      -> interpréteur (json, optparse, open3 sont dans la bibliothèque standard)
#   iproute2  -> ip et ss
#   procps    -> ps (et free, uptime...)
#   systemd   -> systemctl (pour is-active / is-enabled)
#   (uname, df, users sont fournis par coreutils, déjà présent dans l'image)
# --no-install-recommends : on n'installe que le strict nécessaire
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ruby \
        iproute2 \
        procps \
        systemd \
    && rm -rf /var/lib/apt/lists/*

# Copie du script d'audit
WORKDIR /app
COPY audit.rb /app/audit.rb

# Point d'entrée : tous les arguments de "docker run <image> ..." sont ajoutés
# après cette commande, donc transmis à audit.rb (ex. : -f texte -n 10)
ENTRYPOINT ["ruby", "/app/audit.rb"]
