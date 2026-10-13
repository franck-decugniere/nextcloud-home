
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

###############################################################################
# CONFIGURATION
###############################################################################

SCRIPT_DIR="/usr/local/sbin/nextcloud-backup"

ENV_FILE="${SCRIPT_DIR}/.env"
EXCLUDE_FILE="${SCRIPT_DIR}/nextcloud-exclude.txt"

export RCLONE_CONFIG="${SCRIPT_DIR}/rclone.conf"

SOURCE="/mnt/storage/nextcloud"

DS212_MOUNT="/mnt/backup-ds212"
BACKUP="${DS212_MOUNT}/nextcloud"

LOG="/var/log/backup-nextcloud.log"
LOCK="/run/lock/nextcloud-backup.lock"

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"

SCW_REMOTE="scaleway"
SCW_BUCKET="nextcloud-backup"
SCW_PATH="nextcloud"

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

if [[ ! -r "$ENV_FILE" ]]; then
    echo "ERREUR : fichier absent ou illisible : $ENV_FILE" >&2
    exit 1
fi

source "$ENV_FILE"

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
    echo "Vérification du remote Scaleway..."

    if ! rclone lsd "${SCW_REMOTE}:" >/dev/null; then
        echo "ERREUR : remote Scaleway inaccessible."
        return 1
    fi

    # Vérifier que le bucket cible existe et est accessible.
    if ! rclone lsf "${SCW_REMOTE}:${SCW_BUCKET}" \
        --max-depth 1 >/dev/null; then
        echo "ERREUR : bucket Scaleway inaccessible : ${SCW_BUCKET}"
        return 1
    fi

    echo "Scaleway accessible."
}

backup_ds212() {
    echo
    echo "========== BACKUP VERS DS212 =========="

    if [[ ! -d "$SOURCE" ]]; then
        echo "ERREUR : source absente : $SOURCE"
        return 1
    fi

    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        echo "ERREUR : fichier d'exclusion absent : $EXCLUDE_FILE"
        return 1
    fi

    check_ds212

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
        --exclude-from "$EXCLUDE_FILE" \
        --backup-dir "$BACKUP/deleted/$DATE" \
        --create-empty-src-dirs \
        --modify-window 1s \
        --log-level INFO \
        --stats 30s

    echo "Backup DS212 terminé."
}

backup_scaleway() {
    echo
    echo "========== BACKUP VERS SCALEWAY GLACIER =========="

    # Scaleway utilise exclusivement le backup local déjà réalisé.
    check_ds212
    check_scaleway

    if [[ ! -d "$BACKUP/files" || ! -d "$BACKUP/database" ]]; then
        echo "ERREUR : backup DS212 incomplet ou absent."
        return 1
    fi

    echo "Copie des fichiers du DS212 vers Scaleway..."

    rclone copy \
        "$BACKUP/files" \
        "${SCW_REMOTE}:${SCW_BUCKET}/${SCW_PATH}/files" \
        --s3-storage-class GLACIER \
        --create-empty-src-dirs \
        --modify-window 1s \
        --log-level INFO \
        --stats 30s

    echo "Copie des dumps MariaDB vers Scaleway..."

    rclone copy \
        "$BACKUP/database" \
        "${SCW_REMOTE}:${SCW_BUCKET}/${SCW_PATH}/database" \
        --s3-storage-class GLACIER \
        --log-level INFO \
        --stats 30s

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
