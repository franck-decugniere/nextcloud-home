# Installation

## Schema d'archi
```
                                  INTERNET
                                     │ HTTPS :8443
                                     ▼
                         ┌──────────────────────┐
                         │      CLOUDFLARE      │
                         │                      │
                         │ DNS                  │
                         │ ReverseProxy / CDN   │
                         │ DNS-01 Let's Encrypt │
                         └──────────┬───────────┘
                                    │ HTTPS
                                    ▼
                         ┌──────────────────────┐
                         │      BOX SFR         │
                         │    192.168.1.x       │
                         │                      │
                         │ NAT                  │
                         │ :8443 → Huawei       │
                         └──────────┬───────────┘
                                    ▼
                         ┌──────────────────────┐
                         │   HUAWEI MESH 3      │
                         │   192.168.3.1        │
                         │                      │
                         │ NAT                  │
                         │ :8443 → 192.168.3.63 │
                         └──────────┬───────────┘
                                    │ LAN
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       SERVEUR NEXTCLOUD                              │
│                         192.168.3.63                                 │
│                                                                      │
│  Docker                                                              │
│                                                                      │
│  ┌──────────────────────┐                                            │
│  │       CADDY          │                                            │
│  │                      │                                            │
│  │ :443                 │◄──── Docker :8443 → :443                   │
│  │ Reverse Proxy        │                                            │
│  │ TLS                  │                                            │
│  │ Cloudflare DNS-01    │                                            │
│  └──────────┬───────────┘                                            │
│             │ HTTP :80                                               │
│             ▼                                                        │
│  ┌──────────────────────┐                                            │
│  │      NEXTCLOUD       │                                            │
│  │                      │                                            │
│  │      :80             │                                            │
│  │                      │                                            │
│  │ /var/www/html        │                                            │
│  └──────┬───────┬───────┘                                            │
│         ▼       ▼                                                    │
│  ┌──────────┐ ┌───────────────┐                                      │
│  │ MariaDB  │ │     Redis     │                                      │
│  │          │ │               │                                      │
│  │ :3306    │ │ :6379         │                                      │
│  └──────────┘ └───────────────┘                                      │
│                                                                      │
│  /mnt/storage/nextcloud/                                             │
│  ├── config/                                                         │
│  ├── custom_apps/                                                    │
│  ├── data/                                                           │
│  ├── db/          ← données MariaDB                                  │
│  └── redis/       ← données Redis                                    │
│                                                                      │
│  /mnt/storage/caddy/                                                 │
│  ├── data/                                                           │
│  └── config/                                                         │
│                                                                      │
│  ┌─────────────────────────────────────────┐                         │
│  │       BACKUP JOB / RCLONE               │                         │
│  │                                         │                         │
│  │ MariaDB dump → .sql.gz                  │                         │
│  │ config + custom_apps + data → rclone    │                         │
│  └──────────────────┬──────────────────────┘                         │
└─────────────────────┼────────────────────────────────────────────────┘
                      │
                      │ SMB 2.0
                      │
                      ▼
             ┌──────────────────────┐
             │       SYNOLOGY       │
             │        DS212         │
             │     192.168.3.62     │
             │                      │
             │ /volume1/            │
             │ nextcloud-backup/    │
             │                      │
             │ ├── files/           │
             │ ├── database/        │
             │ └── deleted/         │
             └──────────────────────┘
```             

## Nom de domaine (Scalway)
```decugniere.fr``` enregistré chez le registrar Scaleway (renouvellement 23/09/2027)  
Mise à jour des serveurs de noms (``DNS NS``) pour pointer sur ceux de Cloudflare.

```txt
;; NS Records
decugniere.fr.	86400	IN	NS	desiree.ns.cloudflare.com.
decugniere.fr.	86400	IN	NS	dom.ns.cloudflare.com.
```


## DNS (Cloudflare)

Utilisé comme gestionnaire de DNS et Reverse Proxy

Créer un API Token qui permet à Caddy de modifier le DNS de la zone ``decugniere.fr`` pour créer et renouveler le certificat SSL letsencrypt via challenge ``DNS-01``

```txt
Token name : NextCloud/Caddy / Edit zone DNS  
Permissions : DNS:Edit
```

Modifier le DNS (``DNS record``) pour pointer sur l'IP fixe de la box SFR + cocher ```proxied```

```txt
;; A Records
decugniere.fr.	1	IN	A	78.xx.xx.xx ; cf_tags=cf-proxied:true
nextcloud.decugniere.fr.	1	IN	A	78.xx.xx.xx ; cf_tags=cf-proxied:true

;; CNAME Records
www.decugniere.fr.	1	IN	CNAME	decugniere.fr. ; cf_tags=cf-proxied:true
```

## Nextcloud
Solution de cloud personnel auto hebergée - alternative de Google Drive


## MariaDB
Base utilisée par Nextcloud

## Redis
Utilisé par Nextcloud pour le verrouillage des fichiers et le cache distribué.

## Caddy
Reverse proxy, gestion certificat SSL

```sh
# Verifier la configuration Caddy (avant démarrage)
docker compose run --rm caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Création des répertoires
```sh
sudo mkdir -p \
  /mnt/storage/nextcloud/config \
  /mnt/storage/nextcloud/data \
  /mnt/storage/nextcloud/custom_apps \
  /mnt/storage/nextcloud/db \
  /mnt/storage/nextcloud/redis \
  /mnt/storage/caddy/data \
  /mnt/storage/caddy/config
```

## Démarrage Containers
Créer le fichier .env 
```sh
# Example de fichier .env
EMAIL=email@gmail.com
NEXTCLOUD_TRUSTED_DOMAINS=nextcloud.decugniere.fr:8443
OVERWRITEHOST=nextcloud.decugniere.fr:8443
OVERWRITECLIURL=https://nextcloud.decugniere.fr:8443
MYSQL_ROOT_PASSWORD=<mysql_root_password>
MYSQL_PASSWORD=<mysql_password>
CLOUDFLARE_API_TOKEN=<cloudflare_api_token>
```

```sh
# Se placer sur le répertoire du docker-compose.yml
cd /home/franck/nextcloud@home

# Télécharger les containeurs
docker compose pull

# Recuperer les UIDs pour chaque containers

docker run --rm nextcloud:stable-apache id www-data
uid=33(www-data) gid=33(www-data) groups=33(www-data)

sudo chown -R 33:33 \
  /mnt/storage/nextcloud/config \
  /mnt/storage/nextcloud/data \
  /mnt/storage/nextcloud/custom_apps

sudo chmod 750 \
  /mnt/storage/nextcloud/config \
  /mnt/storage/nextcloud/data \
  /mnt/storage/nextcloud/custom_apps

docker run --rm mariadb:11.8 id mysql
uid=999(mysql) gid=999(mysql) groups=999(mysql)

docker run --rm redis:7-alpine id redis
uid=999(redis) gid=1000(redis) groups=1000(redis),1000(redis)

docker run --rm caddybuilds/caddy-cloudflare:latest id
uid=0(root) gid=0(root) groups=0(root),0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)


# Lancer les containeurs
docker compose up -d


# Verifier le statut des containers
docker compose ps

NAME              IMAGE                                 COMMAND                  SERVICE     CREATED      STATUS                PORTS
caddy             caddybuilds/caddy-cloudflare:latest   "caddy run --config …"   caddy       9 days ago   Up 9 days             80/tcp, 2019/tcp, 443/udp, 0.0.0.0:8443->443/tcp, [::]:8443->443/tcp
nextcloud         nextcloud:stable-apache               "/entrypoint.sh apac…"   nextcloud   9 days ago   Up 9 days             80/tcp
nextcloud-db      mariadb:11.8                          "docker-entrypoint.s…"   mariadb     9 days ago   Up 9 days (healthy)   3306/tcp
nextcloud-redis   redis:7-alpine                        "docker-entrypoint.s…"   redis       9 days ago   Up 9 days (healthy)   6379/tcp

# Voir les logs d'un containeur
docker logs -f caddy

```

## Reseau

2 réseaux Docker
- proxy (Caddy <=> Nextcloud)
- backend (Nextcloud <=> MariaDB)

```sh
route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         192.168.3.1     0.0.0.0         UG    100    0        0 enp2s0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0
172.18.0.0      0.0.0.0         255.255.0.0     U     0      0        0 br-6726e2cea293
172.28.0.0      0.0.0.0         255.255.0.0     U     0      0        0 br-19dd1daf19e0
172.30.0.0      0.0.0.0         255.255.255.0   U     0      0        0 br-9cc24ccfc53c
192.168.3.0     0.0.0.0         255.255.255.0   U     100    0        0 enp2s0

```

## Backup

Synchronisation one-way avec ``rclone sync`` d'un dump de la base MariaDB + config nextcloud + data utilisateurs.

Protection contre les suppressions accidentelles.

### Local (Vers Synology)

Création d'un compte ``nextcloud-backup`` et d'un dossier partagé ``nextcloud-backup`` sur le Synology

Sur le serveur, création de ``/mnt/backup-ds212``

Ajout dans ``/etc/fstab`` :
```sh
# /etc/fstab
//192.168.3.62/nextcloud-backup /mnt/backup-ds212 cifs credentials=/root/.smb-ds212,vers=2.0,iocharset=utf8,_netdev,nofail,x-systemd.automount 0 0

puis 

sudo systemctl daemon-reload
sudo mount /mnt/backup-ds212
```

Création du fichier ``/root/.smb-ds212`` avec id et mot de passe du compte ``nextcloud-backup``

```sh
sudo chmod 600 /root/.smb-ds212
-rw------- 1 root root 56 sept. 28 18:40 /root/.smb-ds212
```

Création du fichier ``/root/.nextcloud-backup.env`` pour stocker le mot de passe MariaDB pour le dump sql
```sh
sudo chmod 600 /root/.nextcloud-backup.env
```

Installer rclone
```sh
sudo apt install -y rclone
```

Arborescence de backup
```
sudo mkdir -p /mnt/backup-ds212/nextcloud/{files,database,deleted}

/mnt/backup-ds212/
└── nextcloud/
    ├── files/
    │   ├── config/
    │   ├── custom_apps/
    │   └── data/
    ├── database/
    └── deleted/
```

### Remote (vers Scalway Glacier)



# Commandes utiles
## Docker

```sh
# Arreter tous les containeurs
docker compose stop

# Arreter et supprimer tous les containeurs
docker compose down

# Prise en compte modification docker-compose.yml
docker compose up -d

# Afficher les 100 dernieres lignes de log
docker compose logs --tail=100 nextcloud
```


# Troubleshooting

```sh
# Vérifier que Caddy ecoute bien
sudo ss -lntp | grep 8443
LISTEN 0      4096         0.0.0.0:8443       0.0.0.0:*    users:(("docker-proxy",pid=338789,fd=8))
LISTEN 0      4096            [::]:8443          [::]:*    users:(("docker-proxy",pid=338794,fd=8))
```

```sh
# Test Caddy en local (bypass CloudFlare)
curl -vk --resolve nextcloud.decugniere.fr:8443:127.0.0.1   https://nextcloud.decugniere.fr:8443/
```