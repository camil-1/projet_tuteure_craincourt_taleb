# Partie 2 : Automatisation avec un script Ruby

Le script s'appelle `audit.rb`. Il regroupe toutes les informations de la partie 1, sans dialogue interactif, et n'utilise que la bibliothèque standard de Ruby : `optparse` pour les options, `json` pour l'export, `open3` pour lancer les commandes et `time` pour la date. Il n'y a aucune gem à installer, ce qui simplifie aussi l'image Docker de la partie 3.

Dépôt git : [URL du dépôt]

## Utilisation

```
ruby audit.rb -f texte                          # affichage lisible
ruby audit.rb                                   # JSON sur la sortie standard
ruby audit.rb -n 10 -s ssh,cron,docker,nginx    # 10 processus, services choisis
ruby audit.rb -o audit.json                     # JSON enregistré dans un fichier
ruby audit.rb -r /host -f texte                 # fichiers système lus sous /host
```

| Option             | Rôle                                          | Défaut            |
| ---                | ---                                           | ---               |
| `-n`, `--nombre N` | nombre de processus affichés (CPU et mémoire) | 5                 |
| `-f`, `--format`   | `json` ou `texte`                             | `json`            |
| `-s`, `--services` | liste de services séparés par des virgules    | `ssh,cron,docker` |
| `-r`, `--racine`   | répertoire sous lequel lire `/etc`, `/proc`.. | `/`               |
| `-o`, `--sortie`   | enregistre le JSON dans ce fichier            | aucun             |

Les valeurs sont vérifiées au lancement : un format inconnu, un `N` inférieur à 1 ou une racine qui n'existe pas arrêtent le script avec un message clair. Les noms de services ne peuvent contenir que des caractères valides pour une unité systemd, puisqu'ils sont passés à `systemctl`.

## Organisation du code

Chaque information a sa méthode (`audit_machine`, `audit_uptime`, `audit_memoire`, `audit_reseau`, `audit_utilisateurs`, `audit_disque`, `audit_processus`, `audit_connexions`, `audit_services`). Elle renvoie un Hash, ou un tableau de Hash pour les listes. Le résultat global est un Hash qui contient la date de l'audit, les paramètres utilisés et le retour de chaque méthode. On l'affiche avec `afficher_texte` ou on le convertit avec `JSON.pretty_generate`.

Le JSON a donc ces clés de premier niveau : `date_audit`, `parametres`, `machine`, `uptime_et_charge`, `memoire`, `reseau`, `utilisateurs`, `disques`, `processus_gourmands`, `connexions`, `services_cles`. La date est au format ISO 8601 avec le fuseau (`2026-10-23T14:44:31+00:00`), ce qui permet de comparer sans ambiguïté un audit fait sur l'hôte et un audit fait dans un conteneur.

## Ce qui change par rapport à la partie 1

En partie 1, j'ai testé les commandes à la main. Dans le script, certains choix sont différents, pour deux raisons : l'option `--racine` oblige à lire des fichiers plutôt qu'à interroger des commandes, et un script a besoin d'une sortie facile à analyser.

| Information | Partie 1 | Script | Pourquoi |
|---|---|---|---|
| Nom de la machine | `hostname` | `/etc/hostname` sous la racine | `hostname` interroge le conteneur, pas l'hôte. Si le fichier manque, le script se rabat sur la commande. |
| Distribution | `cat /etc/os-release` | même fichier, lu avec `PRETTY_NAME`, `NAME`, `VERSION_ID` | pas de dépendance à `lsb-release` |
| Noyau | `uname -r` | `uname -r` | sortie propre, et c'est la même valeur dans un conteneur (noyau partagé) |
| Uptime et charge | `uptime` | `/proc/uptime` et `/proc/loadavg` | `uptime` lit ces fichiers et les met en forme. Les lire directement évite d'analyser du texte formaté (le séparateur décimal change avec la langue). |
| Mémoire et swap | `free -h` | `/proc/meminfo` | même source que `free`. Utilisée = `MemTotal - MemAvailable`, comme `free`. |
| Réseau | `ip addr show` | `ip -j addr show` | la sortie JSON évite des expressions régulières fragiles |
| Utilisateurs | `/etc/passwd`, `who`, `users` | `/etc/passwd` filtré par `UID_MIN` et `UID_MAX`, puis sessions logind et `utmp` | voir plus bas |
| Disques | `df -h` | `df -P`, sur les points de montage de type disque | `-P` donne un format stable, en blocs de 1 Kio |
| Processus | `ps -eo pid,%cpu,%mem,comm --sort=-%cpu` | même commande avec `--no-headers`, `pcpu` et `pmem` | le script garde les N premières lignes |
| Connexions | `ss -tuapn` | `ss -H -tuapn` | `-H` supprime l'en-tête, donc une ligne analysée en moins |
| Services | `systemctl is-active` et `is-enabled` | idem, plus `ssh.socket` quand on teste `ssh` | sur Ubuntu récent, SSH peut être démarré par la socket |

Quelques points méritent plus d'explications.

**Utilisateurs connectés.** `who` et `users` lisent le fichier `utmp`, qui n'existe pas toujours dans un conteneur ou sur un système récent. Le script regarde donc deux sources : les fichiers de session de systemd-logind (`/run/systemd/sessions/`, où chaque fichier contient `USER=` et `STATE=`), et `utmp` via `who <fichier>`. Les chemins passent par la racine (`<racine>/run/...`), et pas par `/var/run`, car `/var/run` est un lien symbolique absolu qui sortirait de la racine choisie.

**Utilisateurs humains.** On garde les comptes dont l'UID est compris entre `UID_MIN` et `UID_MAX` de `/etc/login.defs`. Les valeurs par défaut (1000 et 60000) ne servent que si le fichier est absent. `nobody` (UID 65534) est exclu naturellement, puisque son UID dépasse `UID_MAX`.

**Disques.** `df` sans argument liste aussi les `tmpfs` et les paquets snap, qui apparaissent comme des `/dev/loop*` toujours pleins. Le script lit la table des montages du processus 1 (`<racine>/proc/1/mounts`), garde les sources qui commencent par `/dev/`, écarte `squashfs` et `iso9660`, puis lance `df -P` sur chaque point de montage. Avec `--racine /host`, la table lue est celle de l'hôte, et les points de montage s'affichent sans le préfixe `/host`.

**Processus.** Le `%CPU` de `ps` est une moyenne depuis le lancement du processus, pas une mesure instantanée. Comme `ruby` vient de démarrer et travaille tout de suite, il arrive souvent en tête (85 % dans notre premier test). Ce n'est pas un défaut du script. Pour une valeur instantanée, il faudrait lire `/proc/stat` deux fois, ou utiliser `top -b -n 2`. Nous avons gardé `ps`, qui suffit pour repérer les gros consommateurs. La colonne `comm` est aussi tronquée à 15 caractères (d'où `jetbrains-toolb`).

**Connexions.** Sans root, `ss -p` ne montre que les processus de l'utilisateur courant. Le script distingue trois cas. Si le processus est connu, il affiche son nom et son PID. Si l'on n'est pas root et que le processus manque, il écrit « inaccessible sans root ». Si l'on est root et que le processus manque, c'est qu'aucun processus n'est associé au socket, par exemple une connexion en `TIME-WAIT`.

## Robustesse

Le sujet impose que le script tourne sans root et ne s'arrête jamais sur une erreur. Voici comment il y répond :

- `executer_commande` lance les commandes sans shell (les arguments sont séparés, donc pas d'injection) avec `LC_ALL=C` pour avoir des sorties non traduites. Elle renvoie la sortie standard, la sortie d'erreur et le code de retour. Une commande absente ou en échec produit un message d'erreur dans le résultat, pas une exception.
- `lire_fichier` renvoie `nil` si un fichier est absent ou illisible, et chaque méthode gère ce cas.
- Les informations qu'on ne peut pas lire sans root sont signalées comme telles.

# Partie 3 : Déploiement dans Docker

## Le Dockerfile

L'image part de `debian:stable-slim` et installe uniquement ce que le script utilise :

| Paquet | Apporte |
|---|---|
| `ruby` | l'interpréteur, avec `json`, `optparse`, `open3` et `time` |
| `iproute2` | `ip` et `ss` |
| `procps` | `ps` |
| `systemd` | `systemctl` |

`uname`, `df`, `who` et `hostname` viennent déjà avec l'image de base. L'installation utilise `--no-install-recommends`, et `/var/lib/apt/lists` est supprimé dans la même couche pour garder l'image légère. Le script est copié dans `/app`. Le point d'entrée est `ENTRYPOINT ["ruby", "/app/audit.rb"]` sous la forme exec : tout ce qui suit le nom de l'image dans `docker run` est transmis au script. Par exemple, `docker run --rm audit-sys -f texte -n 10` lance `ruby /app/audit.rb -f texte -n 10`.

## Exécution sans option

```
docker build -t audit-sys .
docker run --rm audit-sys -f texte
```

Sans option, le conteneur a ses propres espaces de noms (processus, réseau, nom de machine, système de fichiers) mais partage le noyau de l'hôte. Le résultat est un mélange des deux :

- **Nom de machine** : l'identifiant du conteneur (12 caractères hexadécimaux), car il a son propre espace de noms UTS.
- **Distribution** : celle de l'image (Debian stable), pas celle de l'hôte. Sur un hôte Ubuntu, la différence se verrait tout de suite.
- **Noyau, uptime, charge, mémoire** : ceux de l'hôte. Le noyau est partagé, et `/proc/meminfo` n'est pas virtualisé, donc la RAM totale est celle de la machine entière.
- **Réseau** : seulement `lo` et `eth0`, avec une adresse du réseau `bridge` de Docker (172.17.0.x). Les interfaces `wlp109s0` ou `docker0` de l'hôte ne sont pas visibles.
- **Utilisateurs** : aucun humain. Le `/etc/passwd` de l'image ne contient que des comptes système, donc personne n'est connecté non plus.
- **Disques** : le conteneur n'a pas de partition à lui, sa racine est un système `overlay`. Les seuls montages de type `/dev/` sont les fichiers que Docker y monte (`/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf`), qui viennent du disque de l'hôte.
- **Processus** : seulement `ruby` (PID 1) et la commande `ps` lancée par le script.
- **Connexions** : presque aucune, puisque rien n'écoute dans le conteneur.
- **Services** : `systemctl` ne trouve pas de systemd en fonctionnement ni de socket pour lui parler, donc les services sont signalés comme inactifs ou en erreur.
- **Date** : en UTC.

Pour auditer l'hôte, il faut donc donner au conteneur accès à ce qu'il ne voit pas.

## Options retenues pour auditer l'hôte

Le fichier `compose.yaml` regroupe toutes les options. On le lance avec `docker compose run --rm audit`.

| Option | Information concernée | Justification |
|---|---|---|
| `pid: host` | processus, et `/proc/<pid>` pour `ss -p` | le conteneur partage l'espace de noms PID de l'hôte |
| `network_mode: host` | interfaces et connexions | `ip` et `ss` voient la vraie pile réseau |
| `/:/host:ro` avec `--racine /host` | `/etc`, `/proc`, montages | l'hôte entier est visible en lecture seule, et le script lit ses fichiers sous `/host` |
| `/run/systemd:/run/systemd:ro` | services | contient la socket de systemd et le dossier `system`, que `systemctl` cherche pour savoir si systemd tourne |
| `SYSTEMD_IGNORE_CHROOT=1` | services | avec `pid: host`, `/proc/1/root` diffère de la racine du conteneur, et `systemctl` se croit dans un chroot et refuse de parler à systemd |
| `cap_add: SYS_PTRACE` | processus des connexions | lire `/proc/<pid>/fd` d'un autre utilisateur demande cette capacité, absente par défaut |
| `apparmor=unconfined` | processus des connexions | le profil `docker-default` interdit le `ptrace` vers des processus de l'hôte non confinés |
| `no-new-privileges:true` | sécurité | aucune élévation de privilèges dans le conteneur |
| `read_only: true` et `tmpfs: /tmp` | sécurité | le système de fichiers du conteneur ne peut pas être modifié, le script n'a rien à y écrire |
| `./out:/out` | export JSON | seul dossier accessible en écriture, pour `-o /out/audit.json` |

Je n'ai pas activé `uts: host`. Le nom de la machine est lu dans `/host/etc/hostname`, donc cette option n'apporte rien de plus, et elle partagerait un espace de noms inutilement. `--privileged` n'est pas utilisé non plus : il donnerait au conteneur presque tous les droits sur l'hôte, alors que l'audit n'a besoin que de la capacité `SYS_PTRACE`.

Le service tourne en root dans le conteneur (pas d'instruction `USER`), parce que `ss -p` et la lecture de `/proc/<pid>/fd` ne fonctionnent pas autrement.

## Comparaison entre l'hôte et le conteneur

Nous avons lancé le script directement sur l'hôte (Debian 13, noyau 6.12.113, sans root), puis dans le conteneur avec les options ci-dessus.

| Information | Hôte (sans root) | Conteneur (avec options) | Explication |
|---|---|---|---|
| Nom, distribution, noyau | `camil`, Debian 13 (trixie), 6.12.113 | identique | `/host/etc/hostname` et `/host/etc/os-release` sont les fichiers de l'hôte, et le noyau est partagé |
| Date | `16:44:26` | `14:44:31+00:00` | même instant : l'hôte est en UTC+2, le conteneur en UTC. Les 5 secondes viennent du délai entre les deux lancements. |
| Uptime | 1158,7 s | 1164,1 s | même noyau, les 5,4 s correspondent au délai entre les lancements |
| RAM utilisée | 3 970 656 ko | 4 013 716 ko | `/host/proc/meminfo` est celui de l'hôte |
| Interfaces | 8 interfaces | les mêmes, avec les mêmes MAC | `network_mode: host` |
| Utilisateurs | `camil` connecté | `camil` connecté | lecture des sessions logind sous `/host/run/systemd/sessions` |
| Disques | `/` et `/boot/efi` | `/` et `/boot/efi` | le préfixe `/host` est retiré à l'affichage. La sortie de l'hôte listait aussi les montages snap, car elle date d'avant le filtre `squashfs`. |
| Processus gourmands | `ruby` 85,7 % | `ruby` 69,2 % et `docker-compose` 14,2 % | `docker-compose`, le client qui a lancé le conteneur, est visible grâce à `pid: host`. Le `%CPU` est une moyenne depuis le démarrage. |
| Connexions | 10 connexions sur 23 en « inaccessible sans root » | `avahi-daemon`, `NetworkManager` et `cupsd` identifiés | voir ci-dessous |
| Services | `cron` et `docker` actifs et activés, `ssh` non installé | identique | socket de systemd montée |

La ligne des connexions est la seule vraie différence, et elle ne vient pas de Docker. Sur l'hôte, nous étions un utilisateur normal. Dans le conteneur, nous sommes root avec `SYS_PTRACE`, donc `ss -p` voit tous les processus. Sept des dix connexions « inaccessibles » ont été identifiées (4 sockets d'`avahi-daemon`, 1 de `NetworkManager`, 2 de `cupsd`). Les trois autres n'ont pas de propriétaire : deux sont en `TIME-WAIT` et une en `CLOSING`. Ce sont des connexions en cours de fermeture, que le noyau gère seul. Pour comparer à égalité, il faudrait lancer `sudo ruby audit.rb -f texte` sur l'hôte, ce qui doit donner les mêmes processus.

Le conteneur affiche aussi le fuseau horaire et les adresses IPv6, que l'ancienne sortie de l'hôte n'avait pas : c'est une différence de version du script, pas de Docker.

## Implications en matière de sécurité

Ces options rendent le conteneur beaucoup moins isolé que d'habitude. Voici ce qu'un attaquant qui prendrait le contrôle de ce conteneur pourrait faire.

**`/:/host:ro` expose tous les fichiers de l'hôte en lecture.** Le root du conteneur peut lire `/etc/shadow`, les clés SSH, les fichiers de `/home` et de `/root`. Le `:ro` empêche d'écrire, pas de lire.

**`/run/systemd:ro` n'empêche pas d'envoyer des ordres à systemd.** Une socket Unix se connecte et s'utilise même sur un montage en lecture seule. Comme le root du conteneur a le même UID 0 que le root de l'hôte (pas de remappage), systemd lui obéit. Il pourrait démarrer, arrêter ou créer des services sur l'hôte, ce qui revient à en prendre le contrôle. C'est la partie la plus dangereuse de la configuration.

**`pid: host` avec `SYS_PTRACE` donne accès à la mémoire des processus de l'hôte.** Le conteneur peut lire `/proc/<pid>/mem` et s'attacher aux processus. Avec `apparmor=unconfined`, plus aucun profil ne limite cet accès.

**`network_mode: host` supprime l'isolation réseau.** Le conteneur peut écouter sur les ports de l'hôte, atteindre les services qui n'écoutent que sur `127.0.0.1`, et capturer du trafic puisque la capacité `NET_RAW` fait partie des droits par défaut de Docker.

Les options `no-new-privileges`, `read_only` et l'absence de `--privileged` limitent les dégâts, mais elles ne compensent pas les accès précédents. Pour un audit ponctuel sur sa propre machine, le risque est acceptable. Il ne le serait pas pour un conteneur qui tourne en permanence ou qui expose un service.

## Pistes pour réduire les droits

- Monter seulement les fichiers lus (`/etc/os-release`, `/etc/passwd`, `/etc/login.defs`, `/etc/hostname`) au lieu de la racine entière. Le script lit alors `/proc` grâce à `pid: host`.
- Supprimer toutes les capacités avec `cap_drop: ALL`, puis ajouter seulement `SYS_PTRACE` et celles que `ss -p` exige encore. À tester, car certaines lectures de `/proc/<pid>/fd` demandent aussi de contourner les droits d'accès aux fichiers.
- Remplacer `apparmor=unconfined` par un profil AppArmor écrit pour ce conteneur, qui autorise `ptrace` en lecture et rien d'autre.
- Se passer de la socket systemd si l'état des services n'est pas indispensable, ou la remplacer par la lecture des fichiers de `/run/systemd`.
- Pour un audit régulier, lancer le script directement sur l'hôte, par exemple avec `cron`, évite tous ces compromis.

# Conclusion

Le script répond à la partie 1 en regroupant les commandes testées à la main, avec quelques adaptations pour qu'il marche aussi dans un conteneur. Le plus dur a été la partie Docker. Trois difficultés ont demandé du temps :

- `systemctl` refusait de répondre tant que nous n'avions pas compris le problème du chroot : avec `pid: host`, il compare `/proc/1/root` à sa propre racine, les trouve différentes, et croit être dans un chroot. Il a fallu `SYSTEMD_IGNORE_CHROOT`.
- `ss -p` n'affichait aucun processus de l'hôte avant l'ajout de `SYS_PTRACE` et de `apparmor=unconfined`.
- `df` listait des dizaines de montages snap et ajoutait le préfixe `/host` dans le conteneur, ce qui nous a conduits à lire la table des montages du processus 1.
