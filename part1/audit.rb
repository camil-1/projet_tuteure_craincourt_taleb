# Partie 2 : Script Ruby

require 'json'
require 'optparse'
require 'open3'

# Gestion des paramètres (optparse)
options = {
    nombre_processus: 5,
    format: 'json',
    services: ['ssh', 'cron', 'docker'],
    racine: '/',
    fichier_sortie: nil
}

OptionParser.new do |analyseur|
    analyseur.banner = "Utilisation : audit.rb [options]"

    analyseur.on("-n", "--nombre N", Integer, "Nombre de processus à afficher (défaut: 5)") do |nombre|
        options[:nombre_processus] = nombre
    end

    analyseur.on("-f", "--format FORMAT", "Format de sortie: json ou texte (défaut: json)") do |format_choisi|
        options[:format] = format_choisi.downcase
    end

    analyseur.on("-s", "--services LISTE", Array, "Services à vérifier, séparés par des virgules") do |liste_services|
        options[:services] = liste_services
    end

    analyseur.on("-r", "--racine REPERTOIRE", "Répertoire racine pour l'audit (défaut: /)") do |repertoire|
        options[:racine] = repertoire
    end

    analyseur.on("-o", "--sortie FICHIER", "Sauvegarder le résultat JSON dans un fichier") do |fichier|
        options[:fichier_sortie] = fichier
    end
end.parse!


# Fonctions utilitaires
# Lance une commande et récupère sa sortie standard, sa sortie d'erreur et son succès
def executer_commande(commande)
    begin
        sortie_standard, sortie_erreur, statut = Open3.capture3(commande)

        {
            sortie_standard: sortie_standard.strip,
            sortie_erreur: sortie_erreur.strip,
            succes: statut.success?
        }
    rescue StandardError => exception
        {
            sortie_standard: "",
            sortie_erreur: "Exception Ruby: #{exception.message}",
            succes: false
        }
    end
end

def afficher_texte(audit)
    puts "=========================================="
    puts "       RESULTAT DE L'AUDIT SYSTEME        "
    puts "=========================================="
    puts "Date de l'audit : #{audit[:date_audit]}"
    puts "Racine inspectée : #{audit[:parametres][:racine]}"
    
    puts "\n[ --- MACHINE --- ]"
    puts "Nom machine  : #{audit[:machine][:nom_machine]}"
    puts "Distribution : #{audit[:machine][:distribution]}"
    puts "Noyau        : #{audit[:machine][:noyau]}"
    
    puts "\n[ --- UPTIME ET CHARGE --- ]"
    puts "Uptime (sec) : #{audit[:uptime_et_charge][:uptime_secondes]}"
    puts "Charge (1,5,15m): #{audit[:uptime_et_charge][:charge_moyenne]}"
    
    puts "\n[ --- MEMOIRE (ko) --- ]"
    if audit[:memoire][:erreur]
        puts "Erreur : #{audit[:memoire][:erreur]}"
    else
        infos_memoire = audit[:memoire]
        puts "RAM  : Totale=#{infos_memoire[:memoire_totale_ko]} | Utilisée=#{infos_memoire[:memoire_utilisee_ko]} | Dispo=#{infos_memoire[:memoire_disponible_ko]}"
        # Contrairement à la RAM qui possède un cache libérable (Dispo), le swap est soit alloué, soit libre
        puts "SWAP : Totale=#{infos_memoire[:swap_total_ko]} | Utilisée=#{infos_memoire[:swap_utilisee_ko]} | Libre=#{infos_memoire[:swap_libre_ko]}"
    end

    puts "\n[ --- RESEAU (Interfaces) --- ]"
    audit[:reseau].each do |nom_interface, donnees_interface|
        if nom_interface == :erreur
            puts "Erreur : #{donnees_interface}"
        else
            puts "- #{nom_interface} (MAC: #{donnees_interface[:mac] || 'Aucune adresse MAC'}) | IPv4: #{donnees_interface[:ipv4].join(', ')}"
        end
    end
    
    puts "\n[ --- UTILISATEURS HUMAINS --- ]"
    audit[:utilisateurs].each do |utilisateur, donnees_utilisateur|
        if utilisateur == :erreur
            puts "Erreur : #{donnees_utilisateur}"
        else
            if donnees_utilisateur[:connecte]
                puts "- #{utilisateur} : Connecté"
            else
                puts "- #{utilisateur} : Déconnecté"
            end
        end
    end
    
    puts "\n[ --- DISQUES --- ]"
    audit[:disques].each do |disque|
        if disque[:erreur]
            puts "Erreur : #{disque[:erreur]}"
        else
            puts "- #{disque[:systeme]} (monté sur #{disque[:montage]}) : #{disque[:utilise_ko]} ko utilisés, #{disque[:disponible_ko]} ko disponibles"
        end
    end
    
    puts "\n[ --- LES #{audit[:parametres][:nombre_processus]} PROCESSUS LES PLUS GOURMANDS --- ]"
    puts "CPU :"
    audit[:processus_gourmands][:plus_gourmands_cpu].each { |processus| puts "  PID #{processus[:pid]} | CPU: #{processus[:cpu]}% | #{processus[:commande]}" } unless audit[:processus_gourmands][:plus_gourmands_cpu].empty?
    puts "MEMOIRE :"
    audit[:processus_gourmands][:plus_gourmands_memoire].each { |processus| puts "  PID #{processus[:pid]} | MEM: #{processus[:memoire]}% | #{processus[:commande]}" } unless audit[:processus_gourmands][:plus_gourmands_memoire].empty?
    
    puts "\n[ --- CONNEXIONS RESEAU --- ]"
    audit[:connexions].each do |connexion|
        if connexion[:erreur]
            puts "Erreur : #{connexion[:erreur]}"
        else
            if connexion[:pid]
                pid_affiche = " (PID: #{connexion[:pid]})"
            else
                pid_affiche = ""
            end
            puts "- #{connexion[:protocole].upcase} | #{connexion[:local]} -> #{connexion[:distant]} | Processus: #{connexion[:processus]}#{pid_affiche}"
        end
    end

    puts "\n[ --- SERVICES --- ]"
    audit[:services_cles].each do |service, etat|
        if etat.is_a?(String)
            puts "- #{service} : #{etat}"
        else
            puts "- #{service} : #{etat[:actif]}, au démarrage: #{etat[:active_au_demarrage]}"
        end
    end
    puts "=========================================="
end


# Méthodes d'audit (Retournent des Hash)

# Récupère le nom de la machine, l'OS et le noyau depuis /etc/hostname, /etc/os-release et 'uname -r'. Pas besoin de root.
def audit_machine(racine)
    fichier_nom_machine = File.join(racine, 'etc', 'hostname')
    if File.exist?(fichier_nom_machine)
        nom_machine = File.read(fichier_nom_machine).strip
    else
        nom_machine = "Erreur: Fichier introuvable"
    end

    fichier_os_release = File.join(racine, 'etc', 'os-release')
    distribution = "Erreur: Fichier introuvable"
    
    if File.exist?(fichier_os_release)
        IO.readlines(fichier_os_release).each do |ligne|
            # Capture la valeur de PRETTY_NAME 
            # Les parenthèses ([^"\n]+) isolent le nom de la distribution (sans les guillemets) pour le ranger dans $1
            distribution = $1 if ligne =~ /^PRETTY_NAME="?([^"\n]+)"?/
        end
    end

    resultat_noyau = executer_commande('uname -r')
    if resultat_noyau[:succes]
        noyau = resultat_noyau[:sortie_standard]
    else
        noyau = "Erreur: #{resultat_noyau[:sortie_erreur]}"
    end

    {
        nom_machine: nom_machine,
        distribution: distribution,
        noyau: noyau
    }
end

# Récupère l'uptime et la charge depuis /proc/uptime et /proc/loadavg. Pas besoin de root.
def audit_uptime(racine)
    fichier_uptime = File.join(racine, 'proc', 'uptime')
    if File.exist?(fichier_uptime)
        uptime_en_secondes = File.read(fichier_uptime).split[0].to_f
    else
        uptime_en_secondes = "Erreur: Fichier introuvable"
    end

    fichier_charge = File.join(racine, 'proc', 'loadavg')
    if File.exist?(fichier_charge)
        charge_moyenne = File.read(fichier_charge).split[0..2].map(&:to_f)
    else
        charge_moyenne = "Erreur: Fichier introuvable"
    end

    {
        uptime_secondes: uptime_en_secondes,
        charge_moyenne: charge_moyenne
    }
end

# Calcule la mémoire et le swap depuis /proc/meminfo. Pas besoin de root.
def audit_memoire(racine)
    fichier_meminfo = File.join(racine, 'proc', 'meminfo')
    
    if !File.exist?(fichier_meminfo)
        return { erreur: "Fichier #{fichier_meminfo} introuvable" }
    end
    
    valeurs_meminfo = {}
    IO.readlines(fichier_meminfo).each do |ligne|
        # \w+ capture le nom (ex: MemTotal) qu'on range dans $1
        # \d+ capture la valeur numérique qu'on range dans $2
        valeurs_meminfo[$1] = $2.to_i if ligne =~ /^(\w+):\s+(\d+)\s+kB/
    end

    memoire_totale = valeurs_meminfo["MemTotal"] || 0
    memoire_disponible = valeurs_meminfo["MemAvailable"] || 0
    swap_total = valeurs_meminfo["SwapTotal"] || 0
    swap_libre = valeurs_meminfo["SwapFree"] || 0

    memoire_utilisee = 0
    if memoire_totale > 0
        memoire_utilisee = memoire_totale - memoire_disponible
    end

    swap_utilisee = 0
    if swap_total > 0
        swap_utilisee = swap_total - swap_libre
    end

    {
        memoire_totale_ko: memoire_totale,
        memoire_disponible_ko: memoire_disponible,
        memoire_utilisee_ko: memoire_utilisee,
        swap_total_ko: swap_total,
        swap_libre_ko: swap_libre,
        swap_utilisee_ko: swap_utilisee
    }

end

# Liste les interfaces IP, adresses MAC, IPv4 et IPv6 via 'ip addr show'. Pas besoin de root.
def audit_reseau
    resultat_ip = executer_commande('ip addr show')
    if !resultat_ip[:succes]
        return { erreur: "Commande ip en échec: #{resultat_ip[:sortie_erreur]}" }
    end

    interfaces = {}
    interface_courante = nil

    resultat_ip[:sortie_standard].each_line do |ligne|
        if ligne =~ /^\d+:\s+([^:]+):/
            interface_courante = $1
            interfaces[interface_courante] = {
                mac: nil,
                ipv4: [],
                ipv6: []
            }
        elsif interface_courante
            if ligne =~ /link\/ether\s+([a-f0-9:]+)/
                interfaces[interface_courante][:mac] = $1
            # Capture une adresse IP (des chiffres et des points) + son masque de sous réseau optionnel (/\d+)
            elsif ligne =~ /inet\s+([0-9\.]+)(\/\d+)?\s+/
                interfaces[interface_courante][:ipv4] << $1
            # Capture une IPv6 (chiffres hexa et deux-points) + masque optionnel
            elsif ligne =~ /inet6\s+([a-f0-9:]+)(\/\d+)?\s+/
                interfaces[interface_courante][:ipv6] << $1
            end
        end
    end
    
    interfaces
end

# Filtre les utilisateurs réels via /etc/passwd et vérifie les sessions avec 'users'. Pas besoin de root.
def audit_utilisateurs(racine)
    fichier_login_defs = File.join(racine, 'etc', 'login.defs')
    fichier_passwd = File.join(racine, 'etc', 'passwd')

    uid_min, uid_max = 1000, 60000

    if File.exist?(fichier_login_defs)
        IO.readlines(fichier_login_defs).each do |ligne|
            uid_min = $1.to_i if ligne =~ /^UID_MIN\s+(\d+)/
            uid_max = $1.to_i if ligne =~ /^UID_MAX\s+(\d+)/
        end
    end

    humains = []
    
    if File.exist?(fichier_passwd)
        IO.readlines(fichier_passwd).each do |ligne|
            # Le premier ([^:]*) isole le nom d'utilisateur jusqu'au 1er deux points
            # Le second (\d+) isole l'UID (situé après le 2ème deux points)
            if ligne =~ /^([^:]*):[^:]*:(\d+):/
                identifiant, uid = $1, $2.to_i
                if uid >= uid_min && uid <= uid_max
                    humains << identifiant
                end
            end
        end
    else
        return { erreur: "Fichier /etc/passwd introuvable" }
    end

    resultat_users = executer_commande('users')
    connectes = []
    if resultat_users[:succes]
        connectes = resultat_users[:sortie_standard].split
    end

    resultat = {}
    
    humains.each do |utilisateur|
        resultat[utilisateur] = {
            connecte: connectes.include?(utilisateur)
        }
    end
    
    resultat
end

# Liste l'utilisation des partitions physiques ou virtuelles (/dev/) via 'df -P'. Pas besoin de root.
def audit_disque
    resultat_df = executer_commande('df -P')
    if !resultat_df[:succes]
        # On renvoie un tableau avec le hash a l'interieur
        return [{ erreur: "Commande df en échec: #{resultat_df[:sortie_erreur]}" }]
    end

    partitions = []
    premiere_ligne = true

    resultat_df[:sortie_standard].each_line do |ligne|
        if premiere_ligne
            premiere_ligne = false
            next
        end
        
        champs = ligne.split
        
        if champs.size >= 6 && champs[0] =~ /^\/dev\//
            partitions << {
                systeme: champs[0],
                taille_ko: champs[1].to_i,
                utilise_ko: champs[2].to_i,
                disponible_ko: champs[3].to_i,
                montage: champs[5]
            }
        end
    end
    
    partitions
end

# Renvoie les N processus les plus gourmands via 'ps'. Pas besoin de root.
def audit_processus(nombre)
    resultat_ps_cpu = executer_commande("ps -eo pid,%cpu,%mem,comm --sort=-%cpu --no-headers")
    resultat_ps_memoire = executer_commande("ps -eo pid,%cpu,%mem,comm --sort=-%mem --no-headers")

    plus_gourmands_cpu = []
    
    if resultat_ps_cpu[:succes]
        # each_line.take(nombre) : on garde que les N premières lignes
        resultat_ps_cpu[:sortie_standard].each_line.take(nombre).each do |ligne|
            # split(nil, 4) découpe selon les espaces, mais s'arrête après 4 champs 
            # Le 4e champ (la commande) garde donc ses éventuels espaces internes intacts
            champs = ligne.split(nil, 4)
            if champs.size == 4
                plus_gourmands_cpu << { 
                    pid: champs[0].to_i, 
                    cpu: champs[1].to_f, 
                    memoire: champs[2].to_f, 
                    commande: champs[3].strip 
                }
            end
        end
    else
        plus_gourmands_cpu << { erreur: "Commande ps cpu en échec: #{resultat_ps_cpu[:sortie_erreur]}" }
    end

    plus_gourmands_memoire = []
    
    if resultat_ps_memoire[:succes]
        resultat_ps_memoire[:sortie_standard].each_line.take(nombre).each do |ligne|
            champs = ligne.split(nil, 4)
            if champs.size == 4
                plus_gourmands_memoire << { 
                    pid: champs[0].to_i, 
                    cpu: champs[1].to_f, 
                    memoire: champs[2].to_f, 
                    commande: champs[3].strip 
                }
            end
        end
    else
        plus_gourmands_memoire << { erreur: "Commande ps memoire en échec: #{resultat_ps_memoire[:sortie_erreur]}" }
    end

    {
        plus_gourmands_cpu: plus_gourmands_cpu,
        plus_gourmands_memoire: plus_gourmands_memoire
    }
end

# Liste les connexions TCP/UDP via 'ss -tuapn'. L'affichage du processus nécessite root
def audit_connexions
    resultat_ss = executer_commande('ss -tuapn')
    if !resultat_ss[:succes]
        return [{ erreur: "Commande ss en échec: #{resultat_ss[:sortie_erreur]}" }]
    end

    connexions = []
    premiere_ligne = true

    resultat_ss[:sortie_standard].each_line do |ligne|
        if premiere_ligne
            premiere_ligne = false
            next
        end

        champs = ligne.split
        next if champs.size < 5

        protocole = champs[0]
        
        # Process.uid == 0 vérifie si on exécute le script en root
        # Si c'est le cas, c'est que le socket n'a vraiment pas de processus
        # Sinon, c'est juste un manque de droits
        if Process.uid == 0
            processus = "Non identifié"
        else
            processus = "inaccessible sans root"
        end
        pid = nil
        
        # On extrait la sous chaîne qui ressemble à users:(("processus",pid=1234,...))
        if ligne =~ /users:\(\("([^"]+)",pid=(\d+)/
            processus = $1
            pid = $2.to_i
        end
        
        adresse_locale = champs[4]
        if champs.size > 5
            adresse_distante = champs[5]
        else
            adresse_distante = "Inconnu"
        end

        connexions << {
            protocole: protocole,
            local: adresse_locale,
            distant: adresse_distante,
            processus: processus,
            pid: pid
        }
    end
    
    connexions
end

# Analyse l'état des services via systemctl. Pas besoin de root.
def audit_services(services)
    resultat = {}
    
    services.each do |service|
        services_a_tester = [service]
        services_a_tester << "ssh.socket" if service == 'ssh'

        services_a_tester.each do |unite|
            resultat_actif = executer_commande("systemctl is-active #{unite}")
            resultat_demarrage = executer_commande("systemctl is-enabled #{unite}")
            
            # Quand is-active ou is-enabled ne trouvent pas le service ou qu'il est "inactive", 
            # la commande échoue (code de retour != 0)
            # On prend la sortie standard en priorité, ou la sortie d'erreur si elle est vide, pour récupérer l'état
            if resultat_actif[:sortie_standard].empty?
                etat_actif = resultat_actif[:sortie_erreur]
            else
                etat_actif = resultat_actif[:sortie_standard]
            end

            if resultat_demarrage[:sortie_standard].empty?
                etat_demarrage = resultat_demarrage[:sortie_erreur]
            else
                etat_demarrage = resultat_demarrage[:sortie_standard]
            end
            
            # Si vraiment rien ne sort (même pas d'erreur), c'est probablement que systemctl a planté
            if etat_actif.empty? && etat_demarrage.empty?
                etat = "Erreur: aucune sortie ou commande introuvable"
            else
                etat = {
                    actif: etat_actif,
                    active_au_demarrage: etat_demarrage
                }
            end
            
            resultat[unite] = etat
        end
    end
    
    resultat
end


# Construction de l'objet global
audit_global = {
    date_audit: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
    parametres: options,
    machine: audit_machine(options[:racine]),
    uptime_et_charge: audit_uptime(options[:racine]),
    memoire: audit_memoire(options[:racine]),
    reseau: audit_reseau(),
    utilisateurs: audit_utilisateurs(options[:racine]),
    disques: audit_disque(),
    processus_gourmands: audit_processus(options[:nombre_processus]),
    connexions: audit_connexions(),
    services_cles: audit_services(options[:services])
}

# Affichage final ou Export
if options[:fichier_sortie]
    begin
        File.write(options[:fichier_sortie], JSON.pretty_generate(audit_global))
        puts "Audit sauvegardé avec succès dans le fichier : #{options[:fichier_sortie]}"
    rescue StandardError => exception
        puts "Erreur lors de l'écriture du fichier : #{exception.message}"
    end
elsif options[:format] == 'texte'
    afficher_texte(audit_global)
else
    puts JSON.pretty_generate(audit_global)
end