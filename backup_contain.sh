#!/bin/bash

# 📌 Configuración - Edita estas variables antes de ejecutar
ODOO_DB="your_database_name"              # Nombre de la base de datos
ODOO_USER="your_db_user"                  # Usuario de la base de datos
PG_CONTAINER="your_postgres_container"    # Nombre del contenedor PostgreSQL
ODOO_CONTAINER="your_odoo_container"      # Nombre del contenedor Odoo
BACKUP_DIR="$HOME/odoo_backups"           # Carpeta donde se guardarán los backups
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")        # Marca de tiempo
BACKUP_FILE="${BACKUP_DIR}/${ODOO_DB}_${TIMESTAMP}.zip"
LOG_FILE="${BACKUP_DIR}/backup.log"       # Archivo de log

# 🚀 Asegurar que el directorio de backups existe
mkdir -p "$BACKUP_DIR"

# 🌍 Verificar si los contenedores están corriendo
if ! docker ps --format '{{.Names}}' | grep -q "$ODOO_CONTAINER"; then
    echo "❌ ERROR: El contenedor Odoo ($ODOO_CONTAINER) no está corriendo." | tee -a "$LOG_FILE"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "$PG_CONTAINER"; then
    echo "❌ ERROR: El contenedor PostgreSQL ($PG_CONTAINER) no está corriendo." | tee -a "$LOG_FILE"
    exit 1
fi

# 1️⃣ Backup de la base de datos
echo "📀 Iniciando backup de la base de datos..." | tee -a "$LOG_FILE"
docker exec -t "$PG_CONTAINER" pg_dump -U "$ODOO_USER" -F p -b -v -f "/tmp/dump.sql" "$ODOO_DB"
if [ $? -ne 0 ]; then
    echo "❌ ERROR: No se pudo realizar el backup de la base de datos." | tee -a "$LOG_FILE"
    exit 1
fi

# Copiar dump.sql al directorio de backups en el host
docker cp "$PG_CONTAINER:/tmp/dump.sql" "$BACKUP_DIR/"
docker exec "$PG_CONTAINER" rm "/tmp/dump.sql"

# Verificar que el archivo dump.sql existe y tiene contenido
if [ ! -s "${BACKUP_DIR}/dump.sql" ]; then
    echo "❌ ERROR: El archivo dump.sql no se generó correctamente." | tee -a "$LOG_FILE"
    exit 1
fi
echo "✅ Backup de la base de datos completado." | tee -a "$LOG_FILE"

# 2️⃣ Copia del filestore
echo "📂 Copiando filestore..." | tee -a "$LOG_FILE"
docker cp "$ODOO_CONTAINER:/var/lib/odoo/.local/share/Odoo/filestore" "$BACKUP_DIR/"
if [ $? -ne 0 ]; then
    echo "⚠️ ADVERTENCIA: No se encontró el filestore, es posible que no haya archivos adjuntos." | tee -a "$LOG_FILE"
else
    echo "✅ Filestore copiado correctamente." | tee -a "$LOG_FILE"
fi

# 3️⃣ Generar el archivo manifest.json
echo "📜 Generando manifest.json..." | tee -a "$LOG_FILE"
docker exec "$ODOO_CONTAINER" bash -c "psql -h '$PG_CONTAINER' -U '$ODOO_USER' -d '$ODOO_DB' -t -c '
COPY (
    SELECT row_to_json(t) FROM (
        SELECT 
            (SELECT array_agg(name) FROM ir_module_module WHERE state=''installed'') AS modules
    ) t
) TO STDOUT;'" > "${BACKUP_DIR}/manifest.json"

if [ ! -s "${BACKUP_DIR}/manifest.json" ]; then
    echo "❌ ERROR: No se pudo generar el archivo manifest.json o está vacío." | tee -a "$LOG_FILE"
    exit 1
fi
echo "✅ Archivo manifest.json generado correctamente." | tee -a "$LOG_FILE"

# 4️⃣ Empaquetar en ZIP
echo "📦 Comprimiendo backup..." | tee -a "$LOG_FILE"
cd "$BACKUP_DIR"
zip -r "$BACKUP_FILE" "filestore" "manifest.json" "dump.sql"
cd -

if [ $? -ne 0 ]; then
    echo "❌ ERROR: No se pudo comprimir el backup." | tee -a "$LOG_FILE"
    exit 1
fi
echo "✅ Backup completado exitosamente: $BACKUP_FILE" | tee -a "$LOG_FILE"

# 5️⃣ Limpiar archivos temporales
echo "🧹 Eliminando archivos temporales..." | tee -a "$LOG_FILE"
rm -rf "$BACKUP_DIR/filestore" "$BACKUP_DIR/manifest.json" "$BACKUP_DIR/dump.sql"

exit 0
