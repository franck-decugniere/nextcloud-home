Solution locale de stockage cloud identique à Google Drive avec backup vers solution de stockage froid, à déployer sur un Ubuntu. 

Genere un docker compose pour nextcloud avec 

- reverse proxy pour SSL (caddy ?) 
- certificat letsencrypt automatique avec challenge DNS-01 chez Cloudflare (caddy ?) 
- database mariadb 
- /mnt/storage/nextcloud/data pour les données utilisateeurs 
- /mnt/storage/nextcloud/db pour mariadb 
- /mnt/storage/caddy/data pour les données caddy 
- /mnt/storage/caddy/config pour la configuration caddy 
- nextcloud accessible via https://nextcloud.decugniere.fr:8443 
- autoriser uniquement l'ip cloudflare (le trafic est proxifié)