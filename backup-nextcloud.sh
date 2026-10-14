#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

###############################################################################
# CONFIGURATION
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -r "$ENV_FILE" ]]; then
    echo "ERREUR : fichier absent ou illisible : $ENV_FILE" >&2
    exit 1
fi

source "$ENV_FILE"



DS212_EXCLUDE_FILE="${SCRIPT_DIR}/ds212-exclude.txt"
SCALEWAY_EXCLUDE_FILE="${SCRIPT_DIR}/scaleway-exclude.txt"


export RCLONE_CONFIG="${SCRIPT_DIR}/rclone.conf"

SOURCE="/mnt/storage/nextcloud"

DS212_MOUNT="/mnt/backup-ds212"
BACKUP="${DS212_MOUNT}/nextcloud"

LOG="/var/log/backup-nextcloud.log"
LOCK="/run/lock/nextcloud-backup.lock"

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"

SCW_REMOTE="${SCW_REMOTE:-scaleway}"
SCW_BUCKET="${SCW_BUCKET:-nextcloud-backup}"
SCW_PATH="${SCW_PATH:-nextcloud}"
SCW_STORAGE_CLASS="${SCW_STORAGE_CLASS:-GLACIER}"

export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"


###############################################################################
# AIDE ET PARAMETRE
###############################################################################

usage() {
    cat <<'EOF'
Usage :
  backup-nextcloud.sh ds212     Backup Nextcloud + dump MariaDB vers DS212
  backup-nextcloud.sh scaleway  Envoi du backup DS212 vers Scaleway Glacier
  backup-nextcloud.sh all       DS212 puis Scaleway
  backup-nextcloud.sh help      Affiche cette aide
EOF
}

MODE="${1:-all}"

case "$MODE" in
    ds212|scaleway|all)
        ;;
    help|-h|--help)
        usage
        exit 0
        ;;
    *)
        echo "ERREUR : mode inconnu : $MODE" >&2
        usage >&2
        exit 2
        ;;
esac

###############################################################################
# ENVIRONNEMENT ET JOURNALISATION
###############################################################################

# Utiliser explicitement le fichier de configuration rclone de root.
export RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"

exec >> "$LOG" 2>&1

echo
echo "=============================================================="
echo "Backup Nextcloud - mode=$MODE - $DATE"
echo "=============================================================="

###############################################################################
# VERROUILLAGE
###############################################################################

exec 9>"$LOCK"

if ! flock -n 9; then
    echo "ERREUR : un backup est déjà en cours."
    exit 1
fi

###############################################################################
# FONCTIONS
###############################################################################

check_ds212() {
    echo "Vérification du DS212..."

    if ! mountpoint -q "$DS212_MOUNT"; then
        echo "ERREUR : $DS212_MOUNT n'est pas monté."
        return 1
    fi

    local test_file="${DS212_MOUNT}/.backup-test-$$"

    if ! touch "$test_file"; then
        echo "ERREUR : impossible d'écrire sur le DS212."
        return 1
    fi

    rm -f "$test_file"
    echo "DS212 accessible."
}

check_scaleway() {

    local rclone_config="$1"

    echo "Vérification du remote Scaleway..."

    if ! rclone --config "$rclone_config" lsd "${SCW_REMOTE}:" >/dev/null; then
        echo "ERREUR : remote Scaleway inaccessible."
        return 1
    fi

    # Vérifier que le bucket cible existe et est accessible.
    if ! rclone --config "$rclone_config" lsf "${SCW_REMOTE}:${SCW_BUCKET}" \
        --max-depth 1 >/dev/null; then
        echo "ERREUR : bucket Scaleway inaccessible : ${SCW_BUCKET}"
        return 1
    fi

    echo "Scaleway accessible."
}

NEXTCLOUD_CONTAINER="nextcloud"
NEXTCLOUD_MAINTENANCE=0

nextcloud_maintenance_on() {
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$NEXTCLOUD_CONTAINER"; then
        echo "Conteneur $NEXTCLOUD_CONTAINER non démarré : pas de basculement en mode maintenance."
        return 0
    fi

    echo "Mise en mode maintenance Nextcloud..."
    if ! docker exec --user www-data "$NEXTCLOUD_CONTAINER" \
        php /var/www/html/occ maintenance:mode --on; then
        echo "ERREUR : impossible de mettre Nextcloud en mode maintenance."
        return 1
    fi

    NEXTCLOUD_MAINTENANCE=1
    echo "Nextcloud est désormais en mode maintenance."
}

nextcloud_maintenance_off() {
    if [[ "$NEXTCLOUD_MAINTENANCE" -ne 1 ]]; then
        return 0
    fi

    echo "Sortie du mode maintenance Nextcloud..."
    if ! docker exec --user www-data "$NEXTCLOUD_CONTAINER" \
        php /var/www/html/occ maintenance:mode --off; then
        echo "ATTENTION : impossible de sortir Nextcloud du mode maintenance."
        return 1
    fi

    NEXTCLOUD_MAINTENANCE=0
    echo "Nextcloud est de nouveau disponible."
}

cleanup_on_exit() {
    local exit_code=$?
    if [[ "$NEXTCLOUD_MAINTENANCE" -eq 1 ]]; then
        nextcloud_maintenance_off || true
    fi
    return "$exit_code"
}

trap cleanup_on_exit EXIT

backup_ds212() {
    echo
    echo "========== BACKUP VERS DS212 =========="

    if [[ ! -d "$SOURCE" ]]; then
        echo "ERREUR : source absente : $SOURCE"
        return 1
    fi

    if [[ ! -f "$DS212_EXCLUDE_FILE" ]]; then
        echo "ERREUR : fichier d'exclusion absent : $DS212_EXCLUDE_FILE"
        return 1
    fi

    check_ds212
    nextcloud_maintenance_on || return 1

    mkdir -p \
        "$BACKUP/files" \
        "$BACKUP/database" \
        "$BACKUP/deleted"

    # Dump MariaDB : fichier temporaire, puis validation avant conservation.
    local dump_tmp="${BACKUP}/database/.nextcloud-${DATE}.sql.gz.tmp"
    local dump_final="${BACKUP}/database/nextcloud-${DATE}.sql.gz"

    echo "Création du dump MariaDB..."

    if ! docker exec nextcloud-db \
        mariadb-dump \
        --single-transaction \
        --routines \
        --triggers \
        -u root \
        -p"${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD absent}" \
        nextcloud | gzip > "$dump_tmp"; then
        rm -f "$dump_tmp"
        echo "ERREUR : échec du dump MariaDB."
        return 1
    fi

    if ! gzip -t "$dump_tmp"; then
        rm -f "$dump_tmp"
        echo "ERREUR : dump MariaDB invalide."
        return 1
    fi

    mv "$dump_tmp" "$dump_final"
    echo "Dump MariaDB valide : $dump_final"

    # Ne conserver que les 7 dumps les plus récents.
    # Ce nettoyage intervient seulement après validation du nouveau dump.
    find "$BACKUP/database" -maxdepth 1 -type f \
        -name 'nextcloud-*.sql.gz' -printf '%T@ %p\n' |
        sort -nr |
        tail -n +8 |
        cut -d ' ' -f 2- |
        while IFS= read -r old_dump; do
            [[ -n "$old_dump" ]] && rm -f -- "$old_dump"
        done

    echo "Synchronisation des fichiers vers le DS212..."

    rclone sync \
        "$SOURCE" \
        "$BACKUP/files" \
        --exclude-from "$DS212_EXCLUDE_FILE" \
        --backup-dir "$BACKUP/deleted/$DATE" \
        --create-empty-src-dirs \
        --modify-window 1s \
        --log-level INFO \
        --stats 30s

    echo "Backup DS212 terminé."
}

rclone_config_scaleway() {
    cat <<EOF
[${SCW_REMOTE}]
type = s3
provider = Scaleway
env_auth = true
region = ${SCW_REGION}
endpoint = ${SCW_ENDPOINT}
acl = private
EOF
}

backup_scaleway() {
    echo
    echo "========== BACKUP VERS SCALEWAY GLACIER =========="

    # Configuration temporaire rclone
    local rclone_tmp
    rclone_tmp="$(mktemp)"
    chmod 600 "$rclone_tmp"
    rclone_config_scaleway > "$rclone_tmp"
	
    echo "$rclone_tmp"

    # Scaleway utilise exclusivement le backup local déjà réalisé.
    check_ds212
    check_scaleway "$rclone_tmp"

    if [[ ! -d "$BACKUP/files" || ! -d "$BACKUP/database" ]]; then
        echo "ERREUR : backup DS212 incomplet ou absent."
        return 1
    fi

    echo "Copie des fichiers du DS212 vers Scaleway..."

    rclone sync \
        "$BACKUP/files" \
        "${SCW_REMOTE}:${SCW_BUCKET}/${SCW_PATH}/files" \
	--exclude-from "$SCALEWAY_EXCLUDE_FILE" \
	--no-update-modtime \
        --s3-storage-class "$SCW_STORAGE_CLASS" \
        --create-empty-src-dirs \
        --log-level INFO \
        --stats 30s \
        --config "$rclone_tmp"

    echo "Copie des dumps MariaDB vers Scaleway..."

    rclone sync \
        "$BACKUP/database" \
        "${SCW_REMOTE}:${SCW_BUCKET}/${SCW_PATH}/database" \
	--exclude-from "$SCALEWAY_EXCLUDE_FILE" \
	--no-update-modtime \
	--s3-storage-class "$SCW_STORAGE_CLASS" \
        --log-level INFO \
        --stats 30s \
        --config "$rclone_tmp"

    rm -f "$rclone_tmp"

    echo "Copie Scaleway terminée."
}

###############################################################################
# EXECUTION
###############################################################################

case "$MODE" in
    ds212)
        backup_ds212
        ;;
    scaleway)
        backup_scaleway
        ;;
    all)
        # Si le backup DS212 échoue, set -e arrête le script :
        # Scaleway ne sera pas lancé.
        backup_ds212
        backup_scaleway
        ;;
esac

echo
echo "=============================================================="
echo "SUCCES : mode=$MODE - $DATE"
echo "=============================================================="
